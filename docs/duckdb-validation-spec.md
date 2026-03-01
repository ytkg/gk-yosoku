# DuckDB 移行検証仕様（ドラフト）

## 目的

- CSV版とDuckDB版の同値性を定量的に判定する

## 検証対象

1. raw results
2. features
3. split(train/valid)
4. eval summary

## 判定基準

### 1. 件数

- `race_date` 単位で件数一致（差分 0）

### 2. キー一致

- `race_id`, `car_number` の集合一致

### 3. 重要列一致

- 完全一致:
  - `rank`
  - `top1`
  - `top3`
  - `result_status`

### 4. 連続値一致

- `abs(csv_value - duckdb_value) <= 1e-9`
- 対象: `hist_*`, `pair_*`, `triplet_*`, `odds_*` など連続値列

### 5. 評価指標

- `auc`, `winner_hit_rate`, `top3_exact_match_rate` の差分が `1e-6` 以内

## 失敗時の分類

1. Schema mismatch（列型/NULL可否）
2. Join mismatch（キー不整合）
3. Numeric drift（丸め/型変換差）
4. Filtering mismatch（`result_status` 等の除外条件差）

## 実行タイミング

1. PR時: サンプル期間（短期）
2. 日次バッチ: 前日分
3. フェーズ切替前: 本番相当期間（長期）

運用メモ:

- CSV版とDuckDB版の並走検証は実施する
- 長期比較期間は 6か月を採用する
- CIの必須比較は当面「短期データ」のみとする（長期比較は手動運用）

## 最低限の自動チェック項目（CI）

1. 件数比較ジョブ
2. 主要列一致ジョブ
3. 連続値誤差チェックジョブ
4. 学習・評価E2Eジョブ（短期データ）

## レポート形式

- `reports/duckdb_validation/YYYYMMDD/summary.json`
- `reports/duckdb_validation/YYYYMMDD/diff_samples.csv`

## 決定事項

1. 連続値の許容誤差は当面、単一閾値 `1e-9` を採用する
2. 列別閾値の導入検討は、長期比較（6か月）で有意なドリフトが出た場合に再評価する
