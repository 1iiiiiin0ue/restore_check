# MySQL -> MariaDB 移行検証ツール

MySQL 5.0のダンプをMariaDB 10.xにリストアし、テーブル件数とサンプルレコードの比較でデータ整合性を検証する。

## 前提条件

- `mysql` / `mysqldump` クライアントがインストール済み
- リストア元(MySQL)とリストア先(MariaDB)にネットワーク到達可能
- リストア先DBへの書き込み権限あり

## ディレクトリ構成

```
scripts/
  config.env                  設定ファイル(接続情報)
  01_dump_and_snapshot.sh     ダンプ + スナップショット取得
  02_restore.sh               リストア
  03_verify.sh                検証
  04_export_grants.sh         ユーザー権限エクスポート
  05_rollback.sh              リストア先をリストア前状態へ戻す
docker-compose.yml            ローカル検証用Docker環境(任意)
```

## Usage

### 1. 設定

`scripts/config.env` を環境に合わせて編集する。

```sh
# リストア元(MySQL)
SRC_HOST="192.168.1.10"
SRC_PORT="3306"
SRC_USER="backup_user"
SRC_PASS="password"

# リストア先(MariaDB)
DST_HOST="192.168.1.20"
DST_PORT="3306"
DST_USER="root"
DST_PASS="password"

# 対象データベース
# "--all": 全ユーザーDB(システムDB除外)
# "db1 db2 db3": スペース区切りで複数DB指定
# "myapp": 単一DB指定
TARGET_DBS="--all"
```

`--all`指定時、以下のシステムDBは自動的に除外される:
- `information_schema`, `mysql`, `performance_schema`, `sys`

### 2. ダンプ + スナップショット取得

リストア元MySQLに接続し、ダンプファイルと検証用スナップショットを取得する。

```sh
sh scripts/01_dump_and_snapshot.sh
```

出力物:
- `dump/<DB名>.sql` -- DB別mysqldumpファイル
- `snapshot/<DB名>/counts.tsv` -- 全テーブルの件数
- `snapshot/<DB名>/samples/<テーブル名>.tsv` -- 各テーブルの先頭/末尾レコード

### 3. ダンプファイルの転送

リストア先マシンにダンプとスナップショットを転送する。

```sh
scp -r dump/ snapshot/ user@mariadb-host:/path/to/restore_check/
```

### 4. リストア

リストア先MariaDBにダンプをリストアする。実行前に接続先情報と対象DB一覧が表示され、確認を求められる。

```sh
sh scripts/02_restore.sh
```

**文字セットの自動チェック:** リストア先のデフォルト文字セットが`utf8mb4`の場合、警告を表示する。MySQL5.0の`utf8`(= utf8mb3, 1文字3bytes)のダンプを`utf8mb4`(1文字4bytes)環境にリストアすると、インデックスサイズが上限(767bytes)を超えて`ERROR 1071: Specified key was too long`が発生する可能性がある。警告時に`y`を選択すると、DB作成時にutf8mb3を強制指定してリストアする。

### 5. 検証

リストア後のデータをスナップショットと比較する。

```sh
sh scripts/03_verify.sh
```

検証結果は画面に表示され、以下に保存される:
- `verify_results/summary.txt` -- 全DB横断のサマリー
- `verify_results/<DB名>/report.txt` -- DB別の詳細レポート

### 6. リストアのやり直し(任意)

リストアに失敗した、またはダンプファイルを修正して再リストアしたい場合、`05_rollback.sh` でリストア先をリストア前の状態に戻せる。

```sh
sh scripts/05_rollback.sh
```

**`02_restore.sh` がリストアで新規作成したDBのみ** を DROP する。リストア前から既に存在していたDB(ユーザーデータ等)には一切触れない。

実行前に DROP 対象一覧が表示され、確認プロンプトで承認後に DROP を実行する。完了後は状態ファイルが自動削除され、次回 `02_restore.sh` 実行時に再生成される。

再リストアしたい場合は、ロールバック後に修正したダンプで `02_restore.sh` を再実行する。

**仕組み:**

- `02_restore.sh` はリストア対象DBごとに「DST に存在したか」をチェックし、**存在しなかったDBのみ** を `restore_state/created_dbs.txt` に記録する
- `05_rollback.sh` はこのファイルに記録されたDBを順に DROP する
- 既存データを持つDBを上書きリストアした場合、そのDBは記録されず、ロールバックの影響を受けない(保護される)
- 既存DBも強制 DROP したい場合は、`05_rollback.sh` を使わず手動で `DROP DATABASE` を実行する

### 7. ユーザー権限エクスポート(任意)

MySQLのユーザーアカウントと権限(GRANT)をSQL形式でエクスポートする。
`mysql`データベースを丸ごとダンプする代わりに、権限だけを安全に移行できる。

```sh
sh scripts/04_export_grants.sh
```

出力物:
- `grants/grants.sql` -- 全ユーザーのGRANT文

リストア先への適用:

```sh
# 適用前にgrants.sqlを確認・編集(root等の不要な権限を除外)
mysql -h DST_HOST -P DST_PORT -u root -p < grants/grants.sql
mysql -h DST_HOST -P DST_PORT -u root -p -e "FLUSH PRIVILEGES;"
```

