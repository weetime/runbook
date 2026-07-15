# runbook 复用 runner —— 离线 docker 模式 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `evalscope/` docker 压测通过 modeldoctor 的 `python -m runner` 入口跑,sweep 循环搬进容器内 `sweep.sh`,产物与在线 modeldoctor 同布局(sink 走 `LocalWriter`)。

**Architecture:** `run.sh` 组 `MD_*` env → 一次 `docker run`(镜像默认入口 `python -m runner`)→ runner 跑 `MD_ARGV=["bash","/rb/sweep.sh"]` → sweep.sh 在容器内按轴扫 + 末尾 parse 打表。一个 run = 一个容器。

**Tech Stack:** bash · docker · evalscope 镜像 `ghcr.io/weetime/md-runner-evalscope`(ENTRYPOINT `python -m runner`)· python3(镜像内)。

## Global Constraints

- 镜像统一 `ghcr.io/weetime/md-runner-evalscope:<tag>`(= `lib.sh` 的 `BOOT_IMG`),与在线 modeldoctor 同镜像。
- runner 契约(消费,不改 modeldoctor):`MD_BENCHMARK_ID`、`MD_ARGV`、`MD_OUTPUT_FILES`、`MD_OUTPUT_DIR`、`OPENAI_API_KEY`(env,不进 argv)。sink:`MD_OUTPUT_DIR`→本地。
- run-id:`YYYYmmdd-HHMMSS-<template>`;smoke 用 `smoke-<template>`(不落 latest)。
- 宿主只需 `bash + make + docker`。parse.py 只在镜像内跑。
- 脱敏红线:真实端点/密钥只进 `config.env`(不入库)。
- 不引入 `MODE` 开关;不做 k8s/helm/compose。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `evalscope/sweep.sh`(新增) | 容器内 sweep:map_dataset + 确保 /tok + 按轴扫描 + 末尾 parse 打表,写 `$MD_OUTPUT_DIR/$MD_BENCHMARK_ID/`。 |
| `evalscope/run.sh`(重写) | 组 `MD_*` env → 一次 `docker run`(默认入口)。 |
| `evalscope/lib.sh`(改) | 移除 host 端 tokenizer/dataset 逻辑(入 sweep.sh);留 `RB`/`BOOT_IMG`/`ensure_boot_image`/`ensure_image`/`pyc`。 |
| `evalscope/tests/sweep_test.sh`(新增) | 假 evalscope/python 验 sweep.sh 轴逻辑 + 产物布局。 |
| `evalscope/tests/run_smoke_test.sh`(改) | 验 run.sh 组出的 docker run 走 runner 入口 + MD_* env。 |
| `evalscope/RUNBOOK.md`·根 `README.md`(改) | 对齐 runner 入口。 |

---

## Task 1: 抽出 `sweep.sh`(容器内 sweep)

**Files:**
- Create: `evalscope/sweep.sh`
- Test: `evalscope/tests/sweep_test.sh`

**Interfaces:**
- Consumes(env,Task 2 注入):`MD_BENCHMARK_ID` `MD_OUTPUT_DIR` `URL` `MODEL` `OPENAI_API_KEY` `AXIS` `DATASET` `PARALLEL` `NUMBER` `PROMPT_LENS` `PROMPT_MIN` `PROMPT_MAX` `MIN_TOKENS` `MAX_TOKENS` `ROUNDS` `SEED` `TTFT_SLO` `ITL_SLO` `TEMPLATE` `TOKENIZER_MODE` `TOKENIZER_ID` `TOKENIZER_SOURCE` `HF_ENDPOINT` `SMOKE`。测试可用 `TOK_OVERRIDE` 覆盖 `/tok`。
- Produces:`$MD_OUTPUT_DIR/$MD_BENCHMARK_ID/{round$r/…,run.env,summary.csv}`;调 `/rb/parse.py`。

- [ ] **Step 1: 写失败测试** `evalscope/tests/sweep_test.sh`(内容见附录 A)

- [ ] **Step 2: 跑测试确认失败** — Run: `bash evalscope/tests/sweep_test.sh` — Expected: FAIL(`./sweep.sh` 不存在)

- [ ] **Step 3: 写 `evalscope/sweep.sh`**(内容见附录 B)

- [ ] **Step 4: 跑测试确认通过** — Run: `bash evalscope/tests/sweep_test.sh` — Expected: `sweep.sh OK`

- [ ] **Step 5: 提交**

```bash
git add evalscope/sweep.sh evalscope/tests/sweep_test.sh
git commit -m "feat(evalscope): 抽出容器内 sweep.sh(直接调 evalscope + 末尾 parse)"
```

---

## Task 2: `run.sh` 走 runner 入口 + `lib.sh` 精简

