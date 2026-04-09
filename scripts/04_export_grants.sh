#!/bin/sh
# MySQL -> MariaDB 移行検証: ユーザー権限エクスポート
#
# 実行: sh scripts/04_export_grants.sh
# 前提: config.env の SRC_* に旧DB(MySQL)の接続情報を設定済み
# 出力: grants/grants.sql (GRANT文一覧)
#
# MySQL5.0互換: mysql.userテーブルから直接ユーザー一覧を取得し、
# SHOW GRANTS FOR で各ユーザーの権限をSQL形式で出力する。
# root@localhostおよびホスト未指定の空ユーザーはスキップする。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

GRANTS_DIR="grants"
GRANTS_FILE="$GRANTS_DIR/grants.sql"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

src_mysql() {
    mysql -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -p"$SRC_PASS" "$@" 2>/dev/null
}

# コマンド存在チェック
if ! command -v mysql >/dev/null 2>&1; then
    log "エラー: mysql コマンドが見つかりません"
    exit 1
fi

# 接続テスト
log "接続テスト: $SRC_HOST:$SRC_PORT"
if ! mysql -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -p"$SRC_PASS" -e "SELECT 1" >/dev/null 2>&1; then
    log "エラー: MySQLに接続できません"
    log "  ホスト: $SRC_HOST"
    log "  ポート: $SRC_PORT"
    log "  ユーザー: $SRC_USER"
    log "config.env の SRC_* 設定を確認してください"
    exit 1
fi
log "接続OK"

# 出力ディレクトリ準備
mkdir -p "$GRANTS_DIR"

# ユーザー一覧取得(user@host形式)
# MySQL5.0互換: INFORMATION_SCHEMAではなくmysql.userを直接参照
log "ユーザー一覧取得"
user_list=$(src_mysql -N -e "SELECT CONCAT(user, '@', host) FROM mysql.user ORDER BY user, host")

if [ -z "$user_list" ]; then
    log "エラー: ユーザーが取得できませんでした"
    exit 1
fi

total=$(printf "%s\n" "$user_list" | wc -l | tr -d ' ')
log "ユーザー数: ${total}"

# GRANT文エクスポート
log "権限エクスポート開始"
current=0
exported=0
skipped=0

{
    echo "-- MySQL権限エクスポート"
    echo "-- リストア元: ${SRC_HOST}:${SRC_PORT}"
    echo "-- エクスポート日時: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "-- "
    echo "-- 適用方法: mysql -h HOST -P PORT -u root -p < ${GRANTS_FILE}"
    printf "\n"
} > "$GRANTS_FILE"

tmp_user_list=$(mktemp)
printf "%s\n" "$user_list" > "$tmp_user_list"

while IFS= read -r user_host; do
    current=$((current + 1))
    user=$(echo "$user_host" | sed 's/@.*//')
    host=$(echo "$user_host" | sed 's/.*@//')

    # 空ユーザー(匿名ユーザー)はスキップ
    if [ -z "$user" ]; then
        log "  [${current}/${total}] (anonymous)@${host}: スキップ(匿名ユーザー)"
        skipped=$((skipped + 1))
        continue
    fi

    # SHOW GRANTS実行
    grants=$(src_mysql -N -e "SHOW GRANTS FOR '${user}'@'${host}'" 2>/dev/null) || {
        log "  [${current}/${total}] ${user}@${host}: スキップ(SHOW GRANTS失敗)"
        skipped=$((skipped + 1))
        continue
    }

    if [ -n "$grants" ]; then
        {
            echo "-- ${user}@${host}"
            printf "%s\n" "$grants" | while IFS= read -r grant_line; do
                printf "%s;\n" "$grant_line"
            done
            printf "\n"
        } >> "$GRANTS_FILE"
        log "  [${current}/${total}] ${user}@${host}: エクスポート完了"
        exported=$((exported + 1))
    fi
done < "$tmp_user_list"

rm -f "$tmp_user_list"

log ""
log "============================="
log "権限エクスポート完了"
log "  出力: $GRANTS_FILE"
log "  エクスポート: ${exported}ユーザー"
log "  スキップ: ${skipped}ユーザー"
log "============================="
log ""
log "リストア先への適用:"
log "  mysql -h \$DST_HOST -P \$DST_PORT -u root -p < $GRANTS_FILE"
log "  適用後: FLUSH PRIVILEGES;"
log ""
log "注意: root権限やリストア先固有のユーザーは"
log "  適用前に手動で確認・編集してください"
