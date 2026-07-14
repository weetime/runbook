# runbook 复用 runner —— 离线 docker/k8s 两模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `evalscope/` 压测通过 modeldoctor 的 `python -m runner` 入口跑,离线支持 `docker`(默认)与 `k8s`(渲染 yaml → kubectl apply)两模式,与在线 modeldoctor 共用同一镜像、契约、产物布局。

**Architecture:** sweep 循环从 `run.sh` 抽到容器内跑的 `sweep.sh`(直接调 `evalscope`,不再 `docker run`);`run.sh` 变分发器,按 `MODE` 构建 `MD_*` env + 落地(docker `docker run` / k8s 渲染 yaml)。一个 run = 一个容器/Job。sink 走 runner 的 `LocalWriter`(`MD_OUTPUT_DIR`,PR #358 已提供)。

**Tech Stack:** bash · docker · kubectl · evalscope 镜像 `ghcr.io/weetime/md-runner-evalscope`(ENTRYPOINT `python -m runner`)· python3(镜像内,跑 parse.py)。

## Global Constraints

- 镜像统一 `ghcr.io/weetime/md-runner-evalscope:<tag>`(= `lib.sh` 的 `BOOT_IMG`),两模式同镜像,与在线 modeldoctor 同镜像。
- runner 契约(消费,不改 modeldoctor):`MD_BENCHMARK_ID`、`MD_ARGV`(JSON argv)、`MD_OUTPUT_FILES`(JSON alias→cwd 相对路径)、`MD_OUTPUT_DIR`(离线 sink 根)、`OPENAI_API_KEY`(env,不进 argv)。sink 选择:`S3_ENDPOINT` 有→S3;否则 `MD_OUTPUT_DIR`→本地;都无→退出。
- k8s Job 命名对齐 modeldoctor:Job 名 `run-<run-id>`、容器名 `runner`、labels `app.kubernetes.io/name: modeldoctor-run` + `app.kubernetes.io/managed-by: runbook-evalscope`。
- run-id 语义 `YYYYmmdd-HHMMSS-<template>`。
- 宿主只需 `bash + make + docker`(k8s 模式另需 `kubectl`)。parse.py 只在镜像内跑。
- 脱敏红线:真实端点/密钥只进 `config.env`(不入库),脚本/yaml 一律变量或 Secret,不硬编码。
- 不做:helm、docker-compose、runbook 自己发起在线 k8s、一个 run 多 Job 扇出。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `evalscope/sweep.sh`(新增) | 容器内 sweep:map_dataset + ensure /tok + 按轴扫描 + 末尾 parse 打表,写 `$MD_OUTPUT_DIR/$MD_BENCHMARK_ID/`。宿主无关。 |
| `evalscope/run.sh`(重写) | 分发器:load config+template → build `MD_*` env → 按 `MODE` 调 docker / k8s。 |
| `evalscope/lib.sh`(改) | 增 `render_k8s_yaml`;保留 `ensure_boot_image`/`ensure_image`/`pyc`;移除 host 端 tokenizer 拉取(移入 sweep.sh)。 |
| `evalscope/config.example.env`(改) | 增 `MODE=docker` + k8s 可选项(`K8S_NAMESPACE`)。 |
| `evalscope/Makefile`(改) | `run`/`smoke` 透传 `MODE`。 |
| `evalscope/config.sh`(改) | 向导增一步选 MODE。 |
| `evalscope/tests/sweep_test.sh`(新增) | 假 evalscope/python 验 sweep.sh 轴逻辑 + 产物布局。 |
| `evalscope/tests/run_smoke_test.sh`(改) | 验 run.sh 组出的 docker run 走 runner 入口 + MD_* env。 |
| `evalscope/tests/render_k8s_test.sh`(新增) | 验 render_k8s_yaml 结构 + `kubectl --dry-run`。 |
| `evalscope/RUNBOOK.md`·`README.md`·`SCENARIOS.md`(改) | 文档对齐两模式。 |

**Phase 1(Task 1–4)docker 模式端到端,独立可交付。Phase 2(Task 5–7)加 k8s。**

---

## Task 1: 抽出 `sweep.sh`(容器内 sweep)

**Files:**
- Create: `evalscope/sweep.sh`
- Test: `evalscope/tests/sweep_test.sh`

**Interfaces:**
- Consumes(env,由 Task 2 的 run.sh 注入):`MD_BENCHMARK_ID` `MD_OUTPUT_DIR` `URL` `MODEL` `OPENAI_API_KEY` `AXIS` `DATASET` `PARALLEL` `NUMBER` `PROMPT_LENS` `PROMPT_MIN` `PROMPT_MAX` `MIN_TOKENS` `MAX_TOKENS` `ROUNDS` `SEED` `TTFT_SLO` `ITL_SLO` `TEMPLATE` `TOKENIZER_MODE` `TOKENIZER_ID` `TOKENIZER_SOURCE` `HF_ENDPOINT` `SMOKE`。
- Produces:`$MD_OUTPUT_DIR/$MD_BENCHMARK_ID/{round$r/…,run.env,summary.csv}`;调 `/rb/parse.py`。

- [ ] **Step 1: 写失败测试** `evalscope/tests/sweep_test.sh`

```bash
#!/usr/bin/env bash
# 用假 evalscope + 假 python 验 sweep.sh:轴逻辑、输出目录、tokenizer 校验。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 假 evalscope:把 outputs-dir 与关键 flag 落盘
cat > "$TMP/evalscope" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$EVX_LOG"
# 造出 parse 需要的最小产物,让 sweep 末尾 parse 不报错
od=""; while [ $# -gt 0 ]; do [ "$1" = "--outputs-dir" ] && od="$2"; shift; done
[ -n "$od" ] && mkdir -p "$od/sweep/parallel_4_number_8" && printf '{}' > "$od/sweep/parallel_4_number_8/benchmark_summary.json"
exit 0
EOF
chmod +x "$TMP/evalscope"
# 假 python:sweep 末尾 `python /rb/parse.py`,只需成功
cat > "$TMP/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/python"

# 离线 tokenizer fixture(免拉取)
mkdir -p "$TMP/tok"; printf '{}' > "$TMP/tok/tokenizer.json"

OUT="$TMP/out"; mkdir -p "$OUT"
export EVX_LOG="$TMP/evx.log"
# 用 TOK 覆盖 sweep.sh 里的 /tok(测试注入)
env PATH="$TMP:$PATH" \
  MD_BENCHMARK_ID=20260714-000000-context-length MD_OUTPUT_DIR="$OUT" \
  URL="http://H:8000/v1/chat/completions" MODEL=m OPENAI_API_KEY=EMPTY \
  AXIS=prompt_len DATASET=random PROMPT_LENS="1024 8192" PARALLEL=8 NUMBER=16 \
  MIN_TOKENS=128 MAX_TOKENS=256 ROUNDS=2 SEED=42 TTFT_SLO=5000 ITL_SLO=300 \
  TEMPLATE=context-length TOKENIZER_MODE=offline TOK_OVERRIDE="$TMP/tok" \
  bash ./sweep.sh

RDIR="$OUT/20260714-000000-context-length"
grep -q -- '--min-prompt-length' "$EVX_LOG" || { echo "FAIL: prompt_len 轴应传 --min-prompt-length"; exit 1; }
grep -q -- '1024' "$EVX_LOG" || { echo "FAIL: 缺 1024 长度档"; exit 1; }
grep -q -- '8192' "$EVX_LOG" || { echo "FAIL: 缺 8192 长度档"; exit 1; }
[ -d "$RDIR/round1/len1024" ] || { echo "FAIL: 缺 round1/len1024 输出目录"; exit 1; }
[ -d "$RDIR/round2/len8192" ] || { echo "FAIL: 缺 round2/len8192(暖轮)"; exit 1; }
[ -f "$RDIR/run.env" ] || { echo "FAIL: 缺 run.env"; exit 1; }
echo "sweep.sh OK"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash evalscope/tests/sweep_test.sh`
Expected: FAIL(`./sweep.sh` 不存在)

- [ ] **Step 3: 写 `evalscope/sweep.sh`**

```bash
#!/usr/bin/env bash
# 容器内 sweep:按模板轴扫描 → 写 $MD_OUTPUT_DIR/$MD_BENCHMARK_ID/ → 末尾 parse 打表。
# 由 runner(python -m runner)以 MD_ARGV=["bash","/rb/sweep.sh"] 调起;宿主无关,直接调 evalscope。
set -euo pipefail

: "${MD_BENCHMARK_ID:?}"; : "${MD_OUTPUT_DIR:?}"
: "${URL:?}"; : "${MODEL:?}"; : "${AXIS:?}"; : "${DATASET:?}"
: "${MIN_TOKENS:?}"; : "${MAX_TOKENS:?}"; : "${SEED:?}"
KEY="${OPENAI_API_KEY:-EMPTY}"
RDIR="$MD_OUTPUT_DIR/$MD_BENCHMARK_ID"; mkdir -p "$RDIR"
TOK="${TOK_OVERRIDE:-/tok}"     # 测试可用 TOK_OVERRIDE 注入

# 数据集逻辑名 → evalscope reader + 镜像内路径
case "$DATASET" in
  longalpaca)   DS_READER=line_by_line; DS_PATH=/opt/evalscope-datasets/longalpaca.txt;;
  openqa)       DS_READER=openqa;       DS_PATH=/opt/evalscope-datasets/openqa/open_qa.jsonl;;
  share_gpt_en) DS_READER=share_gpt_en; DS_PATH=/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl;;
  share_gpt_zh) DS_READER=share_gpt_zh; DS_PATH=/opt/evalscope-datasets/sharegpt/common_zh_70k.jsonl;;
  random)       DS_READER=random;       DS_PATH=;;
  *) echo "✗ 未知 dataset:$DATASET" >&2; exit 1;;
esac

# tokenizer:/tok 有就用;没有且 online 就拉(docker 挂 host ./tok 缓存;k8s 挂 emptyDir)
_have_tok() { [ -s "$TOK/tokenizer.json" ] || [ -s "$TOK/tokenizer.model" ]; }
if ! _have_tok; then
  [ "${TOKENIZER_MODE:-online}" = online ] || { echo "✗ 离线模式但 $TOK 无 tokenizer" >&2; exit 1; }
  : "${TOKENIZER_ID:?online 需 TOKENIZER_ID}"; mkdir -p "$TOK"
  P="['config.json','tokenizer.json','tokenizer_config.json','tokenizer.model','vocab.json','merges.txt','special_tokens_map.json','generation_config.json','chat_template.jinja','chat_template.json']"
  echo "↓ 容器内拉取 tokenizer:$TOKENIZER_ID(源:${TOKENIZER_SOURCE:-modelscope})"
  if [ "${TOKENIZER_SOURCE:-modelscope}" = hf ]; then
    HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}" python -c "from huggingface_hub import snapshot_download; snapshot_download('$TOKENIZER_ID', allow_patterns=$P, local_dir='$TOK')"
  else
    python -c "from modelscope import snapshot_download; snapshot_download('$TOKENIZER_ID', allow_patterns=$P, local_dir='$TOK')"
  fi
fi
_have_tok || { echo "✗ $TOK 无 tokenizer 文件" >&2; exit 1; }

_evalscope() {
  local outdir="$1"; shift
  evalscope perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
    --tokenizer-path "$TOK" \
    --dataset "$DS_READER" ${DS_PATH:+--dataset-path "$DS_PATH"} \
    --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
    --stream --seed "$SEED" \
    --name sweep --no-timestamp --outputs-dir "$outdir" "$@"
}

# 冒烟:单档小跑
if [ "${SMOKE:-0}" = 1 ]; then
  echo "==> 冒烟:parallel=4 number=8(模板轴=$AXIS)"
  if [ "$AXIS" = prompt_len ]; then
    L="$(printf '%s\n' $PROMPT_LENS | sort -n | head -1)"
    _evalscope "$RDIR/smoke" --parallel 4 --number 8 --min-prompt-length "$L" --max-prompt-length "$L"
  else
    _evalscope "$RDIR/smoke" --parallel 4 --number 8 \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo "==> 冒烟通过即可 make run"; exit 0
fi

# 自描述 run.env(供 parse 独立解析)
cat > "$RDIR/run.env" <<EOF
TEMPLATE=${TEMPLATE:-}
AXIS=$AXIS
DATASET=$DATASET
TTFT_SLO=${TTFT_SLO:-}
ITL_SLO=${ITL_SLO:-}
EOF

: "${PARALLEL:?}"; : "${NUMBER:?}"; : "${ROUNDS:?}"
for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  if [ "$AXIS" = prompt_len ]; then
    for L in $PROMPT_LENS; do
      echo "---------- 输入长度 $L ----------"
      _evalscope "$RDIR/round$r/len$L" --parallel $PARALLEL --number $NUMBER \
        --min-prompt-length "$L" --max-prompt-length "$L"
    done
  else
    _evalscope "$RDIR/round$r" --parallel $PARALLEL --number $NUMBER \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
done

# 末尾就地 parse 打表(python3 在镜像内)
AXIS="$AXIS" TTFT_SLO="${TTFT_SLO:-}" ITL_SLO="${ITL_SLO:-}" TEMPLATE="${TEMPLATE:-}" \
  python /rb/parse.py "$RDIR" || echo "(parse 失败,原始产物已在 $RDIR)"
echo "==> 完成 → 产物 $RDIR"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `bash evalscope/tests/sweep_test.sh`
Expected: `sweep.sh OK`

- [ ] **Step 5: 提交**

```bash
git add evalscope/sweep.sh evalscope/tests/sweep_test.sh
git commit -m "feat(evalscope): 抽出容器内 sweep.sh(直接调 evalscope + 末尾 parse)"
```

---

## Task 2: `run.sh` docker 分发(走 runner 入口)

**Files:**
- Modify: `evalscope/run.sh`(整体重写)
- Modify: `evalscope/lib.sh`(移除 host 端 fetch/ensure_tokenizer,保留其余)
- Test: `evalscope/tests/run_smoke_test.sh`(改)

**Interfaces:**
- Consumes:`lib.sh` 的 `ensure_image`(校验/拉 `$IMG`)、`BOOT_IMG`。
- Produces(env → Task 1 sweep.sh 消费):`MD_BENCHMARK_ID` `MD_ARGV='["bash","/rb/sweep.sh"]'` `MD_OUTPUT_DIR=/work/out` `MD_OUTPUT_FILES='{"summary.csv":"out/<run-id>/summary.csv"}'` + 全部模板/端点/tokenizer env;docker `-w /work`,挂 `sweep.sh`/`parse.py`/`out/`/`tok`。

- [ ] **Step 1: 改测试** `evalscope/tests/run_smoke_test.sh`(替换断言段为下)

```bash
#!/usr/bin/env bash
# 验 run.sh smoke 走 runner 入口:docker run 带 MD_* env + 挂 sweep.sh,不再 --entrypoint evalscope。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  image) exit 0 ;;
  pull)  exit 0 ;;
  run)   printf '%s\n' "$@" >> "$RB_DOCKER_LOG"; exit 0 ;;
  *)     exit 0 ;;
