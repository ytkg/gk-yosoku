# gk-yosoku

ガールズケイリン予測のためのデータ取得・学習パイプラインです。  
基本操作は **Makefile経由** で実行します。

## モデル構成（重要）

このプロジェクトは、最終目的の **2連単/3連単予測** のためにモデルを2つ使います。

- `top3` モデル: 「3着以内に入る確率」を予測
- `top1` モデル: 「1着になる確率」を予測

その後、`make exotic` で両モデルの予測を合成し、2連単/3連単候補を作成します。  
つまり、最終成果物は「単一モデル」ではなく、**2モデル+合成ロジック** です。

加えて、2連単を直接当てにいく **exacta専用モデル** も使えます。

- `exacta` モデル: 「順序つき2車ペア（1着-2着）が正解か」を直接予測

実運用ではこの2モデルを**別目的で最適化**します。

- `top3`: `top3_exact_match_rate` を優先
- `top1`: `winner_hit_rate` を優先

## 予測フロー

1. `make parquet-bootstrap` と `make features-duckdb` で特徴量作成
2. `make split-duckdb` で学習/検証データ分割
3. `make train` と `make train-top1` で2モデル学習
4. `make exotic` で2連単/3連単候補を生成
5. `make eval-exotic` で hit@N を確認

exacta専用モデルを使う場合:

1. `make features-exacta` で順序ペア特徴量を作成
2. `make train-exacta` で2連単専用モデル学習
3. `make eval-exacta-model` で `hit@N` を確認

## 前提

- Docker
- GNU Make（通常 `make`）

## クイックスタート

```bash
make build
make help
```

## CIチェック（PR時）

PRでは次の2つを必須チェックとして扱います。

1. `ruby40-scripts-spec`（Ruby 4.0.1 scripts spec + CLI/API parity）
2. `duckdb-short-parity`（DuckDB生成結果とCSV基準の整合チェック）

補足:
- `duckdb-short-parity` は DuckDB 系コマンドのみで実行します。

## ローカル Prediction API（Sinatra）

ローカル専用で `POST /predict` を提供します（デプロイは想定しません）。
タイムアウト秒は `GK_PREDICT_TIMEOUT_SEC`（既定: `30`）で調整できます。
`POST /predict` の成功レスポンスは、予測結果の構造化JSON（`race`, `entries`, `rankings`, `confidence`, `exotics`）を `detail` に返します。
レスポンス契約は以下のJSON Schemaで管理します。

- `docs/api/predict-success.schema.json`
- `docs/api/predict-error.schema.json`
- `docs/api/predict-request.schema.json`
- バージョニング運用: `docs/api/contract-versioning.md`

起動:

```bash
make build
make api-start
```

バックグラウンド起動/停止/ログ:

```bash
make api-start-bg
make api-logs
make api-stop
```

ヘルスチェック:

```bash
make api-health
```

payloadファイルで呼び出し:

```bash
make api-predict PAYLOAD=docs/api/request-examples/predict-basic.json
```

request examples の一括スモーク検証:

```bash
make api-smoke
```

CLI/API同値性検証:

```bash
make api-cli-parity
```

直接 `curl` で呼び出し:

```bash
curl -sS -X POST http://127.0.0.1:4567/predict \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://keirin.kdreams.jp/toride/racedetail/2320260225030001/",
    "use_cache": true
  }'
```

CLIからAPI経由で実行する場合:

```bash
ruby scripts/predict_race.rb \
  --url https://keirin.kdreams.jp/toride/racedetail/2320260225030001/ \
  --api-url http://127.0.0.1:4567/predict
```

CLI利用からAPI利用へ切り替える場合は、マイグレーションガイドを参照してください。

- `docs/api/migration-cli-to-api.md`
- `docs/api/predict-payload.md`
- `docs/api/troubleshooting.md`
- `docs/api/configuration.md`
- `docs/api/cli-exit-codes.md`
- `docs/api/fixtures/README.md`
- `docs/api/request-examples/predict-basic.json`
- `docs/api/response-examples/predict-success.sample.json`

