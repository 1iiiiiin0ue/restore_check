#!/bin/sh
# MySQL -> MariaDB 移行検証: リストア
#
# 実行: sh scripts/02_restore.sh
# 前提: 01_dump_and_snapshot.sh でダンプ取得済み
#        config.env の DST_* に新DB(MariaDB)の接続情報を設定済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

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
log "リストア先の文字セット: $dst_charset"

if [ "$dst_charset" = "utf8mb4" ]; then
    log ""
    log "警告: リストア先のデフォルト文字セットが utf8mb4 です"
    log "  MySQL5.0(utf8mb3)のダンプをそのままリストアすると"
    log "  ERROR 1071: Specified key was too long が発生する可能性があります"
    log ""
    log "対処方法:"
    log "  1) リストア先のデフォルトを utf8mb3 に変更する(推奨)"
    log "  2) このまま続行する(各DBにCHARACTER SET utf8を指定してリストア)"
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
else
    FORCE_UTF8MB3=0
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
