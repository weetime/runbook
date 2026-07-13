#!/usr/bin/env bash
# evalscope runbook · 公共 shell 逻辑(被 run.sh / parse.sh source)。
# 宿主只需 bash + make + docker:conf.py / parse.py 都在镜像内跑(镜像自带 python3+sqlite)。
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引导镜像:仅用来在容器内跑 runbook 的 python(conf.py/parse.py)。与 conf.py DEFAULT_IMG 一致。
export BOOT_IMG="${BOOT_IMG:-ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2}"

# 某镜像缺则拉取。
ensure_boot_image() {
  docker image inspect "$BOOT_IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$BOOT_IMG"; docker pull "$BOOT_IMG"; }
}

# 被测所用镜像(可被 config.env 的 IMG= 覆盖)。
ensure_image() {
  : "${IMG:?IMG 未设置}"
  docker image inspect "$IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$IMG"; docker pull "$IMG"; }
}

# 数据集逻辑名 → evalscope 的 --dataset reader + 镜像内 --dataset-path。设 DS_READER / DS_PATH。
map_dataset() {
  case "$1" in
    longalpaca)   DS_READER=line_by_line; DS_PATH=/opt/evalscope-datasets/longalpaca.txt;;
    openqa)       DS_READER=openqa;       DS_PATH=/opt/evalscope-datasets/openqa/open_qa.jsonl;;
    share_gpt_en) DS_READER=share_gpt_en; DS_PATH=/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl;;
    share_gpt_zh) DS_READER=share_gpt_zh; DS_PATH=/opt/evalscope-datasets/sharegpt/common_zh_70k.jsonl;;
    random)       DS_READER=random;       DS_PATH=;;   # 合成,无文件
    *) echo "✗ 未知 dataset:$1" >&2; return 1;;
  esac
}

# 只在镜像内跑 parse.py(统计,镜像自带 python3+sqlite)。挂载 runbook 目录到 /rb。
pyc() {
  docker run --rm -v "$RB:/rb" -w /rb \
    -e AXIS -e TTFT_SLO -e ITL_SLO -e WARMUP_DROP -e TEMPLATE \
    --entrypoint python "$BOOT_IMG" "$@"
}

# 在线拉取时只取 tokenizer 相关文件,绝不下几十 GB 权重
# 含 chat_template.*:部分模型把 chat 模板放在独立文件而非 tokenizer_config.json
TOK_PATTERNS="['config.json','tokenizer.json','tokenizer_config.json','tokenizer.model','vocab.json','merges.txt','special_tokens_map.json','generation_config.json','chat_template.jinja','chat_template.json']"

_have_tokenizer() { [ -s "$1/tokenizer.json" ] || [ -s "$1/tokenizer.model" ]; }

# chat_template 可能落在:tokenizer_config.json 的 "chat_template" 键,或独立的
# chat_template.jinja / chat_template.json 文件。三处任一存在即算有。
_have_chat_template() {
  local d="$1"
  [ -s "$d/chat_template.jinja" ] && return 0
  [ -s "$d/chat_template.json" ] && return 0
  grep -q '"chat_template"' "$d/tokenizer_config.json" 2>/dev/null && return 0
  return 1
}

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
  # chat/completions 压测要用 tokenizer 的 chat_template 拼多轮 prompt;缺了会跑到
  # 一半才崩(Cannot use chat template ...),这里启动即拦,并给出可操作提示。
  if ! _have_chat_template "$TOK_DIR"; then
    echo "✗ tokenizer 缺 chat_template:$TOK_DIR" >&2
    echo "  chat/completions 压测需要它拼对话 prompt。请换成被测模型对应的" >&2
    echo "  Instruct/Chat 版 tokenizer(如 Qwen/Qwen2.5-0.5B-Instruct),改 .env 的" >&2
    echo "  TOKENIZER_ID 后删掉 ./tok 重拉:rm -rf '$RB/tok' && make smoke" >&2
    return 1
  fi
  echo "✓ tokenizer:$TOK_DIR(含 chat_template)"
}
