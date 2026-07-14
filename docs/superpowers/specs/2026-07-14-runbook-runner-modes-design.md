# 设计:runbook 复用 modeldoctor runner —— 离线 docker / k8s 两模式,与在线口径一致

> 状态:已定稿(待实现)· 2026-07-14
> 范围:`evalscope/` 子目录(形态可后续复用到其它工具 runbook)

## 1 · 背景与目标

runbook 的 evalscope 压测目前**绕过** modeldoctor 的 runner:直接
`docker run --entrypoint evalscope <img> perf …`,宿主 bash 循环做 sweep,产物落本地
`out/`,本地 `parse.py` 找 SLO 拐点。

modeldoctor 的 runner(`ghcr.io/weetime/md-runner-evalscope`,ENTRYPOINT
`python -m runner`)是**工具无关、env 驱动**的:读 `MD_ARGV`(JSON argv)/
`MD_OUTPUT_FILES`,在 cwd 里跑工具,tee 日志,收集产物,写 report。

**运行环境只有两大类:在线平台,或离线现场。**

| 谁发起 | 跑在哪 | sink | 归属 |
|---|---|---|---|
| **modeldoctor(在线)** | k8s 集群,平台建 Job | S3 / MinIO | **已有,本设计不碰** |
| **runbook `MODE=docker`(离线)** | 本机 | 本地目录 | 本设计 |
| **runbook `MODE=k8s`(离线)** | 离线 k8s 集群,`kubectl apply` | PVC / 挂载目录 | 本设计 |

**目标**:runbook 只补**离线两模式(docker + k8s)**,并让它们与在线 modeldoctor
**共用同一镜像、同一 `python -m runner` 入口、同一 `MD_ARGV` 契约、同一实时日志与产物
布局** —— 只有 sink 的 env 不同(离线 `LocalWriter`,在线 `S3Writer`)。这样离线量出来的
口径与平台在线一致。

**不做**:
- runbook 自己去在线集群发起(那是 modeldoctor 的活)。
- helm。交付一个一次性压测 Job 不需要 chart 的打包/values/版本化;`kubectl apply`
  裸 yaml 更轻,清理 `kubectl delete job run-<id>`。
- docker-compose。压测是一次性批处理(跑完即退),`docker run --rm` 就是它的原生形态;
  compose 是给长期服务用的,零增量。

**两模式各用运行时最轻的原生形态**:docker → `docker run`(sh);k8s → Job yaml
(`kubectl apply`)。真正跟 k8s Job 对等的 docker 形态是 `docker run`,不是 compose。

约束(用户明确):**不要过度设计;docker 和 k8s 都要轻量**。

## 2 · 关键前提:modeldoctor 侧已就绪(PR #358,已合并)

无需改动 modeldoctor。PR #358(`0afe9b0`,2026-07-14 合并)已给 runner 加了
**可回退的本地目录 sink**,契约固定为:

- `select_sink()`:`S3_ENDPOINT` 存在 → `S3Writer`(在线/平台,零变化);否则
  `MD_OUTPUT_DIR` 存在 → `LocalWriter`(离线);两者都无 → fail-fast。
- `LocalWriter` 把产物写到 `MD_OUTPUT_DIR` 挂载目录,布局与 S3 **逐字节一致**:
  `<id>/meta.json` · `<id>/result.json` · `<id>/stdout.log` · `<id>/stderr.log` ·
  `<id>/files/<alias>`。原子写(sibling `.tmp` + `os.replace`),key 防逃逸。

runbook 离线只需:设 `MD_BENCHMARK_ID` / `MD_ARGV` / `MD_OUTPUT_FILES` /
`MD_OUTPUT_DIR`,并挂载输出目录。**不配 S3 = 写文件到挂载目录**(不是只在终端飘一下);
终端/日志是另一回事,永远都有(runner 把工具输出 tee 到 stdout),与 sink 无关。

## 3 · 架构:MODE 分发 + 单一 sweep 契约

### 3.1 UX —— 新增一个 `MODE` 轴,其余不变

