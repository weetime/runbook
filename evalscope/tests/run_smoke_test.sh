#!/usr/bin/env bash
# 用假 docker + 离线 tokenizer fixture 验证 run.sh smoke 组出的 evalscope argv。
set -euo pipefail
cd "$(dirname "$0")/.."          # 到 evalscope 目录(run.sh/conf.py 所在)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 假 docker:image inspect 返回 0(跳过 pull);conf.py 解析步在宿主用 python3 跑
# (让 run.sh 拿到 exports);evalscope perf 调用把 argv 落盘。
cat > "$TMP/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  image) exit 0 ;;
  pull)  exit 0 ;;
  run)
    if printf '%s\n' "$@" | grep -q 'conf.py'; then
      if printf '%s\n' "$@" | grep -q -- '--json'; then python3 conf.py --json; else python3 conf.py; fi
      exit 0
    fi
    printf '%s\n' "$@" >> "$RB_DOCKER_LOG"; exit 0 ;;
  *)     exit 0 ;;
esac
EOF
chmod +x "$TMP/docker"

# 离线 tokenizer fixture(带 chat_template,过 ensure_tokenizer 校验)
mkdir -p "$TMP/tok"
printf '{}' > "$TMP/tok/tokenizer.json"
printf '{}' > "$TMP/tok/chat_template.jinja"

cat > "$TMP/config.yaml" <<EOF
endpoint: {url: http://HOST:8000/v1/chat/completions, model: m, key: EMPTY}
tokenizer: {mode: offline, path: $TMP/tok}
template: context-length
EOF

export RB_DOCKER_LOG="$TMP/argv.log"
PATH="$TMP:$PATH" CONFIG="$TMP/config.yaml" ./run.sh smoke

grep -q -- '--dataset' "$TMP/argv.log" || { echo "FAIL: 缺 --dataset"; exit 1; }
grep -q -- 'random'    "$TMP/argv.log" || { echo "FAIL: 缺 random reader"; exit 1; }
grep -q -- '--min-prompt-length' "$TMP/argv.log" || { echo "FAIL: prompt_len 轴应传 --min-prompt-length"; exit 1; }
grep -q -- '1024' "$TMP/argv.log" || { echo "FAIL: smoke 应取最短长度 1024"; exit 1; }
grep -q -- '/work/out/smoke' "$TMP/argv.log" || { echo "FAIL: smoke 输出目录不对"; exit 1; }
echo "run.sh smoke argv OK"
