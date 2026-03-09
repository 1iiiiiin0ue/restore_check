#!/bin/sh
# MySQL -> MariaDB 移行検証: ダンプ + スナップショット取得
#
# 実行: sh scripts/01_dump_and_snapshot.sh
# 前提: config.env の SRC_* に旧DB(MySQL)の接続情報を設定済み
# 出力: dump.sql, snapshot/counts.tsv, snapshot/samples/*.tsv
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

src_mysql() {
    mysql -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -p"$SRC_PASS" "$@" 2>&1 \
        | grep -v "^\[Warning\].*password"
}

get_tables() {
    src_mysql "$SRC_DB" -N -e "SHOW TABLES"
}

get_primary_key() {
    local table="$1"
    src_mysql "$SRC_DB" -N -e "
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$SRC_DB'
          AND TABLE_NAME = '$table'
          AND COLUMN_KEY = 'PRI'
        ORDER BY ORDINAL_POSITION
        LIMIT 1
    "
}

# コマンド存在チェック
for cmd in mysql mysqldump diff sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "エラー: $cmd コマンドが見つかりません"
        exit 1
    fi
done

# 接続テスト
log "接続テスト: $SRC_HOST:$SRC_PORT ($SRC_DB)"
if ! src_mysql "$SRC_DB" -e "SELECT 1" >/dev/null; then
    log "エラー: MySQLに接続できません"
    log "  ホスト: $SRC_HOST"
    log "  ポート: $SRC_PORT"
    log "  ユーザー: $SRC_USER"
    log "  DB: $SRC_DB"
    log "config.env の SRC_* 設定を確認してください"
    exit 1
fi
log "接続OK"

# ダンプ取得
log "mysqldump開始: $SRC_DB"
mysqldump \
    -h "$SRC_HOST" -P "$SRC_PORT" \
    -u "$SRC_USER" -p"$SRC_PASS" \
    --single-transaction \
    --routines \
    --triggers \
    "$SRC_DB" 2>&1 | grep -v "^\[Warning\].*password" > "$DUMP_FILE"

if [ ! -s "$DUMP_FILE" ]; then
    log "エラー: ダンプファイルが空です"
    exit 1
fi
log "mysqldump完了: $DUMP_FILE ($(wc -c < "$DUMP_FILE") bytes)"

# スナップショットディレクトリ準備
rm -rf "$SNAPSHOT_DIR"
mkdir -p "$SNAPSHOT_DIR/samples"

# テーブル一覧取得
tables=$(get_tables)
table_count=$(printf "%s\n" "$tables" | wc -l | tr -d ' ')
log "対象テーブル数: ${table_count}"

# 件数スナップショット
log "件数スナップショット取得開始"
current=0
for table in $tables; do
    current=$((current + 1))
    count=$(src_mysql "$SRC_DB" -N -e "SELECT COUNT(*) FROM \`$table\`")
    printf "%s\t%s\n" "$table" "$count"
    log "  [${current}/${table_count}] $table: ${count}件"
done > "$SNAPSHOT_DIR/counts.tsv"
log "件数スナップショット完了: $SNAPSHOT_DIR/counts.tsv"

# サンプルレコードスナップショット
log "サンプルレコード取得開始 (先頭${SAMPLE_ROWS}件 + 末尾${SAMPLE_ROWS}件)"
current=0
for table in $tables; do
    current=$((current + 1))
    pk=$(get_primary_key "$table")
    if [ -z "$pk" ]; then
        src_mysql "$SRC_DB" -N -e "SELECT * FROM \`$table\` LIMIT $SAMPLE_ROWS" \
            > "$SNAPSHOT_DIR/samples/${table}.tsv"
    else
        head_rows=$(src_mysql "$SRC_DB" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` ASC LIMIT $SAMPLE_ROWS")
        # PK降順で取得した末尾N件をPK昇順に並べ直す
        tail_rows=$(src_mysql "$SRC_DB" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` DESC LIMIT $SAMPLE_ROWS" | sort)

        {
            printf "--- HEAD %s ---\n" "$SAMPLE_ROWS"
            printf "%s\n" "$head_rows"
            printf "--- TAIL %s ---\n" "$SAMPLE_ROWS"
            printf "%s\n" "$tail_rows"
        } > "$SNAPSHOT_DIR/samples/${table}.tsv"
    fi
    log "  [${current}/${table_count}] $table: サンプル取得完了"
done

log "============================="
log "全処理完了"
log "  ダンプ: $DUMP_FILE"
log "  スナップショット: $SNAPSHOT_DIR/"
log "============================="