保留现有全部界面(`config / smoke / run / parse / clean`、`templates/*.env`、
`config.env`)。只加一个分发轴,**只有两种离线取值**:

```bash
make run                 # MODE=docker(默认,离线单机)
make run MODE=k8s        # 离线集群:渲染 yaml → kubectl apply 一个 Job
```

`config.env` 增加 `MODE=docker` 默认值。`smoke` / `parse` / `clean` 与模式无关
(`parse` 始终读本地 `out/`;k8s 模式深挖时先从 PVC 拉回 `out/<run-id>/`)。

### 3.2 单一契约(SSOT):`sweep.sh` + env

`run.sh` 不论模式,只构建**同一份**运行参数(`config.env` + 选定
`templates/*.env`)。两模式消费同一个 `sweep.sh` + env:

- `MD_ARGV = ["bash","<sweep.sh 容器内路径>"]` —— `sweep.sh` 是把今天 `run.sh` 里的
  sweep 循环(ROUNDS 冷/暖 × 轴点)**原样抽出**,使其能在容器内跑。
- `MD_BENCHMARK_ID = <run-id>`(`YYYYmmdd-HHMMSS-<template>`)。
- `MD_OUTPUT_DIR = <挂载的 out 目录>`(离线 sink)。
- 模板变量(`AXIS/DATASET/PARALLEL/NUMBER/PROMPT_LENS/MIN_TOKENS/…/TTFT_SLO/ITL_SLO`)
  作为普通 env 传入,`sweep.sh` 直接读。
- `OPENAI_API_KEY` 走 secret/env(**不进 argv**),`sweep.sh` 里
  `evalscope … --api-key "$OPENAI_API_KEY"`。
- tokenizer:挂载目录(容器内 `/tok`),沿用现有在线拉取 / 离线挂载逻辑。

`sweep.sh` 把 evalscope 产物写到 cwd 下 `out/<run-id>/…`(`MD_OUTPUT_FILES`→cwd
机制),并在末尾跑 `parse.py`,把 SLO 拐点表打到 stdout。

**为什么一个 run = 一个容器/Job(Approach B)**:整套 sweep 在单容器内跑,docker 一次
`run`、k8s 一个 Job。避免 host 端多 Job 扇出 + 产物回收 —— 这是唯一让 "docker/k8s
轻量" 真正成立的形态。sweep 逻辑留在 runbook(不烘进 modeldoctor 镜像),通过挂载脚本
交付(docker bind-mount,k8s ConfigMap)。

## 4 · 两模式落地

两模式共用同一镜像 `ghcr.io/weetime/md-runner-evalscope:<tag>`、同一入口
`python -m runner`、同一 `MD_ARGV` 契约、同一实时日志与产物布局 —— **只有脚本交付方式
与是否挂 PVC 不同**。

### 4.1 docker(离线默认,轻量)

一次 `docker run --rm`,镜像默认入口即 `python -m runner`,bind-mount `sweep.sh`、
`tok/`、`out/`(= `MD_OUTPUT_DIR`)。即今天流程,但过 runner 包装器而非裸 evalscope。
产物落本地 `out/<run-id>/`,`make parse` 照旧。终端实时看 sweep + 末尾 parse 表。
无交付物 —— run.sh 直接 `docker run`,要可看的产物就是它打印的那条命令。

### 4.2 k8s(离线集群,轻量)

`run.sh` 渲染一份**自包含 yaml**(Job + ConfigMap + Secret,heredoc/`envsubst`),
`kubectl apply -f -`。yaml **形态对齐** modeldoctor:labels
`app.kubernetes.io/name: modeldoctor-run`、容器名 `runner`、`backoffLimit 0`、
`restartPolicy Never`、image、Job 名 `run-<id>`。要点:

- `sweep.sh` **内嵌进 ConfigMap**(集群内无宿主 bind-mount)→ yaml 自包含,拿着它到
  任何集群都能跑,是可交付/可版本化的产物。