エラー確認用のpayload:

- `docs/api/request-examples/predict-missing-url.json`
- `docs/api/request-examples/predict-invalid-url.json`

エラー確認の実行例:

```bash
make api-predict PAYLOAD=docs/api/request-examples/predict-missing-url.json
make api-predict PAYLOAD=docs/api/request-examples/predict-invalid-url.json
```

タイムアウト挙動の確認:

```bash
make api-predict-timeout-check
```

代表的なエラーコード:

- `invalid_request`: リクエスト不正（例: `url` 未指定）
- `predict_failed`: 予測CLIの実行失敗（入力URL不正など）
- `predict_timeout`: 予測がタイムアウト（`GK_PREDICT_TIMEOUT_SEC` 超過）

API経由CLI（`--api-url`）の終了コード規約:

- `invalid_request` -> `2`
- `predict_failed` -> `3`
- `predict_timeout` -> `4`
- `internal_error` -> `5`

設定ファイル運用:

```bash
cp .env.example .env
make api-start
```

manifest確認:

```bash
make manifest-inspect MODEL_DIR=data/ml
```

## 主要コマンド（Makefile前提）

### 1. データ取得

```bash
make collect FROM=2025-01-01 TO=2025-12-31 SLEEP=0.2
```

取得を堅牢化したい場合（リトライ・低速アクセス）:

```bash
docker run --rm -v "$PWD:/app" -w /app gk-yosoku ruby scripts/collect_data.rb \
  --from-date 2025-01-01 --to-date 2025-12-31 \
  --max-retries 3 --retry-base-sleep 0.5 --sleep 0.2
```

### 2. 特徴量作成（標準: DuckDB/Parquet）

```bash
make parquet-bootstrap FROM=2025-01-01 TO=2026-02-25
make features-duckdb FROM=2025-01-01 TO=2026-02-25
make split-duckdb FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
make validate-duckdb FROM=2025-01-01 TO=2026-02-25
make eval-duckdb FROM=2026-02-01 TO=2026-02-25
make backup-duckdb
make restore-duckdb SRC=data/duckdb_backup/gk_yosoku_YYYYMMDDTHHMMSSZ.duckdb
```

補足:
- `make parquet-bootstrap`: `data/raw/*.csv` から `data/lake` に Parquet を作成
- `make features-duckdb`: 既定は `sql_v1` モード（`data/lake/raw_results` から SQL 主導で features CSV/Parquet を生成）
- `make features-duckdb-sql`: `make features-duckdb FEATURES_DUCKDB_MODE=sql_v1` のエイリアス
- `make split-duckdb`: `data/lake/features` から `train.csv` / `valid.csv` と mart Parquet を作成
- `make validate-duckdb`: CSV features と Parquet features の差分検証レポートを作成
- `make eval-duckdb`: Parquet features から検証Parquetを生成し、`evaluate_lightgbm.rb --valid-parquet` で評価
- `make backup-duckdb`: DuckDB本体のバックアップを作成
- `make restore-duckdb`: バックアップから DuckDB 本体を復元
- DBファイル既定値: `data/duckdb/gk_yosoku.duckdb`

補足:
- 履歴率系（`hist_*`、`pair_*`、`triplet_*`）には低サンプル時の過学習を抑える縮約（smoothing）を入れています。
- 取得データの追加は不要です（既存CSVで計算）。

#### 現在モデルで使っている特徴量（実列）

学習に使う列は `scripts/lib/feature_schema.rb` の `FEATURE_COLUMNS` です。

