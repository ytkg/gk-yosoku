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

DOCKER_RUN = docker run --rm -v "$$PWD:/app" -w /app $(IMAGE)

.PHONY: help build collect features split train eval train-top1 eval-top1 exotic eval-exotic tune predict test pipeline full

help:
	@echo "Targets:"
	@echo "  make build"
	@echo "  make collect   FROM=YYYY-MM-DD TO=YYYY-MM-DD SLEEP=0.2 CACHE=--cache"
	@echo "  make features  FROM=YYYY-MM-DD TO=YYYY-MM-DD"
	@echo "  make split     FROM=YYYY-MM-DD TO=YYYY-MM-DD TRAIN_TO=YYYY-MM-DD"
	@echo "  make train"
	@echo "  make eval"
	@echo "  make train-top1"
	@echo "  make eval-top1"
	@echo "  make exotic    EXOTIC_OPTS='--win-csv data/ml_top1/valid_pred.csv --exacta-top 10 --trifecta-top 20'"
	@echo "  make eval-exotic"
	@echo "  make tune      TUNE_OPTS='--num-iterations 400 --learning-rates 0.03,0.05'"
	@echo "  make predict   RACE_URL='https://keirin.kdreams.jp/.../racedetail/xxxxxxxxxxxxxxxx/' PREDICT_OPTS='--exacta-top 20 --trifecta-top 50'"
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

features:
	$(DOCKER_RUN) ruby scripts/build_features.rb \
		--from-date $(FROM) \
		--to-date $(TO)

split:
	$(DOCKER_RUN) ruby scripts/split_features.rb \
		--from-date $(FROM) \
		--to-date $(TO) \
		--train-to $(TRAIN_TO)

train:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb

eval:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb

train-top1:
	$(DOCKER_RUN) ruby scripts/train_lightgbm.rb --target-col top1 --out-dir data/ml_top1

eval-top1:
	$(DOCKER_RUN) ruby scripts/evaluate_lightgbm.rb --target-col top1 --model data/ml_top1/model.txt --encoders data/ml_top1/encoders.json --out-dir data/ml_top1

exotic:
	$(DOCKER_RUN) ruby scripts/generate_exotics.rb $(EXOTIC_OPTS)

eval-exotic:
	$(DOCKER_RUN) ruby scripts/evaluate_exotics.rb

tune:
	$(DOCKER_RUN) ruby scripts/tune_lightgbm.rb $(TUNE_OPTS)

predict:
	@if [ -z "$(RACE_URL)" ]; then echo "RACE_URL is required"; exit 1; fi
	$(DOCKER_RUN) ruby scripts/predict_race.rb --url "$(RACE_URL)" $(PREDICT_OPTS)

test:
	$(DOCKER_RUN) bundle exec rspec

pipeline:
	$(MAKE) features FROM=$(FROM) TO=$(TO)
	$(MAKE) split FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO)
	$(MAKE) train
	$(MAKE) eval

full:
	$(MAKE) collect FROM=$(FROM) TO=$(TO) SLEEP=$(SLEEP) CACHE=$(CACHE)
	$(MAKE) pipeline FROM=$(FROM) TO=$(TO) TRAIN_TO=$(TRAIN_TO)
