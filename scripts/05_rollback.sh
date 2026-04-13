#!/bin/sh
# MySQL -> MariaDB 移行検証: リストアロールバック
#
# 実行: sh scripts/05_rollback.sh [--force]
# 前提: 02_restore.sh 実行済み(restore_state/ に状態ファイルが存在する)
#
# 挙動:
#   restored_dbs.txt に記録されたリストア対象DBのうち、
#   リストア前に存在しなかったものだけを DROP DATABASE する。
#   リストア前から存在していたDBは既定ではスキップ(既存データ保護のため)。
#   --force 指定時はリストア前から存在していたDBも DROP する。
#   完了後は状態ファイルを自動削除する。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

FORCE=0

# 引数解析
for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=1
            ;;
        *)
            printf "不明な引数: %s\n" "$arg" >&2
            printf "使用法: sh scripts/05_rollback.sh [--force]\n" >&2
            exit 1
            ;;
    esac
done

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$@" 2>/dev/null
}

# リストア前DB一覧に含まれるか判定
was_pre_existing() {
    local db="$1"
    local state_file="$2"
    [ -f "$state_file" ] || return 1
    # コメント行除外で完全一致検索
    grep -v '^#' "$state_file" | grep -Fxq -- "$db"
}

# コマンド存在チェック
if ! command -v mysql >/dev/null 2>&1; then
    log "エラー: mysql コマンドが見つかりません"
    exit 1
fi

# 状態ファイルチェック
pre_restore_file="$RESTORE_STATE_DIR/pre_restore_dbs.txt"
restored_dbs_file="$RESTORE_STATE_DIR/restored_dbs.txt"
if [ ! -f "$pre_restore_file" ] || [ ! -f "$restored_dbs_file" ]; then
    log "エラー: リストア状態ファイルが見つかりません"
    log "  必要: $pre_restore_file"
    log "  必要: $restored_dbs_file"
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

# 対象DB解決(restored_dbs.txtから読み込み)
databases=$(grep -v '^#' "$restored_dbs_file" | grep -v '^[[:space:]]*$' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [ -z "$databases" ]; then
    log "エラー: 対象DBが記録されていません: $restored_dbs_file"
    exit 1
fi

# ロールバック対象の分類
drop_list=""
skip_list=""
notfound_list=""

for db in $databases; do
    # information_schemaで完全一致判定(SHOW DATABASES LIKE はワイルドカードを解釈するため使用不可)
    exists=$(dst_mysql -N -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$db'")
    if [ -z "$exists" ]; then
        notfound_list="$notfound_list $db"
        continue
    fi

    if was_pre_existing "$db" "$pre_restore_file"; then
        if [ "$FORCE" -eq 1 ]; then
            drop_list="$drop_list $db"
        else
            skip_list="$skip_list $db"
        fi
    else
        drop_list="$drop_list $db"
    fi
done

drop_list=$(echo "$drop_list" | sed 's/^ //')
skip_list=$(echo "$skip_list" | sed 's/^ //')
notfound_list=$(echo "$notfound_list" | sed 's/^ //')

# 実行計画表示
log "============================="
log "ロールバック計画:"
log "  リストア先: $DST_HOST:$DST_PORT"
log "  --force: $([ "$FORCE" -eq 1 ] && echo "有効" || echo "無効")"
log ""
if [ -n "$drop_list" ]; then
    log "  DROP対象: $drop_list"
else
    log "  DROP対象: (なし)"
fi
if [ -n "$skip_list" ]; then
    log "  保護(リストア前から存在): $skip_list"
    log "    -> --force 指定で強制DROP可能"
fi
if [ -n "$notfound_list" ]; then
    log "  未存在(スキップ): $notfound_list"
fi
log "============================="

if [ -z "$drop_list" ]; then
    log "DROP対象がありません。終了します。"
    exit 0
fi

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
drop_count=$(echo "$drop_list" | wc -w | tr -d ' ')
current=0
for db in $drop_list; do
    current=$((current + 1))
    log "[${current}/${drop_count}] DROP DATABASE: $db"
    dst_mysql -e "DROP DATABASE IF EXISTS \`$db\`"
done

# 状態ファイルを削除(次回02_restore.shで現在のDST状態を再スナップショット)
rm -f "$pre_restore_file" "$restored_dbs_file"
log "リストア状態ファイルを削除: $pre_restore_file, $restored_dbs_file"

log ""
log "============================="
log "ロールバック完了 (${drop_count}件 DROP)"
log "============================="
