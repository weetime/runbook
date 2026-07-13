# evalscope 压测 runbook · make help 看所有目标
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help config smoke run parse clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n",$$1,$$2}'

config: ## 交互配端点/tokenizer/选模板 → 写 config.yaml(拉镜像+预取 tokenizer 由 run/smoke 懒执行)
	@./config.sh

smoke: ## 冒烟:所选模板单档小跑,验全链路(镜像缺则懒拉)
	@./run.sh smoke

run: ## 按模板全量扫,产出独立 out/<run-id>/(可 TEMPLATE=xxx 覆盖)
	@./run.sh

parse: ## 解析最新一次 run(默认 out/latest,或 RUN=<id>),找 SLO 拐点
	@python3 parse.py

clean: ## 清空压测产物(out/*)
	@rm -rf out/* && echo "cleaned"
