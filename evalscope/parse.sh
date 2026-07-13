#!/usr/bin/env bash
# parse:在镜像内跑 parse.py(宿主无需 python)。默认解析 out/latest,或 RUN=<id>。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
ensure_boot_image

RUNDIR="out/${RUN:-latest}"
[ -e "$RUNDIR" ] || { echo "✗ 没有结果:$RUNDIR(先跑 make run)" >&2; exit 1; }

# 命令行 SLO 优先;否则用 run 目录自描述的 run.env
_cli_ttft="${TTFT_SLO:-}"; _cli_itl="${ITL_SLO:-}"
[ -f "$RUNDIR/run.env" ] && source "$RUNDIR/run.env"
[ -n "$_cli_ttft" ] && TTFT_SLO="$_cli_ttft"
[ -n "$_cli_itl" ] && ITL_SLO="$_cli_itl"
export AXIS TTFT_SLO ITL_SLO TEMPLATE

pyc parse.py "$RUNDIR"
