# PR1: 学習/推論 特徴量差分インベントリ

対象:
- 学習側: `scripts/build_features.rb`
- 推論側: `scripts/predict_race.rb` (`build_feature_rows`)

## 1. 現状サマリ

- 共通化済みの一部ロジック:
  - `GK::FeatureEngineCommon.recent_rate_smoothed_f`
  - `GK::FeatureEngineCommon.enrich_relative_ranks!`
- ただし、特徴量生成の主処理はまだ2実装に分岐している。

## 2. 主要差分

1. 同名特徴量でも算出値が一致しない項目がある
- `same_meet_prev_day_rank_inv`
- `same_meet_recent3_synergy`
- 学習側は計算済み、推論側は現状 `"0.0"` 固定

2. 入力データの取得経路が異なる
- 学習側: 日次CSV + `raw_html` キャッシュ
- 推論側: 単一レースURLのHTMLを都度取得

3. 出力スキーマ責務が異なる
- 学習側: `rank/top1/top3` を含む教師データ行
- 推論側: 予測用入力行（教師ラベルなし）

4. メソッド構造の差
- 学習側: `build_rows_for_date` が日次・複数レースを一括処理
- 推論側: `build_feature_rows` が単一レースを処理

5. 周辺処理の結合度
- 推論側は特徴量生成と予測・券種計算が同一クラスに同居
- 学習側は特徴量生成に責務が集中

## 3. 置換優先順位（PR1）

1. 優先度A（先に共通化）
- プレイヤー履歴率:
  - `hist_*`, `recent*`, `days_since_last`
- 開催内履歴:
  - `same_meet_*`
- 相性履歴:
  - `pair_*`, `triplet_*`
- レース内相対順位:
  - `race_rel_*`

2. 優先度B（Aの後）
- 入力正規化層（CSV行/URL取得HTMLから共通入力DTOへ変換）
- 型変換/フォーマット（文字列化タイミングの統一）

3. 優先度C（最後）
- 推論固有の予測/券種計算ロジック分離
- 学習固有の出力列制御（`rank/top1/top3`）

## 4. 非対象（PR1で直接は扱わない）

- model manifest の厳密運用（PR2）
- API入出力スキーマ拡張（PR2）

## 5. 実装方針メモ

- `core/features/feature_builder.rb` を単一入口として育てる
- 学習/推論で同じ計算関数を通し、差は「入力アダプタ」と「出力アダプタ」で吸収する
- 最終的に「同一入力 -> 同一特徴量」をゴールデンテストで固定する