esac
EOF
chmod +x "$TMP/docker"

mkdir -p "$TMP/tok"; printf '{}' > "$TMP/tok/tokenizer.json"; printf '{}' > "$TMP/tok/chat_template.jinja"
cat > "$TMP/config.env" <<EOF
URL="http://HOST:8000/v1/chat/completions"
MODEL="m"
KEY="EMPTY"
TOKENIZER_MODE=offline
TOKENIZER_PATH="$TMP/tok"
TEMPLATE=inference-baseline
MODE=docker
EOF

export RB_DOCKER_LOG="$TMP/argv.log"
PATH="$TMP:$PATH" CONFIG="$TMP/config.env" ./run.sh smoke

grep -q -- 'MD_ARGV' "$TMP/argv.log" || { echo "FAIL: 缺 MD_ARGV(应走 runner 入口)"; exit 1; }
grep -q -- '/rb/sweep.sh' "$TMP/argv.log" || { echo "FAIL: 未挂 sweep.sh"; exit 1; }
grep -q -- 'MD_OUTPUT_DIR' "$TMP/argv.log" || { echo "FAIL: 缺 MD_OUTPUT_DIR sink"; exit 1; }
grep -q -- 'SMOKE=1' "$TMP/argv.log" || { echo "FAIL: smoke 应置 SMOKE=1"; exit 1; }
grep -q -- '\-\-entrypoint' "$TMP/argv.log" && { echo "FAIL: 不应再覆盖 entrypoint(用镜像默认 python -m runner)"; exit 1; }
echo "run.sh docker OK"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash evalscope/tests/run_smoke_test.sh`
Expected: FAIL(旧 run.sh 仍 `--entrypoint evalscope`,断言不满足)

- [ ] **Step 3: 重写 `evalscope/run.sh`**

```bash
#!/usr/bin/env bash
# run:分发器。load config+template → 构建 MD_* env → 按 MODE 落地(docker/k8s)。
# sweep 循环在容器内的 sweep.sh 里跑;本脚本只组 env + 起容器/Job。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

