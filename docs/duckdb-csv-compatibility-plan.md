# DuckDB専用運用に向けたCSV互換フロー縮退計画

## 目的

- 日常運用の既定経路を DuckDB/Parquet に一本化する
- CSV中心フローを「比較検証・互換用途」のみに限定する

## 現状の運用経路

### DuckDB/Parquet（既定にしたい）

- `make parquet-bootstrap`
- `make features-duckdb`
- `make split-duckdb`
- `make validate-duckdb`
- `make eval-duckdb`

### CSV中心（互換用途へ限定）

- `make features`
- `make split`
- `make eval`

## 縮退方針

1. READMEとhelp表示で DuckDB系を先頭にし、CSV系は「compat only」と明記する
2. CIは DuckDB整合チェックを必須とし、CSV系は補助検証扱いにする
3. CSV系スクリプト削除は行わず、最小メンテ対象として維持する

## 移行ガードレール

1. DuckDB系の失敗時のみCSV系を使用する
2. CSV系で発見した差分は `validate-duckdb` レポートに集約する
3. 互換用途の解除条件（完全移行）は別Issueで管理する

## CSV互換解除チェックリスト（完全DuckDB移行判定）

1. 直近4週間のPRで `duckdb-short-parity` が全件成功
2. `validate-duckdb` の差分メトリクスが連続4週間で閾値内
3. 日常運用手順から `make features` / `make split` / `make eval` を参照しない
4. 障害時の暫定運用手順が DuckDB系のみで成立している
5. 互換解除後のロールバック手順（復帰条件と担当）が明文化されている

## 判定に必要な計測・ログ

1. GitHub Actions: `duckdb-short-parity` の成功履歴
2. `reports/duckdb_validation/*.json` の日次差分
3. 運用手順ドキュメント更新履歴（README/docs）

## 解除判定の運用手順

1. 毎週1回、差分メトリクスとCI履歴をレビューする
2. チェックリスト5項目がすべて満たされたら、削除/非推奨化の実装Issueを起票する
3. 実装Issue完了後、CSV互換フローを正式に終了する

## 実装タスク分解

1. Makefile/READMEのCSV互換注記統一
2. CIジョブの必須/任意の位置づけ整理
3. 互換解除条件（完全DuckDB移行）のチェックリスト化
