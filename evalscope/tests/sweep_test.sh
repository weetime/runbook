#!/usr/bin/env bash
# 用假 evalscope + 假 python 验 sweep.sh:轴逻辑、输出目录、tokenizer 校验。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/evalscope" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$EVX_LOG"
od=""; while [ $# -gt 0 ]; do [ "$1" = "--outputs-dir" ] && od="$2"; shift; done
[ -n "$od" ] && mkdir -p "$od/sweep/parallel_4_number_8" && printf '{}' > "$od/sweep/parallel_4_number_8/benchmark_summary.json"
exit 0
EOF
chmod +x "$TMP/evalscope"
cat > "$TMP/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/python"

mkdir -p "$TMP/tok"; printf '{}' > "$TMP/tok/tokenizer.json"
OUT="$TMP/out"; mkdir -p "$OUT"
export EVX_LOG="$TMP/evx.log"
env PATH="$TMP:$PATH" \
  MD_BENCHMARK_ID=20260714-000000-context-length MD_OUTPUT_DIR="$OUT" \
  URL="http://H:8000/v1/chat/completions" MODEL=m OPENAI_API_KEY=EMPTY \
  AXIS=prompt_len DATASET=random PROMPT_LENS="1024 8192" PARALLEL=8 NUMBER=16 \
  MIN_TOKENS=128 MAX_TOKENS=256 ROUNDS=2 SEED=42 TTFT_SLO=5000 ITL_SLO=300 \
  TEMPLATE=context-length TOKENIZER_MODE=offline TOK_OVERRIDE="$TMP/tok" \
  bash ./sweep.sh

RDIR="$OUT/20260714-000000-context-length"
grep -q -- '--min-prompt-length' "$EVX_LOG" || { echo "FAIL: prompt_len 轴应传 --min-prompt-length"; exit 1; }
grep -q -- '1024' "$EVX_LOG" || { echo "FAIL: 缺 1024 长度档"; exit 1; }
grep -q -- '8192' "$EVX_LOG" || { echo "FAIL: 缺 8192 长度档"; exit 1; }
[ -d "$RDIR/round1/len1024" ] || { echo "FAIL: 缺 round1/len1024"; exit 1; }
[ -d "$RDIR/round2/len8192" ] || { echo "FAIL: 缺 round2/len8192(暖轮)"; exit 1; }
[ -f "$RDIR/run.env" ] || { echo "FAIL: 缺 run.env"; exit 1; }
echo "sweep.sh OK"
