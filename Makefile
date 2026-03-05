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
PAYLOAD ?= docs/api/request-examples/predict-basic.json
API_BASE_URL ?= http://127.0.0.1:4567
WEAK_DROP ?= odds_2shatan_min_first
WEIGHT_MODE ?= none
DECAY_HALF_LIFE_DAYS ?= 120
MIN_SAMPLE_WEIGHT ?= 0.2
TOP3_TRAIN_OPTS ?=
TOP1_TRAIN_OPTS ?=
TOP3_EVAL_OPTS ?=
TOP1_EVAL_OPTS ?=
TOP3_FEATURE_SET ?= full
TOP1_FEATURE_SET ?= full
EXACTA_TRAIN_OPTS ?=
EXACTA_EVAL_OPTS ?=
CV_OPTS ?=
HALF_LIFE_OPTS ?=
LAKE_DIR ?= data/lake
PARQUET_DB ?= data/duckdb/gk_yosoku.duckdb
FEATURE_SET_VERSION ?= v1
DUCKDB_DB_OPTS ?= --db-path $(PARQUET_DB)
DUCKDB_FEATURE_OPTS ?= --lake-dir $(LAKE_DIR) --feature-set-version $(FEATURE_SET_VERSION) $(DUCKDB_DB_OPTS)
EVAL_DUCKDB_OPTS ?=
EVAL_MODEL ?= data/ml/model.txt
EVAL_ENCODERS ?= data/ml/encoders.json
EVAL_OUT_DIR ?= data/ml
EVAL_TARGET_COL ?= top3
EVAL_DUCKDB_BASE_OPTS ?= $(DUCKDB_FEATURE_OPTS)
DUCKDB_BACKUP_DIR ?= data/duckdb_backup
HIT5_PROFILE ?= data/ml/exotic_profile_hit5.json
HIT5_LEARN_OPTS ?=
EXACTA_PROFILE ?= data/ml/exotic_profile_exacta_hit1.json
EXACTA_LEARN_OPTS ?= --objective-n 1 --exacta-weight 1.0 --trifecta-weight 0.0 --temp-grid 0.1,0.12,0.15,0.18,0.2,0.25,0.3 --exp-grid 0.6,0.8,1.0,1.2,1.4 --exacta-second-win-exp-grid 0.0,0.2,0.4,0.7,1.0 --max-trials 2500 --random-seed 42
EXOTIC_OPT_PROFILE ?= data/ml/exotic_profile_optimized_hitk.json
EXOTIC_OPT_LEARN_OPTS ?=
EXOTIC_OPT_EVAL_OUT ?= data/ml/exotic_eval_summary_optimized_hitk.json
EXOTIC_TOPS ?= 20,50
comma := ,
EXOTIC_TOPS_WORDS := $(subst $(comma), ,$(EXOTIC_TOPS))
EXACTA_TOP_N := $(word 1,$(EXOTIC_TOPS_WORDS))
TRIFECTA_TOP_N := $(word 2,$(EXOTIC_TOPS_WORDS))
HIT5_TOP3_MODEL ?= data/ml_noplayer/tuning_v2/trial_024/model.txt
HIT5_TOP3_ENCODERS ?= data/ml_noplayer/tuning_v2/trial_024/encoders.json
HIT5_TOP1_MODEL ?= data/ml_top1/tuning_v2/trial_002/model.txt
HIT5_TOP1_ENCODERS ?= data/ml_top1/tuning_v2/trial_002/encoders.json
PROFILE_SPLIT_ID ?= $(subst -,,$(FROM))_$(subst -,,$(TO))_train_to_$(subst -,,$(TRAIN_TO))
PROFILE_MART_DIR ?= data/marts/train_valid/split_id=$(PROFILE_SPLIT_ID)
TRAIN_DUCKDB_OPTS ?= --train-parquet $(PROFILE_MART_DIR)/train.parquet --valid-parquet $(PROFILE_MART_DIR)/valid.parquet $(DUCKDB_DB_OPTS)
TUNE_TRAIN_PARQUET ?= $(PROFILE_MART_DIR)/train.parquet
TUNE_VALID_PARQUET ?= $(PROFILE_MART_DIR)/valid.parquet
TUNE_DUCKDB_OPTS ?= --train-parquet $(TUNE_TRAIN_PARQUET) --valid-parquet $(TUNE_VALID_PARQUET) $(DUCKDB_DB_OPTS)
CV_DUCKDB_OPTS ?= $(DUCKDB_FEATURE_OPTS)
HALF_LIFE_GRID ?= 60,90,120,180
HALF_LIFE_CV_OUT_DIR ?= data/ml_cv_half_life
TOP3_FEATURE_OPTS := $(if $(filter noplayer,$(TOP3_FEATURE_SET)),--drop-features player_name,)
TOP1_FEATURE_OPTS := $(if $(filter noplayer,$(TOP1_FEATURE_SET)),--drop-features player_name,)