CLI_TEMPLATE="${TEMPLATE:-}"
CFG="${CONFIG:-config.env}"
[ -f "$CFG" ] || { echo "✗ 未找到 $CFG —— 先跑:make config" >&2; exit 1; }
source "$CFG"
[ -n "$CLI_TEMPLATE" ] && TEMPLATE="$CLI_TEMPLATE"
: "${TEMPLATE:?config.env 缺 TEMPLATE}"
TPL="templates/$TEMPLATE.env"
[ -f "$TPL" ] || { echo "✗ 模板不存在:$TPL(见 templates/)" >&2; exit 1; }
source "$TPL"

: "${URL:?config.env 缺 URL}"; : "${MODEL:?config.env 缺 MODEL}"
export KEY="${KEY:-EMPTY}"
export IMG="${IMG:-$BOOT_IMG}"
MODE="${MODE:-docker}"
SMOKE=0; [ "${1:-run}" = smoke ] && SMOKE=1

# run-id:smoke 用固定名(不落 latest),run 用时间戳
if [ "$SMOKE" = 1 ]; then RUN_ID="smoke-$TEMPLATE"; else RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"; fi

# 传给 sweep.sh 的模板/端点/tokenizer env 清单(值来自已 source 的 config+template)
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)

case "$MODE" in
  docker) run_docker ;;
  k8s)    run_k8s ;;
  *) echo "✗ MODE 只能是 docker / k8s(见 config.env)" >&2; exit 1 ;;