- カテゴリ: `venue`, `player_name`, `mark_symbol`, `leg_style`
- 数値: `race_number`, `car_number`, `hist_races`, `hist_win_rate`, `hist_top3_rate`, `hist_avg_rank`, `hist_last_rank`, `hist_recent3_weighted_avg_rank`, `hist_recent3_win_rate`, `hist_recent3_top3_rate`, `recent3_vs_hist_top3_delta`, `hist_recent5_weighted_avg_rank`, `hist_recent5_win_rate`, `hist_recent5_top3_rate`, `hist_days_since_last`, `same_meet_day_number`, `same_meet_prev_day_exists`, `same_meet_prev_day_rank`, `same_meet_prev_day_top1`, `same_meet_prev_day_top3`, `same_meet_races`, `same_meet_avg_rank`, `same_meet_prev_day_rank_inv`, `same_meet_recent3_synergy`, `pair_hist_count_total`, `pair_hist_i_top3_rate_avg`, `pair_hist_both_top3_rate_avg`, `triplet_hist_count_total`, `triplet_hist_i_top3_rate_avg`, `triplet_hist_all_top3_rate_avg`, `race_rel_hist_avg_rank_rank`, `race_rel_hist_recent3_top3_rate_rank`, `race_rel_hist_recent5_top3_rate_rank`, `race_rel_same_meet_prev_day_rank`, `race_rel_same_meet_avg_rank_rank`, `race_rel_same_meet_recent3_synergy_rank`, `race_rel_pair_i_top3_rate_rank`, `race_rel_triplet_i_top3_rate_rank`, `race_rel_hist_win_rate_rank`, `race_rel_hist_top3_rate_rank`, `mark_score`, `race_rel_mark_score_rank`, `odds_2shatan_min_first`, `race_rel_odds_2shatan_rank`, `race_field_size`

補足:
- 目的変数は `top3` または `top1`（学習時に切替）
- `race_id`, `race_date`, `racedetail_id`, `rank` は入力特徴量には使いません

#### 特徴量候補（現データで追加しやすいもの）

追加スクレイピングなしで、既存CSV/HTMLキャッシュから拡張しやすい候補です。

- `girls_results_*.csv` 由来:
  - `age`（年齢）
  - `class`（級班）
  - `frame_number`（枠番）
  - `result_status`（`normal`, `fall`, `dq`, `dns`, `dnf`）
  - `raw_cells` の展開情報（着差/決まり手/SB/レース短評）
- `girls_races_*.csv` 由来:
  - `kaisai_day_no`, `kaisai_start_date`（開催日次）
- `raw_html/results/**/*.html` 由来:
  - 2車単以外のオッズ特徴（3連単・2車複・ワイド・人気順）
  - 払戻・人気順テーブル
  - `parse_race_detail_full_json` で取れる全テーブル/リンク情報

### 3. train/valid 分割（標準: DuckDB）

```bash
make split-duckdb FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
```

### 4. 学習

```bash
make train
```

1着モデルを学習する場合:

```bash
make train-top1
```

2モデルをまとめて学習する場合:

```bash
make train-dual
```

時間減衰重みを有効化する場合（新しいレースを重視）:

```bash
make train WEIGHT_MODE=time_decay DECAY_HALF_LIFE_DAYS=120 MIN_SAMPLE_WEIGHT=0.2
make train-top1 WEIGHT_MODE=time_decay DECAY_HALF_LIFE_DAYS=120 MIN_SAMPLE_WEIGHT=0.2
```

オッズ弱依存モデルを学習する場合（既定では `odds_2shatan_min_first` を除外）:

```bash
make train-weakodds
make train-top1-weakodds
```

除外する特徴量を変える場合:

```bash
make train-weakodds WEAK_DROP="odds_2shatan_min_first,race_rel_odds_2shatan_rank"
make train-top1-weakodds WEAK_DROP="odds_2shatan_min_first,race_rel_odds_2shatan_rank"
```

### 5. 評価（標準: DuckDB）

```bash
make eval-duckdb FROM=2026-02-01 TO=2026-02-25
```

1着モデルを評価する場合:

```bash
make eval-top1
```

