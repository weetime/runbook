#!/usr/bin/env bash
# run:按模板 sweep 轴扫描,每次落独立 out/<run-id>/。`./run.sh smoke` 单档冒烟。
# 模板 = 一组 run 参数(templates/<name>.env),source 进来即自动填充,用户无需再填。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# 连接(含选定 TEMPLATE)。命令行 TEMPLATE=xxx 优先于 config.env 里的默认。
CLI_TEMPLATE="${TEMPLATE:-}"
CFG="${CONFIG:-config.env}"        # 可用 CONFIG=path 覆盖(测试用)
[ -f "$CFG" ] || { echo "✗ 未找到 $CFG —— 先跑:make config" >&2; exit 1; }
source "$CFG"
[ -n "$CLI_TEMPLATE" ] && TEMPLATE="$CLI_TEMPLATE"
: "${TEMPLATE:?config.env 缺 TEMPLATE}"
TPL="templates/$TEMPLATE.env"
[ -f "$TPL" ] || { echo "✗ 模板不存在:$TPL(见 templates/)" >&2; exit 1; }
source "$TPL"                       # 自动填充 AXIS/DATASET/PARALLEL/... 等全部参数

: "${URL:?config.env 缺 URL}"; : "${MODEL:?config.env 缺 MODEL}"
export KEY="${KEY:-EMPTY}"
export IMG="${IMG:-$BOOT_IMG}"
map_dataset "$DATASET"             # 设 DS_READER / DS_PATH

ensure_image
ensure_tokenizer                   # 导出 TOK_DIR

DOUT="$PWD/out"; mkdir -p "$DOUT"

# 单次 evalscope 调用。$1=容器内 outputs-dir,其余=额外 flag(并发档 / prompt 长度)
_evalscope() {
  local outdir="$1"; shift
  docker run --rm -v "$TOK_DIR:/tok:ro" -v "$DOUT:/work/out" --entrypoint evalscope "$IMG" \
    perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
      --tokenizer-path /tok \
      --dataset "$DS_READER" ${DS_PATH:+--dataset-path "$DS_PATH"} \
      --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
      --stream --seed "$SEED" \
      --name sweep --no-timestamp --outputs-dir "$outdir" "$@"
}

# 冒烟:单档小跑,不写 run-id
if [ "${1:-run}" = "smoke" ]; then
  echo "==> 冒烟:单档 parallel=4 number=8(模板 $TEMPLATE,只看跑不跑得通)"
  rm -rf "$DOUT/smoke"
  if [ "$AXIS" = "prompt_len" ]; then
    L="$(printf '%s\n' $PROMPT_LENS | sort -n | head -1)"
    _evalscope "/work/out/smoke" --parallel 4 --number 8 --min-prompt-length "$L" --max-prompt-length "$L"
  else
    _evalscope "/work/out/smoke" --parallel 4 --number 8 \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo "==> 冒烟通过即可 make run"
  exit 0
fi

# 全量扫:独立 run 目录 + 自描述 run.env(供 parse 独立解析)
RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"
RDIR="$DOUT/$RUN_ID"; mkdir -p "$RDIR"
cat > "$RDIR/run.env" <<EOF
TEMPLATE=$TEMPLATE
AXIS=$AXIS
DATASET=$DATASET
TTFT_SLO=$TTFT_SLO
ITL_SLO=$ITL_SLO
EOF
ln -sfn "$RUN_ID" "$DOUT/latest"

echo "被测端点: $URL"
echo "模型:     $MODEL"
echo "模板:     $TEMPLATE(轴=$AXIS)| 轮次: $ROUNDS(round1=冷缓存)"
echo "产物:     out/$RUN_ID(out/latest → 之)"
echo

for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  if [ "$AXIS" = "prompt_len" ]; then
    for L in $PROMPT_LENS; do
      echo "---------- 输入长度 $L ----------"
      _evalscope "/work/out/$RUN_ID/round$r/len$L" \
        --parallel $PARALLEL --number $NUMBER \
        --min-prompt-length "$L" --max-prompt-length "$L"
    done
  else
    _evalscope "/work/out/$RUN_ID/round$r" \
      --parallel $PARALLEL --number $NUMBER \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo
done
echo "==> 全部完成 → make parse(默认解析 out/latest)"