esac
```

追加 `run_docker`(放在 `case` 之前,函数形式;此处集中展示):

```bash
run_docker() {
  ensure_image
  local DOUT="$PWD/out"; mkdir -p "$DOUT"
  # tokenizer 挂载源:online 挂 host ./tok(可写缓存),offline 挂用户目录(只读)
  local TOK_MOUNT
  if [ "${TOKENIZER_MODE:-online}" = offline ]; then
    : "${TOKENIZER_PATH:?offline 缺 TOKENIZER_PATH}"
    TOK_MOUNT="$TOKENIZER_PATH:/tok:ro"
  else
    mkdir -p "$PWD/tok"; TOK_MOUNT="$PWD/tok:/tok"
  fi
  # 组 -e 列表
  local ENVARGS=(-e MD_BENCHMARK_ID="$RUN_ID" -e MD_ARGV='["bash","/rb/sweep.sh"]'
    -e MD_OUTPUT_DIR=/work/out -e MD_OUTPUT_FILES="{\"summary.csv\":\"out/$RUN_ID/summary.csv\"}"
    -e OPENAI_API_KEY="$KEY" -e SMOKE="$SMOKE")
  local v; for v in "${SWEEP_ENV[@]}"; do ENVARGS+=(-e "$v=${!v-}"); done
  echo "被测端点: $URL"; echo "模型: $MODEL"; echo "模板: $TEMPLATE(轴=$AXIS)"; echo "产物: out/$RUN_ID"; echo
  docker run --rm "${ENVARGS[@]}" -w /work \
    -v "$PWD/sweep.sh:/rb/sweep.sh:ro" -v "$PWD/parse.py:/rb/parse.py:ro" \
    -v "$DOUT:/work/out" -v "$TOK_MOUNT" "$IMG"
  [ "$SMOKE" = 1 ] || ln -sfn "$RUN_ID" "$DOUT/latest"
  echo "==> 完成 → make parse(默认 out/latest)"
}
```

> 注:`run_k8s` 在 Task 5 实现;Phase 1 先放一个占位 `run_k8s() { echo "✗ k8s 模式见 Task 5(尚未实现)" >&2; exit 1; }` 于 run.sh,保证 docker 路径可跑、测试通过。

- [ ] **Step 4: `lib.sh` 精简** —— 删除 `fetch_tokenizer` / `ensure_tokenizer` / `map_dataset` / `_have_tokenizer` / `_have_chat_template` / `TOK_PATTERNS`(逻辑已进 sweep.sh);保留 `RB` `BOOT_IMG` `ensure_boot_image` `ensure_image` `pyc`。

- [ ] **Step 5: 跑测试确认通过**

Run: `bash evalscope/tests/run_smoke_test.sh`
Expected: `run.sh docker OK`

- [ ] **Step 6: 提交**

```bash
git add evalscope/run.sh evalscope/lib.sh evalscope/tests/run_smoke_test.sh
git commit -m "feat(evalscope): run.sh 走 runner 入口(MD_ARGV=sweep.sh)+ docker 分发;tokenizer 逻辑入容器"
```

---

## Task 3: MODE 面板(Makefile / config.example / config.sh)

**Files:**
- Modify: `evalscope/Makefile`
- Modify: `evalscope/config.example.env`
- Modify: `evalscope/config.sh`

**Interfaces:** Consumes:Task 2 的 `MODE` 语义(docker/k8s)。Produces:`config.env` 含 `MODE=`;`make run MODE=k8s` 透传。

- [ ] **Step 1: `Makefile`** —— `run`/`smoke` 目标透传 `MODE`(make 变量已自动进环境即可,补文档):把 `run` 行改注释为 `按模板全量扫,产出 out/<run-id>/(可 TEMPLATE=xxx / MODE=k8s 覆盖)`。无需改配方(`./run.sh` 继承环境变量)。验证:`MODE=k8s make -n run` 不报错。

- [ ] **Step 2: `config.example.env`** —— 末尾加:

```sh
# ── 落地模式 ──
MODE=docker            # docker(离线单机)| k8s(离线集群,渲染 yaml → kubectl apply)
#K8S_NAMESPACE=default # MODE=k8s 用
```

- [ ] **Step 3: `config.sh`** —— 在写 `$CFG` 前加一步选 MODE,并写入:

```bash
echo
echo "── 落地模式 ──"
echo "  docker) 离线单机,docker run"
echo "  k8s)    离线集群,渲染 yaml → kubectl apply"
MODE=$(ask "模式 docker/k8s" "docker")
[ "$MODE" = docker ] || [ "$MODE" = k8s ] || { echo "✗ MODE 只能 docker/k8s" >&2; exit 1; }
[ "$MODE" = k8s ] && NS=$(ask "k8s namespace" "default")
```

并在 heredoc 里追加 `echo "MODE=$MODE"` 及 `[ "$MODE" = k8s ] && echo "K8S_NAMESPACE=$NS"`。

- [ ] **Step 4: 手验**

Run: `cd evalscope && printf '\n' | MODE=k8s make -n run`
Expected: 打印将执行 `./run.sh`,无报错。

- [ ] **Step 5: 提交**

```bash
git add evalscope/Makefile evalscope/config.example.env evalscope/config.sh
git commit -m "feat(evalscope): MODE 面板(config 向导/示例/Makefile 透传)"
```

---

## Task 4: Phase 1 端到端手验 + 文档(docker)

**Files:**
- Modify: `evalscope/RUNBOOK.md` `README.md`(根)`SCENARIOS.md`(根)

- [ ] **Step 1: 真跑一次 docker**(需可达端点)

Run: `cd evalscope && make smoke && make run && make parse`
Expected: `out/<run-id>/` 含 `round*/`、`run.env`、`result.json`(runner 写)、`summary.csv`;终端见 SLO 拐点表。

- [ ] **Step 2: 文档** —— `RUNBOOK.md` 加「落地模式」小节:docker(默认)走 `python -m runner`,产物 `out/<run-id>/`;并说明 result.json/meta.json 由 runner 写、与在线 modeldoctor 布局一致。`README.md`/`SCENARIOS.md` 命令块补 `MODE=`。

- [ ] **Step 3: 提交**

```bash
git add evalscope/RUNBOOK.md README.md SCENARIOS.md
git commit -m "docs(evalscope): 对齐 runner 入口 + docker 模式"
```

---

## Task 5: `render_k8s_yaml`(渲染 Job+ConfigMap+Secret)

**Files:**
- Modify: `evalscope/lib.sh`(增 `render_k8s_yaml`)
- Test: `evalscope/tests/render_k8s_test.sh`

**Interfaces:**
- Consumes:`run.sh` 已 source 的 env(`RUN_ID` `IMG` `URL` `MODEL` `KEY` `MODE` `K8S_NAMESPACE` + `SWEEP_ENV` 清单)、`$PWD/sweep.sh`。
- Produces:`render_k8s_yaml` 把完整 yaml(3 文档:Secret / ConfigMap / Job)打到 stdout。

- [ ] **Step 1: 写失败测试** `evalscope/tests/render_k8s_test.sh`

```bash
#!/usr/bin/env bash
# 验 render_k8s_yaml 结构:命名/labels/容器名/env/挂载;有 kubectl 则 dry-run。
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lib.sh