オッズ弱依存モデルを評価する場合:

```bash
make eval-weakodds
make eval-top1-weakodds
```

### 5.1 2連単専用モデル（exacta直接学習）

```bash
make features-exacta
make train-exacta
make eval-exacta-model
```

`make eval-exacta-model` の出力:

- `data/ml_exacta/exacta_pred.csv`（レースごとの2連単候補）
- `data/ml_exacta/eval_summary.json`（`hit_at` と `auc`）

### 6. 2連単/3連単候補の生成

```bash
make exotic
```

出力件数を変える場合:

```bash
make exotic EXOTIC_OPTS="--exacta-top 20 --trifecta-top 50 --win-temperature 0.2"
```

`top1` モデルを1着確率として併用する場合:

```bash
make exotic EXOTIC_OPTS="--in-csv data/ml/valid_pred.csv --win-csv data/ml_top1/valid_pred.csv --exacta-top 20 --trifecta-top 50 --win-temperature 0.2"
```

### 7. チューニング（グリッド探索）

```bash
make tune
```

`top3` 専用チューニング（`top3_exact_match_rate` 基準）:

```bash
make tune-top3 TUNE_OPTS="--num-iterations 600 --learning-rates 0.02,0.03,0.05 --num-leaves 15,31,63 --min-data-in-leaf 10,20,40"
```

探索条件を変更する場合:

```bash
make tune TUNE_OPTS="--num-iterations 500 --learning-rates 0.03,0.05 --num-leaves 31,63 --min-data-in-leaf 20,40,80"
```

`top1` 専用チューニング（`winner_hit_rate` 基準）:

```bash
make tune-top1 TUNE_OPTS="--num-iterations 600 --learning-rates 0.02,0.03,0.05 --num-leaves 15,31,63 --min-data-in-leaf 10,20,40,80"
```

`top3` の `player_name` なしチューニング（`top3_exact_match_rate` 基準）:

```bash
make tune-top3-noplayer TUNE_OPTS="--num-iterations 600 --learning-rates 0.02,0.03,0.05 --num-leaves 15,31,63 --min-data-in-leaf 10,20,40"
```

オッズ弱依存チューニング（top3/top1）:

```bash
make tune-weakodds TUNE_OPTS="--num-iterations 500 --learning-rates 0.03,0.05 --num-leaves 15,31,63 --min-data-in-leaf 10,20,40"
make tune-top1-weakodds TUNE_OPTS="--num-iterations 500 --learning-rates 0.03,0.05 --num-leaves 15,31,63 --min-data-in-leaf 10,20,40"
```

時間減衰重みをチューニングにも適用する例:

```bash
make tune-top3 WEIGHT_MODE=time_decay DECAY_HALF_LIFE_DAYS=120 MIN_SAMPLE_WEIGHT=0.2
make tune-top1 WEIGHT_MODE=time_decay DECAY_HALF_LIFE_DAYS=120 MIN_SAMPLE_WEIGHT=0.2
```

### 7.1 時系列CV（再現性確認）

複数foldで時系列CVを回して、単発split依存を下げます。

```bash
make cv CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
make cv-top1 CV_OPTS="--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28"
```

出力:
- `data/ml_cv/cv_results.csv`, `data/ml_cv/cv_summary.json`
- `data/ml_cv_top1/cv_results.csv`, `data/ml_cv_top1/cv_summary.json`

### 8. 重要特徴量の確認

```bash
make importance
```

`top3` モデルと `top1` モデルの feature importance 上位を表示します。

### 9. 2連単/3連単の的中率評価（hit@N）

```bash
make eval-exotic
```

`data/ml/valid.csv`（実着順）と `data/ml/exacta_pred.csv` / `data/ml/trifecta_pred.csv` を照合して、  
`data/ml/exotic_eval_summary.json` に `hit@1,3,5,10,20` を出力します。