- sink:挂 **PVC**(或 hostPath 单节点)当 `MD_OUTPUT_DIR`;离线不假设集群有 MinIO。
- 端点/密钥经 **Secret**(`OPENAI_API_KEY` 等),不进 Job manifest 明文。
- `kubectl apply -f -` → 一个 Job → `kubectl logs -f job/run-<run-id>` 实时看
  sweep + 末尾 parse 表。清理 `kubectl delete job run-<run-id>`(或按 label)。

## 5 · 产物回收 —— 两模式统一

两模式一致:**容器内跑 sweep → parse → 打印 SLO 表**;产物同时落挂载卷 / PVC。
- docker:bind-mount,`out/<run-id>/` 本地可读,`make parse` 照旧。
- k8s:头条 SLO 表在 `kubectl logs`;要深挖再从 PVC 拉 `out/<run-id>/` 后 `make parse`。

在线 modeldoctor 侧:产物在 S3,平台 UI 读 —— 不在本设计范围。

## 6 · runbook 文件改动

| 文件 | 改动 |
|---|---|
| `evalscope/sweep.sh` | **新增**。从 `run.sh` 抽出的容器内 sweep 循环(rounds × 轴)+ 末尾调 `parse.py` 打表。读模板 env,写 `out/<run-id>/`。 |
| `evalscope/run.sh` | 改为**分发器**:构建 env + `MD_ARGV` → 按 `MODE`(docker/k8s)落地。sweep 循环移出到 `sweep.sh`。 |
| `evalscope/lib.sh` | 增 `render_k8s_yaml`(Job+ConfigMap+Secret 渲染);沿用 `ensure_image`/`ensure_tokenizer`/`map_dataset`。 |
| `evalscope/config.example.env` | 增 `MODE=docker` 默认 + k8s 相关可选项(namespace / PVC / storageClass)。 |
| `evalscope/Makefile` | `run` 目标透传 `MODE=`(现有 `TEMPLATE=` 一样透传)。 |
| `evalscope/config.sh` | 向导增一步选 MODE(默认 docker;选 k8s 时多问 namespace/PVC)。 |
| `evalscope/RUNBOOK.md` · `README.md` · `SCENARIOS.md` | 文档对齐两模式 + 与在线口径一致的说明。 |

**不变**:`templates/*.env`、`parse.py`/`parse.sh`、tokenizer 在线/离线逻辑、脱敏红线。
模板原样复用(已编码 sweep)。

## 7 · 镜像与命名一致性

- 镜像:两模式统一 `ghcr.io/weetime/md-runner-evalscope:<tag>`(= 现 `BOOT_IMG`),
  与在线 modeldoctor 同镜像。
- k8s 渲染的 Job 命名对齐 modeldoctor:Job 名 `run-<id>`、容器名 `runner`、labels
  `app.kubernetes.io/name: modeldoctor-run` / `app.kubernetes.io/managed-by`。
- run-id 语义与本地一致(`YYYYmmdd-HHMMSS-<template>`)。

## 8 · 测试

- `sweep.sh`:沿用/扩展 `tests/run_smoke_test.sh` —— 单档 `parallel=4 number=8` 走
  `python -m runner` + `MD_OUTPUT_DIR` 本地 sink,断言 `out/<id>/result.json` +
  evalscope 产物 + parse 表都在。
- `render_k8s_yaml`:单测渲染出的 Job/ConfigMap/Secret 结构(labels / 容器名 /
  envFrom / 镜像 / ConfigMap 挂载 / PVC)对齐 modeldoctor 形态;
  `kubectl apply --dry-run=client -f -` 过一遍渲染结果。
- `parse.py` 单测不变。

## 9 · 不在本设计范围

- 在线 k8s(modeldoctor 平台发起 + S3 sink)—— 已有,不重复实现;本设计只保证离线与其
  **口径/镜像/契约一致**。
- 其它工具(guidellm/aiperf/tau3)的 runbook 化 —— 本设计形态成型后可复用。
- 一个 run 多 Job sweep 扇出(Approach A)—— 明确不做。
- helm / docker-compose —— 明确不做(见 §1)。
- 离线集群产物自动回传宿主(除日志外)—— 需要时手动从 PVC 拉。
- 改动 modeldoctor —— 无需,PR #358 已提供全部契约。
