#!/usr/bin/env bash
# 验 run.sh smoke 走 runner 入口:docker run 带 MD_* env + 挂 sweep.sh,不再 --entrypoint evalscope。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  image) exit 0 ;;
  pull)  exit 0 ;;
  run)   printf '%s\n' "$@" >> "$RB_DOCKER_LOG"; exit 0 ;;
  *)     exit 0 ;;
esac
EOF
chmod +x "$TMP/docker"

mkdir -p "$TMP/tok"; printf '{}' > "$TMP/tok/tokenizer.json"; printf '{}' > "$TMP/tok/chat_template.jinja"
cat > "$TMP/config.env" <<EOF
URL="http://HOST:8000/v1/chat/completions"
MODEL="m"
KEY="EMPTY"
TOKENIZER_MODE=offline
TOKENIZER_PATH="$TMP/tok"
TEMPLATE=inference-baseline
EOF

export RB_DOCKER_LOG="$TMP/argv.log"
PATH="$TMP:$PATH" CONFIG="$TMP/config.env" ./run.sh smoke

grep -q -- 'MD_ARGV' "$TMP/argv.log" || { echo "FAIL: 缺 MD_ARGV(应走 runner 入口)"; exit 1; }
grep -q -- '/rb/sweep.sh' "$TMP/argv.log" || { echo "FAIL: 未挂 sweep.sh"; exit 1; }
grep -q -- 'MD_OUTPUT_DIR' "$TMP/argv.log" || { echo "FAIL: 缺 MD_OUTPUT_DIR sink"; exit 1; }
grep -q -- 'PYTHONPATH=/app' "$TMP/argv.log" || { echo "FAIL: 缺 PYTHONPATH=/app(-w /work 下 python -m runner 找不到包)"; exit 1; }
grep -q -- 'SMOKE=1' "$TMP/argv.log" || { echo "FAIL: smoke 应置 SMOKE=1"; exit 1; }
if grep -q -- '--entrypoint' "$TMP/argv.log"; then echo "FAIL: 不应再覆盖 entrypoint"; exit 1; fi
echo "run.sh docker OK"