`generate_exotics.rb` のスコアは高精度で保存されるため、`eval-exotic` の順位判定は `predict` 実行時と整合しやすくなっています。

払戻CSVがある場合はROIも評価できます:

```bash
docker run --rm -v "$PWD:/app" -w /app gk-yosoku ruby scripts/evaluate_exotics.rb \
  --payout-csv data/raw/payouts.csv --unit 100
```

`payouts.csv` は `race_id,bet_type,combination,payout`（例: `2026-02-26-toride-05,exacta,2-6,1230`）を想定します。

任意のNで評価したい場合（直接実行例）:

```bash
docker run --rm -v "$PWD:/app" -w /app gk-yosoku ruby scripts/evaluate_exotics.rb --ns 1,5,10,20,50
```

### 10. レースURLから実予想を出す

```bash
make predict RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
```

出力件数などを変更する場合:

```bash
make predict RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/" \
  PREDICT_OPTS="--exacta-top 20 --trifecta-top 50 --win-temperature 0.2"
```

このコマンドは `data/ml/model.txt`（top3）と `data/ml_top1/model.txt`（top1）を使って、
Top1順位と2連単/3連単候補を表示します。

既定では2連単は従来の top1/top3 合成スコアを使います。  
exacta専用モデルを使いたい場合は `--exacta-model`（または `make predict-exacta`）を指定してください。

買い目改善オプション（例）:

```bash
make predict RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/" \
  PREDICT_OPTS="--no-bet-gap-threshold 0.03 --exacta-min-ev 1.05 --bankroll 10000 --unit 100 --kelly-cap 0.03"
```

- `--no-bet-gap-threshold`: 1位と2位の予測差が小さいレースを見送り判定
- `--exacta-min-ev`: EV（推定確率 × オッズ）が閾値未満の2連単を除外
- `--bankroll`, `--unit`, `--kelly-cap`: 簡易Kellyで推奨金額を表示
- `--exacta-second-win-exp`: 2連単の2着側に「1着力(top1)」を混ぜる強さ（0なら無効）
- 表の下に `均等買い総額`、`均等買い払戻レンジ`、`推奨額合計`、`トリガミ回避買い` も表示

`トリガミ回避買い` は、表示中の買い目を対象に「どれが当たっても購入総額を下回らない」ように配分できる場合、その配分案を表示します。成立しない場合は `不可` と表示します。

堅めの買い目を優先したい場合:

```bash
make predict RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/" \
  PREDICT_OPTS="--bet-style solid --exacta-top 10 --trifecta-top 10"
```

- `--bet-style standard`: 標準。スコア重視
- `--bet-style solid`: 堅め。低オッズ優先
- `--bet-style value`: 回収期待値重視

評価で良かったプリセットを使う場合:

```bash
# 先にhit@5専用プロファイルを学習（温度・指数を自動探索）
make learn-hit5-profile

# 早く回す場合（探索グリッドを絞る）
make learn-hit5-profile HIT5_LEARN_OPTS="--temp-grid 0.15,0.25 --exp-grid 0.8,1.0 --objective-n 5"

# 2連単/3連単のバランス重視
make predict-balanced RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# 3連単 hit@1 重視
make predict-trifecta RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# hit@5（2連単+3連単）重視
make predict-hit5 RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# 学習したhit@5プロファイルを適用
make predict-hit5-profile RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# 2連単 hit@1 を優先したプロファイルを学習
make learn-exacta-profile

# 2連単 hit@1 用プロファイルで valid を再評価
make eval-exacta-profile

# 3連単 hit@5 重視
make predict-tri5 RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# オッズ弱依存モデル（学習済みの data/ml_weakodds, data/ml_top1_weakodds を使う）
make predict-weakodds RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"

# exacta専用モデルを明示して使う
make predict-exacta RACE_URL="https://keirin.kdreams.jp/toride/racedetail/2320260225030004/"
```

現時点の検証結果（validデータ）:

