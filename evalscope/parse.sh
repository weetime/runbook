#!/usr/bin/env bash
# parse:在镜像内跑 parse.py(宿主无需 python)。默认解析 out/latest,或 RUN=<id> / 传目录参数。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
ensure_boot_image
pyc parse.py "$@"