DOCKER_RUN = docker run --rm -v "$$PWD:/app" -w /app $(IMAGE)
DOCKER_RUN_API = docker run --rm -p 4567:4567 -v "$$PWD:/app" -w /app $(IMAGE)
API_TIMEOUT_CHECK_CONTAINER ?= gk-yosoku-api-timeout-check
API_PARITY_CONTAINER ?= gk-yosoku-api-parity
API_PARITY_PORT ?= 4568
API_PID_FILE ?= tmp/api.pid
API_LOG_FILE ?= tmp/api.log

ifneq (,$(wildcard .env))
include .env
export
endif

.PHONY: help issue-cycle build api-start api-start-bg api-stop api-logs api-health api-predict api-predict-timeout-check api-smoke api-cli-parity manifest-inspect collect parquet-bootstrap features features-duckdb features-duckdb-sql split split-duckdb validate-duckdb eval-duckdb backup-duckdb restore-duckdb features-exacta train train-top3-noplayer eval train-top1 train-top1-noplayer eval-top1 train-exacta eval-exacta-model train-dual eval-dual train-weakodds eval-weakodds train-top1-weakodds eval-top1-weakodds exotic eval-exotic exotic-weakodds eval-exotic-weakodds learn-hit5-profile learn-exacta-profile eval-exacta-profile optimize-exotic-hitk tune tune-top1 tune-top1-noplayer tune-top3 tune-top3-noplayer tune-weakodds tune-top1-weakodds cv cv-top1 cv-top3-noplayer cv-top1-noplayer cv-half-life-grid importance predict predict-exacta predict-balanced predict-trifecta predict-hit5 predict-hit5-profile predict-tri5 predict-weakodds test test-duckdb pipeline full

