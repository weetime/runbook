#!/usr/bin/env bash
# 验 MODE=k8s:run.sh 渲染 yaml → 假 kubectl apply(捕获 yaml)+ 假 wait/logs。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/kubectl" <<'EOF'
#!/usr/bin/env bash
# apply 出现在参数里 → 落 stdin 的 yaml;其余(config/wait/logs)当成功。
for a in "$@"; do [ "$a" = apply ] && { cat > "$RB_KLOG"; exit 0; }; done
exit 0
EOF
chmod +x "$TMP/kubectl"

cat > "$TMP/config.env" <<EOF
URL="http://10.0.0.1:30888/v1/chat/completions"
MODEL="m"
KEY="EMPTY"
TOKENIZER_MODE=online
TOKENIZER_ID="org/m"
TEMPLATE=inference-baseline
MODE=k8s
K8S_NAMESPACE=bench
EOF

export RB_KLOG="$TMP/applied.yaml"
PATH="$TMP:$PATH" CONFIG="$TMP/config.env" ./run.sh
[ -f "$TMP/applied.yaml" ] || { echo "FAIL: 未 apply(kubectl apply 没被调用)"; exit 1; }
grep -q 'kind: Job' "$TMP/applied.yaml" || { echo "FAIL: 未 apply Job"; exit 1; }
grep -qE 'name: run-.*-inference-baseline' "$TMP/applied.yaml" || { echo "FAIL: Job 名不对"; exit 1; }
grep -q 'namespace: bench' "$TMP/applied.yaml" || { echo "FAIL: namespace 不对"; exit 1; }
echo "run.sh k8s OK"
