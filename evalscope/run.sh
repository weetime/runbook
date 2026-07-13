#!/bin/bash
# 步骤 3-4:ShareGPT 真实流量,并发扫描 4/8/16/32,冷/暖各若干轮。
set -e
cd "$(dirname "$0")"; source ./env.sh
echo "被测端点: $URL"
echo "模型:     $MODEL"
echo "并发档:   $PAR    | 每档请求数: $NUM"
echo "轮次:     $ROUNDS(round1=冷缓存,其余=暖缓存;每档去极值取中位)"
echo

rm -rf "$OUT"/round*        # evalscope 若见旧 benchmark_data.db 会拒跑,先清空

for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  docker run --rm -v "$TOK:/tok" -v "$OUT:/work/out" --entrypoint evalscope "$IMG" \
    perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
      --tokenizer-path /tok \
      --dataset share_gpt_en --dataset-path "$SG" \
      --parallel $PAR --number $NUM \
      --max-tokens 256 --min-tokens 128 \
      --stream --seed 42 \
      --outputs-dir "/work/out/round$r" --name sweep --no-timestamp
  echo
done
echo "全部完成 → $OUT"
echo "下一步:python3 parse.py   # 聚合去极值 + 找 SLO 拐点"