help:
	@echo "Targets:"
	@echo "  make build"
	@echo "  make api-start"
	@echo "  make api-start-bg"
	@echo "  make api-stop"
	@echo "  make api-logs"
	@echo "  make api-health"
	@echo "  make api-predict PAYLOAD=docs/api/request-examples/predict-basic.json"
	@echo "  make api-predict-timeout-check"
	@echo "  make api-smoke"
	@echo "  make api-cli-parity"
	@echo "  make manifest-inspect MODEL_DIR=data/ml"
	@echo "  make collect   FROM=YYYY-MM-DD TO=YYYY-MM-DD SLEEP=0.2 CACHE=--cache"
	@echo "  make parquet-bootstrap FROM=YYYY-MM-DD TO=YYYY-MM-DD LAKE_DIR=data/lake PARQUET_DB=data/duckdb/gk_yosoku.duckdb"
	@echo "  make features-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD LAKE_DIR=data/lake PARQUET_DB=data/duckdb/gk_yosoku.duckdb"
	@echo "  make features-duckdb-sql FROM=YYYY-MM-DD TO=YYYY-MM-DD"
	@echo "  make features (deprecated wrapper)"
	@echo "  make split-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make split (deprecated wrapper)"
	@echo "  make validate-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD"
	@echo "  make eval-duckdb FROM=YYYY-MM-DD TO=YYYY-MM-DD EVAL_DUCKDB_OPTS='--target-col top3'"
	@echo "  make backup-duckdb"
	@echo "  make restore-duckdb SRC=path/to/gk_yosoku_YYYYMMDDTHHMMSSZ.duckdb"
	@echo "  make features-exacta"
	@echo "  make train"
	@echo "  make train-top3-noplayer  # top3をplayer_name除外で学習"
	@echo "  make eval (deprecated wrapper)"
	@echo "  make train-top1"
	@echo "  make train-top1-noplayer  # top1をplayer_name除外で学習"
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
	@echo "  make optimize-exotic-hitk EXOTIC_TOPS='20,50' EXOTIC_OPT_PROFILE=data/ml/exotic_profile_optimized_hitk.json EXOTIC_OPT_LEARN_OPTS='--config docs/exotic_profile_config.sample.yml'"
	@echo "  make tune FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD TUNE_OPTS='--num-iterations 400 --learning-rates 0.03,0.05'"
	@echo "  make tune-top3 FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD TUNE_OPTS='--learning-rates 0.03,0.05 --num-leaves 15,31,63'"
	@echo "  make tune-top1 FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD TOP1_FEATURE_SET=noplayer TUNE_OPTS='--learning-rates 0.03,0.05'"
	@echo "  make tune-top1-noplayer FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD TUNE_OPTS='--learning-rates 0.03,0.05 --num-leaves 15,31,63'"
	@echo "  make tune-top3-noplayer FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD TUNE_OPTS='--learning-rates 0.03,0.05 --num-leaves 15,31,63'"
	@echo "  make tune-weakodds FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make tune-top1-weakodds FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD WEAK_DROP='odds_2shatan_min_first'"
	@echo "  make cv FROM=YYYY-MM-DD TO=YYYY-MM-DD CV_OPTS='--from-date ... --to-date ... --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make cv-top1 FROM=YYYY-MM-DD TO=YYYY-MM-DD CV_OPTS='--from-date ... --to-date ... --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make cv-top3-noplayer FROM=YYYY-MM-DD TO=YYYY-MM-DD CV_OPTS='--from-date ... --to-date ... --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make cv-top1-noplayer FROM=YYYY-MM-DD TO=YYYY-MM-DD CV_OPTS='--from-date ... --to-date ... --train-days 180 --valid-days 28 --step-days 28'"
	@echo "  make cv-half-life-grid FROM=YYYY-MM-DD TO=YYYY-MM-DD HALF_LIFE_GRID='60,90,120,180'"
	@echo "    -> out: data/ml_cv_half_life/half_life_leaderboard.csv, half_life_summary.json"
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
	@echo "  make test-duckdb"
	@echo "  make issue-cycle"
	@echo "  make pipeline  FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make full      FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD SLEEP=0.2 CACHE=--cache"
	@echo "  notes:"
	@echo "    vars(train): TOP3_FEATURE_SET=full|noplayer TOP1_FEATURE_SET=full|noplayer"
	@echo "    vars(exotic): EXOTIC_TOPS=exacta_top,trifecta_top (example: 20,50)"
	@echo "    noplayer quick map: train-top3-noplayer train-top1-noplayer tune-top3-noplayer tune-top1-noplayer cv-top3-noplayer cv-top1-noplayer"
	@echo "    issue-cycle: includes final open-issue check"

issue-cycle:
	@echo "Issue運用サイクル:"
	@echo "  1) 子Issueを起票（受け入れ条件を明記）"
	@echo "  2) 実装と検証を完了（必要な make/spec 実行）"
	@echo "  3) コミット（Issue番号を含める）"
	@echo "  4) Issueに完了コメント（コミットID/検証結果）"
	@echo "  5) 子Issueをクローズ"
	@echo "  6) 改善Issueを1件以上起票"
	@echo "  7) 親Issue #32 を更新"
	@echo "  8) open issue を確認（gh issue list --state open）"

build:
	docker build -t $(IMAGE) .

api-start:
	$(DOCKER_RUN_API) bundle exec rackup -s webrick -o 0.0.0.0 -p 4567

api-start-bg:
	@set -eu; \
	mkdir -p "$$(dirname "$(API_PID_FILE)")"; \
	if [ -f "$(API_PID_FILE)" ] && kill -0 "$$(cat "$(API_PID_FILE)")" >/dev/null 2>&1; then echo "API is already running (pid=$$(cat "$(API_PID_FILE)"))"; exit 0; fi; \
	nohup $(DOCKER_RUN_API) bundle exec rackup -s webrick -o 0.0.0.0 -p 4567 >"$(API_LOG_FILE)" 2>&1 & echo $$! >"$(API_PID_FILE)"; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if curl -fsS "$(API_BASE_URL)/health" >/dev/null 2>&1; then echo "API started in background (pid=$$(cat "$(API_PID_FILE)"))"; exit 0; fi; \
		sleep 1; \
	done; \
	echo "API startup failed. See logs: $(API_LOG_FILE)"; \
	kill "$$(cat "$(API_PID_FILE)")" >/dev/null 2>&1 || true; \
	rm -f "$(API_PID_FILE)"; \
	exit 1

