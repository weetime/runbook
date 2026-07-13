#!/bin/bash
# evalscope RUNBOOK · ShareGPT 真实流量压测 DeepSeek-V4-Flash endpoint
# 就绪:镜像内含 evalscope 1.7.0 + ShareGPT(70k);tok/ 已下 DeepSeek-V4-Flash tokenizer(vocab 129280)
# 被测 endpoint 三要素放在 .secret.env(gitignored):URL / MODEL / KEY
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$RB/.secret.env" ] && source "$RB/.secret.env"
export URL="${URL:?请在 .secret.env 里设置 URL}"                            # 被测端点(LAN IP 直连,容器默认桥接可达)
export MODEL="${MODEL:?请在 .secret.env 里设置 MODEL}"                       # 服务端注册的模型名
export KEY="${KEY:-EMPTY}"                                                  # 网关 key(无则 EMPTY)

export IMG="md-runner-evalscope:b6a824c-sharegpt2"
export SG="/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl"           # 镜像内 ShareGPT
export TOK="$RB/tok"                                                        # 本机 tokenizer 目录
export OUT="$RB/out"
export PAR="4 8 16 32"                                                      # 并发档
export NUM="60 80 120 160"                                                  # 每档请求数(演示规模;N 需大于每档冷启动离群点数,让 p95 落在暖区)
export ROUNDS="${ROUNDS:-3}"                                               # 每档 3 轮:round1=冷,2/3=暖;聚合去极值取中位
mkdir -p "$OUT"
