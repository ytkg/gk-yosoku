# API経由CLIの終了コード規約

対象: `ruby scripts/predict_race.rb --api-url ...`

- `0`: 成功
- `1`: 未分類エラー
- `2`: `invalid_request`
- `3`: `predict_failed`
- `4`: `predict_timeout`
- `5`: `internal_error`
- `6`: APIレスポンスが非JSON
- `7`: API接続失敗（通信例外）
