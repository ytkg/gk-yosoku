# Model Manifest Contract

## Purpose

- Fix the minimum contract for `model_manifest.json`.
- Keep evaluation outputs traceable to the manifest used by inference/training.

## Required Keys

`model_manifest.json` must include:

1. `model_id`
2. `target_col`
3. `feature_set_version`
4. `feature_columns_digest`
5. `train_window` (`from`, `to`)
6. `valid_window` (`from`, `to`)
7. `metrics`

## Runtime Validation

- `scripts/predict_race.rb` validates:
  - required keys
  - `feature_columns_digest` consistency
- Validation failure must stop prediction.

## Evaluation Linkage

- `scripts/evaluate_lightgbm.rb` writes `eval_summary.json` with `model_manifest`:
  - `path`
  - `present`
  - `summary` (`model_id`, `target_col`, `feature_set_version`, `feature_columns_digest`, `train_window`, `valid_window`)

This keeps evaluation reports and model artifacts traceable.
