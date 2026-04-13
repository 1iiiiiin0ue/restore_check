#!/bin/sh
# MySQL -> MariaDB 移行検証: 件数 + サンプルレコード比較
#
# 実行: sh scripts/03_verify.sh
# 前提: 01_dump_and_snapshot.sh, 02_restore.sh を実行済み
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/config.env"

# config.env後方互換: 古いconfig.envに無い場合のデフォルト
: "${TARGET_DBS:=--all}"

SYSTEM_DBS="information_schema mysql performance_schema sys"

log() {
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >&2
}

dst_mysql() {
    local db="$1"
    shift
    mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$db" "$@" 2>/dev/null
}

get_primary_key() {
    local db="$1"
    local table="$2"
    dst_mysql "$db" -N -e "
        SELECT COLUMN_NAME
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_SCHEMA = '$db'
          AND TABLE_NAME = '$table'
          AND COLUMN_KEY = 'PRI'
        ORDER BY ORDINAL_POSITION
        LIMIT 1
    "
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
        # スナップショットディレクトリからDB名を取得
        resolved=""
        for d in "$SNAPSHOT_DIR"/*/; do
            [ -d "$d" ] || continue
            db=$(basename "$d")
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
for cmd in mysql diff sort; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "エラー: $cmd コマンドが見つかりません"
        exit 1
    fi
done

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

# 対象DB一覧を解決
databases=$(resolve_databases)
if [ -z "$databases" ]; then
    log "エラー: 対象データベースがありません"
    log "先に 01_dump_and_snapshot.sh を実行してください"
    exit 1
fi
db_count=$(echo "$databases" | wc -w | tr -d ' ')
log "対象データベース (${db_count}件): $databases"

# 全体集計用
grand_total_tables=0
grand_count_ok=0
grand_count_ng=0
grand_sample_ok=0
grand_sample_ng=0
grand_sample_skip=0
all_reports=""

db_current=0
for db in $databases; do
    db_current=$((db_current + 1))
    snapshot_db_dir="$SNAPSHOT_DIR/$db"
    verify_db_dir="$VERIFY_DIR/$db"

    log ""
    log "========== [${db_current}/${db_count}] データベース: $db =========="

    # 前提チェック
    if [ ! -f "$snapshot_db_dir/counts.tsv" ]; then
        log "  スナップショットが見つかりません: $snapshot_db_dir/counts.tsv、スキップ"
        continue
    fi

    # DB接続テスト
    if ! mysql -h "$DST_HOST" -P "$DST_PORT" -u "$DST_USER" -p"$DST_PASS" "$db" -e "SELECT 1" >/dev/null 2>&1; then
        log "  MariaDBのDB '$db' に接続できません、スキップ"
        continue
    fi

    # 結果ディレクトリ準備
    rm -rf "$verify_db_dir"
    mkdir -p "$verify_db_dir"

    total_tables=0
    count_ok=0
    count_ng=0
    sample_ok=0
    sample_ng=0
    sample_skip=0
    count_details=""
    sample_details=""

    # 件数比較
    log "=== 件数比較 ==="
    while IFS='	' read -r table old_count; do
        total_tables=$((total_tables + 1))
        new_count=$(dst_mysql "$db" -N -e "SELECT COUNT(*) FROM \`$table\`")

        if [ "$old_count" = "$new_count" ]; then
            count_ok=$((count_ok + 1))
            count_details="${count_details}  [OK] ${table}: ${new_count}件 一致\n"
            log "  [OK] $table: ${new_count}件 一致"
        else
            diff_count=$((new_count - old_count))
            count_ng=$((count_ng + 1))
            count_details="${count_details}  [NG] ${table}: 旧=${old_count}件 / 新=${new_count}件 (差分: ${diff_count}件)\n"
            log "  [NG] $table: 旧=${old_count}件 / 新=${new_count}件 (差分: ${diff_count}件)"
        fi
    done < "$snapshot_db_dir/counts.tsv"

    log ""

    # サンプルレコード比較
    log "=== サンプルレコード比較 (先頭${SAMPLE_ROWS}件 + 末尾${SAMPLE_ROWS}件) ==="
    while IFS='	' read -r table _; do
        old_sample="$snapshot_db_dir/samples/${table}.tsv"
        new_sample="$verify_db_dir/${table}_new.tsv"

        if [ ! -f "$old_sample" ]; then
            sample_skip=$((sample_skip + 1))
            sample_details="${sample_details}  [SKIP] ${table}: 旧スナップショットなし\n"
            log "  [SKIP] $table: 旧スナップショットなし"
            continue
        fi

        pk=$(get_primary_key "$db" "$table")
        if [ -z "$pk" ]; then
            dst_mysql "$db" -N -e "SELECT * FROM \`$table\` LIMIT $SAMPLE_ROWS" \
                > "$new_sample"
        else
            head_rows=$(dst_mysql "$db" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` ASC LIMIT $SAMPLE_ROWS")
            # PK降順で取得した末尾N件をPK昇順に並べ直す
            tail_rows=$(dst_mysql "$db" -N -e "SELECT * FROM \`$table\` ORDER BY \`$pk\` DESC LIMIT $SAMPLE_ROWS" | sort)

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
            diff "$old_sample" "$new_sample" > "$verify_db_dir/${table}.diff" 2>&1 || true
            sample_ng=$((sample_ng + 1))
            sample_details="${sample_details}  [NG] ${table}: 差分あり -> ${verify_db_dir}/${table}.diff\n"
            log "  [NG] $table: 差分あり -> ${verify_db_dir}/${table}.diff"
        fi
    done < "$snapshot_db_dir/counts.tsv"

    # DB別レポート出力
    report="$verify_db_dir/report.txt"
    {
        printf "============================================\n"
        printf "  データ移行検証レポート [%s]\n" "$db"
        printf "  実行日時: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
        printf "  リストア元: %s:%s\n" "$SRC_HOST" "$SRC_PORT"
        printf "  リストア先: %s:%s\n" "$DST_HOST" "$DST_PORT"
        printf "============================================\n"
        printf "\n"
        printf "[件数比較]\n"
        printf "$count_details"
        printf "\n"
        printf "[サンプルレコード比較] (先頭%s件 + 末尾%s件)\n" "$SAMPLE_ROWS" "$SAMPLE_ROWS"
        printf "$sample_details"
        printf "\n"
        printf "============================================\n"
        printf "  検証結果: %s\n" "$([ "$count_ng" -gt 0 ] || [ "$sample_ng" -gt 0 ] && echo "NG" || echo "OK")"
        printf "  対象テーブル数: %s\n" "$total_tables"
        printf "  件数比較:     OK=%d  NG=%d\n" "$count_ok" "$count_ng"
        printf "  サンプル比較: OK=%d  NG=%d  SKIP=%d\n" "$sample_ok" "$sample_ng" "$sample_skip"
        printf "============================================\n"
    } > "$report"

    # 全体集計に加算
    grand_total_tables=$((grand_total_tables + total_tables))
    grand_count_ok=$((grand_count_ok + count_ok))
    grand_count_ng=$((grand_count_ng + count_ng))
    grand_sample_ok=$((grand_sample_ok + sample_ok))
    grand_sample_ng=$((grand_sample_ng + sample_ng))
    grand_sample_skip=$((grand_sample_skip + sample_skip))
done

# 最終判定
if [ "$grand_count_ng" -gt 0 ] || [ "$grand_sample_ng" -gt 0 ]; then
    final_result="NG"
    exit_code=1
else
    final_result="OK"
    exit_code=0
fi

# 全体サマリー出力
summary="$VERIFY_DIR/summary.txt"
{
    printf "============================================\n"
    printf "  データ移行検証サマリー\n"
    printf "  実行日時: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf "  リストア元: %s:%s\n" "$SRC_HOST" "$SRC_PORT"
    printf "  リストア先: %s:%s\n" "$DST_HOST" "$DST_PORT"
    printf "  対象DB: %s\n" "$databases"
    printf "============================================\n"
    printf "\n"
    printf "  総合結果: %s\n" "$final_result"
    printf "  対象DB数: %d\n" "$db_count"
    printf "  対象テーブル総数: %d\n" "$grand_total_tables"
    printf "  件数比較:     OK=%d  NG=%d\n" "$grand_count_ok" "$grand_count_ng"
    printf "  サンプル比較: OK=%d  NG=%d  SKIP=%d\n" "$grand_sample_ok" "$grand_sample_ng" "$grand_sample_skip"
    printf "============================================\n"
} | tee "$summary"

log ""
log "サマリー: $summary"
log "DB別レポート: ${VERIFY_DIR}/*/report.txt"

if [ "$grand_count_ng" -gt 0 ] || [ "$grand_sample_ng" -gt 0 ]; then
    log "差分ファイル: ${VERIFY_DIR}/*/*.diff"
fi

exit "$exit_code"
