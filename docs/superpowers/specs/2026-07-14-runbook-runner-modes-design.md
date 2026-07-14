# 设计:runbook 复用 modeldoctor runner —— docker / k8s / helm 三模式统一入口

> 状态:已定稿(待实现)· 2026-07-14
> 范围:`evalscope/` 子目录(形态可后续复用到其它工具 runbook)

## 1 · 背景与目标

runbook 的 evalscope 压测目前**绕过** modeldoctor 的 runner:直接
`docker run --entrypoint evalscope <img> perf …`,宿主 bash 循环做 sweep,产物落本地
`out/`,本地 `parse.py` 找 SLO 拐点。

modeldoctor 的 runner(`ghcr.io/weetime/md-runner-evalscope`,ENTRYPOINT
`python -m runner`)是**工具无关、env 驱动**的:读 `MD_ARGV`(JSON argv)/
`MD_OUTPUT_FILES`,在 cwd 里跑工具,tee 日志,收集产物,写 report。

**目标**:让 runbook 复用这个 runner,使**同一镜像、同一命名、同一契约**能在三处跑:

| 模式 | 场景 | 落地 |
|---|---|---|
| `docker` | 离线单机(默认) | 一次 `docker run` |
| `k8s` | 在线集群 | `kubectl apply` 一个 Job |
| `helm` | 离线集群 | `helm install` 同一个 Job |

约束(用户明确):**不要过度设计;docker 和 helm 一定要轻量**。

## 2 · 关键前提:modeldoctor 侧已就绪(PR #358,已合并)

无需改动 modeldoctor。PR #358(`0afe9b0`,2026-07-14 合并)已给 runner 加了
**可回退的本地目录 sink**,契约固定为:

- `select_sink()`:`S3_ENDPOINT` 存在 → `S3Writer`(在线/k8s,零变化);否则
  `MD_OUTPUT_DIR` 存在 → `LocalWriter`(离线);两者都无 → fail-fast。
- `LocalWriter` 把产物写到 `MD_OUTPUT_DIR` 挂载目录,布局与 S3 **逐字节一致**:
  `<id>/meta.json` · `<id>/result.json` · `<id>/stdout.log` · `<id>/stderr.log` ·
  `<id>/files/<alias>`。原子写(sibling `.tmp` + `os.replace`),key 防逃逸。

runbook 只需:设 `MD_BENCHMARK_ID` / `MD_ARGV` / `MD_OUTPUT_FILES` /
`MD_OUTPUT_DIR`(离线)或 `S3_*`(在线),并挂载输出目录。

## 3 · 架构:MODE 分发 + 单一 sweep 契约

### 3.1 UX —— 新增一个 `MODE` 轴,其余不变

保留现有全部界面(`config / smoke / run / parse / clean`、`templates/*.env`、
`config.env`)。只加一个分发轴:

```bash
make run                 # MODE=docker(默认,离线单机)
make run MODE=k8s        # 在线:kubectl apply 一个 Job 到当前 context 集群
make run MODE=helm       # 离线集群:helm install 同一个 Job
```

`config.env` 增加 `MODE=` 默认值。`smoke` / `parse` / `clean` 与模式无关
(`parse` 始终读本地 `out/`)。

### 3.2 单一契约(SSOT):`sweep.sh` + env

`run.sh` 不论模式,只构建**同一份**运行参数(`config.env` + 选定
`templates/*.env`)。下游三模式消费同一个 `sweep.sh` + env:

- `MD_ARGV = ["bash","<sweep.sh 容器内路径>"]` —— `sweep.sh` 是把今天 `run.sh` 里的
  sweep 循环(ROUNDS 冷/暖 × 轴点)**原样抽出**,使其能在容器内跑。
- `MD_BENCHMARK_ID = <run-id>`(`YYYYmmdd-HHMMSS-<template>`)。
- 模板变量(`AXIS/DATASET/PARALLEL/NUMBER/PROMPT_LENS/MIN_TOKENS/…/TTFT_SLO/ITL_SLO`)
  作为普通 env 传入,`sweep.sh` 直接读。
- `OPENAI_API_KEY` 走 secret/env(**不进 argv**),`sweep.sh` 里
  `evalscope … --api-key "$OPENAI_API_KEY"`。
- tokenizer:挂载目录(容器内 `/tok`),沿用现有在线拉取 / 离线挂载逻辑。

`sweep.sh` 把 evalscope 产物写到 cwd 下 `out/<run-id>/…`(`MD_OUTPUT_FILES`→cwd
机制),并在末尾跑 `parse.py`,把 SLO 拐点表打到 stdout。

**为什么一个 run = 一个容器/Job(Approach B)**:整套 sweep 在单容器内跑,docker 一次
`run`、k8s/helm 一个 Job。避免 host 端多 Job 扇出 + 产物回收 —— 这是唯一让
"docker/helm 轻量" 真正成立的形态。sweep 逻辑留在 runbook(不烘进 modeldoctor 镜像),
通过挂载脚本交付。

## 4 · 三模式落地

三模式共用同一镜像 `ghcr.io/weetime/md-runner-evalscope:<tag>`、同一入口
`python -m runner`、同一 `MD_ARGV` 契约、同一实时日志与产物布局 —— **只有 sink 的
env 与脚本交付方式不同**。

