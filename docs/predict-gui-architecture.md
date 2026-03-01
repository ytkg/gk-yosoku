# 予想GUIアーキテクチャ案（自分専用・非公開）

## 目的

- 学習やデータ収集はGUI化しない
- レースURLを入力して予想結果（Top1 / 2連単 / 3連単）を表示する
- ローカル利用のみ（外部公開しない）

## 方針（結論）

- フロントエンド: React + Vite
- バックエンド: Ruby + Sinatra（薄いAPI）
- 予想エンジン: 既存の `scripts/predict_race.rb` を再利用
- 実行環境: Docker Compose（`127.0.0.1` バインドのみ）

ジョブ基盤（Sidekiq等）は初期段階では不要。  
予想処理のみなら同期APIで十分運用できる。

## 全体構成

1. Browser（ローカル）
2. Frontend（React）
3. API（Sinatra）
4. Predictor（`scripts/predict_race.rb`）
5. Model files（`data/ml*/model.txt`, `encoders.json`）

通信は `Frontend -> API` のみ。  
APIは内部で `predict_race.rb` を実行し、結果JSONを返す。

## なぜこの構成か

- 既存資産（Rubyスクリプト、モデル、特徴量ロジック）を最大再利用できる
- 非公開運用なので、認証基盤や大規模な非同期基盤は過剰
- Docker Composeで再現性を確保しやすい

## API設計（最小）

### `POST /api/predict`

リクエスト:

```json
{
  "race_url": "https://keirin.kdreams.jp/toride/racedetail/2320260225030004/",
  "preset": "balanced"
}
```

- `race_url` は必須
- `preset` は任意（`default` / `balanced` / `trifecta`）

レスポンス（例）:

```json
{
  "race": {
    "race_id": "2026-02-25-toride-04",
    "venue": "toride",
    "race_number": 4,
    "race_date": "2026-02-25"
  },
  "top1": [
    { "rank": 1, "car_number": 2, "player_name": "A", "score_top1": 0.4123, "score_top3": 0.8112 }
  ],
  "exacta": [
    { "rank": 1, "first": 2, "second": 6, "score": 0.0821, "odds": 12.4, "ev": 1.02 }
  ],
  "trifecta": [
    { "rank": 1, "first": 2, "second": 6, "third": 1, "score": 0.0312, "odds": 45.8, "ev": 1.43 }
  ],
  "meta": {
    "preset": "balanced",
    "win_temperature": 0.30,
    "elapsed_ms": 1834
  }
}
```

### `GET /api/health`

- 死活監視用
- `{"status":"ok"}` を返すだけ

## 重要実装ポイント

1. `predict_race.rb` に `--format json` を追加する  
   現在はCLI表示中心のため、API連携にはJSON出力が安定
2. APIはJSONをそのまま返す薄い層にする
3. `preset` ごとにモデルパスと温度パラメータを固定管理する

## Preset管理案

- `default`: `data/ml` + `data/ml_top1`, temp `0.15`
- `balanced`: `data/ml_noplayer` + `data/ml_top1`, temp `0.30`
- `trifecta`: `data/ml_noplayer/tuning_v2/trial_024` + `data/ml_top1/tuning_v2/trial_029`, temp `0.15`

定義はAPI内の1ファイル（例: `app/presets.rb`）に集約する。

## 画面要件（最小）

1. レースURL入力欄
2. Preset選択（default / balanced / trifecta）
3. 実行ボタン
4. Top1順位テーブル
5. 2連単テーブル（score / odds / ev）
6. 3連単テーブル（score / odds / ev）
7. エラー表示（URL不正、取得失敗、オッズ取得失敗）

## エラーハンドリング方針

- APIエラー形式は統一する

```json
{
  "error": {
    "code": "PREDICT_FAILED",
    "message": "予想処理に失敗しました",
    "detail": "HTTP 404: ..."
  }
}
```

- HTTPステータス目安
  - `400`: 入力不正
  - `422`: URLは正しいが予想不能
  - `500`: 内部エラー

## セキュリティ（ローカル前提）

- `docker-compose.yml` で `127.0.0.1` のみバインド
- 外部公開しない（ルータ開放・Cloud公開なし）
- CORSは `http://localhost:<frontend-port>` のみ許可

## 運用

- 起動: `docker compose up --build`
- 停止: `docker compose down`
- ログ確認: `docker compose logs -f api`

## 将来の拡張（必要になったら）

1. タイムアウト頻発時のみ簡易ジョブ化
2. 予想履歴保存（SQLite）
3. オッズ更新ポーリング

## 実装ステップ（推奨順）

1. `predict_race.rb` に JSON出力オプション追加
2. Sinatraで `POST /api/predict` 実装
3. Reactで入力フォームと結果表示を実装
4. Composeでローカル一括起動
5. エラー表示とバリデーションを整備
