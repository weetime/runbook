#!/usr/bin/env bash
# evalscope runbook · 公共 shell 逻辑(被 run.sh / parse.sh source)。
# 宿主只需 bash + make + docker:sweep / conf / parse 都在容器内跑(镜像自带 python3+sqlite)。
# tokenizer / dataset 映射已随 sweep 逻辑移进容器内的 sweep.sh。
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引导镜像:容器内跑 runbook 的 python(sweep 调 evalscope + parse.py)。与被测镜像同一个。
export BOOT_IMG="${BOOT_IMG:-ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2}"

# 引导镜像缺则拉取。
ensure_boot_image() {
  docker image inspect "$BOOT_IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$BOOT_IMG"; docker pull "$BOOT_IMG"; }
}

# 被测所用镜像(可被 config.env 的 IMG= 覆盖)。
ensure_image() {
  : "${IMG:?IMG 未设置}"
  docker image inspect "$IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$IMG"; docker pull "$IMG"; }
}

# 只在镜像内跑 parse.py(统计,镜像自带 python3+sqlite)。挂载 runbook 目录到 /rb。
pyc() {
  docker run --rm -v "$RB:/rb" -w /rb \
    -e AXIS -e TTFT_SLO -e ITL_SLO -e WARMUP_DROP -e TEMPLATE \
    --entrypoint python "$BOOT_IMG" "$@"
}