api-stop:
	@if [ ! -f "$(API_PID_FILE)" ]; then echo "API is not running"; exit 0; fi
	@if kill -0 "$$(cat "$(API_PID_FILE)")" >/dev/null 2>&1; then kill "$$(cat "$(API_PID_FILE)")"; fi
	@rm -f "$(API_PID_FILE)"
	@echo "API stopped"

api-logs:
	@if [ ! -f "$(API_LOG_FILE)" ]; then echo "API log file not found: $(API_LOG_FILE)"; exit 1; fi
	tail -f "$(API_LOG_FILE)"

api-health:
	curl -sS "$(API_BASE_URL)/health"

api-predict:
	@if [ ! -f "$(PAYLOAD)" ]; then echo "PAYLOAD file not found: $(PAYLOAD)"; exit 1; fi
	curl -sS -X POST "$(API_BASE_URL)/predict" \
		-H 'Content-Type: application/json' \
		--data @"$(PAYLOAD)"

api-predict-timeout-check:
	@set -eu; \
	mkdir -p tmp; \
	docker rm -f "$(API_TIMEOUT_CHECK_CONTAINER)" >/dev/null 2>&1 || true; \
	trap 'docker rm -f "$(API_TIMEOUT_CHECK_CONTAINER)" >/dev/null 2>&1 || true' EXIT; \
	docker run -d --name "$(API_TIMEOUT_CHECK_CONTAINER)" -e GK_PREDICT_TIMEOUT_SEC=1 -p 4567:4567 -v "$$PWD:/app" -w /app "$(IMAGE)" bundle exec rackup -s webrick -o 0.0.0.0 -p 4567 >/dev/null; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if curl -fsS http://127.0.0.1:4567/health >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	curl -sS -X POST http://127.0.0.1:4567/predict \
		-H 'Content-Type: application/json' \
		--data @docs/api/request-examples/predict-timeout-check.json > tmp/api-timeout-check.json; \
	docker run --rm -v "$$PWD:/app" -w /app "$(IMAGE)" ruby -rjson -e 'j=JSON.parse(File.read("tmp/api-timeout-check.json")); abort("expected predict_timeout, got #{j["code"]}") unless j["code"]=="predict_timeout"; puts JSON.pretty_generate(j)'

api-smoke:
	bash scripts/api_smoke.sh

api-cli-parity:
	@set -eu; \
	docker rm -f "$(API_PARITY_CONTAINER)" >/dev/null 2>&1 || true; \
	trap 'docker rm -f "$(API_PARITY_CONTAINER)" >/dev/null 2>&1 || true' EXIT; \
	docker run -d --name "$(API_PARITY_CONTAINER)" -p "$(API_PARITY_PORT):4567" -v "$$PWD:/app" -w /app "$(IMAGE)" bundle exec rackup -s webrick -o 0.0.0.0 -p 4567 >/dev/null; \
	for i in 1 2 3 4 5 6 7 8 9 10; do \
		if curl -fsS "http://127.0.0.1:$(API_PARITY_PORT)/health" >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done; \
	ruby scripts/api_cli_parity.rb --payload docs/api/fixtures/parity_request.json --api-url "http://127.0.0.1:$(API_PARITY_PORT)/predict" --image "$(IMAGE)"

manifest-inspect:
	@if [ -z "$(MODEL_DIR)" ]; then echo "MODEL_DIR is required"; exit 1; fi
	ruby scripts/inspect_model_manifest.rb --manifest "$(MODEL_DIR)/model_manifest.json"

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
	@echo "[deprecated] make features is now DuckDB-first. running parquet-bootstrap + features-duckdb"
	$(MAKE) parquet-bootstrap FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)
	$(MAKE) features-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)

features-duckdb:
	$(DOCKER_RUN) ruby scripts/build_features_duckdb.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--out-dir data/features \
		--lake-dir $(LAKE_DIR) \
		--db-path $(PARQUET_DB)

features-duckdb-sql:
	$(MAKE) features-duckdb

