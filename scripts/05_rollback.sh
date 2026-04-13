#!/bin/sh
# MySQL -> MariaDB 移行検証: リストアロールバック
#
# 実行: sh scripts/05_rollback.sh
# 前提: 02_restore.sh 実行済み(restore_state/created_dbs.txt が存在する)
#
# 挙動:
#   02_restore.sh がリストアで新規作成したDBを全てDROPする。
#   リストア前から存在していたDBは created_dbs.txt に記録されていないため
#   このスクリプトは一切触らない(既存データを保護)。
#   完了後は状態ファイルを自動削除する。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

# config.env後方互換: 古いconfig.envにRESTORE_STATE_DIRが無い場合のデフォルト
: "${RESTORE_STATE_DIR:=restore_state}"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$@" 2>/dev/null
}

# コマンド存在チェック
if ! command -v mysql >/dev/null 2>&1; then
    log "エラー: mysql コマンドが見つかりません"
    exit 1
fi

# 状態ファイルチェック
created_dbs_file="$RESTORE_STATE_DIR/created_dbs.txt"
if [ ! -f "$created_dbs_file" ]; then
    log "エラー: 状態ファイルが見つかりません: $created_dbs_file"
    log "先に 02_restore.sh を実行してください"
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

# 対象DB読み込み
databases=$(xargs < "$created_dbs_file")
if [ -z "$databases" ]; then
    log "状態ファイルは空です。ロールバック対象なし。"
    rm -f "$created_dbs_file"
    exit 0
fi

db_count=$(echo "$databases" | wc -w | tr -d ' ')

# 実行計画表示
log "============================="
log "ロールバック計画:"
log "  リストア先: $DST_HOST:$DST_PORT"
log "  DROP対象 (${db_count}件): $databases"
log "============================="

printf "上記DBを DROP しますか? [y/N]: "
read -r answer
case "$answer" in
    [yY]) ;;
    *)
        log "中断しました"
        exit 0
        ;;
esac

# DROP実行
current=0
for db in $databases; do
    current=$((current + 1))
    log "[${current}/${db_count}] DROP DATABASE: $db"
    dst_mysql -e "DROP DATABASE IF EXISTS \`$db\`"
done

# 状態ファイルを削除(次回02_restore.shで再作成される)
rm -f "$created_dbs_file"
log "状態ファイルを削除: $created_dbs_file"

log ""
log "============================="
log "ロールバック完了 (${db_count}件 DROP)"
log "============================="