export RUN_ID=20260714-000000-inference-baseline
export IMG=ghcr.io/weetime/md-runner-evalscope:test
export URL="http://H:8000/v1/chat/completions" MODEL=m KEY=EMPTY
export K8S_NAMESPACE=bench
export AXIS=parallel DATASET=share_gpt_en PARALLEL="4 8" NUMBER="60 80" \
  MIN_TOKENS=128 MAX_TOKENS=256 ROUNDS=3 SEED=42 TTFT_SLO=1500 ITL_SLO=200 \
  TEMPLATE=inference-baseline TOKENIZER_MODE=online TOKENIZER_ID=org/m TOKENIZER_SOURCE=modelscope
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)

Y="$(render_k8s_yaml)"
grep -q 'name: run-20260714-000000-inference-baseline' <<<"$Y" || { echo "FAIL: Job 名不对"; exit 1; }
grep -q 'app.kubernetes.io/name: modeldoctor-run' <<<"$Y" || { echo "FAIL: 缺 modeldoctor label"; exit 1; }
grep -q 'name: runner' <<<"$Y" || { echo "FAIL: 容器名应为 runner"; exit 1; }
grep -q 'namespace: bench' <<<"$Y" || { echo "FAIL: namespace 未渲染"; exit 1; }
grep -q 'MD_ARGV' <<<"$Y" || { echo "FAIL: 缺 MD_ARGV"; exit 1; }
grep -q 'restartPolicy: Never' <<<"$Y" || { echo "FAIL: 缺 restartPolicy Never"; exit 1; }
grep -q 'sweep.sh' <<<"$Y" || { echo "FAIL: ConfigMap 未含 sweep.sh"; exit 1; }
grep -q 'OPENAI_API_KEY' <<<"$Y" || { echo "FAIL: Secret 缺 OPENAI_API_KEY"; exit 1; }
if command -v kubectl >/dev/null 2>&1; then
  kubectl apply --dry-run=client -f - <<<"$Y" >/dev/null || { echo "FAIL: kubectl dry-run 不过"; exit 1; }