split:
	@echo "[deprecated] make split now delegates to split-duckdb"
	$(MAKE) split-duckdb FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)

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
		--model $(EVAL_MODEL) \
		--encoders $(EVAL_ENCODERS) \
		--out-dir $(EVAL_OUT_DIR) \
		--target-col $(EVAL_TARGET_COL) \
		$(EVAL_DUCKDB_BASE_OPTS) \
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
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top3 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(TRAIN_DUCKDB_OPTS) $(TOP3_TRAIN_OPTS)

train-top3-noplayer:
	$(MAKE) train TOP3_FEATURE_SET=noplayer TOP3_TRAIN_OPTS="$(TOP3_TRAIN_OPTS)"

eval:
	@echo "[deprecated] make eval now delegates to eval-duckdb"
	$(MAKE) eval-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB) EVAL_DUCKDB_OPTS="$(TOP3_EVAL_OPTS)" EVAL_MODEL=data/ml/model.txt EVAL_ENCODERS=data/ml/encoders.json EVAL_OUT_DIR=data/ml EVAL_TARGET_COL=top3

train-top1:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top1 --out-dir data/ml_top1 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_FEATURE_OPTS) $(TRAIN_DUCKDB_OPTS) $(TOP1_TRAIN_OPTS)

train-top1-noplayer:
	$(MAKE) train-top1 TOP1_FEATURE_SET=noplayer TOP1_TRAIN_OPTS="$(TOP1_TRAIN_OPTS)"

eval-top1:
	$(MAKE) eval-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB) EVAL_MODEL=data/ml_top1/model.txt EVAL_ENCODERS=data/ml_top1/encoders.json EVAL_OUT_DIR=data/ml_top1 EVAL_TARGET_COL=top1 EVAL_DUCKDB_OPTS="$(TOP1_EVAL_OPTS)"

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
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top3 --drop-features $(WEAK_DROP) --out-dir data/ml_weakodds --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(TRAIN_DUCKDB_OPTS) $(TOP3_TRAIN_OPTS)

eval-weakodds:
	$(MAKE) eval-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB) EVAL_MODEL=data/ml_weakodds/model.txt EVAL_ENCODERS=data/ml_weakodds/encoders.json EVAL_OUT_DIR=data/ml_weakodds EVAL_TARGET_COL=top3

train-top1-weakodds:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top1 --drop-features $(WEAK_DROP) --out-dir data/ml_top1_weakodds --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_FEATURE_OPTS) $(TRAIN_DUCKDB_OPTS) $(TOP1_TRAIN_OPTS)

eval-top1-weakodds:
	$(MAKE) eval-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB) EVAL_MODEL=data/ml_top1_weakodds/model.txt EVAL_ENCODERS=data/ml_top1_weakodds/encoders.json EVAL_OUT_DIR=data/ml_top1_weakodds EVAL_TARGET_COL=top1

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
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 --model $(HIT5_TOP3_MODEL) --encoders $(HIT5_TOP3_ENCODERS) --valid-parquet $(PROFILE_MART_DIR)/train.parquet --db-path $(PARQUET_DB) --out-dir data/ml_profile/top3_train
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model $(HIT5_TOP1_MODEL) --encoders $(HIT5_TOP1_ENCODERS) --valid-parquet $(PROFILE_MART_DIR)/train.parquet --db-path $(PARQUET_DB) --out-dir data/ml_profile/top1_train
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top3 --model $(HIT5_TOP3_MODEL) --encoders $(HIT5_TOP3_ENCODERS) --valid-parquet $(PROFILE_MART_DIR)/valid.parquet --db-path $(PARQUET_DB) --out-dir data/ml_profile/top3_valid
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model $(HIT5_TOP1_MODEL) --encoders $(HIT5_TOP1_ENCODERS) --valid-parquet $(PROFILE_MART_DIR)/valid.parquet --db-path $(PARQUET_DB) --out-dir data/ml_profile/top1_valid
	$(DOCKER_RUN) ruby scripts/learn_exotic_profile.rb --out $(HIT5_PROFILE) $(HIT5_LEARN_OPTS)

learn-exacta-profile:
	$(MAKE) learn-hit5-profile HIT5_PROFILE=$(EXACTA_PROFILE) HIT5_LEARN_OPTS="$(EXACTA_LEARN_OPTS)"

