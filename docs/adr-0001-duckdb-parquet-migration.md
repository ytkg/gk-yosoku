# ADR-0001: DuckDB/Parquet 中心データ基盤への移行

- Status: Proposed
- Status: Accepted
- Date: 2026-03-01
- Decision Makers: _TBD_

## Context

現行は CSV 中心のデータパイプラインで運用している。  
特徴量生成・split・評価で同じデータを繰り返し読み書きするため、以下の課題がある。

- 型崩れ/欠損の検知が遅い
- 学習データ生成が遅い
- 再現性の基準（同じ処理を同じ手順で再実行）が弱い

## Decision

データ保存形式を Parquet に移行し、結合・集計・split・検証は DuckDB で実行する。  
学習器都合で必要な TSV/CSV は最終段だけ一時生成する。

固定決定:

1. DuckDBファイルは `data/duckdb/gk_yosoku.duckdb` で固定する
2. Parquetパーティションは `race_date=YYYY-MM-DD` で統一する
3. 一意キーは `race_id + car_number` で統一する
4. `result_status != normal` は features生成時に除外する
5. 並走中に差分が出た場合は CSV版を正とする
6. CI比較テストは当面「短期データ」中心で運用する

## Scope

- In:
  - `collect` の Parquet 出力追加
  - 特徴量生成 (`features`) の DuckDB SQL 化
  - split/eval の DuckDB 化
- Out:
  - 推論API仕様変更（別ADR）
  - モデルアルゴリズム変更（別ADR）

## Alternatives Considered

1. CSV 継続 + Ruby最適化
- Pros: 変更量が小さい
- Cons: 型管理と再現性の課題が残る

2. Polars/Pandas 中心へ移行
- Pros: 柔軟性が高い
- Cons: 既存Ruby資産との一貫性が下がる

3. DuckDB/Parquet（採用）
- Pros: SQL中心で再現性と速度が両立
- Cons: SQL/スキーマ管理の運用整備が必要

## Consequences

- Good:
  - データ契約が明確化される
  - 比較検証をSQLで固定化できる
- Bad:
  - 移行期間は CSV/Parquet 併用で運用が複雑化する

## Rollout Plan

1. Phase 1: CSV + Parquet 二重出力
2. Phase 2: features/split/eval を DuckDB 優先に切替
3. Phase 3: CSV中心フローを縮退

補足:

- 並走（CSVとDuckDB/Parquetの同時運用）は実施する
- 並走期間や終了基準の詳細値は後決めとする

## Acceptance Criteria

1. `features` 件数差分が 0
2. 重要列（`race_id`, `car_number`, `rank`, `top1`, `top3`）完全一致
3. 連続値列は許容誤差 `1e-9` 以内

## Open Questions

1. 旧CSV成果物をいつ削除するか