fi
echo "render_k8s_yaml OK"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash evalscope/tests/render_k8s_test.sh`
Expected: FAIL(`render_k8s_yaml` 未定义)

- [ ] **Step 3: 在 `lib.sh` 增 `render_k8s_yaml`**

```bash
# 渲染离线集群 Job(Secret + ConfigMap + Job 三文档)到 stdout。形态对齐 modeldoctor。
# sweep.sh 内嵌进 ConfigMap → yaml 自包含。sink 走 emptyDir(online tok 在 pod 内拉;
# 产物随 pod 生命周期,头条结果看 kubectl logs;要深挖挂 PVC 另配)。
render_k8s_yaml() {
  local ns="${K8S_NAMESPACE:-default}" job="run-$RUN_ID"
  # env 列表(sweep.sh 消费),缩进到 container env
  local envblock="" v
  for v in "${SWEEP_ENV[@]}"; do
    printf -v line '        - {name: %s, value: %q}\n' "$v" "${!v-}"
    envblock+="$line"
  done
  # sweep.sh 逐行缩进进 ConfigMap data(| 块标量,8 空格)
  local script; script="$(sed 's/^/    /' sweep.sh)"
  cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $job
  namespace: $ns
  labels: {app.kubernetes.io/name: modeldoctor-run, app.kubernetes.io/managed-by: runbook-evalscope}
type: Opaque
stringData:
  OPENAI_API_KEY: ${KEY:-EMPTY}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: $job
  namespace: $ns
  labels: {app.kubernetes.io/name: modeldoctor-run, app.kubernetes.io/managed-by: runbook-evalscope}
data:
  sweep.sh: |
$script
---
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $ns
  labels: {app.kubernetes.io/name: modeldoctor-run, app.kubernetes.io/managed-by: runbook-evalscope}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels: {app.kubernetes.io/name: modeldoctor-run, app.kubernetes.io/managed-by: runbook-evalscope}
    spec:
      restartPolicy: Never
      containers:
      - name: runner
        image: $IMG
        imagePullPolicy: IfNotPresent
        workingDir: /work
        env:
        - {name: MD_BENCHMARK_ID, value: "$RUN_ID"}
        - {name: MD_ARGV, value: '["bash","/rb/sweep.sh"]'}
        - {name: MD_OUTPUT_DIR, value: /work/out}
        - {name: MD_OUTPUT_FILES, value: '{"summary.csv":"out/$RUN_ID/summary.csv"}'}
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
```

> 注:ConfigMap 只放 `sweep.sh`;`parse.py` 也要进 pod → 追加到同一 ConfigMap（Step 3b）。

- [ ] **Step 3b: `render_k8s_yaml` 的 ConfigMap 追加 `parse.py`** —— 在 `sweep.sh: |` 块后加:

```bash
  parse.py: |
$(sed 's/^/    /' parse.py)
```

并把容器 `MD_ARGV` 对应的 sweep 里 `python /rb/parse.py` 已指向 `/rb`(ConfigMap 挂载点),故 `parse.py` 随 `rb` 卷一起在 `/rb/parse.py`。更新测试加一行 `grep -q 'parse.py' <<<"$Y"`。

- [ ] **Step 4: 跑测试确认通过**

Run: `bash evalscope/tests/render_k8s_test.sh`
Expected: `render_k8s_yaml OK`

- [ ] **Step 5: 提交**

```bash
git add evalscope/lib.sh evalscope/tests/render_k8s_test.sh
git commit -m "feat(evalscope): render_k8s_yaml —— 自包含 Job/ConfigMap/Secret,形态对齐 modeldoctor"
```

---

## Task 6: `run.sh` k8s 分发(kubectl apply + logs)

**Files:**
- Modify: `evalscope/run.sh`(实现 `run_k8s`,替换 Task 2 的占位)
- Test: `evalscope/tests/run_smoke_test.sh`(加 k8s 分支断言)

**Interfaces:** Consumes:`render_k8s_yaml`(Task 5)。Produces:`kubectl apply -f -` + `kubectl logs -f job/run-<id>`。

- [ ] **Step 1: 加 k8s 测试** `evalscope/tests/run_k8s_dispatch_test.sh`

```bash
#!/usr/bin/env bash
# 验 MODE=k8s:run.sh 渲染 yaml → 假 kubectl apply(捕获 yaml)+ logs。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  apply) cat > "$RB_KLOG" ;;    # 落 stdin 的 yaml
  logs)  exit 0 ;;
  wait)  exit 0 ;;
  *)     exit 0 ;;
