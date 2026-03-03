# DuckDBロールバック手順（ローカル運用）

## 対象

- `data/duckdb/gk_yosoku.duckdb` を利用するローカル運用
- 障害例: 破損、想定外のデータ差分、評価値の急変

## 実施判断基準

1. `make validate-duckdb` が連続して失敗し、差分原因が即時に特定できない
2. 学習/評価が継続失敗し、同日中の復旧が難しい
3. 手動確認でバックアップ復元の方が短時間で安全と判断できる

## 最小ロールバック手順

1. 現在のDBを退避
  - `cp data/duckdb/gk_yosoku.duckdb data/duckdb/gk_yosoku.before_rollback.duckdb`
2. 直近バックアップを確認
  - `ls -1t data/duckdb_backup/*.duckdb | head -n 5`
3. 復元実行
  - `make restore-duckdb SRC=data/duckdb_backup/<backup_file>.duckdb`
4. ヘルス確認
  - `make features-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD`
  - `make validate-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD`
5. 復旧記録を残す
  - 障害内容、復元元ファイル、実施日時、再発防止メモ

## 復旧失敗時の再対応

1. 1つ前のバックアップで再実行
2. `data/duckdb/gk_yosoku.before_rollback.duckdb` に戻して原因調査を優先
3. 調査中は `#32` 親Issueに状況を追記

## 責任分担（ローカル運用）

1. 実施者: 手順実行と結果確認
2. レビュー担当: 差分内容と再発防止策の確認
