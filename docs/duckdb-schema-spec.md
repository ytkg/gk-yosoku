# DuckDB/Parquet スキーマ定義書（ドラフト）

## 目的

- データ契約（列/型/NULL可否/キー）を固定し、処理間の齟齬を防ぐ
- 固定事項: キーは `race_id + car_number`、featuresでは `result_status != normal` を除外

## 1. Raw Results（`lake.raw_results`）

想定物理配置: `data/lake/raw_results/race_date=YYYY-MM-DD/*.parquet`

| column | type | null | note |
|---|---|---|---|
| schema_version | VARCHAR | NO | 例: `1` |
| race_date | DATE | NO | |
| venue | VARCHAR | NO | |
| race_number | INTEGER | NO | |
| racedetail_id | VARCHAR | NO | |
| race_id | VARCHAR | NO | `YYYY-MM-DD-venue-rr` |
| car_number | INTEGER | NO | |
| player_name | VARCHAR | NO | |
| rank | INTEGER | YES | 1-7, 異常時はNULL可 |
| result_status | VARCHAR | NO | `normal/fall/dq/dns/dnf` |
| frame_number | INTEGER | YES | |
| age | INTEGER | YES | |
| class | VARCHAR | YES | |
| class_normalized | VARCHAR | NO | `UPPER(TRIM(class))` |
| raw_cells | VARCHAR | YES | |
| ingested_at | TIMESTAMP | NO | |

主キー（論理）: `race_id`, `car_number`

## 2. Features v1（`lake.features_v1`）

想定物理配置: `data/lake/features/feature_set=v1/race_date=YYYY-MM-DD/*.parquet`

必須列:

- キー: `race_id`, `race_date`, `car_number`
- ラベル: `rank`, `top1`, `top3`
- 特徴量群: `scripts/lib/feature_schema.rb` の `FEATURE_COLUMNS`
- メタ: `feature_set_version`, `schema_version`, `generated_at`

主キー（論理）: `race_id`, `car_number`

## 3. Train/Valid Mart（`marts.train_valid`）

想定物理配置: `data/marts/train_valid/split_id=YYYYMMDD/*.parquet`

| column | type | null | note |
|---|---|---|---|
| split_id | VARCHAR | NO | |
| split | VARCHAR | NO | `train` or `valid` |
| race_date | DATE | NO | |
| race_id | VARCHAR | NO | |
| car_number | INTEGER | NO | |
| target_top3 | INTEGER | NO | 0/1 |
| target_top1 | INTEGER | NO | 0/1 |
| ...feature columns... | MIXED | NO/YES | 契約に従う |

## 4. バージョン管理

1. `schema_version`: 入力・中間フォーマット仕様の版
2. `feature_set_version`: 特徴量定義の版

バージョン更新ルール:

1. 列追加: `MINOR` 扱い（下位互換あり）
2. 列削除/型変更: `MAJOR` 扱い（下位互換なし）

## 5. データ品質ルール

1. `race_id` 重複禁止（`race_id`, `car_number`）
2. `car_number` は `1..9` 範囲（ドメインに応じて要調整）
3. `top1` は各 `race_id` で合計1
4. `top3` は各 `race_id` で合計3（不成立レース除外時の扱いは別途定義）

## 6. 未決事項

1. `raw_cells` の保持期間

## 7. 決定事項

1. `class` は raw取り込み時に `class_normalized = UPPER(TRIM(class))` を生成する
2. モデル入力への採用可否は feature_set_version ごとに判断する
