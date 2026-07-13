#!/usr/bin/env bash
# evalscope runbook · 配置 + 公共逻辑(被 install.sh / run.sh 用 source 载入)
# 真实端点/密钥/tokenizer 都从 .env 读(.env 不入库);跑 `make setup` 交互生成。
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$RB/.env" ]; then
  echo "✗ 未找到 .env —— 先跑:make setup(或 ./setup.sh)" >&2
  return 1 2>/dev/null || exit 1
fi
set -a; source "$RB/.env"; set +a

# ── 必填校验 ──
: "${URL:?.env 缺 URL}"
: "${MODEL:?.env 缺 MODEL}"
export KEY="${KEY:-EMPTY}"

# ── 镜像 + 镜像内置 ShareGPT ──
export IMG="${IMG:-ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2}"
export SG="/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl"

# ── 负载参数(.env 可覆盖)──
export PARALLEL="${PARALLEL:-4 8 16 32}"     # 并发档
export NUMBER="${NUMBER:-60 80 120 160}"     # 每档请求数(与并发档逐元素配对)
export ROUNDS="${ROUNDS:-3}"                 # round1=冷缓存,其余=暖缓存
export MIN_TOKENS="${MIN_TOKENS:-128}"
export MAX_TOKENS="${MAX_TOKENS:-256}"

export OUT="$RB/out"; mkdir -p "$OUT"

# 在线拉取时只取 tokenizer 相关文件,绝不下几十 GB 权重
TOK_PATTERNS="['config.json','tokenizer.json','tokenizer_config.json','tokenizer.model','vocab.json','merges.txt','special_tokens_map.json','generation_config.json']"

_have_tokenizer() { [ -s "$1/tokenizer.json" ] || [ -s "$1/tokenizer.model" ]; }

# 在线拉取 tokenizer → 本地目录(modelscope 默认;hf 走 HF_ENDPOINT 镜像)
fetch_tokenizer() {
  local id="$1" src="$2" dest="$3"
  mkdir -p "$dest"
  echo "↓ 在线拉取 tokenizer:$id(源:$src)→ $dest"
  if [ "$src" = "hf" ]; then
    docker run --rm --user root -e HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}" \
      -v "$dest:/tok" --entrypoint python "$IMG" \
      -c "from huggingface_hub import snapshot_download; snapshot_download('$id', allow_patterns=$TOK_PATTERNS, local_dir='/tok')"
  else
    docker run --rm --user root -v "$dest:/tok" --entrypoint python "$IMG" \
      -c "from modelscope import snapshot_download; snapshot_download('$id', allow_patterns=$TOK_PATTERNS, local_dir='/tok')"
  fi
}

# 解析 tokenizer,导出 TOK_DIR(供 run 挂载)。在线模式若本地缺,按需拉取。
# online / offline 最终都归一到「挂载一个本地目录」——evalscope 只读本地,最稳、可复现。
ensure_tokenizer() {
  case "${TOKENIZER_MODE:-online}" in
    offline)
      : "${TOKENIZER_PATH:?.env 缺 TOKENIZER_PATH(离线模式)}"
      _have_tokenizer "$TOKENIZER_PATH" || { echo "✗ $TOKENIZER_PATH 里没有 tokenizer.json/.model(可能下到了 metadata 小文件)" >&2; return 1; }
      export TOK_DIR="$TOKENIZER_PATH" ;;
    online)
      : "${TOKENIZER_ID:?.env 缺 TOKENIZER_ID(在线模式)}"
      _have_tokenizer "$RB/tok" || fetch_tokenizer "$TOKENIZER_ID" "${TOKENIZER_SOURCE:-modelscope}" "$RB/tok"
      _have_tokenizer "$RB/tok" || { echo "✗ 拉取失败:$RB/tok 无 tokenizer 文件" >&2; return 1; }
      export TOK_DIR="$RB/tok" ;;
    *) echo "✗ TOKENIZER_MODE 只能是 online / offline" >&2; return 1 ;;
  esac
  echo "✓ tokenizer:$TOK_DIR"
}
