IMAGE ?= gk-yosoku
FROM ?= 2026-01-01
TO ?= 2026-02-25
TRAIN_TO ?= 2026-01-31
SLEEP ?= 0.2
CACHE ?= --cache
TUNE_OPTS ?=
EXOTIC_OPTS ?=
PREDICT_OPTS ?=
RACE_URL ?=
WEAK_DROP ?= odds_2shatan_min_first
WEIGHT_MODE ?= none
DECAY_HALF_LIFE_DAYS ?= 120
MIN_SAMPLE_WEIGHT ?= 0.2
TOP3_TRAIN_OPTS ?=
TOP1_TRAIN_OPTS ?=
TOP3_EVAL_OPTS ?=
TOP1_EVAL_OPTS ?=
EXACTA_TRAIN_OPTS ?=
EXACTA_EVAL_OPTS ?=
CV_OPTS ?=
LAKE_DIR ?= data/lake
PARQUET_DB ?= data/duckdb/gk_yosoku.duckdb
EVAL_DUCKDB_OPTS ?=
DUCKDB_BACKUP_DIR ?= data/duckdb_backup
HIT5_PROFILE ?= data/ml/exotic_profile_hit5.json
HIT5_LEARN_OPTS ?=
EXACTA_PROFILE ?= data/ml/exotic_profile_exacta_hit1.json
EXACTA_LEARN_OPTS ?= --objective-n 1 --exacta-weight 1.0 --trifecta-weight 0.0 --temp-grid 0.1,0.12,0.15,0.18,0.2,0.25,0.3 --exp-grid 0.6,0.8,1.0,1.2,1.4 --exacta-second-win-exp-grid 0.0,0.2,0.4,0.7,1.0 --max-trials 2500 --random-seed 42
HIT5_TOP3_MODEL ?= data/ml_noplayer/tuning_v2/trial_024/model.txt
HIT5_TOP3_ENCODERS ?= data/ml_noplayer/tuning_v2/trial_024/encoders.json
HIT5_TOP1_MODEL ?= data/ml_top1/tuning_v2/trial_002/model.txt
HIT5_TOP1_ENCODERS ?= data/ml_top1/tuning_v2/trial_002/encoders.json

DOCKER_RUN = docker run --rm -v "$$PWD:/app" -w /app $(IMAGE)

.PHONY: help build collect parquet-bootstrap features features-duckdb split split-duckdb validate-duckdb eval-duckdb backup-duckdb restore-duckdb features-exacta train eval train-top1 eval-top1 train-exacta eval-exacta-model train-dual eval-dual train-weakodds eval-weakodds train-top1-weakodds eval-top1-weakodds exotic eval-exotic exotic-weakodds eval-exotic-weakodds learn-hit5-profile learn-exacta-profile eval-exacta-profile tune tune-top1 tune-top3 tune-top3-noplayer tune-weakodds tune-top1-weakodds cv cv-top1 importance predict predict-exacta predict-balanced predict-trifecta predict-hit5 predict-hit5-profile predict-tri5 predict-weakodds test pipeline full

