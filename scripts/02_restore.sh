#!/bin/sh
# MySQL -> MariaDB 移行検証: リストア
#
# 実行: sh scripts/02_restore.sh
# 前提: 01_dump_and_snapshot.sh でダンプ取得済み
#        config.env の DST_* に新DB(MariaDB)の接続情報を設定済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

# config.env後方互換: 古いconfig.envに無い場合のデフォルト
: "${TARGET_DBS:=--all}"
: "${DUMP_DIR:=dump}"
: "${RESTORE_STATE_DIR:=restore_state}"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$@" 2>/dev/null
}

resolve_databases() {
    if [ "$TARGET_DBS" = "--all" ]; then
        # ダンプディレクトリ内の.sqlファイル名からDB名を取得
        # (01_dump_and_snapshot.sh 時点でシステムDBは除外済み)
        resolved=""
        for f in "$DUMP_DIR"/*.sql; do
            [ -f "$f" ] || continue
            db=$(basename "$f" .sql)
            resolved="$resolved $db"
        done
        echo "$resolved" | sed 's/^ //'
    else
        echo "$TARGET_DBS"
    fi
}

# コマンド存在チェック
if ! command -v mysql >/dev/null 2>&1; then
    log "エラー: mysql コマンドが見つかりません"
    exit 1
fi

# ダンプディレクトリ存在チェック
if [ ! -d "$DUMP_DIR" ]; then
    log "エラー: ダンプディレクトリが見つかりません: $DUMP_DIR"
    log "先に 01_dump_and_snapshot.sh を実行してください"
    exit 1
fi

# 接続テスト
log "接続テスト: $DST_HOST:$DST_PORT"
if ! mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    log "エラー: MariaDBに接続できません"
    log "  ホスト: $DST_HOST"
    log "  ポート: $DST_PORT"
    log "  ユーザー: $DST_USER"
    log "config.env の DST_* 設定を確認してください"
    exit 1
fi
log "接続OK"

# 文字セットチェック
dst_charset=$(dst_mysql -N -e "SELECT @@character_set_server")
dst_version=$(dst_mysql -N -e "SELECT @@version")
# MariaDBバージョンからメジャー.マイナーを抽出(例: "11.4.10-MariaDB" -> "11.4")
dst_major_minor=$(echo "$dst_version" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
log "リストア先: MariaDB $dst_version (文字セット: $dst_charset)"

FORCE_UTF8MB3=0

if [ "$dst_charset" = "utf8mb4" ]; then
    # MariaDB10.3以降はinnodb_large_prefixが常にON(インデックス上限3072bytes)
    # utf8mb4でもVARCHAR(255)=1020bytesで問題なし
    major=$(echo "$dst_major_minor" | cut -d. -f1)
    minor=$(echo "$dst_major_minor" | cut -d. -f2)
    safe=0
    if [ "$major" -gt 10 ]; then
        safe=1
    elif [ "$major" -eq 10 ] && [ "$minor" -ge 3 ]; then
        safe=1
    fi

    if [ "$safe" -eq 1 ]; then
        log "  MariaDB ${dst_major_minor} -> innodb_large_prefix常時ON(上限3072bytes)、utf8mb4で問題なし"
    else
        log ""
        log "警告: リストア先のデフォルト文字セットが utf8mb4 です"
        log "  MariaDB ${dst_major_minor} はinnodb_large_prefixがデフォルトOFFの可能性があり"
        log "  ERROR 1071: Specified key was too long が発生する可能性があります"
        log ""
        printf "utf8mb3を指定してリストアを続行しますか? [y/N]: "
        read -r charset_answer
        case "$charset_answer" in
            [yY])
                FORCE_UTF8MB3=1
                log "utf8mb3を指定してリストアします"
                ;;
            *)
                log "中断しました"
                log "リストア先のmy.cnfで以下を設定してください:"
                log "  [mysqld]"
                log "  character-set-server = utf8"
                log "  collation-server = utf8_general_ci"
                exit 0
                ;;
        esac
    fi
fi

# 対象DB一覧を解決
databases=$(resolve_databases)
if [ -z "$databases" ]; then
    log "エラー: リストア対象のダンプファイルがありません"
    exit 1
fi
db_count=$(echo "$databases" | wc -w | tr -d ' ')

# リストア前の確認
log "============================="
log "リストア先情報:"
log "  ホスト: $DST_HOST:$DST_PORT"
log "  ユーザー: $DST_USER"
log "  対象DB (${db_count}件): $databases"
log "============================="
printf "リストアを実行しますか? [y/N]: "
read -r answer
case "$answer" in
    [yY]) ;;
    *)
        log "中断しました"
        exit 0
        ;;
esac

# ロールバック用の状態ファイルを準備
# 05_rollback.sh が読むファイル: リストアで"新規作成"したDBのみを記録する。
# 既にDST側に存在していたDBは記録しない=ロールバック対象外となる(既存データを保護)。
mkdir -p "$RESTORE_STATE_DIR"
created_dbs_file="$RESTORE_STATE_DIR/created_dbs.txt"
[ -f "$created_dbs_file" ] || : > "$created_dbs_file"

db_current=0
for db in $databases; do
    db_current=$((db_current + 1))
    dump_file="$DUMP_DIR/${db}.sql"

    if [ ! -f "$dump_file" ]; then
        log "[${db_current}/${db_count}] $db: ダンプファイルなし、スキップ"
        continue
    fi

    log ""
    log "========== [${db_current}/${db_count}] データベース: $db =========="

    # ロールバック対象判定: DST未存在のDBはcreated_dbs.txtに記録
    db_exists=$(dst_mysql -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db'")
    if [ -z "$db_exists" ]; then
        if ! grep -Fxq -- "$db" "$created_dbs_file"; then
            echo "$db" >> "$created_dbs_file"
        fi
        log "新規DB(ロールバック対象として記録)"
    else
        log "既存DB(ロールバック対象外)"
    fi

    # DB作成(存在しなければ)
    log "データベース作成: $db"
    if [ "$FORCE_UTF8MB3" -eq 1 ]; then
        dst_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8 COLLATE utf8_general_ci"
        # 既存DBの場合もutf8mb3に変更
        dst_mysql -e "ALTER DATABASE \`$db\` CHARACTER SET utf8 COLLATE utf8_general_ci"
    else
        dst_mysql -e "CREATE DATABASE IF NOT EXISTS \`$db\`"
    fi

    # リストア実行
    log "リストア開始: $dump_file -> $db"
    if [ "$FORCE_UTF8MB3" -eq 1 ]; then
        # utf8mb4によるインデックスサイズ超過を防止
        { echo "SET NAMES utf8;"; cat "$dump_file"; } | dst_mysql "$db"
    else
        dst_mysql "$db" < "$dump_file"
    fi
    log "リストア完了"

    # リストア後の基本チェック
    log "リストア後テーブル一覧:"
    tables=$(dst_mysql "$db" -N -e "SHOW TABLES")
    for table in $tables; do
        count=$(dst_mysql "$db" -N -e "SELECT COUNT(*) FROM \`$table\`")
        log "  $table: ${count}件"
    done
done

log ""
log "============================="
log "全リストア完了"
log "次のステップ: sh scripts/03_verify.sh"
log "============================="