eval-exacta-profile:
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb --in-csv data/ml/valid_pred.csv --win-csv data/ml_top1/valid_pred.csv --out-dir data/ml --profile $(EXACTA_PROFILE) --exacta-top 20 --trifecta-top 50
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb --out data/ml/exotic_eval_summary_exacta_profile.json

optimize-exotic-hitk:
	$(MAKE) learn-hit5-profile HIT5_PROFILE=$(EXOTIC_OPT_PROFILE) HIT5_LEARN_OPTS="$(EXOTIC_OPT_LEARN_OPTS)"
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb --in-csv data/ml/valid_pred.csv --win-csv data/ml_top1/valid_pred.csv --out-dir data/ml --profile $(EXOTIC_OPT_PROFILE) --exacta-top $(EXACTA_TOP_N) --trifecta-top $(TRIFECTA_TOP_N)
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb --out $(EXOTIC_OPT_EVAL_OUT)

tune:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

tune-top3:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --out-dir data/ml/tuning_top3 --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

tune-top1:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top1 --out-dir data/ml_top1/tuning --sort-metric winner_hit_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_FEATURE_OPTS) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

tune-top1-noplayer:
	$(MAKE) tune-top1 TOP1_FEATURE_SET=noplayer TUNE_OPTS="$(TUNE_OPTS)"

tune-top3-noplayer:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --drop-features player_name --out-dir data/ml_noplayer/tuning --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

tune-weakodds:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top3 --drop-features $(WEAK_DROP) --out-dir data/ml_weakodds/tuning --sort-metric top3_exact_match_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

tune-top1-weakodds:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb --target-col top1 --drop-features $(WEAK_DROP) --out-dir data/ml_top1_weakodds/tuning --sort-metric winner_hit_rate --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_FEATURE_OPTS) $(TUNE_DUCKDB_OPTS) $(TUNE_OPTS)

cv:
	$(DOCKER_RUN) ruby scripts/run_timeseries_cv.rb --target-col top3 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP3_FEATURE_OPTS) $(CV_DUCKDB_OPTS) $(CV_OPTS)

cv-top1:
	$(DOCKER_RUN) ruby scripts/run_timeseries_cv.rb --target-col top1 --out-dir data/ml_cv_top1 --weight-mode $(WEIGHT_MODE) --decay-half-life-days $(DECAY_HALF_LIFE_DAYS) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(TOP1_FEATURE_OPTS) $(CV_DUCKDB_OPTS) $(CV_OPTS)

cv-top3-noplayer:
	$(MAKE) cv TOP3_FEATURE_SET=noplayer CV_OPTS="$(CV_OPTS)"

cv-top1-noplayer:
	$(MAKE) cv-top1 TOP1_FEATURE_SET=noplayer CV_OPTS="$(CV_OPTS)"

cv-half-life-grid:
	$(DOCKER_RUN) ruby scripts/compare_time_decay_half_life.rb --from-date $(FROM) --to-date $(TO) --half-lives $(HALF_LIFE_GRID) --target-col top3 --out-dir $(HALF_LIFE_CV_OUT_DIR) --min-sample-weight $(MIN_SAMPLE_WEIGHT) $(CV_DUCKDB_OPTS) $(HALF_LIFE_OPTS)

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

test-duckdb:
	$(DOCKER_RUN) bundle exec rspec \
		spec/scripts/parquet_bootstrap_spec.rb \
		spec/scripts/build_features_duckdb_spec.rb \
		spec/scripts/split_features_duckdb_spec.rb \
		spec/scripts/validate_duckdb_parity_spec.rb \
		spec/scripts/evaluate_lightgbm_duckdb_spec.rb \
		spec/scripts/backup_duckdb_spec.rb

pipeline:
	$(MAKE) parquet-bootstrap FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)
	$(MAKE) features-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)
	$(MAKE) split-duckdb FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)
	$(MAKE) validate-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)
	$(MAKE) features-exacta
	$(MAKE) train
	$(MAKE) eval-duckdb FROM=$(FROM) TO=$(TO) LAKE_DIR=$(LAKE_DIR) PARQUET_DB=$(PARQUET_DB)

full:
	$(MAKE) collect FROM=$(FROM) TO=$(TO) SLEEP=$(SLEEP) CACHE=$(CACHE)
	$(MAKE) pipeline FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO)
