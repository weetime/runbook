# evalscope 压测 runbook · make help 看所有目标
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help setup install smoke run parse clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

setup: ## 交互式填信息 → 生成 .env
	@./setup.sh

install: ## 拉镜像 +(在线模式)预取 tokenizer 到 ./tok
	@./install.sh

smoke: ## 冒烟:单档小跑验证全链路
	@./run.sh smoke

run: ## 扫并发(冷/暖多轮)
	@./run.sh

parse: ## 聚合去冷轮 + 池化,找 SLO 拐点
	@python3 parse.py

clean: ## 清空压测产物(out/round*)
	@rm -rf out/round* && echo "cleaned"
