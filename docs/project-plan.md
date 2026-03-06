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

## 運用ルール（Issue駆動）

- 親Issue: [#32](https://github.com/ytkg/gk-yosoku/issues/32) を常設運用する
- 実装は「子Issue起票 -> 実装/検証 -> コミット -> 子Issueクローズ」の単位で進行する
- 子Issueが0件でも親Issueはクローズしない
- 方針変更や完了判定の更新は、親Issue本文と本ドキュメントの両方に反映する
- 親Issueコメント更新は「子Issueを3件以上クローズした時点」または「open issue が親Issueのみになった時点」で実施する

## 更新手順チェックリスト

`make issue-cycle` の実行タイミング:

1. 作業開始時（最初の子Issueを起票する前）
2. 子Issueをクローズした直後（次のIssueに着手する前）

実行時に表示される 1-8 の手順を、1サイクルごとに順番どおり実施する。

1. 子Issueを起票し、受け入れ条件を明文化する
2. 実装・検証（必要な `make`/spec 実行）を完了する
3. 変更をコミットする（Issue番号をコミットメッセージに含める）
4. 子Issueへ完了コメント（実装コミット・検証結果）を投稿する
5. 子Issueをクローズする
6. 必要に応じて改善Issueを1件以上起票する
7. exotics閾値（`EXOTIC_TOPS`）や温度関連パラメータを更新した場合は `make optimize-exotic-hitk` を実行する
8. 親Issue #32 の進捗欄・次候補欄を更新する
9. `gh issue list --state open` で open issue を確認する
10. 親Issue更新は `make issue-cycle-report` の自動コメントを優先する

## 次候補更新ルール（簡易）

1. 新しい改善Issueを起票した直後に、親Issue #32 の「次候補」を更新する
2. 直前の次候補Issueをクローズした直後に、次のIssue番号へ差し替える
3. 更新時は project-plan の「次の改善候補」と親Issue #32 の記述を同一内容にそろえる
4. 更新は `make sync-next-issue` を優先し、親Issueと project-plan の次候補先頭を同時同期する
5. open issue が親Issueのみのときは `make suggest-next-issue` で次の起票候補を確認する

## パイプライン構成（現行）

- 取得: `scripts/collect_data.rb`
- 特徴量作成: `scripts/parquet_bootstrap.rb` + `scripts/build_features_duckdb.rb`
- 分割: `scripts/split_features_duckdb.rb`
- 学習: `scripts/train_lightgbm.rb`
- 評価: `scripts/evaluate_lightgbm_duckdb.rb`
- exacta特徴量作成: `scripts/build_exacta_features.rb`
- exacta学習: `scripts/train_exacta_lightgbm.rb`
- exacta評価: `scripts/evaluate_exacta_lightgbm.rb`
- 時系列CV: `scripts/run_timeseries_cv.rb`

## Make実行フロー

```bash
make build
make collect FROM=2025-01-01 TO=2025-12-31 SLEEP=0.2
make parquet-bootstrap FROM=2025-01-01 TO=2026-02-25
make features-duckdb FROM=2025-01-01 TO=2026-02-25
make split-duckdb FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
make train
make eval-duckdb FROM=2026-02-01 TO=2026-02-25
make train-top1
make eval-top1
make features-exacta
make train-exacta
make eval-exacta-model
```

noplayer 実行例:

```bash
make train-top3-noplayer
make train-top1-noplayer
make cv-top3-noplayer FROM=2025-01-01 TO=2026-02-25 \
  CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
make cv-top1-noplayer FROM=2025-01-01 TO=2026-02-25 \
  CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
make tune-top3-noplayer TUNE_OPTS="--num-iterations 600 --learning-rates 0.02,0.03,0.05"
```

補足: `tune-top3-noplayer` は `top3_exact_match_rate` を主指標に、`player_name` 除外時の過学習抑制効果を比較する用途で使う。

一括実行（取得含む）:

```bash
make full FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31 SLEEP=0.2
```

## DuckDB共通オプション変数（Make）

- `FEATURE_SET_VERSION`  
  既定: `v1`
- `DUCKDB_DB_OPTS`  
  既定: `--db-path $(PARQUET_DB)`
- `DUCKDB_FEATURE_OPTS`  
  既定: `--lake-dir $(LAKE_DIR) --feature-set-version $(FEATURE_SET_VERSION) $(DUCKDB_DB_OPTS)`
- `EVAL_DUCKDB_MODEL` / `EVAL_DUCKDB_ENCODERS` / `EVAL_DUCKDB_OUT_DIR` / `EVAL_DUCKDB_TARGET_COL`
  `eval-duckdb` 実行時の推奨変数（旧 `EVAL_MODEL` 系は互換エイリアス）
- `EVAL_DUCKDB_BASE_OPTS`  
  既定: `$(DUCKDB_FEATURE_OPTS)`
- `CV_DUCKDB_OPTS`  
  既定: `$(DUCKDB_FEATURE_OPTS)`
- `TRAIN_DUCKDB_OPTS`  
  既定: `--train-parquet $(PROFILE_MART_DIR)/train.parquet --valid-parquet $(PROFILE_MART_DIR)/valid.parquet $(DUCKDB_DB_OPTS)`
- `SPLIT_EMIT_CSV`
  既定: `true`（`false` 指定で split 時の CSV 生成をスキップ）
- `TUNE_TRAIN_PARQUET`  
  既定: `$(PROFILE_MART_DIR)/train.parquet`
- `TUNE_DUCKDB_OPTS`  
  既定: `--train-parquet $(TUNE_TRAIN_PARQUET) --valid-parquet $(TUNE_VALID_PARQUET) $(DUCKDB_DB_OPTS)`
- `TOP3_FEATURE_SET` / `TOP1_FEATURE_SET`  
  既定: `full`（`noplayer` 指定時は `player_name` を除外）
- `EXOTIC_TOPS`  
  既定: `20,50`（`optimize-exotic-hitk` の `exacta_top,trifecta_top` 指定）

推奨の共通命名（train/eval/tune/cv で統一）:
1. 実行期間: `FROM` / `TO`（CLIでは `--from-date` / `--to-date`）
2. 重み付け: `WEIGHT_MODE` / `DECAY_HALF_LIFE_DAYS` / `MIN_SAMPLE_WEIGHT`
3. split入力: `TRAIN_DUCKDB_OPTS` / `TUNE_DUCKDB_OPTS`（Parquet優先）
4. CVウィンドウ: `CV_OPTS`（`--train-days` / `--valid-days` / `--step-days`）

上書き例:

```bash
make cv CV_DUCKDB_OPTS="--lake-dir data/lake --db-path data/duckdb/gk_yosoku.duckdb --feature-set-version v1" \
  CV_OPTS="--from-date 2026-01-01 --to-date 2026-02-25 --train-days 120 --valid-days 28 --step-days 28"
make optimize-exotic-hitk EXOTIC_TOPS="10,30" \
  EXOTIC_OPT_LEARN_OPTS="--config docs/exotic_profile_config.sample.yml"
```

## チューニング（DuckDB前提）

前提:
1. `make split-duckdb FROM=... TO=... TRAIN_TO=...` を先に実行
2. `data/marts/train_valid/split_id=.../train.parquet` が存在する
3. `data/marts/train_valid/split_id=.../valid.parquet` が存在する

実行例:

```bash
make tune FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31 \
  TUNE_OPTS="--num-iterations 500 --learning-rates 0.03,0.05"
```

補足:
- 既定で `TUNE_VALID_PARQUET=$(PROFILE_MART_DIR)/valid.parquet` を使用
- 既定値を変える場合は `TUNE_VALID_PARQUET=...` を明示する

## 時系列CV（DuckDB前提）

実行例:

```bash
make cv FROM=2025-01-01 TO=2026-02-25 \
  CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
make cv-top1 FROM=2025-01-01 TO=2026-02-25 \
  CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
```

確認ポイント:
1. `data/ml_cv*/cv_results.csv` の fold 数と期間
2. `data/ml_cv*/cv_summary.json` の主要指標（auc / winner_hit_rate / top3系）

半減期比較ジョブ（`make cv-half-life-grid`）の出力:
1. `data/ml_cv_half_life/half_life_leaderboard.csv`
2. `data/ml_cv_half_life/half_life_summary.json`

## データ仕様（現行）

### 取得出力

- `data/raw/girls_races_YYYYMMDD.csv`
- `data/raw/girls_results_YYYYMMDD.csv`
- `data/raw/girls_errors_YYYYMMDD.csv`
- `data/raw_html/kaisai_YYYYMMDD.html`
- `data/raw_html/results/YYYYMMDD/result_*.html`

`girls_results` の重要列:

- `race_date`, `venue`, `race_number`, `racedetail_id`
- `rank`, `car_number`, `player_name`
- `result_status`（`normal`, `fall`, `dq`, `dns`, `dnf`）
- 取得失敗・パース失敗・件数異常は `girls_errors_YYYYMMDD.csv` に記録

### 特徴量出力

- `data/features/features_YYYYMMDD.csv`（互換CSV）
- `data/lake/features/feature_set=v1/race_date=YYYY-MM-DD/features_YYYYMMDD.parquet`（標準）

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

- `data/ml/train.csv`, `data/ml/valid.csv`（互換用途CSV）
- `data/marts/train_valid/split_id=.../train.parquet`, `data/marts/train_valid/split_id=.../valid.parquet`（分割結果Parquet）
- `data/ml/model.txt`
- `data/ml/encoders.json`
- `data/ml/valid_pred.csv`
- `data/ml/eval_summary.json`
- `data/ml/valid_from_duckdb.parquet`（DuckDB評価用）
- `data/ml/valid_from_parquet.csv`（評価時の一時CSV）
- `data/ml_top1/model.txt`
- `data/ml_top1/encoders.json`
- `data/ml_top1/valid_pred.csv`
- `data/ml_top1/eval_summary.json`
- `data/ml_exacta/train.csv`, `data/ml_exacta/valid.csv`（互換用途CSV）
- `data/ml_exacta/model.txt`
- `data/ml_exacta/encoders.json`
- `data/ml_exacta/valid_pair_pred.csv`
- `data/ml_exacta/exacta_pred.csv`
- `data/ml_exacta/eval_summary.json`

補足:
1. 標準運用の一次データは Parquet（lake/marts）を使う
2. CSVは互換モードと一部下流処理のために限定生成する
3. `make features` / `make split` / `make eval` は互換用途の deprecated wrapper として残置する

## 検証方針

- 分割は時系列（未来情報リーク防止）
- 主指標:
  - `auc`
  - `top3_exact_match_rate`
  - `top3_recall_at3`
  - `winner_hit_rate`
  - `exacta_hit@k`（`evaluate_exacta_lightgbm.rb`）

## 直近の改善点

### PR3: API運用基盤

- SinatraベースのPrediction APIを整備
- CLI/API同値性チェックと契約テストを整備
- ローカル運用導線（start/stop/health/predict/smoke）を標準化

### PR4-PR5: DuckDB/Parquet移行と運用一本化

- `parquet-bootstrap` / `features-duckdb` / `split-duckdb` / `validate-duckdb` / `eval-duckdb` を整備
- SQLテンプレート（staging/features/split/eval）を整備
- CIでDuckDB parityを継続実行
- ドキュメントとMake導線をDuckDB前提に統一

### PR6-PR11: 評価・CV・チューニングのDuckDB統一

- `run_timeseries_cv` の分割経路をDuckDB化
- `evaluate_lightgbm` に `--valid-parquet` を追加
- top1/weakodds評価を `eval-duckdb` 経路へ統一
- `learn-hit5-profile` の入力を marts Parquet に統一
- `tune_lightgbm` の valid 入力をParquet対応
- README / Make help / project-plan を最新導線へ更新

### モデル改善（継続）

- `top3` / `top1` の目的分離運用
- 時間減衰サンプル重み（`weight_mode=time_decay`）
- 相性特徴量（`pair_*`, `triplet_*`）
- exacta専用モデル追加と `predict-exacta` 導線整備

### time-decay 半減期の比較結果（2026-03-05）

- 比較対象: `data/ml_cv_hl60`, `data/ml_cv_hl90`, `data/ml_cv_hl120`, `data/ml_cv_hl180`
- `winner_hit_rate` 平均: `hl120=0.6786`, `hl90=0.6773`, `hl60=0.6740`, `hl180=0.6728`
- 決定: 既定値は `DECAY_HALF_LIFE_DAYS=120` を維持

### top1/top3 特徴量セット分岐の比較結果（2026-03-05）

- `top3`: `data/ml/eval_summary.json`（full）が `data/ml_noplayer/tuning_v2/trial_024/eval_summary.json` より高指標
- `top1`: `data/ml_top1/tuning_v2/trial_029/eval_summary.json` と `data/ml_top1_noplayer/tuning_v2/trial_025/eval_summary.json` は `winner_hit_rate` 同率、`auc` は full が優位
- 決定: 既定値は `TOP3_FEATURE_SET=full` / `TOP1_FEATURE_SET=full`

再比較トリガー:
1. 学習期間を3か月以上更新したとき
2. `winner_hit_rate` または `top3_exact_match_rate` が直近基準より 0.01 以上悪化したとき
3. 特徴量の追加/削除を実施したとき

## 既知の方針

- 古すぎるデータは性能を落とす可能性があるため、まずは直近12か月中心で比較
- 期間（3/6/12か月）ごとに `eval_summary.json` を比較して採用期間を決める

## 次の改善候補

1. [P2] #203 [改善] evaluate_lightgbm_duckdb / tune_lightgbm / run_timeseries_cv の共通オプション名を完全統一する
2. [P1] `evaluate_lightgbm_duckdb` / `tune_lightgbm` / `run_timeseries_cv` の共通オプションを整理し、実行インターフェースを統一する
3. [P2] time-decay の半減期をCV平均で探索し、既定値を再設定する
4. [P2] `top1` と `top3` の特徴量セット分岐最適化（モデル目的に合わせた削減/追加）
5. [P2] エキゾチック指標（exacta/trifecta hit@k）を直接最適化する探索ジョブを整備する

## train.csv / valid.csv 依存縮退の棚卸し（2026-03-06）

### P1（先行着手）

1. 学習/評価/CVの主要経路
   - `scripts/train_lightgbm.rb`
   - `scripts/evaluate_lightgbm.rb`
   - `scripts/tune_lightgbm.rb`
   - `scripts/run_timeseries_cv.rb`
2. 互換CSVを生成する分割経路
   - `scripts/split_features_duckdb.rb`
   - `Makefile`（`train`, `eval`, `tune`, `cv` の `--train-csv` / `--valid-csv` 受け渡し）

### P2（P1完了後）

1. exotic/exacta 系のCSV依存
   - `scripts/build_exacta_features.rb`
   - `scripts/train_exacta_lightgbm.rb`
   - `scripts/evaluate_exacta_lightgbm.rb`
   - `scripts/evaluate_exotics.rb`
   - `scripts/learn_exotic_profile.rb`
2. ドキュメント上の互換CSV説明の縮退
   - `README.md`
   - `docs/project-plan.md`