esac
EOF
chmod +x "$TMP/kubectl"
cat > "$TMP/config.env" <<EOF
URL="http://HOST:8000/v1/chat/completions"
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
grep -q 'kind: Job' "$TMP/applied.yaml" || { echo "FAIL: 未 apply Job"; exit 1; }
grep -q 'name: run-.*-inference-baseline' "$TMP/applied.yaml" || { echo "FAIL: Job 名不对"; exit 1; }
echo "run.sh k8s OK"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `bash evalscope/tests/run_k8s_dispatch_test.sh`
Expected: FAIL(占位 `run_k8s` 直接 exit 1)

- [ ] **Step 3: 实现 `run_k8s`(替换 run.sh 占位)**

```bash
run_k8s() {
  command -v kubectl >/dev/null 2>&1 || { echo "✗ MODE=k8s 需要 kubectl" >&2; exit 1; }
  local job="run-$RUN_ID" ns="${K8S_NAMESPACE:-default}"
  echo "被测端点: $URL"; echo "模型: $MODEL"; echo "模板: $TEMPLATE(轴=$AXIS)"
  echo "落地: k8s Job $job(ns=$ns)"; echo
  render_k8s_yaml | kubectl apply -f -
  echo "==> 已 apply,跟随日志(Ctrl-C 不影响 Job):"
  kubectl -n "$ns" wait --for=condition=ready pod -l app.kubernetes.io/name=modeldoctor-run --timeout=120s 2>/dev/null || true
  kubectl -n "$ns" logs -f "job/$job" || true
  echo "==> 结束。清理:kubectl -n $ns delete job $job configmap $job secret $job"
}
```