- `default`（`data/ml` + `data/ml_top1`, temp=0.15）  
  `exacta_hit@1=0.4136`, `trifecta_hit@1=0.1914`
- `balanced`（`data/ml_noplayer/tuning_v2/trial_024` + `data/ml_top1/tuning_v2/trial_029`, temp=0.30）  
  `exacta_hit@1=0.4259`, `trifecta_hit@1=0.2716`
- `trifecta`（`data/ml_noplayer/tuning_v2/trial_027` + `data/ml_top1/tuning_v2/trial_002`, temp=0.20）  
  `exacta_hit@1=0.3951`, `trifecta_hit@1=0.2840`
- `hit5`（`data/ml_noplayer/tuning_v2/trial_024` + `data/ml_top1/tuning_v2/trial_002`, temp=0.35）  
  `exacta_hit@5=0.8086`, `trifecta_hit@5=0.5000`
- `tri5`（`data/ml_noplayer/tuning_v2/trial_008` + `data/ml_top1/tuning_v2/trial_014`, temp=0.15）  
  `exacta_hit@5=0.7593`, `trifecta_hit@5=0.5123`

追加比較メモ（2026-02-28）:

- `hit@5` 合計（`exacta_hit@5 + trifecta_hit@5`）は  
  `trial_024 + trial_002 + temp=0.35` が `1.3086` で最大（現行 `predict-hit5` と同一）
- `trifecta_hit@5` 単独は  
  `trial_008 + trial_014 + temp=0.15` が `0.5123` で最大（現行 `predict-tri5` と同一）

### 11. テスト実行

```bash
make test
```

`spec/scripts/*.rb` で、主要スクリプトのCLIテストを実行します。

### 12. HTMLの全量パース（探索用）

「今使っていない項目も含めて」取りたい場合は、以下でJSON化できます。

```bash
docker run --rm -v "$PWD:/app" -w /app gk-yosoku \
  ruby scripts/dump_race_html_json.rb \
  --html-file data/raw_html/results/20260226/result_xxx.html \
  --mode full \
  --out data/tmp/race_full.json
```

- `--mode basic`: 現在の予測で使う主要項目中心
- `--mode full`: `tables` / `links` / `result_rows` も含めて広く抽出

### まとめて実行（取得以外）

```bash
make pipeline FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
```

`pipeline` には `features-exacta` も含まれます。

### まとめて実行（取得から評価まで）

```bash
make full FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31 SLEEP=0.2
```

---

## Make変数

- `IMAGE`（既定: `gk-yosoku`）
- `FROM`（既定: `2026-01-01`）
- `TO`（既定: `2026-02-25`）
- `TRAIN_TO`（既定: `2026-01-31`）
- `SLEEP`（既定: `0.2`）
- `CACHE`（既定: `--cache`、必要時のみ `CACHE=--no-cache` を指定）
- `EXOTIC_OPTS`（既定: 空、`make exotic` の追加オプション。例: `--win-csv data/ml_top1/valid_pred.csv`）
- `TUNE_OPTS`（既定: 空、`make tune` の追加オプション）
- `CV_OPTS`（既定: 空、`make cv` の追加オプション）
- `HIT5_PROFILE`（既定: `data/ml/exotic_profile_hit5.json`、`make learn-hit5-profile` / `make predict-hit5` で使用）
- `HIT5_LEARN_OPTS`（既定: 空、`make learn-hit5-profile` の追加オプション）
- `EXACTA_PROFILE`（既定: `data/ml/exotic_profile_exacta_hit1.json`、`make learn-exacta-profile` / `make eval-exacta-profile` で使用）
- `EXACTA_LEARN_OPTS`（既定: `objective-n=1` と 2連単向け探索設定）
- `HIT5_TOP3_MODEL` / `HIT5_TOP3_ENCODERS`（既定: `trial_024`、hit@5学習時のtop3モデル）
- `HIT5_TOP1_MODEL` / `HIT5_TOP1_ENCODERS`（既定: `trial_002`、hit@5学習時のtop1モデル）
- `RACE_URL`（既定: 空、`make predict` で必須）
- `PREDICT_OPTS`（既定: 空、`make predict` の追加オプション）
- `WEIGHT_MODE`（既定: `none`、`none` or `time_decay`）
- `DECAY_HALF_LIFE_DAYS`（既定: `120`、`time_decay` の半減期）
- `MIN_SAMPLE_WEIGHT`（既定: `0.2`、`time_decay` の最小重み）
- `TOP3_TRAIN_OPTS` / `TOP1_TRAIN_OPTS`（各学習ターゲット固有の追加オプション）
- `TOP3_EVAL_OPTS` / `TOP1_EVAL_OPTS`（各評価ターゲット固有の追加オプション）
- `EXACTA_TRAIN_OPTS` / `EXACTA_EVAL_OPTS`（exacta専用モデルの追加オプション）

