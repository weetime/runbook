#!/usr/bin/env bash
# run:组 MD_* env → 按 MODE 落地(docker 本地 / k8s 离线集群)。sweep 循环在容器内 sweep.sh。
# `./run.sh smoke` 单档冒烟(仅 docker)。模板 = templates/<name>.env,source 进来即自动填充。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# 传给 sweep.sh 的 env 清单(值来自已 source 的 config+template)——docker 与 k8s 共用。
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)

run_docker() {
  ensure_image
  local DOUT="$PWD/out"; mkdir -p "$DOUT"
  # tokenizer 挂载源:online 挂 host ./tok(可写缓存),offline 挂用户目录(只读)
  local TOK_MOUNT
  if [ "${TOKENIZER_MODE:-online}" = offline ]; then
    : "${TOKENIZER_PATH:?offline 缺 TOKENIZER_PATH}"
    TOK_MOUNT="$TOKENIZER_PATH:/tok:ro"
  else
    mkdir -p "$PWD/tok"; TOK_MOUNT="$PWD/tok:/tok"
  fi
  # PYTHONPATH=/app:runner 包在镜像 /app 下;-w /work 改了 cwd(让 MD_OUTPUT_FILES 相对路径落到
  # 挂载卷),故显式加 /app 到模块搜索路径,否则 `python -m runner` 找不到包。
  local ENVARGS=(-e MD_BENCHMARK_ID="$RUN_ID" -e MD_ARGV='["bash","/rb/sweep.sh"]'
    -e MD_OUTPUT_DIR=/work/out -e MD_OUTPUT_FILES="{\"summary.csv\":\"out/$RUN_ID/summary.csv\"}"
    -e PYTHONPATH=/app -e OPENAI_API_KEY="$KEY" -e SMOKE="$SMOKE")
  local v; for v in "${SWEEP_ENV[@]}"; do ENVARGS+=(-e "$v=${!v-}"); done

  echo "被测端点: $URL"; echo "模型:     $MODEL"
  echo "模板:     $TEMPLATE(轴=$AXIS)"; echo "落地:     docker · 产物 out/$RUN_ID"; echo

  docker run --rm "${ENVARGS[@]}" -w /work \
    -v "$PWD/sweep.sh:/rb/sweep.sh:ro" -v "$PWD/parse.py:/rb/parse.py:ro" \
    -v "$DOUT:/work/out" -v "$TOK_MOUNT" "$IMG"

  [ "$SMOKE" = 1 ] || ln -sfn "$RUN_ID" "$DOUT/latest"
  [ "$SMOKE" = 1 ] && echo "==> 冒烟通过即可 make run" || echo "==> 完成 → make parse(默认 out/latest)"
}

run_k8s() {
  command -v kubectl >/dev/null 2>&1 || { echo "✗ MODE=k8s 需要 kubectl" >&2; exit 1; }
  local job="run-$RUN_ID" ns="${K8S_NAMESPACE:-default}"
  echo "被测端点: $URL"; echo "模型:     $MODEL"
  echo "模板:     $TEMPLATE(轴=$AXIS)"
  echo "落地:     k8s Job $job(ns=$ns · context=$(kubectl config current-context 2>/dev/null))"; echo
  render_k8s_yaml | kubectl -n "$ns" apply -f -
  echo "==> 已 apply;等 pod 起来后跟随日志(首次拉镜像可能较久,Ctrl-C 不停 Job):"
  # 轮询直到 pod 进入 Running/Succeeded/Failed 再跟日志:apply 返回时 Job 控制器可能还没建 pod
  # (kubectl wait 会 "no matching resources found" 直接返回),且首拉大镜像会长时间 ContainerCreating。
  local i phase
  for i in $(seq 1 180); do
    phase="$(kubectl -n "$ns" get pods -l "batch.kubernetes.io/job-name=$job" \
      -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    case "$phase" in Running|Succeeded|Failed) break ;; esac
    sleep 5
  done
  kubectl -n "$ns" logs -f "job/$job" || true
  echo "==> 结束。清理:kubectl -n $ns delete job/$job configmap/$job secret/$job"
}

CLI_TEMPLATE="${TEMPLATE:-}"
CFG="${CONFIG:-config.env}"
[ -f "$CFG" ] || { echo "✗ 未找到 $CFG —— 先跑:make config" >&2; exit 1; }
source "$CFG"
[ -n "$CLI_TEMPLATE" ] && TEMPLATE="$CLI_TEMPLATE"
: "${TEMPLATE:?config.env 缺 TEMPLATE}"
TPL="templates/$TEMPLATE.env"
[ -f "$TPL" ] || { echo "✗ 模板不存在:$TPL(见 templates/)" >&2; exit 1; }
source "$TPL"

: "${URL:?config.env 缺 URL}"; : "${MODEL:?config.env 缺 MODEL}"
export KEY="${KEY:-EMPTY}"
export IMG="${IMG:-$BOOT_IMG}"
MODE="${MODE:-docker}"
SMOKE=0; [ "${1:-run}" = smoke ] && SMOKE=1
if [ "$MODE" = k8s ] && [ "$SMOKE" = 1 ]; then
  echo "ℹ smoke 仅 docker 本地;k8s 直接跑完整 run" >&2; SMOKE=0
fi
if [ "$SMOKE" = 1 ]; then RUN_ID="smoke-$TEMPLATE"; else RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"; fi

case "$MODE" in
  docker) run_docker ;;
  k8s)    run_k8s ;;
  *) echo "✗ MODE 只能是 docker / k8s(见 config.env)" >&2; exit 1 ;;
esac
