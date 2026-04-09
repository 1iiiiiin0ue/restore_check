#!/bin/sh
# MySQL -> MariaDB 移行検証: ダンプ + スナップショット取得
#
# 実行: sh scripts/01_dump_and_snapshot.sh
# 前提: config.env の SRC_* に旧DB(MySQL)の接続情報を設定済み
# 出力: dump/{db}.sql, snapshot/{db}/counts.tsv, snapshot/{db}/samples/*.tsv
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

SYSTEM_DBS="information_schema mysql performance_schema sys"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

src_mysql() {
    mysql -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" -p"$SRC_PASS" "$@" 2>/dev/null
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
        all_dbs=$(src_mysql -N -e "SHOW DATABASES")
        resolved=""
        for db in $all_dbs; do
            if ! is_system_db "$db"; then
                resolved="$resolved $db"
            fi
        done
        echo "$resolved" | sed 's/^ //'
    else
        echo "$TARGET_DBS"
    fi
}

get_tables() {
    local db="$1"
    src_mysql "$db" -N -e "SHOW TABLES"
}

get_primary_key() {
    local db="$1"
    local table="$2"
    src_mysql "$db" -N -e "
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$db'
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

# 対象DB一覧を解決
databases=$(resolve_databases)
if [ -z "$databases" ]; then
    log "エラー: 対象データベースがありません"
    exit 1
fi
db_count=$(echo "$databases" | wc -w | tr -d ' ')
log "対象データベース (${db_count}件): $databases"

# ダンプディレクトリ準備
mkdir -p "$DUMP_DIR"

db_current=0
for db in $databases; do
    db_current=$((db_current + 1))
    log ""
    log "========== [${db_current}/${db_count}] データベース: $db =========="

    # ダンプ取得
    dump_file="$DUMP_DIR/${db}.sql"
    log "mysqldump開始: $db"
    mysqldump \
        -h "$SRC_HOST" -P "$SRC_PORT" \
        -u "$SRC_USER" -p"$SRC_PASS" \
        --single-transaction \
        --routines \
        --triggers \
        "$db" > "$dump_file" 2>/dev/null

    if [ ! -s "$dump_file" ]; then
        log "エラー: ダンプファイルが空です: $dump_file"
        exit 1
    fi
    log "mysqldump完了: $dump_file ($(wc -c < "$dump_file") bytes)"

    # スナップショットディレクトリ準備
    snapshot_db_dir="$SNAPSHOT_DIR/$db"
    rm -rf "$snapshot_db_dir"
    mkdir -p "$snapshot_db_dir/samples"

    # テーブル一覧取得
    tables=$(get_tables "$db")
    table_count=$(printf "%s\n" "$tables" | wc -l | tr -d ' ')
    log "対象テーブル数: ${table_count}"

    # 件数スナップショット
    log "件数スナップショット取得開始"
    current=0
    for table in $tables; do
        current=$((current + 1))
        count=$(src_mysql "$db" -N -e "SELECT COUNT(*) FROM \`$table\`")
        printf "%s\t%s\n" "$table" "$count"
        log "  [${current}/${table_count}] $table: ${count}件"
    done > "$snapshot_db_dir/counts.tsv"
    log "件数スナップショット完了: $snapshot_db_dir/counts.tsv"

    # サンプルレコードスナップショット
    log "サンプルレコード取得開始 (先頭${SAMPLE_ROWS}件 + 末尾${SAMPLE_ROWS}件)"
    current=0
    for table in $tables; do
        current=$((current + 1))
        pk=$(get_primary_key "$db" "$table")
        if [ -z "$pk" ]; then
            src_mysql "$db" -N -e "SELECT * FROM \`$table\` LIMIT $SAMPLE_ROWS" \
                > "$snapshot_db_dir/samples/${table}.tsv"
        else
            head_rows=$(src_mysql "$db" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` ASC LIMIT $SAMPLE_ROWS")
            # PK降順で取得した末尾N件をPK昇順に並べ直す
            tail_rows=$(src_mysql "$db" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` DESC LIMIT $SAMPLE_ROWS" | sort)

            {
                echo "--- HEAD ${SAMPLE_ROWS} ---"
                echo "$head_rows"
                echo "--- TAIL ${SAMPLE_ROWS} ---"
                echo "$tail_rows"
            } > "$snapshot_db_dir/samples/${table}.tsv"
        fi
        log "  [${current}/${table_count}] $table: サンプル取得完了"
    done
done

log ""
log "============================="
log "全処理完了"
log "  ダンプ: $DUMP_DIR/"
log "  スナップショット: $SNAPSHOT_DIR/"
log "============================="
