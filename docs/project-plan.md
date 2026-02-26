# プロジェクト全体像（最新版）

## 目的

ガールズケイリンを対象に、各選手の「3着以内確率（`top3`）」を予測する。  
予測単位は「1レース内の各選手（1行=1選手×1レース）」。

## タスク定義

- タスク: 二値分類
- 目的変数: `top3`
  - `1`: 3着以内
  - `0`: 4着以下
- モデル: LightGBM（CLI）

## 現在の実装フェーズ

1. 取得（Kドリームズ）
2. 特徴量作成
3. 時系列分割（train/valid）
4. 学習
5. 評価

## 実行基盤

- 言語: Ruby
- 環境: Docker
- 実行インターフェース: Makefile

## パイプライン構成（現行）

- 取得: `scripts/collect_data.rb`
- 特徴量作成: `scripts/build_features.rb`
- 分割: `scripts/split_features.rb`
- 学習: `scripts/train_lightgbm.rb`
- 評価: `scripts/evaluate_lightgbm.rb`

## Make実行フロー

```bash
make build
make collect FROM=2025-01-01 TO=2025-12-31 SLEEP=0.2
make features FROM=2025-01-01 TO=2026-02-25
make split FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
make train
make eval
```

一括実行（取得含む）:

```bash
make full FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31 SLEEP=0.2
```

## データ仕様（現行）

### 取得出力

- `data/raw/girls_races_YYYYMMDD.csv`
- `data/raw/girls_results_YYYYMMDD.csv`
- `data/raw_html/kaisai_YYYYMMDD.html`
- `data/raw_html/results/YYYYMMDD/result_*.html`

`girls_results` の重要列:

- `race_date`, `venue`, `race_number`, `racedetail_id`
- `rank`, `car_number`, `player_name`
- `result_status`（`normal`, `fall`, `dq`, `dns`, `dnf`）

### 特徴量出力

- `data/features/features_YYYYMMDD.csv`

主な列:

- 基本: `venue`, `race_number`, `car_number`, `player_name`
- 履歴: `hist_races`, `hist_win_rate`, `hist_top3_rate`, `hist_avg_rank`, `hist_last_rank`, `hist_days_since_last`
- レース: `race_field_size`
- 目的変数: `top3`

### 学習・評価出力

- `data/ml/train.csv`, `data/ml/valid.csv`
- `data/ml/model.txt`
- `data/ml/encoders.json`
- `data/ml/valid_pred.csv`
- `data/ml/eval_summary.json`

## 検証方針

- 分割は時系列（未来情報リーク防止）
- 主指標:
  - `auc`
  - `top3_exact_match_rate`
  - `top3_recall_at3`
  - `winner_hit_rate`

## 直近の改善点

- 結果CSVに `result_status` を保持（落車・失格など）
- `build_features` で履歴特徴量を追加
- `train` はカテゴリEncoderをtrainデータのみで作成（リーク抑制）
- Dockerイメージ内に LightGBM CLI を同梱

## 既知の方針

- 古すぎるデータは性能を落とす可能性があるため、まずは直近12か月中心で比較
- 期間（3/6/12か月）ごとに `eval_summary.json` を比較して採用期間を決める

## 次の改善候補

1. early stopping 追加
2. `num_leaves` / `min_data_in_leaf` のチューニング自動化
3. 追加特徴量（オッズ・選手属性の強化）
4. 時系列CV（複数期間で再現性確認）
