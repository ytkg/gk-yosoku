# DuckDB/Parquet 移行 Runbook（ドラフト）

## 目的

- CSV中心フローから DuckDB/Parquet 中心フローへ安全に移行する

## 前提

1. Docker イメージに DuckDB CLI または duckdb gem を導入済み
2. 既存CSVフローが現状で動作している
3. `data/lake`, `data/marts`, `data/duckdb` を作成可能
4. DuckDBファイルは `data/duckdb/gk_yosoku.duckdb` を使用
5. 差分発生時の正は CSV版とする

## Phase 1: 併用開始（CSV + Parquet）

1. 既存 `collect` を実行
2. 同じ入力から Parquet へ二重出力
3. 日次で件数比較を実行

方針メモ:

- 並走は必須で実施する
- 並走期間（週数）は固定せず、差分状況を見て確定する

完了条件:

1. 連続7日で件数差分 0
2. 主要列差分 0

## Phase 2: features を DuckDB 優先へ切替

1. `features_v1.sql` を確定
2. `make features-duckdb` を追加
3. 既存 `make features` と同値比較

完了条件:

1. 比較対象期間で差分ルールを満たす
2. 既存学習/評価コマンドが成功する

## Phase 3: split/eval を DuckDB 化

1. split SQL を導入 (`split_train_valid.sql`)
2. eval向け集計を SQL 化
3. 既存評価JSONと比較

完了条件:

1. `eval_summary` の主要指標差分が許容範囲内
2. CIでCSV版比較テストが常時成功

## Phase 4: CSV縮退

1. 既存CSV成果物を「互換用途のみ」に限定
2. ドキュメントと運用手順を更新
3. 旧パス依存ジョブを削除

完了条件:

1. 本番系ジョブが全て DuckDB/Parquet 経由
2. 障害時フォールバック手順が更新済み

## ロールバック手順

1. フェーズ切替ごとにタグを打つ
2. 差分不整合時は前フェーズの `make` ターゲットへ戻す
3. 不整合原因（スキーマ/SQL/データ欠損）を分類して再実施

## 監視項目

1. 日次件数（raw/features/train/valid）
2. 欠損率（主要列）
3. 評価指標（auc, winner_hit_rate, top3_exact_match_rate）

## 未決事項

1. 並走期間（未確定。並走は実施する）
2. `duckdb` ファイルのバックアップ運用
