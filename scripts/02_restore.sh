#!/bin/sh
# MySQL -> MariaDB 移行検証: リストア
#
# 実行: sh scripts/02_restore.sh
# 前提: 01_dump_and_snapshot.sh でダンプ取得済み
#        config.env の DST_* に新DB(MariaDB)の接続情報を設定済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$@" 2>&1 \
        | grep -v "^\[Warning\].*password"
}

# コマンド存在チェック
if ! command -v mysql >/dev/null 2>&1; then
    log "エラー: mysql コマンドが見つかりません"
    exit 1
fi

# ダンプファイル存在チェック
if [ ! -f "$DUMP_FILE" ]; then
    log "エラー: ダンプファイルが見つかりません: $DUMP_FILE"
    log "先に 01_dump_and_snapshot.sh を実行してください"
    exit 1
fi

# 接続テスト
log "接続テスト: $DST_HOST:$DST_PORT"
if ! dst_mysql -e "SELECT 1" >/dev/null; then
    log "エラー: MariaDBに接続できません"
    log "  ホスト: $DST_HOST"
    log "  ポート: $DST_PORT"
    log "  ユーザー: $DST_USER"
    log "config.env の DST_* 設定を確認してください"
    exit 1
fi
log "接続OK"

# リストア前の確認
log "============================="
log "リストア先情報:"
log "  ホスト: $DST_HOST:$DST_PORT"
log "  DB: $DST_DB"
log "  ユーザー: $DST_USER"
log "  ダンプ: $DUMP_FILE ($(wc -c < "$DUMP_FILE") bytes)"
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

# DB作成(存在しなければ)
log "データベース作成: $DST_DB"
dst_mysql -e "CREATE DATABASE IF NOT EXISTS \`$DST_DB\`"

# リストア実行
log "リストア開始: $DUMP_FILE -> $DST_DB"
dst_mysql "$DST_DB" < "$DUMP_FILE"
log "リストア完了"

# リストア後の基本チェック
log "============================="
log "リストア後テーブル一覧:"
tables=$(dst_mysql "$DST_DB" -N -e "SHOW TABLES")
for table in $tables; do
    count=$(dst_mysql "$DST_DB" -N -e "SELECT COUNT(*) FROM \`$table\`")
    log "  $table: ${count}件"
done
log "============================="
log "次のステップ: sh scripts/03_verify.sh"
