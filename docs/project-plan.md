# プロジェクト全体像（最新版）

## 目的

ガールズケイリンを対象に、以下を予測する。  
- 各選手の「3着以内確率（`top3`）」  
- 各選手の「1着確率（`top1`）」  
- 順序つき2車ペアの正解確率（`exacta_top1`）

## タスク定義

- タスク: 二値分類
- 目的変数:
  - `top3`: 3着以内なら1
  - `top1`: 1着なら1
  - `exacta_top1`: 「1着-2着の順序ペア」が正解なら1
- モデル: LightGBM（CLI）

## 現在の実装フェーズ

1. 取得（Kドリームズ）
2. 特徴量作成
3. 時系列分割（train/valid）
4. 学習（top3/top1分離 + exacta専用）
5. 評価
6. 時系列CV（複数fold）

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
- exacta特徴量作成: `scripts/build_exacta_features.rb`
- exacta学習: `scripts/train_exacta_lightgbm.rb`
- exacta評価: `scripts/evaluate_exacta_lightgbm.rb`
- 時系列CV: `scripts/run_timeseries_cv.rb`

## Make実行フロー

```bash
make build
make collect FROM=2025-01-01 TO=2025-12-31 SLEEP=0.2
make features FROM=2025-01-01 TO=2026-02-25
make split FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
make train
make eval
make train-top1
make eval-top1
make features-exacta
make train-exacta
make eval-exacta-model
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
- 相性: `pair_*`, `triplet_*`（共走履歴）
- 目的変数: `top3`
  - `top1`

補足:

- 率系特徴量（`hist_*`, `pair_*`, `triplet_*`）は低サンプル時の過学習を抑える縮約を適用
- 追加スクレイピングなしで計算可能

### 学習・評価出力

- `data/ml/train.csv`, `data/ml/valid.csv`
- `data/ml/model.txt`
- `data/ml/encoders.json`
- `data/ml/valid_pred.csv`
- `data/ml/eval_summary.json`
- `data/ml_top1/model.txt`
- `data/ml_top1/encoders.json`
- `data/ml_top1/valid_pred.csv`
- `data/ml_top1/eval_summary.json`
- `data/ml_exacta/train.csv`, `data/ml_exacta/valid.csv`
- `data/ml_exacta/model.txt`
- `data/ml_exacta/encoders.json`
- `data/ml_exacta/valid_pair_pred.csv`
- `data/ml_exacta/exacta_pred.csv`
- `data/ml_exacta/eval_summary.json`

## 検証方針

- 分割は時系列（未来情報リーク防止）
- 主指標:
  - `auc`
  - `top3_exact_match_rate`
  - `top3_recall_at3`
  - `winner_hit_rate`
  - `exacta_hit@k`（`evaluate_exacta_lightgbm.rb`）

## 直近の改善点

- 結果CSVに `result_status` を保持（落車・失格など）
- `build_features` で履歴特徴量を追加
- `train` はカテゴリEncoderをtrainデータのみで作成（リーク抑制）
- Dockerイメージ内に LightGBM CLI を同梱
- `top3` / `top1` を別目的で運用（目的分離）
- `train_lightgbm` に時間減衰サンプル重み（`weight_mode=time_decay`）を追加
- 相性特徴量（`pair_*`, `triplet_*`）を追加
- 時系列CV実行スクリプトを追加
- `generate_exotics` のスコア丸めを高精度化し、`eval-exotic` と `predict` の順位ずれを縮小
- 予測プリセットを再最適化（balanced: `trial_024 + trial_029 + temp=0.30`, trifecta: `trial_027 + trial_002 + temp=0.20`）
- `hit@5` 重視プリセットを追加（hit5: `trial_024 + trial_002 + temp=0.35`, tri5: `trial_008 + trial_014 + temp=0.15`）
- 追加候補比較（2026-02-28）を実施し、上記 `hit5` / `tri5` プリセットが依然ベストであることを確認
- `learn_exotic_profile.rb` を追加し、hit@N目的で温度・指数を学習して `predict` / `generate_exotics` に適用可能化
- `learn_exotic_profile.rb` にランダム探索上限（`--max-trials`）を追加し、hit@1向けの大きい探索空間を現実的な時間で実行可能化
- 2連単スコアに `exacta.second_win_exp` を追加し、2着側に top1 情報を混ぜる調整が可能に
- exacta専用モデル（順序ペア直接学習）を追加し、`data/ml_exacta` で学習・評価可能化
- `predict_race.rb` で exactaモデル（存在時）を2連単スコアに自動適用し、未学習時は従来合成にフォールバック

## 既知の方針

- 古すぎるデータは性能を落とす可能性があるため、まずは直近12か月中心で比較
- 期間（3/6/12か月）ごとに `eval_summary.json` を比較して採用期間を決める

## 次の改善候補

1. `top1` と `top3` で特徴量セットを分岐最適化
2. time-decayの半減期探索（CV平均で決定）
3. 追加特徴量（ライン/直前気配）検討
4. エキゾチック指標（exacta/trifecta hit@k）を直接最適化する探索