help:
	@echo "Targets:"
	@echo "  make build"
	@echo "  make collect   FROM=YYYY-MM-DD TO=YYYY-MM-DD SLEEP=0.2 CACHE=--cache"
	@echo "  make parquet-bootstrap FROM=YYYY-MM-DD TO=YYYY-MM-DD LAKE_DIR=data/lake PARQUET_DB=data/duckdb/gk_yosoku.duckdb"
	@echo "  make features  FROM=YYYY-MM-DD TO=YYYY-MM-DD"
	@echo "  make features-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD LAKE_DIR=data/lake PARQUET_DB=data/duckdb/gk_yosoku.duckdb"
	@echo "  make split     FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make split-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make validate-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD"
	@echo "  make eval-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD EVAL_DUCKDB_OPTS='--target-col top3'"
	@echo "  make backup-duckdb"
	@echo "  make restore-duckdb SRC=path/to/gk_yosoku_YYYYMMDDTHHMMSSZ.duckdb"
	@echo "  make features-exacta"
	@echo "  make train"
	@echo "  make eval"
	@echo "  make train-top1"
	@echo "  make eval-top1"
	@echo "  make train-exacta"
	@echo "  make eval-exacta-model"
	@echo "  make train-dual"
	@echo "  make eval-dual"
	@echo "  make train-weakodds WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make eval-weakodds"
	@echo "  make train-top1-weakodds WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make eval-top1-weakodds"
	@echo "  make exotic    EXOTIC_OPTS='--win-csv data/ml_top1/valid_pred.csv --exacta-top 10 --trifecta-top 20'"
	@echo "  make eval-exotic"
	@echo "  make exotic-weakodds EXOTIC_OPTS='--exacta-top 20 --trifecta-top 50 --win-temperature 0.3'"
	@echo "  make eval-exotic-weakodds"
	@echo "  make learn-hit5-profile HIT5_PROFILE=data/ml/exotic_profile_hit5.json"
	@echo "  make learn-exacta-profile EXACTA_PROFILE=data/ml/exotic_profile_exacta_hit1.json"
	@echo "  make eval-exacta-profile"
	@echo "  make tune      TUNE_OPTS='--num-iterations 400 --learning-rates 0.03,0.05'"
	@echo "  make tune-top3 TUNE_OPTS='--learning-rates 0.03,0.05 --num-leaves 15,31,63'"
	@echo "  make tune-top1 TUNE_OPTS='--learning-rates 0.03,0.05 --drop-features player_name'"
	@echo "  make tune-top3-noplayer TUNE_OPTS='--learning-rates 0.03,0.05 --num-leaves 15,31,63'"
	@echo "  make tune-weakodds WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make tune-top1-weakodds WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make cv        CV_OPTS='--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make cv-top1   CV_OPTS='--from-date 2025-01-01 --to-date 2026-02-25 --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make importance"
	@echo "  make predict   RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/' PREDICT_OPTS='--exacta-top 20 --trifecta-top 50'"
	@echo "  make predict-exacta RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-balanced RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-trifecta RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-hit5 RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-hit5-profile RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-tri5 RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make predict-weakodds RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/'"
	@echo "  make test"
	@echo "  make pipeline  FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make full      FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD SLEEP=0.2 CACHE=--cache"

build:
	docker build -t $(IMAGE) .

collect:
	$(DOCKER_RUN) ruby scripts/collect_data.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		$(CACHE) \
		--sleep $(SLEEP)

parquet-bootstrap:
	$(DOCKER_RUN) ruby scripts/parquet_bootstrap.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--in-dir data/raw \
		--lake-dir $(LAKE_DIR) \
		--db-path $(PARQUET_DB)

features:
	$(DOCKER_RUN) ruby scripts/build_features.rb \
		--from-date $(FROM) \
		--to-date $(TO)

features-duckdb:
	$(DOCKER_RUN) ruby scripts/build_features_duckdb.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--in-dir data/raw \
		--out-dir data/features \
		--raw-html-dir data/raw_html \
		--lake-dir $(LAKE_DIR) \
		--db-path $(PARQUET_DB)

split:
	$(DOCKER_RUN) ruby scripts/split_features.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--train-to $(TRAIN_TO)

split-duckdb:
	$(DOCKER_RUN) ruby scripts/split_features_duckdb.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--train-to $(TRAIN_TO) \
		--lake-dir $(LAKE_DIR) \
		--out-dir data/ml \
		--mart-dir data/marts/train_valid \
		--db-path $(PARQUET_DB)

validate-duckdb:
	$(DOCKER_RUN) ruby scripts/validate_duckdb_parity.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--csv-features-dir data/features \
		--lake-dir $(LAKE_DIR) \
		--feature-set-version v1 \
		--report-dir reports/duckdb_validation \
		--db-path $(PARQUET_DB)

eval-duckdb:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm_duckdb.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--model data/ml/model.txt \
		--encoders data/ml/encoders.json \
		--out-dir data/ml \
		--target-col top3 \
		--lake-dir $(LAKE_DIR) \
		--feature-set-version v1 \
		--db-path $(PARQUET_DB) \
		$(EVAL_DUCKDB_OPTS)

backup-duckdb:
	$(DOCKER_RUN) ruby scripts/backup_duckdb.rb \
		--db-path $(PARQUET_DB) \
		--out-dir $(DUCKDB_BACKUP_DIR) \
		--mode backup

