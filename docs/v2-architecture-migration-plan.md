# v2 アーキテクチャ案と移行PR計画

## 目的

- 学習時と推論時で特徴量計算が分岐している構造を解消する
- モデル再現性と安全な切替を担保する
- GUI/API拡張に耐える推論基盤へ移行する

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
