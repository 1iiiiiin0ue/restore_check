#!/bin/sh
# MySQL -> MariaDB 移行検証: リストア
#
# 実行: sh scripts/02_restore.sh
# 前提: 01_dump_and_snapshot.sh でダンプ取得済み
#        config.env の DST_* に新DB(MariaDB)の接続情報を設定済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

# config.env後方互換: 古いconfig.envにRESTORE_STATE_DIRが無い場合のデフォルト
: "${RESTORE_STATE_DIR:=restore_state}"

SYSTEM_DBS="information_schema mysql performance_schema sys"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$@" 2>/dev/null
}

is_system_db() {
    local db="$1"
    for sdb in $SYSTEM_DBS; do
        if [ "$db" = "$sdb" ]; then
            return 0
        fi
    done
    return 1
}

resolve_databases() {
    if [ "$TARGET_DBS" = "--all" ]; then
        # リストア時はダンプディレクトリ内の.sqlファイルからDB名を取得
        resolved=""
        for f in "$DUMP_DIR"/*.sql; do
            [ -f "$f" ] || continue
            db=$(basename "$f" .sql)
            if ! is_system_db "$db"; then
                resolved="$resolved $db"
            fi
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

# リストア前の既存DB一覧を保存(ロールバック時に保護すべきDBを判別するため)
# 初回のみ記録し、再実行時は既存ファイルを維持する。
# 再実行時に上書きすると、初回リストアで作成したDBが"リストア前に存在"と誤記録され、
# ロールバックで保護対象になりDROPされなくなる。
mkdir -p "$RESTORE_STATE_DIR"
pre_restore_file="$RESTORE_STATE_DIR/pre_restore_dbs.txt"
if [ -f "$pre_restore_file" ]; then
    log "リストア前DB一覧は既存のものを使用: $pre_restore_file"
    log "  (リセットするには $RESTORE_STATE_DIR/ を削除してから再実行)"
else
    {
        echo "# リストア前に存在していたユーザDB一覧"
        echo "# 作成日時: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# リストア先: ${DST_HOST}:${DST_PORT}"
        dst_mysql -N -e "SHOW DATABASES" | while IFS= read -r existing_db; do
            if ! is_system_db "$existing_db"; then
                echo "$existing_db"
            fi
        done
    } > "$pre_restore_file"
    log "リストア前DB一覧を保存: $pre_restore_file"
fi

# リストア対象DBを状態ファイルに追記(ロールバック時の対象解決に使用)
# dumpディレクトリ変化に影響されないよう、実リストア対象をここに固定記録する。
restored_dbs_file="$RESTORE_STATE_DIR/restored_dbs.txt"
if [ ! -f "$restored_dbs_file" ]; then
    {
        echo "# 02_restore.shでリストア対象にしたDB一覧(重複排除)"
        echo "# 初回作成日時: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# リストア先: ${DST_HOST}:${DST_PORT}"
    } > "$restored_dbs_file"
fi
for db in $databases; do
    if ! grep -v '^#' "$restored_dbs_file" | grep -Fxq -- "$db"; then
        echo "$db" >> "$restored_dbs_file"
    fi
done
log "リストア対象DB一覧を記録: $restored_dbs_file"

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