**Files:**
- Modify: `evalscope/run.sh`(整体重写,内容见附录 C)
- Modify: `evalscope/lib.sh`(删 `fetch_tokenizer`/`ensure_tokenizer`/`map_dataset`/`_have_tokenizer`/`_have_chat_template`/`TOK_PATTERNS`;留其余)
- Test: `evalscope/tests/run_smoke_test.sh`(改,内容见附录 D)

**Interfaces:**
- Consumes:`lib.sh` 的 `ensure_image`、`BOOT_IMG`。
- Produces(env → sweep.sh):见附录 C 的 `docker run` 段。

- [ ] **Step 1: 改测试** `evalscope/tests/run_smoke_test.sh` ← 附录 D

- [ ] **Step 2: 跑测试确认失败** — Run: `bash evalscope/tests/run_smoke_test.sh` — Expected: FAIL(旧 run.sh 仍 `--entrypoint evalscope`)

- [ ] **Step 3: 重写 `run.sh`** ← 附录 C

- [ ] **Step 4: `lib.sh` 精简** — 删附录 E 列出的符号,留 `RB`/`BOOT_IMG`/`ensure_boot_image`/`ensure_image`/`pyc`

- [ ] **Step 5: 跑测试确认通过** — Run: `bash evalscope/tests/run_smoke_test.sh` — Expected: `run.sh docker OK`

- [ ] **Step 6: 提交**

```bash
git add evalscope/run.sh evalscope/lib.sh evalscope/tests/run_smoke_test.sh
git commit -m "feat(evalscope): run.sh 走 runner 入口(MD_ARGV=sweep.sh);tokenizer 逻辑入容器"
```

---

## Task 3: 端到端手验 + 文档

**Files:** Modify `evalscope/RUNBOOK.md` · 根 `README.md`

- [ ] **Step 1: 真跑一次**(需可达端点) — Run: `cd evalscope && make smoke && make run && make parse` — Expected: `out/<run-id>/` 含 `round*/`、`run.env`、`result.json`(runner 写)、`summary.csv`;终端见 SLO 拐点表。
  - 无可达端点时:跳过,记录"待真实端点验证",不阻塞。

- [ ] **Step 2: 文档** — `RUNBOOK.md` 加「走 runner 入口」说明:产物 `out/<run-id>/` 多出 `result.json`/`meta.json`(runner 写,与在线 modeldoctor 布局一致);tokenizer 在容器内拉。`README.md` 用法块保持 `make config/smoke/run/parse` 不变。

- [ ] **Step 3: 提交**

```bash
git add evalscope/RUNBOOK.md README.md
git commit -m "docs(evalscope): 对齐 runner 入口 + docker 模式"
```

---

## 附录 A · `tests/sweep_test.sh`

```bash
#!/usr/bin/env bash
# 用假 evalscope + 假 python 验 sweep.sh:轴逻辑、输出目录、tokenizer 校验。
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/evalscope" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$EVX_LOG"
od=""; while [ $# -gt 0 ]; do [ "$1" = "--outputs-dir" ] && od="$2"; shift; done
[ -n "$od" ] && mkdir -p "$od/sweep/parallel_4_number_8" && printf '{}' > "$od/sweep/parallel_4_number_8/benchmark_summary.json"
exit 0
EOF
chmod +x "$TMP/evalscope"
cat > "$TMP/python" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/python"

mkdir -p "$TMP/tok"; printf '{}' > "$TMP/tok/tokenizer.json"
OUT="$TMP/out"; mkdir -p "$OUT"
export EVX_LOG="$TMP/evx.log"
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
[ -d "$RDIR/round1/len1024" ] || { echo "FAIL: 缺 round1/len1024"; exit 1; }
[ -d "$RDIR/round2/len8192" ] || { echo "FAIL: 缺 round2/len8192(暖轮)"; exit 1; }
[ -f "$RDIR/run.env" ] || { echo "FAIL: 缺 run.env"; exit 1; }
echo "sweep.sh OK"
```

## 附录 B · `sweep.sh`

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
TOK="${TOK_OVERRIDE:-/tok}"

case "$DATASET" in
  longalpaca)   DS_READER=line_by_line; DS_PATH=/opt/evalscope-datasets/longalpaca.txt;;
  openqa)       DS_READER=openqa;       DS_PATH=/opt/evalscope-datasets/openqa/open_qa.jsonl;;
  share_gpt_en) DS_READER=share_gpt_en; DS_PATH=/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl;;
  share_gpt_zh) DS_READER=share_gpt_zh; DS_PATH=/opt/evalscope-datasets/sharegpt/common_zh_70k.jsonl;;
  random)       DS_READER=random;       DS_PATH=;;
  *) echo "✗ 未知 dataset:$DATASET" >&2; exit 1;;
esac

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

AXIS="$AXIS" TTFT_SLO="${TTFT_SLO:-}" ITL_SLO="${ITL_SLO:-}" TEMPLATE="${TEMPLATE:-}" \
  python /rb/parse.py "$RDIR" || echo "(parse 失败,原始产物已在 $RDIR)"
