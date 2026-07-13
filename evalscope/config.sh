#!/usr/bin/env bash
# 交互式向导:填端点 + tokenizer + 选模板 → 生成 config.env(不入库)。
# 压测参数不用填 —— make run 时由所选模板自动填充。
set -euo pipefail
cd "$(dirname "$0")"
CFG="$PWD/config.env"

if [ -f "$CFG" ]; then
  read -r -p "config.env 已存在,覆盖?(y/N) " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
fi

ask() { local p="$1" d="${2:-}" v; read -r -p "  $p${d:+ [$d]}: " v; printf '%s' "${v:-$d}"; }

echo "evalscope runbook · 交互式配置 → 生成 config.env"
echo
echo "── 被测端点(OpenAI 兼容)──"
URL="";   while [ -z "$URL" ];   do URL=$(ask "端点 URL(完整 /v1/chat/completions,必填)"); done
MODEL=""; while [ -z "$MODEL" ]; do MODEL=$(ask "模型名(服务端注册,必填)"); done
KEY=$(ask "API Key(无则 EMPTY)" "EMPTY")

echo
echo "── Tokenizer(evalscope 数 token 用,不是权重)──"
echo "  1) 在线拉取:填模型仓库 id,自动下 tokenizer 到 ./tok"
echo "  2) 离线目录:填本机已有 tokenizer 目录"
M=$(ask "选择 1/2" "1")
if [ "$M" = "2" ]; then
  TMODE=offline
  TPATH=""; while [ -z "$TPATH" ]; do TPATH=$(ask "tokenizer 目录绝对路径"); done
else
  TMODE=online
  TID="";  while [ -z "$TID" ];  do TID=$(ask "模型仓库 id(如 deepseek-ai/DeepSeek-V3)"); done
  TSRC=$(ask "拉取源 modelscope/hf" "modelscope")
fi

echo
echo "── 选测试模板(make run 按它自动填充压测参数)──"
for f in templates/*.env; do
  n="$(basename "$f" .env)"
  d="$(head -1 "$f" | sed 's/^#[[:space:]]*//')"
  printf '  · %-18s %s\n' "$n" "$d"
done
TPL=$(ask "模板名" "inference-baseline")
[ -f "templates/$TPL.env" ] || { echo "✗ 模板不存在:templates/$TPL.env" >&2; exit 1; }

{
  echo "# evalscope runbook · config.sh 生成 —— 含真实端点/密钥,勿入库(见 .gitignore)"
  echo "URL=\"$URL\""
  echo "MODEL=\"$MODEL\""
  echo "KEY=\"$KEY\""
  echo "TOKENIZER_MODE=$TMODE"
  if [ "$TMODE" = offline ]; then
    echo "TOKENIZER_PATH=\"$TPATH\""
  else
    echo "TOKENIZER_ID=\"$TID\""
    echo "TOKENIZER_SOURCE=$TSRC"
  fi
  echo "TEMPLATE=$TPL"
} > "$CFG"

echo
echo "✓ 已写 $CFG"
echo "下一步:make smoke && make run && make parse"
