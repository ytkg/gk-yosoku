# DuckDB前提テスト戦略

## 目的

- DuckDB/Parquet運用での主要回帰を短時間で検知する
- CSV互換に依存しないテスト観点を明確化する

## 実行入口

1. `make test-duckdb`
  - DuckDB移行に関係する主要specのみ実行
2. `make test`
  - 全体回帰確認

## `make test-duckdb` の対象

1. `spec/scripts/parquet_bootstrap_spec.rb`
2. `spec/scripts/build_features_duckdb_spec.rb`
3. `spec/scripts/split_features_duckdb_spec.rb`
4. `spec/scripts/validate_duckdb_parity_spec.rb`
5. `spec/scripts/evaluate_lightgbm_duckdb_spec.rb`
6. `spec/scripts/backup_duckdb_spec.rb`

## 運用ルール

1. DuckDB関連変更のPRでは `make test-duckdb` を最低実行する
2. リリース前は `make test` を実行する
3. 障害対応後は `validate-duckdb` まで含めて再確認する
