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

## 実装タスク分解

1. Makefile/READMEのCSV互換注記統一
2. CIジョブの必須/任意の位置づけ整理
3. 互換解除条件（完全DuckDB移行）のチェックリスト化