### 4.1 docker(离线默认,轻量)

一次 `docker run`,`--entrypoint`(镜像默认已是 `python -m runner`),bind-mount
`sweep.sh`、`tok/`、`out/`(= `MD_OUTPUT_DIR`)。即今天流程,但过 runner 包装器而非
裸 evalscope。产物落本地 `out/`,`make parse` 照旧。

### 4.2 k8s(在线,复用 modeldoctor Job 形态)

`run.sh` 渲染一个 `batch/v1` Job,形态对齐 modeldoctor `buildJobManifest`:
labels `app.kubernetes.io/name: modeldoctor-run`、容器名 `runner`、`backoffLimit 0`、
`restartPolicy Never`、image、`envFrom` secret。差异:

- `sweep.sh` 经 **ConfigMap** 交付(集群内无宿主 bind-mount)。
- sink:在线集群有 MinIO → 用 `S3_*`(runner 原生 S3 路径,零改动);或挂 PVC +
  `MD_OUTPUT_DIR`。
- `kubectl apply` ConfigMap + Secret + Job;`kubectl logs -f job/run-<id>` 实时看
  sweep + 末尾 parse 表 —— **头条结果从日志回来,不用 `kubectl cp`**。

### 4.3 helm(离线集群,轻量)

一个**薄** chart(`evalscope/deploy/helm/`,约 4 个模板:Job / ConfigMap / Secret /
values),渲染出与 k8s 模式**完全相同**的 Job。`values.yaml` 携带:image、模板名、
端点/模型、PVC 开关、tokenizer 来源。`helm install evalscope-<run-id> ./deploy/helm
--set …` → 同一个 Job → 同一份日志。镜像与命名与 docker/k8s 一致。

## 5 · 产物回收 —— 三模式统一

三模式一致:**容器内跑 sweep → parse → 打印 SLO 表**;产物同时落挂载卷 / PVC。
- docker:bind-mount,`out/<run-id>/` 本地可读,`make parse` 照旧。
- k8s / helm:头条 SLO 表在 `kubectl logs`;要深挖再从 PVC 拉 `out/<run-id>/`。

## 6 · runbook 文件改动

| 文件 | 改动 |
|---|---|
| `evalscope/sweep.sh` | **新增**。从 `run.sh` 抽出的容器内 sweep 循环(rounds × 轴)+ 末尾调 `parse.py` 打表。读模板 env,写 `out/<run-id>/`。 |
| `evalscope/run.sh` | 改为**分发器**:构建 env + `MD_ARGV` → 按 `MODE` 调 docker / k8s / helm 落地脚本。sweep 循环移出到 `sweep.sh`。 |
| `evalscope/lib.sh` | 增 `render_job`(渲染 Job/ConfigMap/Secret yaml)+ mode 落地辅助;沿用 `ensure_image`/`ensure_tokenizer`/`map_dataset`。 |
| `evalscope/deploy/helm/` | **新增**薄 chart(Chart.yaml / values.yaml / templates: job / configmap / secret)。 |
| `evalscope/config.example.env` | 增 `MODE=docker` 默认 + k8s/helm 相关可选项(namespace / PVC)。 |
| `evalscope/Makefile` | `run` 目标透传 `MODE=`(现有 `TEMPLATE=` 一样透传)。 |
| `evalscope/config.sh` | 向导增一步选 MODE(默认 docker)。 |
| `evalscope/RUNBOOK.md` · `README.md` · `SCENARIOS.md` | 文档对齐三模式。 |

**不变**:`templates/*.env`、`parse.py`/`parse.sh`、tokenizer 在线/离线逻辑、脱敏红线。
模板原样复用(已编码 sweep);helm 只引用模板名。

## 7 · 镜像与命名一致性

- 镜像:三模式统一 `ghcr.io/weetime/md-runner-evalscope:<tag>`(= 现 `BOOT_IMG`)。
- k8s/helm 命名对齐 modeldoctor:Job 名 `run-<id>`、容器名 `runner`、labels
  `app.kubernetes.io/name: modeldoctor-run` / `app.kubernetes.io/managed-by`。
- run-id 语义与本地一致(`YYYYmmdd-HHMMSS-<template>`)。

## 8 · 测试

- `sweep.sh`:沿用/扩展 `tests/run_smoke_test.sh` —— 单档 `parallel=4 number=8` 走
  `python -m runner` + `MD_OUTPUT_DIR` 本地 sink,断言 `out/<id>/result.json` +
  evalscope 产物 + parse 表都在。
- `render_job`:单测渲染出的 Job/ConfigMap/Secret yaml 结构(labels / 容器名 /
  envFrom / 镜像)符合 modeldoctor 形态;`kubectl apply --dry-run=client` 校验。
- helm:`helm template` + `helm lint` 校验渲染同形 Job。
- `parse.py` 单测不变。

## 9 · 不在本设计范围

- 其它工具(guidellm/aiperf/tau3)的 runbook 化 —— 本设计形态成型后可复用。
- k8s 多 Job sweep 扇出(Approach A)—— 明确不做。
- 在线集群的产物自动回传宿主(除日志外)—— 需要时手动从 PVC 拉。
- 改动 modeldoctor —— 无需,PR #358 已提供全部契约。
