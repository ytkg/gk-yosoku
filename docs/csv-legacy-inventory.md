# CSV専用処理の残存棚卸し（2026-03-03）

## 目的

- DuckDB完全移行に向けて、CSV依存コードの残存箇所を明確化する
- 削除対象と維持対象を分離する

## 今回削減した項目

1. `scripts/build_features_duckdb.rb` の `csv_bridge` モード削除
2. `build_features_duckdb` 実行経路を `sql_v1` 固定化
3. Makefileの `features-duckdb` から `mode` 引数を削除

## 残存するCSV依存（維持対象）

1. `scripts/collect_data.rb` のraw CSV出力
  - 理由: データ取得の一次成果物として継続利用
2. `scripts/evaluate_lightgbm.rb` 系のCSV入力
  - 理由: 学習・評価の既存入出力契約を維持
3. `scripts/build_exacta_features.rb` など下流スクリプトのCSV I/O
  - 理由: exacta系処理の前提フォーマット

## 次の削減候補

1. 評価系スクリプトのParquet直接入力化
2. CSV生成を最終互換出力に限定する設計へ再編
