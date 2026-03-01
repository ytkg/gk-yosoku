# v2 アーキテクチャ案と移行PR計画

## 目的

- 学習時と推論時で特徴量計算が分岐している構造を解消する
- モデル再現性と安全な切替を担保する
- API拡張に耐える推論基盤へ移行する

## 進捗サマリ（2026-03-01 時点）

- PR1: 未完了
- PR2: 未完了
- PR3: 完了（Issue #33 クローズ済み）

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

- API利用の安定基盤化

### 実施結果（完了）

1. `apps/api` に `POST /predict` を実装（JSON I/O固定）
2. `predict_race.rb` に API呼び出しオプションを追加
3. contract test を追加し、レスポンス契約をJSON Schemaで固定
4. `make` ベースの運用導線（起動/health/predict/smoke）を整備

### 完了Issue

- `#33`, `#34`, `#35`, `#36`, `#38`, `#39`, `#40`, `#41`, `#42`, `#43`, `#44`, `#45`, `#46`, `#47`

## 移行時の注意点

1. PR1完了まで新特徴量追加は慎重に行う
2. PR2導入後は「manifestなしモデル」の利用を避ける
3. 追加施策は親Issue `#32` 配下で子Issue化して管理する

## DuckDB/Parquet 移行詳細

### 方針

- データ保存の標準を CSV から Parquet に移す
- 結合・集計・split・検証は DuckDB で実行する
- 学習器都合で必要な TSV/CSV は最終段だけ一時生成する

### 実装タスク（最小）

1. `scripts/lib/storage/duckdb_client.rb` を追加
2. `scripts/lib/storage/parquet_writer.rb` を追加
3. `make parquet-bootstrap`（初期化）を追加
4. `make features-duckdb`（DuckDB版特徴量生成）を追加
5. CIに「CSV版 vs DuckDB版」の整合テストを追加
