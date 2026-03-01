# API設定

## 環境変数

### `GK_PREDICT_TIMEOUT_SEC`
- 用途: `/predict` の実行タイムアウト秒
- 既定: `30`
- 例:
```bash
GK_PREDICT_TIMEOUT_SEC=60 make api-start
```

## `.env` 運用
- `Makefile` は `.env` がある場合に自動読込します。
- 例:
```bash
cp .env.example .env
make api-start
```

## 補足
- `API_BASE_URL` は `make api-health` / `make api-predict` / `make api-smoke` の接続先切替に使えます。
- `PAYLOAD` は `make api-predict` で使う入力JSONファイルパスです。
