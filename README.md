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
SRC_DB="myapp"

# リストア先(MariaDB)
DST_HOST="192.168.1.20"
DST_PORT="3306"
DST_USER="root"
DST_PASS="password"
DST_DB="myapp"
```

### 2. ダンプ + スナップショット取得

リストア元MySQLに接続し、ダンプファイルと検証用スナップショットを取得する。

```sh
sh scripts/01_dump_and_snapshot.sh
```

出力物:
- `dump.sql` -- mysqldumpファイル
- `snapshot/counts.tsv` -- 全テーブルの件数
- `snapshot/samples/<テーブル名>.tsv` -- 各テーブルの先頭/末尾レコード

### 3. ダンプファイルの転送

リストア先マシンにダンプとスナップショットを転送する。

```sh
scp -r dump.sql snapshot/ user@mariadb-host:/path/to/restore_check/
```

### 4. リストア

リストア先MariaDBにダンプをリストアする。実行前に接続先情報が表示され、確認を求められる。

```sh
sh scripts/02_restore.sh
```

### 5. 検証

リストア後のデータをスナップショットと比較する。

```sh
sh scripts/03_verify.sh
```

検証結果は画面に表示され、`verify_results/report.txt` にも保存される。

## 検証レポートの読み方

```
============================================
  データ移行検証レポート
  実行日時: 2026-03-09 15:30:00
  リストア元: 192.168.1.10:3306 (myapp)
  リストア先: 192.168.1.20:3306 (myapp)
============================================

[件数比較]
  [OK] users: 12345件 一致
  [NG] orders: 旧=98765件 / 新=98760件 (差分: -5件)

[サンプルレコード比較] (先頭5件 + 末尾5件)
  [OK] users: 一致
  [NG] orders: 差分あり -> verify_results/orders.diff

============================================
  検証結果: NG
  対象テーブル数: 2
  件数比較:     OK=1  NG=1
  サンプル比較: OK=1  NG=1  SKIP=0
============================================
```

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
| `Unknown system variable 'GTID_PURGED'` | ダンプにGTID設定が含まれている。`sed -i '/SET @@GLOBAL.GTID_PURGED/d' dump.sql` で削除 |
| `Access denied` | DST_USER の権限不足。`GRANT ALL ON myapp.* TO ...` で付与 |
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
cat verify_results/<テーブル名>.diff
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

# 後片付け
docker compose down -v
```
