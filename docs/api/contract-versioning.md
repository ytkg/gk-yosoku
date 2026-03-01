# APIレスポンス契約のバージョニング運用

対象: `POST /predict` のレスポンス契約（`code`, `message`, `detail`）

## 1. 契約ソース
- 成功系: `docs/api/predict-success.schema.json`
- 失敗系: `docs/api/predict-error.schema.json`

## 2. 変更分類
- 破壊的変更（major）
  - 既存フィールドの削除
  - 既存フィールドの型変更
  - 既存の `enum` 値削除
- 非破壊変更（minor）
  - 任意フィールドの追加
  - 既存 `enum` 値の追加
  - `detail` 内の拡張（既存クライアントに影響しない範囲）
- 文言・コメントのみ（patch）
  - スキーマ意味を変えない説明変更

## 3. 破壊的変更時の運用
1. 事前にIssueを作成し、影響範囲を明記する。
2. 移行期間を設定し、親Issue `#32` に計画を追記する。
3. PRで「契約変更あり」を明示し、レビュー時に承認を得る。
4. 変更後はREADMEと関連Issueを更新する。

## 4. レビュー運用
- PRで「契約変更あり/なし」を必ずチェックする。
- 契約変更ありの場合は、以下を必須とする。
  - スキーマ更新
  - contract test更新
  - 変更理由の記載

## 5. CI/テスト
- `spec/apps/api/app_spec.rb` のJSON Schema検証を契約テストとして扱う。
- レスポンス構造を変更するPRは、同specの通過を必須とする。