echo "==> 完成 → 产物 $RDIR"
```

## 附录 C · `run.sh`(整体重写)

```bash
#!/usr/bin/env bash
# run:组 MD_* env → 一次 docker run(镜像默认 python -m runner)。sweep 循环在容器内 sweep.sh。
# `./run.sh smoke` 单档冒烟。模板 = templates/<name>.env,source 进来即自动填充。
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
SMOKE=0; [ "${1:-run}" = smoke ] && SMOKE=1
if [ "$SMOKE" = 1 ]; then RUN_ID="smoke-$TEMPLATE"; else RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"; fi

ensure_image
DOUT="$PWD/out"; mkdir -p "$DOUT"

# tokenizer 挂载源:online 挂 host ./tok(可写缓存),offline 挂用户目录(只读)
if [ "${TOKENIZER_MODE:-online}" = offline ]; then
  : "${TOKENIZER_PATH:?offline 缺 TOKENIZER_PATH}"
  TOK_MOUNT="$TOKENIZER_PATH:/tok:ro"
else
  mkdir -p "$PWD/tok"; TOK_MOUNT="$PWD/tok:/tok"
fi

# 传给 sweep.sh 的 env 清单(值来自已 source 的 config+template)
SWEEP_ENV=(URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX
  MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE
  TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT)
ENVARGS=(-e MD_BENCHMARK_ID="$RUN_ID" -e MD_ARGV='["bash","/rb/sweep.sh"]'
  -e MD_OUTPUT_DIR=/work/out -e MD_OUTPUT_FILES="{\"summary.csv\":\"out/$RUN_ID/summary.csv\"}"
  -e OPENAI_API_KEY="$KEY" -e SMOKE="$SMOKE")
for v in "${SWEEP_ENV[@]}"; do ENVARGS+=(-e "$v=${!v-}"); done

echo "被测端点: $URL"; echo "模型:     $MODEL"
echo "模板:     $TEMPLATE(轴=$AXIS)"; echo "产物:     out/$RUN_ID"; echo

docker run --rm "${ENVARGS[@]}" -w /work \
  -v "$PWD/sweep.sh:/rb/sweep.sh:ro" -v "$PWD/parse.py:/rb/parse.py:ro" \
  -v "$DOUT:/work/out" -v "$TOK_MOUNT" "$IMG"

[ "$SMOKE" = 1 ] || ln -sfn "$RUN_ID" "$DOUT/latest"
[ "$SMOKE" = 1 ] && echo "==> 冒烟通过即可 make run" || echo "==> 完成 → make parse(默认 out/latest)"
```

## 附录 D · `tests/run_smoke_test.sh`(改)

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
EOF

export RB_DOCKER_LOG="$TMP/argv.log"
PATH="$TMP:$PATH" CONFIG="$TMP/config.env" ./run.sh smoke

grep -q -- 'MD_ARGV' "$TMP/argv.log" || { echo "FAIL: 缺 MD_ARGV(应走 runner 入口)"; exit 1; }
grep -q -- '/rb/sweep.sh' "$TMP/argv.log" || { echo "FAIL: 未挂 sweep.sh"; exit 1; }
grep -q -- 'MD_OUTPUT_DIR' "$TMP/argv.log" || { echo "FAIL: 缺 MD_OUTPUT_DIR sink"; exit 1; }
grep -q -- 'SMOKE=1' "$TMP/argv.log" || { echo "FAIL: smoke 应置 SMOKE=1"; exit 1; }
if grep -q -- '--entrypoint' "$TMP/argv.log"; then echo "FAIL: 不应再覆盖 entrypoint"; exit 1; fi
echo "run.sh docker OK"
```

## 附录 E · `lib.sh` 删除清单

删:`fetch_tokenizer`、`ensure_tokenizer`、`map_dataset`、`_have_tokenizer`、`_have_chat_template`、`TOK_PATTERNS`。
留:`RB`、`BOOT_IMG`、`ensure_boot_image`、`ensure_image`、`pyc`。

---

## Self-Review 结论

- **Spec 覆盖**:§3.1 一次 docker run→Task 2;§3.2 env 契约→附录 C;§3.3 tokenizer 入容器→附录 B;§4 产物布局→Task 1(sweep 写)+ runner 写;§5 文件改动→逐 Task;§6 命名→run-id/镜像。
- **类型/命名一致**:`MD_OUTPUT_DIR=/work/out`、`MD_ARGV=["bash","/rb/sweep.sh"]`、`SWEEP_ENV` 清单在附录 C 与 B 消费端一致、run-id 语义一致。
- **占位**:无 TODO;每步指向完整附录代码。
- **裁剪**:无 MODE、无 k8s(见 spec §7,后续)。
