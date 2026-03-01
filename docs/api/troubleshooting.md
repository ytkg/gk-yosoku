# APIトラブルシュート

## 1. まず確認すること
1. API起動確認: `make api-health`
2. 代表payload確認: `make api-predict PAYLOAD=docs/api/request-examples/predict-basic.json`
3. スモーク確認: `make api-smoke`

## 2. エラーコード別

### `invalid_request`
- 意味: リクエスト形式不正（例: `url` 欠落）
- 再現:
  - `make api-predict PAYLOAD=docs/api/request-examples/predict-missing-url.json`
- 対処:
  - payloadに `url` を追加

### `predict_failed`
- 意味: 予測CLI実行失敗（URL不正、入力データ不正など）
- 再現:
  - `make api-predict PAYLOAD=docs/api/request-examples/predict-invalid-url.json`
- 対処:
  - URL形式（`.../<venue>/racedetail/<16桁>/`）を確認
  - モデル/encoderファイルのパスを確認

### `predict_timeout`
- 意味: 予測が `GK_PREDICT_TIMEOUT_SEC` を超過
- 再現:
  - `make api-predict-timeout-check`
- 対処:
  - `GK_PREDICT_TIMEOUT_SEC` を増やす
  - 入力URLやI/O負荷を見直す

### `internal_error`
- 意味: API内部で予期しない例外
- 対処:
  - `make api-logs` でログ確認
  - 直近変更とstack traceを照合

## 3. ログ確認
- 前面起動時: 実行ターミナル出力を確認
- バックグラウンド起動時: `make api-logs`