例:

```bash
make collect FROM=2026-01-01 TO=2026-02-25 SLEEP=0.1
```

キャッシュを無効化したい場合:

```bash
make collect FROM=2026-01-01 TO=2026-02-25 CACHE=--no-cache SLEEP=0.1
```

## 生成される主なファイル

### 取得

- `data/raw/girls_races_YYYYMMDD.csv`
- `data/raw/girls_results_YYYYMMDD.csv`
- `data/raw_html/kaisai_YYYYMMDD.html`
- `data/raw_html/results/YYYYMMDD/result_*.html`
- `data/raw/girls_errors_YYYYMMDD.csv`

`girls_results` には `result_status`（`normal`, `fall`, `dq`, `dns`, `dnf`）を含みます。
`girls_errors` には取得失敗・パース失敗・件数異常などの日次エラー/警告が保存されます。

### 特徴量・学習・評価

- `data/features/features_YYYYMMDD.csv`
- `data/ml/train.csv`
- `data/ml/valid.csv`
- `data/ml/model.txt`
- `data/ml/encoders.json`
- `data/ml/valid_pred.csv`
- `data/ml/eval_summary.json`
- `data/ml_top1/model.txt`
- `data/ml_top1/encoders.json`
- `data/ml_top1/valid_pred.csv`
- `data/ml_top1/eval_summary.json`
- `data/ml_exacta/train.csv`
- `data/ml_exacta/valid.csv`
- `data/ml_exacta/model.txt`
- `data/ml_exacta/encoders.json`
- `data/ml_exacta/valid_pair_pred.csv`
- `data/ml_exacta/exacta_pred.csv`
- `data/ml_exacta/eval_summary.json`
- `data/ml/exacta_pred.csv`
- `data/ml/trifecta_pred.csv`
- `data/ml/exotic_eval_summary.json`
- `data/ml/exotic_profile_exacta_hit1.json`
- `data/ml/exotic_eval_summary_exacta_profile.json`
- `data/ml/tuning/tune_leaderboard.csv`
- `data/ml/tuning/best_params.json`

## 指標（`make eval-duckdb`）

- `auc`
- `top3_exact_match_rate`
- `top3_recall_at3`
- `winner_hit_rate`

## 指標（`make eval-exotic`）

- `exacta.hit_at.N` : 正解2連単が上位N候補に含まれる率
- `trifecta.hit_at.N` : 正解3連単が上位N候補に含まれる率

## 補足: スクリプトを直接実行したい場合

通常は `make` 推奨です。  
直接実行も可能ですが、`docker run ... ruby scripts/*.rb` を都度書く必要があります。

`top1` 列を使うため、古い特徴量がある場合は `make parquet-bootstrap` と `make features-duckdb` を再実行してください。

## ドキュメント

- 全体像: `docs/project-plan.md`
- DuckDBロールバック手順: `docs/duckdb-rollback-playbook.md`
- DuckDBテスト戦略: `docs/duckdb-test-strategy.md`
