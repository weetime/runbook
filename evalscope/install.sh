#!/usr/bin/env bash
# install:拉镜像 +(在线模式)预取 tokenizer 到 ./tok,让后续 run 完全离线可复现。
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh

echo "==> 拉取镜像:$IMG"
docker pull "$IMG"

echo "==> 准备 tokenizer"
ensure_tokenizer     # online: 拉到 ./tok;offline: 校验本机目录

echo "==> install 完成。下一步:make smoke,再 make run"
