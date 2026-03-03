# v2 アーキテクチャ案と移行PR計画

## 目的

- 学習時と推論時で特徴量計算が分岐している構造を解消する
- モデル再現性と安全な切替を担保する
- GUI/API拡張に耐える推論基盤へ移行する

## 進捗ステータス（2026-03-03時点）

- PR1（Feature Engine単一化）: 完了
- PR2（Model Registry + スキーマ契約）: 完了
- PR3（Prediction API正式化）: 完了
- PR4（DuckDB/Parquet移行）: 進行中

### PR4内訳

- Phase 1（CSV + Parquet 二重出力）: 完了
- Phase 2（特徴量生成のDuckDB優先化）: 完了（`sql_v1`）
- Phase 3（split/eval の DuckDB 化）: 完了
- Phase 4（CSV中心フロー廃止）: 未完了（互換用途として残置）

## v2 ディレクトリ構成案

```text
gk-yosoku/
  apps/
    api/                     # 推論API（JSON契約）
    cli/                     # 運用CLI（collect/train/eval/predict）
  core/
    domain/                  # Race, Entry, Prediction等のドメインモデル
    features/                # 学習・推論で共通の特徴量計算（単一実装）
    models/                  # LightGBMラッパ、推論器
    scoring/                 # exacta/trifectaスコアリング
    schemas/                 # 入出力スキーマ（バージョン付き）
  pipelines/
    collect/
    build_features/
    train/
    evaluate/
    promote/
  infra/
    storage/                 # DuckDB/Parquetアクセス
    registry/                # model registry実装
  configs/
    feature_sets/
    training/
    presets/
  data/
    raw/
    lake/                    # parquet
    marts/
  tests/
    unit/
    integration/
    contract/
```

## PR1（最優先）: Feature Engine単一化

### 目的

- `build_features.rb` と `predict_race.rb` の特徴量計算を共通化する

### 作業

1. `core/features` に `FeatureBuilder` を新設
2. 既存2箇所を `FeatureBuilder` 呼び出しへ置換
3. 「同一入力→同一特徴量」のゴールデンテスト追加

### 受け入れ条件

1. 学習・推論の同レースで特徴量差分ゼロ
2. 既存E2Eテスト全通過

## PR2: Model Registry + スキーマ契約導入

### 目的

- モデル再現性と安全な切替を担保する

### 作業

1. `model_manifest.json` 追加（`model_id`, `feature_set_version`, `train_window`, `metrics`）
2. `core/schemas` に入力/出力契約定義を追加
3. 推論時に manifest と feature version の整合チェックを実装

### 受け入れ条件

1. 不整合時は推論を明示エラーで停止
2. モデル評価結果と紐づく manifest が必ず残る

## PR3: Prediction API正式化（CLI従属を解消）

### 目的

- GUI/外部連携の安定基盤化

### 作業

1. `apps/api` に `POST /predict` を実装（JSON I/O固定）
2. `predict_race.rb` はAPI内部ユースケースを呼ぶ薄いCLIへ変更
3. contract test を追加（正常系/異常系）

### 受け入れ条件

1. CLIとAPIで同一入力時に同一予測結果
2. エラー形式統一（`code` / `message` / `detail`）

## 移行時の注意点

1. PR1完了まで新特徴量追加を凍結する
2. PR2導入後は「manifestなしモデル」を本番利用禁止にする
3. PR3完了後にGUIを載せる（逆順にしない）

## DuckDB/Parquet 移行詳細

### 方針

- データ保存の標準を CSV から Parquet に移す
- 結合・集計・split・検証は DuckDB で実行する
- 学習器都合で必要な TSV/CSV は最終段だけ一時生成する

### 期待効果

1. 型崩れと列欠損の検知が容易になる
2. 日次データ結合と学習データ生成が高速になる
3. SQLを固定化することで再現性が上がる

### 推奨データ配置

```text
data/
  raw/                         # 既存CSV（移行期間は併用）
  lake/
    raw_results/
      race_date=YYYY-MM-DD/*.parquet
    races/
      race_date=YYYY-MM-DD/*.parquet
    features/
      feature_set=v1/race_date=YYYY-MM-DD/*.parquet
  marts/
    train_valid/
      split_id=YYYYMMDD/*.parquet
  duckdb/
    gk_yosoku.duckdb
```

### スキーマ方針

1. 主要列は明示型で固定する（`DATE`, `INTEGER`, `DOUBLE`, `VARCHAR`）
2. `schema_version` と `feature_set_version` を列で保持する
3. `race_id + car_number` を特徴量行の一意キーとする
4. 欠損許容列を明示し、非許容列は取り込み時にエラーにする

### DuckDBの責務

1. Parquetの参照（`read_parquet(...)`）と統合View作成
2. 特徴量生成SQLの実行
3. train/valid splitの生成
4. 評価用集計（AUC前処理、hit@k計算用テーブル）

### 最小SQL設計（初期）

- `sql/staging_raw_results.sql`
- `sql/features_v1.sql`
- `sql/split_train_valid.sql`
- `sql/eval_materialize.sql`

### 段階移行（安全運用）

1. Phase 1: CSV + Parquet 二重出力（同値チェック実施）
2. Phase 2: 特徴量生成を DuckDB 優先に切替
3. Phase 3: split/eval も DuckDB 化
4. Phase 4: CSV中心フローを廃止し、互換用途のみに限定

### 差分検証ルール

1. 同日同レースで件数一致（raw/features）
2. 重要列（`top1`, `top3`, `rank`, `car_number`）の完全一致
3. 連続値は許容誤差 `1e-9` 以内

### 実装タスク（最小）

1. `scripts/lib/storage/duckdb_client.rb` を追加
2. `scripts/lib/storage/parquet_writer.rb` を追加
3. `make parquet-bootstrap`（初期化）を追加
4. `make features-duckdb`（DuckDB版特徴量生成）を追加
5. CIに「CSV版 vs DuckDB版」の整合テストを追加

## ローカル運用ランブック（デプロイなし）

### 標準実行手順

1. `make parquet-bootstrap FROM=YYYY-MM-DD TO=YYYY-MM-DD`
2. `make features-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD`
3. `make split-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD`
4. `make validate-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD`
5. `make eval-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD`

### トラブルシュート

1. `duckdb command not found`
  - Docker実行経路（`make ...`）で動かし、イメージ内のduckdbを利用する
2. `not found: data/lake/.../*.parquet`
  - `parquet-bootstrap` の日付範囲と入力CSVの存在を確認する
3. `duckdb parity failed`
  - `reports/duckdb_validation` の日次summary/差分CSVを確認し、キー不一致か値差分かを先に切り分ける
4. `docker socket permission denied`
  - Docker Desktop起動状態とローカルユーザーのDockerソケット権限を確認する

## CSV中心フローの扱い

- 学習・評価の標準フローは DuckDB/Parquet を採用する
- CSV中心フローは互換用途・比較検証用途に限定する
