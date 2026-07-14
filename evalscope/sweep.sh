#!/usr/bin/env bash
# 容器内 sweep:按模板轴扫描 → 写 $MD_OUTPUT_DIR/$MD_BENCHMARK_ID/ → 末尾 parse 打表。
# 由 runner(python -m runner)以 MD_ARGV=["bash","/rb/sweep.sh"] 调起;宿主无关,直接调 evalscope。
set -euo pipefail

: "${MD_BENCHMARK_ID:?}"; : "${MD_OUTPUT_DIR:?}"
: "${URL:?}"; : "${MODEL:?}"; : "${AXIS:?}"; : "${DATASET:?}"
: "${MIN_TOKENS:?}"; : "${MAX_TOKENS:?}"; : "${SEED:?}"
KEY="${OPENAI_API_KEY:-EMPTY}"
RDIR="$MD_OUTPUT_DIR/$MD_BENCHMARK_ID"; mkdir -p "$RDIR"
TOK="${TOK_OVERRIDE:-/tok}"

case "$DATASET" in
  longalpaca)   DS_READER=line_by_line; DS_PATH=/opt/evalscope-datasets/longalpaca.txt;;
  openqa)       DS_READER=openqa;       DS_PATH=/opt/evalscope-datasets/openqa/open_qa.jsonl;;
  share_gpt_en) DS_READER=share_gpt_en; DS_PATH=/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl;;
  share_gpt_zh) DS_READER=share_gpt_zh; DS_PATH=/opt/evalscope-datasets/sharegpt/common_zh_70k.jsonl;;
  random)       DS_READER=random;       DS_PATH=;;
  *) echo "✗ 未知 dataset:$DATASET" >&2; exit 1;;
esac

_have_tok() { [ -s "$TOK/tokenizer.json" ] || [ -s "$TOK/tokenizer.model" ]; }
if ! _have_tok; then
  [ "${TOKENIZER_MODE:-online}" = online ] || { echo "✗ 离线模式但 $TOK 无 tokenizer" >&2; exit 1; }
  : "${TOKENIZER_ID:?online 需 TOKENIZER_ID}"; mkdir -p "$TOK"
  P="['config.json','tokenizer.json','tokenizer_config.json','tokenizer.model','vocab.json','merges.txt','special_tokens_map.json','generation_config.json','chat_template.jinja','chat_template.json']"
  echo "↓ 容器内拉取 tokenizer:$TOKENIZER_ID(源:${TOKENIZER_SOURCE:-modelscope})"
  if [ "${TOKENIZER_SOURCE:-modelscope}" = hf ]; then
    HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}" python -c "from huggingface_hub import snapshot_download; snapshot_download('$TOKENIZER_ID', allow_patterns=$P, local_dir='$TOK')"
  else
    python -c "from modelscope import snapshot_download; snapshot_download('$TOKENIZER_ID', allow_patterns=$P, local_dir='$TOK')"
  fi
fi
_have_tok || { echo "✗ $TOK 无 tokenizer 文件" >&2; exit 1; }

_evalscope() {
  local outdir="$1"; shift
  evalscope perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
    --tokenizer-path "$TOK" \
    --dataset "$DS_READER" ${DS_PATH:+--dataset-path "$DS_PATH"} \
    --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
    --stream --seed "$SEED" \
    --name sweep --no-timestamp --outputs-dir "$outdir" "$@"
}

if [ "${SMOKE:-0}" = 1 ]; then
  echo "==> 冒烟:parallel=4 number=8(模板轴=$AXIS)"
  if [ "$AXIS" = prompt_len ]; then
    L="$(printf '%s\n' $PROMPT_LENS | sort -n | head -1)"
    _evalscope "$RDIR/smoke" --parallel 4 --number 8 --min-prompt-length "$L" --max-prompt-length "$L"
  else
    _evalscope "$RDIR/smoke" --parallel 4 --number 8 \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo "==> 冒烟通过即可 make run"; exit 0
fi

cat > "$RDIR/run.env" <<EOF
TEMPLATE=${TEMPLATE:-}
AXIS=$AXIS
DATASET=$DATASET
TTFT_SLO=${TTFT_SLO:-}
ITL_SLO=${ITL_SLO:-}
EOF

: "${PARALLEL:?}"; : "${NUMBER:?}"; : "${ROUNDS:?}"
for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  if [ "$AXIS" = prompt_len ]; then
    for L in $PROMPT_LENS; do
      echo "---------- 输入长度 $L ----------"
      _evalscope "$RDIR/round$r/len$L" --parallel $PARALLEL --number $NUMBER \
        --min-prompt-length "$L" --max-prompt-length "$L"
    done
  else
    _evalscope "$RDIR/round$r" --parallel $PARALLEL --number $NUMBER \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
done

AXIS="$AXIS" TTFT_SLO="${TTFT_SLO:-}" ITL_SLO="${ITL_SLO:-}" TEMPLATE="${TEMPLATE:-}" \
  python /rb/parse.py "$RDIR" || echo "(parse 失败,原始产物已在 $RDIR)"
echo "==> 完成 → 产物 $RDIR"