## 検証レポートの読み方

```
============================================
  データ移行検証サマリー
  実行日時: 2026-03-09 15:30:00
  リストア元: 192.168.1.10:3306
  リストア先: 192.168.1.20:3306
  対象DB: myapp analytics
============================================

  総合結果: NG
  対象DB数: 2
  対象テーブル総数: 15
  件数比較:     OK=14  NG=1
  サンプル比較: OK=14  NG=1  SKIP=0
============================================
```

DB別の詳細は `verify_results/<DB名>/report.txt` を参照。

| 表示 | 意味 |
|------|------|
| `[OK]` | 旧DBと新DBのデータが一致 |
| `[NG]` | 差分あり。原因調査が必要 |
| `[SKIP]` | 旧スナップショットが存在しないテーブル |

終了コード: 全テーブルOKなら `0`、NGが1つでもあれば `1`。

## エラーと対処

### 接続エラー

```
[2026-03-09 15:00:00] エラー: MySQLに接続できません
  ホスト: 192.168.1.10
  ポート: 3306
```

| 確認項目 | コマンド |
|----------|----------|
| ネットワーク到達性 | `ping 192.168.1.10` |
| ポート開放 | `nc -zv 192.168.1.10 3306` |
| 認証情報 | `mysql -h 192.168.1.10 -u backup_user -p` で手動接続 |
| config.env | SRC_HOST, SRC_PORT, SRC_USER, SRC_PASS の値を確認 |

### ダンプファイルが空

```
[2026-03-09 15:00:00] エラー: ダンプファイルが空です
```

- mysqldumpの権限不足: `SHOW GRANTS FOR 'backup_user'@'%';` で `SELECT`, `LOCK TABLES`, `SHOW VIEW`, `TRIGGER` 権限を確認
- 対象DBにテーブルが存在するか: `SHOW TABLES;` で確認

### リストアエラー

リストア中にエラーが出た場合、MySQLとMariaDBの非互換が原因の可能性がある。

| エラー内容 | 原因と対処 |
|------------|------------|
| `Unknown character set` | MySQL側の文字セットがMariaDBで未対応。ダンプファイル内の `CHARSET` を確認し、`sed` で置換 |
| `Unknown system variable 'GTID_PURGED'` | ダンプにGTID設定が含まれている。`sed -i '/SET @@GLOBAL.GTID_PURGED/d' dump/<DB名>.sql` で削除 |
| `Access denied` | DST_USER の権限不足。`GRANT ALL ON <DB名>.* TO ...` で付与 |
| `ERROR 1071: Specified key was too long` | MySQL 5.0の `utf8`(3byte) -> MariaDB 10.xの `utf8mb4`(4byte) でインデックスサイズ超過。ダンプ内の `utf8mb4` を `utf8` に置換するか、`innodb_large_prefix=ON` を設定 |

### コマンドが見つからない

```
[2026-03-09 15:00:00] エラー: mysqldump コマンドが見つかりません
```

MySQLクライアントをインストールする。

## 検証NGの原因特定

### 件数NGの場合

| パターン | 考えられる原因 |
|----------|----------------|
| 全テーブルで件数0 | リストアが実行されていない。`02_restore.sh` の出力を確認 |
| 特定テーブルだけNG | リストア中にそのテーブルでエラーが発生。ダンプファイル内の該当テーブルのINSERT文を確認 |
| 差分が少数(1-10件程度) | ダンプ中にデータが更新された可能性。`--single-transaction` が効いているか確認 |
| 差分が大きい | テーブル定義の非互換でINSERTが途中で失敗。リストア時のエラー出力を確認 |

### サンプルNGの場合

diffファイルの内容で原因を切り分ける。

```sh
cat verify_results/<DB名>/<テーブル名>.diff
```

| diffの特徴 | 考えられる原因 |
|------------|----------------|
| 日時カラムだけ異なる | タイムゾーン設定の差異。両DBの `SELECT @@time_zone;` を比較 |
| 小数点以下の桁数が異なる | DECIMAL/FLOATの精度差異。テーブル定義を比較 |
| 文字化け | 文字セットの不一致。`SHOW CREATE TABLE` で両DBのCHARSETを比較 |
| NULL vs 空文字 | MySQL 5.0とMariaDB 10.xのデフォルト値の扱いの違い |
| 全行異なる | 件数は一致するがソート順が異なる場合がある。PKの型変換(INT->BIGINT等)を確認 |

### SKIP の場合

スナップショット取得時にそのテーブルが存在しなかった。リストア後に追加されたテーブルの可能性がある。手動で確認する。

## Docker検証環境(任意)

ローカルでの動作確認用。本番作業には不要。

```sh
docker compose up -d

# DBが起動するまで待つ
docker compose exec mysql55 mysqladmin ping -h localhost -prootpass --wait=30

# 検証実行
sh scripts/01_dump_and_snapshot.sh
sh scripts/02_restore.sh
sh scripts/03_verify.sh

# 権限エクスポート(任意)
sh scripts/04_export_grants.sh

# リストアのやり直し(任意)
sh scripts/05_rollback.sh

# 後片付け
docker compose down -v
```
