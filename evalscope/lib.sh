#!/usr/bin/env bash
# evalscope runbook · 公共 shell 逻辑(被 run.sh / parse.sh source)。
# 宿主只需 bash + make + docker:sweep / conf / parse 都在容器内跑(镜像自带 python3+sqlite)。
# tokenizer / dataset 映射已随 sweep 逻辑移进容器内的 sweep.sh。
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 引导镜像:容器内跑 runbook 的 python(sweep 调 evalscope + parse.py)。与被测镜像同一个。
# 须 ≥ #358(含 LocalWriter/select_sink),否则 python -m runner 缺 S3 会崩;0afe9b07 = #358 合并点。
export BOOT_IMG="${BOOT_IMG:-ghcr.io/weetime/md-runner-evalscope:0afe9b07}"

# 引导镜像缺则拉取。
ensure_boot_image() {
  docker image inspect "$BOOT_IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$BOOT_IMG"; docker pull "$BOOT_IMG"; }
}

# 被测所用镜像(可被 config.env 的 IMG= 覆盖)。
ensure_image() {
  : "${IMG:?IMG 未设置}"
  docker image inspect "$IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$IMG"; docker pull "$IMG"; }
}

# 只在镜像内跑 parse.py(统计,镜像自带 python3+sqlite)。挂载 runbook 目录到 /rb。
pyc() {
  docker run --rm -v "$RB:/rb" -w /rb \
    -e AXIS -e TTFT_SLO -e ITL_SLO -e WARMUP_DROP -e TEMPLATE \
    --entrypoint python "$BOOT_IMG" "$@"
}

# yaml 双引号标量(转义 \ 与 "),让含 : / 空格的值安全。
_yaml_dq() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

# 渲染离线集群一次性压测:Secret + ConfigMap(内嵌 sweep.sh/parse.py)+ Job 到 stdout。
# 形态对齐 modeldoctor(labels / 容器名 runner / backoffLimit 0 / restartPolicy Never)。
# 与 docker 模式同契约:MD_ARGV=["bash","/rb/sweep.sh"]、MD_OUTPUT_DIR=/work/out、PYTHONPATH=/app。
# sink=emptyDir(产物随 pod 生命周期,头条 SLO 表看 kubectl logs;要留存另挂 PVC)。
# 依赖调用方已 export:RUN_ID IMG KEY K8S_NAMESPACE + SWEEP_ENV 数组及其成员;cwd 有 sweep.sh/parse.py。
render_k8s_yaml() {
  local ns="${K8S_NAMESPACE:-default}" job="run-$RUN_ID" v
  local L1="app.kubernetes.io/name: modeldoctor-run"
  local L2="app.kubernetes.io/managed-by: runbook-evalscope"
  # 容器 env:固定 MD_* + PYTHONPATH,再拼 SWEEP_ENV(block 风格,8 空格缩进)
  local envblock=""
  envblock+="        - {name: MD_BENCHMARK_ID, value: $(_yaml_dq "$RUN_ID")}"$'\n'
  envblock+='        - {name: MD_ARGV, value: "[\"bash\",\"/rb/sweep.sh\"]"}'$'\n'
  envblock+='        - {name: MD_OUTPUT_DIR, value: /work/out}'$'\n'
  envblock+="        - {name: MD_OUTPUT_FILES, value: $(_yaml_dq "{\"summary.csv\":\"out/$RUN_ID/summary.csv\"}")}"$'\n'
  envblock+='        - {name: PYTHONPATH, value: /app}'$'\n'
  for v in "${SWEEP_ENV[@]}"; do
    envblock+="        - {name: $v, value: $(_yaml_dq "${!v-}")}"$'\n'
  done
  local script="$(sed 's/^/    /' sweep.sh)"
  local parse="$(sed 's/^/    /' parse.py)"
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $job
  namespace: $ns
  labels: {$L1, $L2}
type: Opaque
stringData:
  OPENAI_API_KEY: $(_yaml_dq "${KEY:-EMPTY}")
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $job
  namespace: $ns
  labels: {$L1, $L2}
data:
  sweep.sh: |
$script
  parse.py: |
$parse
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $ns
  labels: {$L1, $L2}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {$L1, $L2}
    spec:
      restartPolicy: Never
      containers:
      - name: runner
        image: $IMG
        imagePullPolicy: IfNotPresent
        workingDir: /work
        env:
$envblock        envFrom:
        - secretRef: {name: $job}
        volumeMounts:
        - {name: rb, mountPath: /rb}
        - {name: out, mountPath: /work/out}
        - {name: tok, mountPath: /tok}
      volumes:
      - name: rb
        configMap: {name: $job, defaultMode: 0755}
      - {name: out, emptyDir: {}}
      - {name: tok, emptyDir: {}}
YAML
}
