# `/predict` Payload仕様

`POST /predict` は JSON body でパラメータを受け取り、内部で `scripts/predict_race.rb` を実行します。

## 必須
- `url` (`string`)
  - レース詳細URL
  - 例: `https://keirin.kdreams.jp/toride/racedetail/2320260225030001/`

## 任意
- `model_top3` (`string`)
- `encoders_top3` (`string`)
- `model_top1` (`string`)
- `encoders_top1` (`string`)
- `model_exacta` (`string`)
- `encoders_exacta` (`string`)
- `raw_dir` (`string`)
- `cache_dir` (`string`)
- `win_temperature` (`number`)
- `exotic_profile` (`string`)
- `exacta_win_exp` (`number`)
- `exacta_second_exp` (`number`)
- `exacta_second_win_exp` (`number`)
- `trifecta_win_exp` (`number`)
- `trifecta_second_exp` (`number`)
- `trifecta_third_exp` (`number`)
- `exacta_top` (`integer`)
- `trifecta_top` (`integer`)
- `no_bet_gap_threshold` (`number`)
- `exacta_min_ev` (`number`)
- `bankroll` (`number`)
- `unit` (`integer`)
- `kelly_cap` (`number`)
- `bet_style` (`string`)
- `use_exacta_model` (`boolean`)
- `use_cache` (`boolean`)

## CLIオプション対応
- `--url` <- `url`
- `--model-top3` <- `model_top3`
- `--encoders-top3` <- `encoders_top3`
- `--model-top1` <- `model_top1`
- `--encoders-top1` <- `encoders_top1`
- `--model-exacta` <- `model_exacta`
- `--encoders-exacta` <- `encoders_exacta`
- `--raw-dir` <- `raw_dir`
- `--cache-dir` <- `cache_dir`
- `--win-temperature` <- `win_temperature`
- `--exotic-profile` <- `exotic_profile`
- `--exacta-win-exp` <- `exacta_win_exp`
- `--exacta-second-exp` <- `exacta_second_exp`
- `--exacta-second-win-exp` <- `exacta_second_win_exp`
- `--trifecta-win-exp` <- `trifecta_win_exp`
- `--trifecta-second-exp` <- `trifecta_second_exp`
- `--trifecta-third-exp` <- `trifecta_third_exp`
- `--exacta-top` <- `exacta_top`
- `--trifecta-top` <- `trifecta_top`
- `--bet-gap-threshold` <- `no_bet_gap_threshold`
- `--exacta-min-ev` <- `exacta_min_ev`
- `--bankroll` <- `bankroll`
- `--unit` <- `unit`
- `--kelly-cap` <- `kelly_cap`
- `--bet-style` <- `bet_style`
- `--exacta-model` / `--no-exacta-model` <- `use_exacta_model`
- `--cache` / `--no-cache` <- `use_cache`
