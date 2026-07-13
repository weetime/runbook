#!/usr/bin/env bash
# 交互式向导:一步步引导填信息 → 生成 .env(不入库)。
set -euo pipefail
cd "$(dirname "$0")"
ENV="$PWD/.env"

if [ -f "$ENV" ]; then
  read -r -p ".env 已存在,覆盖?(y/N) " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
fi

ask() { local p="$1" d="${2:-}" v; read -r -p "  $p${d:+ [$d]}: " v; printf '%s' "${v:-$d}"; }

echo "evalscope runbook · 交互式配置 → 生成 .env"
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
echo "── 压测负载(回车用默认)──"
PAR=$(ask "并发档" "4 8 16 32")
NUM=$(ask "每档请求数(与并发档一一对应)" "60 80 120 160")
RND=$(ask "轮次(round1=冷缓存)" "3")
MINT=$(ask "min-tokens" "128")
MAXT=$(ask "max-tokens" "256")

{
  echo "# evalscope runbook · setup.sh 生成 —— 含真实端点/密钥,勿入库(见 .gitignore)"
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
  echo "PARALLEL=\"$PAR\""
  echo "NUMBER=\"$NUM\""
  echo "ROUNDS=$RND"
  echo "MIN_TOKENS=$MINT"
  echo "MAX_TOKENS=$MAXT"
} > "$ENV"

echo
echo "✓ 已写 $ENV"
echo "下一步:make install && make smoke && make run && make parse"
