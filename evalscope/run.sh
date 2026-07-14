#!/usr/bin/env bash
# run:组 MD_* env → 一次 docker run(镜像默认 python -m runner)。sweep 循环在容器内 sweep.sh。
# `./run.sh smoke` 单档冒烟。模板 = templates/<name>.env,source 进来即自动填充。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

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
SMOKE=0; [ "${1:-run}" = smoke ] && SMOKE=1
if [ "$SMOKE" = 1 ]; then RUN_ID="smoke-$TEMPLATE"; else RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"; fi

ensure_image
DOUT="$PWD/out"; mkdir -p "$DOUT"

# tokenizer 挂载源:online 挂 host ./tok(可写缓存),offline 挂用户目录(只读)
if [ "${TOKENIZER_MODE:-online}" = offline ]; then
  : "${TOKENIZER_PATH:?offline 缺 TOKENIZER_PATH}"
  TOK_MOUNT="$TOKENIZER_PATH:/tok:ro"
else
  mkdir -p "$PWD/tok"; TOK_MOUNT="$PWD/tok:/tok"
fi

# 传给 sweep.sh 的 env 清单(值来自已 source 的 config+template)
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)
# PYTHONPATH=/app:runner 包在镜像 /app 下;我们用 -w /work 改了 cwd(让 MD_OUTPUT_FILES
# 相对路径落到挂载卷),故显式加 /app 到模块搜索路径,否则 `python -m runner` 找不到包。
ENVARGS=(-e MD_BENCHMARK_ID="$RUN_ID" -e MD_ARGV='["bash","/rb/sweep.sh"]'
  -e MD_OUTPUT_DIR=/work/out -e MD_OUTPUT_FILES="{\"summary.csv\":\"out/$RUN_ID/summary.csv\"}"
  -e PYTHONPATH=/app -e OPENAI_API_KEY="$KEY" -e SMOKE="$SMOKE")
for v in "${SWEEP_ENV[@]}"; do ENVARGS+=(-e "$v=${!v-}"); done

echo "被测端点: $URL"; echo "模型:     $MODEL"
echo "模板:     $TEMPLATE(轴=$AXIS)"; echo "产物:     out/$RUN_ID"; echo

docker run --rm "${ENVARGS[@]}" -w /work \
  -v "$PWD/sweep.sh:/rb/sweep.sh:ro" -v "$PWD/parse.py:/rb/parse.py:ro" \
  -v "$DOUT:/work/out" -v "$TOK_MOUNT" "$IMG"

[ "$SMOKE" = 1 ] || ln -sfn "$RUN_ID" "$DOUT/latest"
[ "$SMOKE" = 1 ] && echo "==> 冒烟通过即可 make run" || echo "==> 完成 → make parse(默认 out/latest)"
