#!/usr/bin/env bash
# run:ShareGPT 真实流量并发扫描(冷/暖多轮)。`./run.sh smoke` 只跑单档冒烟。
set -euo pipefail
cd "$(dirname "$0")"
source ./env.sh
ensure_tokenizer     # 在线模式若 ./tok 缺,会在此按需拉取(run 阶段也支持在线拉)

if [ "${1:-sweep}" = "smoke" ]; then
  echo "==> 冒烟:单档 parallel=4 number=8(只看跑不跑得通)"
  docker run --rm -v "$TOK_DIR:/tok:ro" --entrypoint evalscope "$IMG" \
    perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
      --tokenizer-path /tok \
      --dataset share_gpt_en --dataset-path "$SG" \
      --parallel 4 --number 8 \
      --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
      --stream --seed 42
  echo "==> 冒烟通过即可 make run"
  exit 0
fi

echo "被测端点: $URL"
echo "模型:     $MODEL"
echo "并发档:   $PARALLEL | 每档: $NUMBER | 轮次: $ROUNDS(round1=冷缓存)"
echo
rm -rf "$OUT"/round*     # evalscope 见旧 benchmark_data.db 会拒跑,先清空

for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  docker run --rm -v "$TOK_DIR:/tok:ro" -v "$OUT:/work/out" --entrypoint evalscope "$IMG" \
    perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
      --tokenizer-path /tok \
      --dataset share_gpt_en --dataset-path "$SG" \
      --parallel $PARALLEL --number $NUMBER \
      --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
      --stream --seed 42 \
      --outputs-dir "/work/out/round$r" --name sweep --no-timestamp
  echo
done
echo "==> 全部完成 → make parse(聚合去冷轮 + 池化找 SLO 拐点)"
