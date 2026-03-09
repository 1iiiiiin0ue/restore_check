#!/bin/sh
# MySQL -> MariaDB 移行検証: 件数 + サンプルレコード比較
#
# 実行: sh scripts/03_verify.sh
# 前提: 01_dump_and_snapshot.sh, 02_restore.sh を実行済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$DST_DB" "$@" 2>/dev/null
}

get_primary_key() {
    local table="$1"
    dst_mysql -N -e "
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$DST_DB'
          AND TABLE_NAME = '$table'
          AND COLUMN_KEY = 'PRI'
        ORDER BY ORDINAL_POSITION
        LIMIT 1
    "
}

# コマンド存在チェック
for cmd in mysql diff sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "エラー: $cmd コマンドが見つかりません"
        exit 1
    fi
done

# 前提チェック
if [ ! -f "$SNAPSHOT_DIR/counts.tsv" ]; then
    log "エラー: スナップショットが見つかりません: $SNAPSHOT_DIR/counts.tsv"
    log "先に 01_dump_and_snapshot.sh を実行してください"
    exit 1
fi

# 接続テスト
log "接続テスト: $DST_HOST:$DST_PORT ($DST_DB)"
if ! mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$DST_DB" -e "SELECT 1" >/dev/null 2>&1; then
    log "エラー: MariaDBに接続できません"
    log "  ホスト: $DST_HOST"
    log "  ポート: $DST_PORT"
    log "  ユーザー: $DST_USER"
    log "  DB: $DST_DB"
    log "config.env の DST_* 設定を確認してください"
    exit 1
fi
log "接続OK"

# 結果ディレクトリ準備
rm -rf "$VERIFY_DIR"
mkdir -p "$VERIFY_DIR"

total_tables=0
count_ok=0
count_ng=0
sample_ok=0
sample_ng=0
sample_skip=0
count_details=""
sample_details=""

log "検証開始"
log ""

# 件数比較
log "=== 件数比較 ==="
while IFS='	' read -r table old_count; do
    total_tables=$((total_tables + 1))
    new_count=$(dst_mysql -N -e "SELECT COUNT(*) FROM \`$table\`")

    if [ "$old_count" = "$new_count" ]; then
        result="OK"
        count_ok=$((count_ok + 1))
        count_details="${count_details}  [OK] ${table}: ${new_count}件 一致\n"
        log "  [OK] $table: ${new_count}件 一致"
    else
        result="NG"
        diff_count=$((new_count - old_count))
        count_ng=$((count_ng + 1))
        count_details="${count_details}  [NG] ${table}: 旧=${old_count}件 / 新=${new_count}件 (差分: ${diff_count}件)\n"
        log "  [NG] $table: 旧=${old_count}件 / 新=${new_count}件 (差分: ${diff_count}件)"
    fi
done < "$SNAPSHOT_DIR/counts.tsv"

log ""

# サンプルレコード比較
log "=== サンプルレコード比較 (先頭${SAMPLE_ROWS}件 + 末尾${SAMPLE_ROWS}件) ==="
while IFS='	' read -r table _; do
    old_sample="$SNAPSHOT_DIR/samples/${table}.tsv"
    new_sample="$VERIFY_DIR/${table}_new.tsv"

    if [ ! -f "$old_sample" ]; then
        sample_skip=$((sample_skip + 1))
        sample_details="${sample_details}  [SKIP] ${table}: 旧スナップショットなし\n"
        log "  [SKIP] $table: 旧スナップショットなし"
        continue
    fi

    pk=$(get_primary_key "$table")
    if [ -z "$pk" ]; then
        dst_mysql -N -e "SELECT * FROM \`$table\` LIMIT $SAMPLE_ROWS" \
            > "$new_sample"
    else
        head_rows=$(dst_mysql -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` ASC LIMIT $SAMPLE_ROWS")
        # PK降順で取得した末尾N件をPK昇順に並べ直す
        tail_rows=$(dst_mysql -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` DESC LIMIT $SAMPLE_ROWS" | sort)

        {
            echo "--- HEAD ${SAMPLE_ROWS} ---"
            echo "$head_rows"
            echo "--- TAIL ${SAMPLE_ROWS} ---"
            echo "$tail_rows"
        } > "$new_sample"
    fi

    if diff -q "$old_sample" "$new_sample" >/dev/null 2>&1; then
        sample_ok=$((sample_ok + 1))
        sample_details="${sample_details}  [OK] ${table}: 一致\n"
        log "  [OK] $table: 一致"
        rm -f "$new_sample"
    else
        diff "$old_sample" "$new_sample" > "$VERIFY_DIR/${table}.diff" 2>&1 || true
        sample_ng=$((sample_ng + 1))
        sample_details="${sample_details}  [NG] ${table}: 差分あり -> ${VERIFY_DIR}/${table}.diff\n"
        log "  [NG] $table: 差分あり -> ${VERIFY_DIR}/${table}.diff"
    fi
done < "$SNAPSHOT_DIR/counts.tsv"

# 最終判定
if [ "$count_ng" -gt 0 ] || [ "$sample_ng" -gt 0 ]; then
    final_result="NG"
    exit_code=1
else
    final_result="OK"
    exit_code=0
fi

# レポート出力
report="$VERIFY_DIR/report.txt"
{
    printf "============================================\n"
    printf "  データ移行検証レポート\n"
    printf "  実行日時: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  リストア元: %s:%s (%s)\n" "$SRC_HOST" "$SRC_PORT" "$SRC_DB"
    printf "  リストア先: %s:%s (%s)\n" "$DST_HOST" "$DST_PORT" "$DST_DB"
    printf "============================================\n"
    printf "\n"
    printf "[件数比較]\n"
    printf "$count_details"
    printf "\n"
    printf "[サンプルレコード比較] (先頭%s件 + 末尾%s件)\n" "$SAMPLE_ROWS" "$SAMPLE_ROWS"
    printf "$sample_details"
    printf "\n"
    printf "============================================\n"
    printf "  検証結果: %s\n" "$final_result"
    printf "  対象テーブル数: %s\n" "$total_tables"
    printf "  件数比較:     OK=%d  NG=%d\n" "$count_ok" "$count_ng"
    printf "  サンプル比較: OK=%d  NG=%d  SKIP=%d\n" "$sample_ok" "$sample_ng" "$sample_skip"
    printf "============================================\n"
} | tee "$report"

log ""
log "レポート出力: $report"

if [ "$count_ng" -gt 0 ] || [ "$sample_ng" -gt 0 ]; then
    log "差分ファイル: ${VERIFY_DIR}/*.diff"
fi

exit "$exit_code"
