# 设计:runbook 复用 modeldoctor runner —— 离线 docker 模式,与在线口径一致

> 状态:已定稿(docker-only 首版)· 2026-07-14
> 范围:`evalscope/` 子目录

## 1 · 背景与目标

runbook 的 evalscope 压测目前**绕过** modeldoctor 的 runner:宿主 bash 循环里
`docker run --entrypoint evalscope <img> perf …` 做 sweep,产物落本地 `out/`,本地
`parse.py` 找 SLO 拐点。

modeldoctor 的 runner(`ghcr.io/weetime/md-runner-evalscope`,ENTRYPOINT
`python -m runner`)是工具无关、env 驱动的:读 `MD_ARGV`(JSON argv)/`MD_OUTPUT_FILES`,
在 cwd 里跑工具,tee 日志,收集产物,写 report。

**目标**:让 docker 离线压测走 runner 入口,与在线 modeldoctor **共用同一镜像、同一
`python -m runner` 入口、同一 `MD_ARGV` 契约、同一实时日志与产物布局** —— 只有 sink 不同
(离线 `LocalWriter`→挂载目录,在线 `S3Writer`→MinIO)。这样离线量出来的口径与平台一致。

**首版只做 docker。** k8s(离线集群、渲染 yaml + kubectl apply)已设计但**本版不实现**
(见 §7),等 docker 形态跑顺再加。helm / docker-compose 明确不做。

约束(用户明确):**不要过度设计;docker 要轻量。**

## 2 · 关键前提:modeldoctor 侧已就绪(PR #358,已合并)

无需改动 modeldoctor。`select_sink()`:`S3_ENDPOINT` 存在 → `S3Writer`;否则
`MD_OUTPUT_DIR` 存在 → `LocalWriter`(布局与 S3 逐字节一致:`<id>/meta.json` ·
`result.json` · `stdout.log` · `stderr.log` · `files/<alias>`,原子写);都无 → 退出。

runbook 只需设 `MD_BENCHMARK_ID`/`MD_ARGV`/`MD_OUTPUT_FILES`/`MD_OUTPUT_DIR` 并挂载
输出目录。**不配 S3 = 写文件到挂载目录**;终端/日志(runner tee stdout)永远都有,与 sink 无关。

## 3 · 架构:一次 docker run,sweep 进容器

### 3.1 核心改动

今天「宿主循环 + `--entrypoint evalscope`」→「一次 `docker run` 走镜像默认入口
`python -m runner`,sweep 循环搬进容器内 `sweep.sh`」。**一个 run = 一个容器**。

```
make run
  └─ run.sh(宿主):source config.env + templates/<T>.env → 组 MD_* env
       └─ docker run --rm  <默认 python -m runner>
            └─ runner:select_sink()→LocalWriter(MD_OUTPUT_DIR=/work/out)
                 ├─ 跑 MD_ARGV=["bash","/rb/sweep.sh"]
                 │    └─ sweep.sh:map_dataset → 确保 /tok → 按轴扫(冷/暖轮)
                 │         → 写 /work/out/<RUN_ID>/round*/… → python parse.py 就地打表
                 └─ 收 MD_OUTPUT_FILES + 写 <RUN_ID>/result.json·meta.json·stdout.log
  产物落宿主 out/<RUN_ID>/(bind-mount)· make parse 可复解析
```

### 3.2 env 契约(run.sh → 容器)

| env | 值 |
|---|---|
| `MD_BENCHMARK_ID` | `<RUN_ID>`(`YYYYmmdd-HHMMSS-<template>`;smoke 用 `smoke-<template>`) |
| `MD_ARGV` | `["bash","/rb/sweep.sh"]` |
| `MD_OUTPUT_DIR` | `/work/out`(离线 sink) |
| `MD_OUTPUT_FILES` | `{"summary.csv":"out/<RUN_ID>/summary.csv"}` |
| `OPENAI_API_KEY` | `$KEY`(**不进 argv**),sweep.sh 用作 `--api-key` |
| `SMOKE` | `0/1` |
| 模板/端点/tokenizer 组 | `URL MODEL AXIS DATASET PARALLEL NUMBER PROMPT_LENS PROMPT_MIN PROMPT_MAX MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO TEMPLATE TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE HF_ENDPOINT` |