- [ ] **Step 4: 跑两个测试确认通过**

Run: `bash evalscope/tests/run_k8s_dispatch_test.sh && bash evalscope/tests/run_smoke_test.sh`
Expected: `run.sh k8s OK` 且 `run.sh docker OK`

- [ ] **Step 5: 提交**

```bash
git add evalscope/run.sh evalscope/tests/run_k8s_dispatch_test.sh
git commit -m "feat(evalscope): run.sh k8s 分发(render → kubectl apply → logs -f)"
```

---

## Task 7: k8s 文档 + 端到端手验

**Files:**
- Modify: `evalscope/RUNBOOK.md` `README.md` `SCENARIOS.md`

- [ ] **Step 1: 真跑一次 k8s**(需可达集群 + 集群内可达端点)

Run: `cd evalscope && MODE=k8s make run`
Expected: `kubectl apply` 成功,`kubectl logs` 见 sweep + 末尾 SLO 表;`kubectl get job run-<id>` Complete。

- [ ] **Step 2: 文档** —— `RUNBOOK.md`「落地模式」补 k8s:`MODE=k8s make run` 渲染自包含 yaml、`kubectl apply`、`kubectl logs -f` 看表、`kubectl delete` 清理;说明 tokenizer 在 pod 内在线拉、产物在 emptyDir(要留存挂 PVC 另配)、镜像/命名/契约与在线 modeldoctor 一致。

- [ ] **Step 3: 提交**

```bash
git add evalscope/RUNBOOK.md README.md SCENARIOS.md
git commit -m "docs(evalscope): k8s 模式说明 + 两模式与在线口径一致"
```

---

## Self-Review 结论

- **Spec 覆盖**:§3.1 MODE→Task 3;§3.2 sweep 契约→Task 1/2;§4.1 docker→Task 2;§4.2 k8s→Task 5/6;§5 产物回收→Task 1(容器内 parse 打表)+Task 4/7;§6 文件改动→逐 Task 对应;§7 命名一致→Task 5(labels/Job 名)。§2 modeldoctor 契约=消费,不改。
- **类型/命名一致**:`MD_OUTPUT_DIR=/work/out`、`MD_ARGV=["bash","/rb/sweep.sh"]`、Job/Secret/ConfigMap 同名 `run-$RUN_ID`、容器名 `runner`、`SWEEP_ENV` 清单在 run.sh 与 render_k8s_test 一致。
- **占位**:无 TODO;每步含完整脚本/yaml/测试。
- **已知裁剪(非 spec 缺口,已在文档说明)**:k8s 产物用 emptyDir(随 pod 生命周期,头条看 logs);offline tokenizer 在 k8s 需另挂 PVC 到 /tok —— 首版不自动化,文档标注。