restore-duckdb:
	@if [ -z "$(SRC)" ]; then echo "SRC is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/backup_duckdb.rb \
		--db-path $(PARQUET_DB) \
		--mode restore \
		--src "$(SRC)"

features-exacta:
	$(DOCKER_RUN) ruby scripts/build_exacta_features.rb \
		--train-csv data/ml/train.csv \
		--valid-csv data/ml/valid.csv \
		--out-dir data/ml_exacta

train:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top3 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_TRAIN_OPTS)

eval:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 $(TOP3_EVAL_OPTS)

train-top1:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top1 --out-dir data/ml_top1 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_TRAIN_OPTS)

eval-top1:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model data/ml_top1/model.txt --encoders data/ml_top1/encoders.json --out-dir data/ml_top1 $(TOP1_EVAL_OPTS)

train-exacta:
	$(DOCKER_RUN) ruby scripts/train_exacta_lightgbm.rb --train-csv data/ml_exacta/train.csv --valid-csv data/ml_exacta/valid.csv --out-dir data/ml_exacta --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(EXACTA_TRAIN_OPTS)

eval-exacta-model:
	$(DOCKER_RUN) ruby scripts/evaluate_exacta_lightgbm.rb --model data/ml_exacta/model.txt --valid-csv data/ml_exacta/valid.csv --encoders data/ml_exacta/encoders.json --out-dir data/ml_exacta $(EXACTA_EVAL_OPTS)

train-dual:
	$(MAKE) train
	$(MAKE) train-top1

eval-dual:
	$(MAKE) eval
	$(MAKE) eval-top1

train-weakodds:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top3 --drop-features $(WEAK_DROP) --out-dir data/ml_weakodds --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_TRAIN_OPTS)

eval-weakodds:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 --model data/ml_weakodds/model.txt --encoders data/ml_weakodds/encoders.json --out-dir data/ml_weakodds

train-top1-weakodds:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top1 --drop-features $(WEAK_DROP) --out-dir data/ml_top1_weakodds --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_TRAIN_OPTS)

eval-top1-weakodds:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model data/ml_top1_weakodds/model.txt --encoders data/ml_top1_weakodds/encoders.json --out-dir data/ml_top1_weakodds

exotic:
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb $(EXOTIC_OPTS)

eval-exotic:
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb

exotic-weakodds:
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb --in-csv data/ml_weakodds/valid_pred.csv --win-csv data/ml_top1_weakodds/valid_pred.csv --out-dir data/ml_weakodds $(EXOTIC_OPTS)

eval-exotic-weakodds:
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb --exacta-csv data/ml_weakodds/exacta_pred.csv --trifecta-csv data/ml_weakodds/trifecta_pred.csv --out data/ml_weakodds/exotic_eval_summary.json

learn-hit5-profile:
	mkdir -p data/ml_profile/top3_train data/ml_profile/top1_train data/ml_profile/top3_valid data/ml_profile/top1_valid
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 --model $(HIT5_TOP3_MODEL) --encoders $(HIT5_TOP3_ENCODERS) --valid-csv data/ml/train.csv --out-dir data/ml_profile/top3_train
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model $(HIT5_TOP1_MODEL) --encoders $(HIT5_TOP1_ENCODERS) --valid-csv data/ml/train.csv --out-dir data/ml_profile/top1_train
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 --model $(HIT5_TOP3_MODEL) --encoders $(HIT5_TOP3_ENCODERS) --valid-csv data/ml/valid.csv --out-dir data/ml_profile/top3_valid
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model $(HIT5_TOP1_MODEL) --encoders $(HIT5_TOP1_ENCODERS) --valid-csv data/ml/valid.csv --out-dir data/ml_profile/top1_valid
	$(DOCKER_RUN) ruby scripts/learn_exotic_profile.rb --out $(HIT5_PROFILE) $(HIT5_LEARN_OPTS)

learn-exacta-profile:
	$(MAKE) learn-hit5-profile HIT5_PROFILE=$(EXACTA_PROFILE) HIT5_LEARN_OPTS="$(EXACTA_LEARN_OPTS)"

eval-exacta-profile:
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb --in-csv data/ml/valid_pred.csv --win-csv data/ml_top1/valid_pred.csv --out-dir data/ml --profile $(EXACTA_PROFILE) --exacta-top 20 --trifecta-top 50
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb --out data/ml/exotic_eval_summary_exacta_profile.json