挂载:`sweep.sh`→`/rb/sweep.sh`、`parse.py`→`/rb/parse.py`、宿主 `out/`→`/work/out`、
tokenizer→`/tok`(online 挂宿主 `./tok` 可写缓存;offline 挂用户目录只读)。`-w /work`。

### 3.3 tokenizer

从宿主(lib.sh)移进容器(sweep.sh):`/tok` 有 tokenizer 就用;缺且 `TOKENIZER_MODE=online`
就在容器内 `snapshot_download` 只拉 tokenizer 白名单文件。docker 把宿主 `./tok` 挂进去当
可写缓存,首跑拉、后续复用;offline 把用户 tokenizer 目录只读挂 `/tok`。

## 4 · 产物布局(宿主 `out/<RUN_ID>/`)

```
round1/…  round2/…                              ← sweep.sh(evalscope 原始 benchmark_*.json)
run.env                                          ← sweep.sh(自描述,供 parse)
summary.csv                                      ← parse.py
result.json meta.json stdout.log stderr.log      ← runner(与在线 modeldoctor 同布局)
files/summary.csv                                ← runner 收 MD_OUTPUT_FILES
```

## 5 · 文件改动

| 文件 | 改动 |
|---|---|
| `evalscope/sweep.sh` | **新增**。容器内 sweep:数据集映射 + tokenizer 确保 + 按轴扫(冷/暖轮)+ 末尾 parse 打表。 |
| `evalscope/run.sh` | 重写:source config+template → 组 `MD_*` env → 一次 `docker run`(默认入口)。sweep 循环移出。 |
| `evalscope/lib.sh` | 删 `fetch_tokenizer`/`ensure_tokenizer`/`map_dataset`/`_have_*`/`TOK_PATTERNS`(移入 sweep.sh);留 `RB`/`BOOT_IMG`/`ensure_boot_image`/`ensure_image`/`pyc`。 |
| `evalscope/tests/sweep_test.sh` | **新增**。假 evalscope/python 验轴逻辑 + 产物布局。 |
| `evalscope/tests/run_smoke_test.sh` | 改:验 `docker run` 走 runner 入口 + `MD_*` env。 |
| `evalscope/RUNBOOK.md` · 根 `README.md` | 对齐 runner 入口 + 与在线口径一致说明。 |

**不变**:`templates/*.env`、`parse.py`/`parse.sh`、`config.sh`/`config.example.env`、
Makefile 目标、脱敏红线。**不引入 `MODE` 开关**(只有 docker 一种,YAGNI;k8s 回来再加)。

## 6 · 镜像与命名一致性

镜像统一 `ghcr.io/weetime/md-runner-evalscope:<tag>`(= `BOOT_IMG`),与在线 modeldoctor
同镜像。run-id 语义 `YYYYmmdd-HHMMSS-<template>`。

## 7 · 不在本版范围(已设计,后续)

- **k8s 模式**(离线集群:`render_k8s_yaml` 出自包含 Secret/ConfigMap/Job → `kubectl apply`
  → `kubectl logs -f`,命名/labels 对齐 modeldoctor)—— 已在讨论中定型,本版不实现;届时
  `run.sh` 外包一层 `case "$MODE"`,`sweep.sh` 原样复用(tokenizer 已可在 pod 内在线拉)。
- 在线 k8s(modeldoctor 平台发起 + S3)—— 已有,不碰。
- 其它工具 runbook 化、多 Job 扇出、helm/compose、离线集群产物留存 —— 不做。
- 改动 modeldoctor —— 无需(PR #358 已提供契约)。
