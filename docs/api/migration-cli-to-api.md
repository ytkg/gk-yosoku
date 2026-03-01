# CLIからSinatra APIへのマイグレーション

対象: これまで `ruby scripts/predict_race.rb ...` を直接実行していた利用者

## 1. 方針
- 運用はローカルのみ（デプロイしない）
- 予測実行は `POST /predict` に統一
- CLIはAPI内部で呼び出されるため、既存オプションの多くはpayloadで引き継げる

## 2. 起動手順（ローカル）
```bash
make build
docker run --rm -p 4567:4567 -v "$PWD:/app" -w /app gk-yosoku bundle exec rackup -o 0.0.0.0 -p 4567
```

## 3. 最小移行（URLのみ）
従来CLI:
```bash
ruby scripts/predict_race.rb \
  --url https://keirin.kdreams.jp/toride/racedetail/2320260225030001/
```

移行後API:
```bash
curl -sS -X POST http://127.0.0.1:4567/predict \
  -H 'Content-Type: application/json' \
  -d '{
    "url": "https://keirin.kdreams.jp/toride/racedetail/2320260225030001/"
  }'
```

## 4. オプション対応表（主要）
- `--model-top3` -> `"model_top3"`
- `--encoders-top3` -> `"encoders_top3"`
- `--model-top1` -> `"model_top1"`
- `--encoders-top1` -> `"encoders_top1"`
- `--exacta-top` -> `"exacta_top"`
- `--trifecta-top` -> `"trifecta_top"`
- `--win-temperature` -> `"win_temperature"`
- `--bet-gap-threshold` -> `"no_bet_gap_threshold"`
- `--exacta-min-ev` -> `"exacta_min_ev"`
- `--bankroll` -> `"bankroll"`
- `--unit` -> `"unit"`
- `--kelly-cap` -> `"kelly_cap"`
- `--bet-style` -> `"bet_style"`
- `--cache` / `--no-cache` -> `"use_cache": true/false`
- `--exacta-model` / `--no-exacta-model` -> `"use_exacta_model": true/false`

## 5. 注意点
- `POST /predict` は成功時 `detail` に構造化JSONを返す。
- 契約は `docs/api/predict-success.schema.json` / `docs/api/predict-error.schema.json` を参照。
- 契約変更時の運用は `docs/api/contract-versioning.md` を参照。
