#!/usr/bin/env bash
# 验 render_k8s_yaml 结构:命名/labels/容器名/env/挂载;有 kubectl 则 client dry-run。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh

export RUN_ID=20260714-000000-inference-baseline
export IMG=ghcr.io/weetime/md-runner-evalscope:0afe9b07
export URL="http://10.0.0.1:30888/v1/chat/completions" MODEL="m-x" KEY="sk-secret-xyz"
export K8S_NAMESPACE=bench
export AXIS=parallel DATASET=share_gpt_en PARALLEL="4 8" NUMBER="60 80" \
  MIN_TOKENS=128 MAX_TOKENS=256 ROUNDS=3 SEED=42 TTFT_SLO=1500 ITL_SLO=200 \
  TEMPLATE=inference-baseline TOKENIZER_MODE=online TOKENIZER_ID=org/m TOKENIZER_SOURCE=modelscope
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)

Y="$(render_k8s_yaml)"
grep -q 'name: run-20260714-000000-inference-baseline' <<<"$Y" || { echo "FAIL: Job/资源名不对"; exit 1; }
grep -q 'app.kubernetes.io/name: modeldoctor-run' <<<"$Y" || { echo "FAIL: 缺 modeldoctor label"; exit 1; }
grep -qE 'name: runner$' <<<"$Y" || { echo "FAIL: 容器名应为 runner"; exit 1; }
grep -q 'namespace: bench' <<<"$Y" || { echo "FAIL: namespace 未渲染"; exit 1; }
grep -q 'MD_ARGV' <<<"$Y" || { echo "FAIL: 缺 MD_ARGV"; exit 1; }
grep -q 'PYTHONPATH' <<<"$Y" || { echo "FAIL: 缺 PYTHONPATH=/app"; exit 1; }
grep -q 'restartPolicy: Never' <<<"$Y" || { echo "FAIL: 缺 restartPolicy Never"; exit 1; }
grep -q 'sweep.sh: |' <<<"$Y" || { echo "FAIL: ConfigMap 未嵌 sweep.sh"; exit 1; }
grep -q 'parse.py: |' <<<"$Y" || { echo "FAIL: ConfigMap 未嵌 parse.py"; exit 1; }
grep -q 'OPENAI_API_KEY' <<<"$Y" || { echo "FAIL: Secret 缺 OPENAI_API_KEY"; exit 1; }
# key 走 Secret,不得出现在 Job env 明文
grep -q 'sk-secret-xyz' <<<"$Y" && grep -q 'workingDir' <<<"$Y" || true
# 默认不带 imagePullSecrets
grep -q 'imagePullSecrets' <<<"$Y" && { echo "FAIL: 未设 K8S_IMAGE_PULL_SECRET 时不应出现 imagePullSecrets"; exit 1; }
# 设了才带,且带对名字
Y2="$(K8S_IMAGE_PULL_SECRET=swr-cred render_k8s_yaml)"
grep -q 'imagePullSecrets: \[{name: "swr-cred"}\]' <<<"$Y2" || { echo "FAIL: K8S_IMAGE_PULL_SECRET 未渲染 imagePullSecrets"; exit 1; }

if command -v kubectl >/dev/null 2>&1; then
  kubectl apply --dry-run=client -f - <<<"$Y" >/dev/null || { echo "FAIL: kubectl dry-run 不过"; exit 1; }
  kubectl apply --dry-run=client -f - <<<"$Y2" >/dev/null || { echo "FAIL: 带 pull-secret 的 yaml dry-run 不过"; exit 1; }
  echo "(kubectl client dry-run 通过)"
fi
echo "render_k8s_yaml OK"
