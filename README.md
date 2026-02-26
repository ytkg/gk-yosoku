# gk-yosoku

ガールズケイリン予測のためのデータ取得・学習パイプラインです。  
基本操作は **Makefile経由** で実行します。

## モデル構成（重要）

このプロジェクトは、最終目的の **2連単/3連単予測** のためにモデルを2つ使います。

- `top3` モデル: 「3着以内に入る確率」を予測
- `top1` モデル: 「1着になる確率」を予測

その後、`make exotic` で両モデルの予測を合成し、2連単/3連単候補を作成します。  
つまり、最終成果物は「単一モデル」ではなく、**2モデル+合成ロジック** です。

## 予測フロー

1. `make features` で特徴量作成
2. `make split` で学習/検証データ分割
3. `make train` と `make train-top1` で2モデル学習
4. `make exotic` で2連単/3連単候補を生成
5. `make eval-exotic` で hit@N を確認

## 前提

- Docker
- GNU Make（通常 `make`）

## クイックスタート

```bash
make build
make help
```

## 主要コマンド（Makefile前提）

### 1. データ取得

```bash
make collect FROM=2025-01-01 TO=2025-12-31 SLEEP=0.2
```

### 2. 特徴量作成

```bash
make features FROM=2025-01-01 TO=2026-02-25
```

### 3. train/valid 分割

```bash
make split FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
```

### 4. 学習

```bash
make train
```

1着モデルを学習する場合:

```bash
make train-top1
```

### 5. 評価

```bash
make eval
```

1着モデルを評価する場合:

```bash
make eval-top1
```

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

探索条件を変更する場合:

```bash
make tune TUNE_OPTS="--num-iterations 500 --learning-rates 0.03,0.05 --num-leaves 31,63 --min-data-in-leaf 20,40,80"
```

### 8. 2連単/3連単の的中率評価（hit@N）

```bash
make eval-exotic
```

`data/ml/valid.csv`（実着順）と `data/ml/exacta_pred.csv` / `data/ml/trifecta_pred.csv` を照合して、  
`data/ml/exotic_eval_summary.json` に `hit@1,3,5,10,20` を出力します。

任意のNで評価したい場合（直接実行例）:

```bash
docker run --rm -v "$PWD:/app" -w /app gk-yosoku ruby scripts/evaluate_exotics.rb --ns 1,5,10,20,50
```

### 9. レースURLから実予想を出す

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

### 10. テスト実行

```bash
make test
```

`spec/scripts_cli_spec.rb` で、主要スクリプトのCLIテストを実行します。

### まとめて実行（取得以外）

```bash
make pipeline FROM=2025-01-01 TO=2026-02-25 TRAIN_TO=2026-01-31
```

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
- `RACE_URL`（既定: 空、`make predict` で必須）
- `PREDICT_OPTS`（既定: 空、`make predict` の追加オプション）

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

`girls_results` には `result_status`（`normal`, `fall`, `dq`, `dns`, `dnf`）を含みます。

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
- `data/ml/exacta_pred.csv`
- `data/ml/trifecta_pred.csv`
- `data/ml/exotic_eval_summary.json`
- `data/ml/tuning/tune_leaderboard.csv`
- `data/ml/tuning/best_params.json`

## 指標（`make eval`）

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

`top1` 列を使うため、古い `features_*.csv` を使っている場合は `make features` を再実行してください。

## ドキュメント

- 全体像: `docs/project-plan.md`