tune:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

tune-top3:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --out-dir data/ml/tuning_top3 --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

tune-top1:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top1 --out-dir data/ml_top1/tuning --sort-metric winner_hit_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

tune-top3-noplayer:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --drop-features player_name --out-dir data/ml_noplayer/tuning --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

tune-weakodds:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --drop-features $(WEAK_DROP) --out-dir data/ml_weakodds/tuning --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

tune-top1-weakodds:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top1 --drop-features $(WEAK_DROP) --out-dir data/ml_top1_weakodds/tuning --sort-metric winner_hit_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_OPTS)

cv:
	$(DOCKER_RUN) ruby scripts/run_timeseries_cv.rb --target-col top3 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(CV_OPTS)

cv-top1:
	$(DOCKER_RUN) ruby scripts/run_timeseries_cv.rb --target-col top1 --out-dir data/ml_cv_top1 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(CV_OPTS)

importance:
	$(DOCKER_RUN) ruby scripts/show_feature_importance.rb
	@echo
	$(DOCKER_RUN) ruby scripts/show_feature_importance.rb --model data/ml_top1/model.txt

predict:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" $(PREDICT_OPTS)

predict-exacta:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-exacta data/ml_exacta/model.txt --encoders-exacta data/ml_exacta/encoders.json --exacta-model $(PREDICT_OPTS)

predict-balanced:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_noplayer/tuning_v2/trial_024/model.txt --encoders-top3 data/ml_noplayer/tuning_v2/trial_024/encoders.json \
		--model-top1 data/ml_top1/tuning_v2/trial_029/model.txt --encoders-top1 data/ml_top1/tuning_v2/trial_029/encoders.json \
		--win-temperature 0.30 $(PREDICT_OPTS)

predict-trifecta:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_noplayer/tuning_v2/trial_027/model.txt --encoders-top3 data/ml_noplayer/tuning_v2/trial_027/encoders.json \
		--model-top1 data/ml_top1/tuning_v2/trial_002/model.txt --encoders-top1 data/ml_top1/tuning_v2/trial_002/encoders.json \
		--win-temperature 0.20 $(PREDICT_OPTS)

predict-hit5:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_noplayer/tuning_v2/trial_024/model.txt --encoders-top3 data/ml_noplayer/tuning_v2/trial_024/encoders.json \
		--model-top1 data/ml_top1/tuning_v2/trial_002/model.txt --encoders-top1 data/ml_top1/tuning_v2/trial_002/encoders.json \
		--win-temperature 0.35 $(PREDICT_OPTS)

predict-hit5-profile:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_noplayer/tuning_v2/trial_024/model.txt --encoders-top3 data/ml_noplayer/tuning_v2/trial_024/encoders.json \
		--model-top1 data/ml_top1/tuning_v2/trial_002/model.txt --encoders-top1 data/ml_top1/tuning_v2/trial_002/encoders.json \
		--exotic-profile $(HIT5_PROFILE) $(PREDICT_OPTS)

predict-tri5:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_noplayer/tuning_v2/trial_008/model.txt --encoders-top3 data/ml_noplayer/tuning_v2/trial_008/encoders.json \
		--model-top1 data/ml_top1/tuning_v2/trial_014/model.txt --encoders-top1 data/ml_top1/tuning_v2/trial_014/encoders.json \
		--win-temperature 0.15 $(PREDICT_OPTS)

predict-weakodds:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" \
		--model-top3 data/ml_weakodds/model.txt --encoders-top3 data/ml_weakodds/encoders.json \
		--model-top1 data/ml_top1_weakodds/model.txt --encoders-top1 data/ml_top1_weakodds/encoders.json \
		--win-temperature 0.30 $(PREDICT_OPTS)

test:
	$(DOCKER_RUN) bundle exec rspec

pipeline:
	$(MAKE) features FROM=$(FROM) TO=$(TO)
	$(MAKE) split FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO)
	$(MAKE) features-exacta
	$(MAKE) train
	$(MAKE) eval

full:
	$(MAKE) collect FROM=$(FROM) TO=$(TO) SLEEP=$(SLEEP) CACHE=$(CACHE)
	$(MAKE) pipeline FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO)
