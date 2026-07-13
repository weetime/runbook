# evalscope 压测 RUNBOOK(镜像版)

> 形态:**我们的 evalscope 镜像**(内置 evalscope 1.7.0 + ShareGPT 70k)+ **外挂 tokenizer**(在线拉取或离线目录)+ **OpenAI 兼容端点**。
> 客户端不需要 GPU、不加载权重,只要能连到被测端点 + 一个 tokenizer 数 token。

## TL;DR

```bash
make setup      # 交互式一步步填端点 / tokenizer / 负载 → 生成 .env
make install    # 拉镜像 +(在线模式)预取 tokenizer 到 ./tok
make smoke      # 冒烟:单档小跑,验证全链路
make run        # 扫并发(冷/暖多轮)
make parse      # 聚合去冷轮 + 池化,找 SLO 拐点
```

`make`(或 `make help`)看所有目标。真实端点 / 密钥只落在 `.env`(不入库)。

---

## 0 · 前置事实(镜像里有什么)

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2`(evalscope 1.7.0,`[perf]` extra) |
| 内置 ShareGPT | `/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl`(70k 真实多轮英文) |
| 其它内置集 | `/opt/evalscope-datasets/longalpaca.txt`、`/opt/evalscope-datasets/openqa/open_qa.jsonl` |
| 镜像默认 ENTRYPOINT | `python -m runner` → **调裸 evalscope 已由脚本加 `--entrypoint evalscope`** |
| **不在镜像里** | **tokenizer**(在线拉 / 离线挂) + **端点三要素**(URL/MODEL/KEY,进 `.env`) |

---

## 1 · 配置:`make setup`(生成 .env)

向导逐项引导,回车用默认:

- **端点**:URL(完整 `/v1/chat/completions`)、MODEL(服务端注册名)、KEY(无则 `EMPTY`)。
- **Tokenizer**(数 token 用,不是权重),二选一:
  - **在线** —— 填模型仓库 id(如 `deepseek-ai/DeepSeek-V3`)+ 源(`modelscope` 默认 / `hf` 走 hf-mirror);`install`/`run` 阶段自动只拉 tokenizer 文件到 `./tok`。
  - **离线** —— 填本机已有 tokenizer 目录(含 `tokenizer.json` / `config.json`),直接挂载。
- **负载**:并发档 `PARALLEL`、每档数 `NUMBER`(逐元素配对)、轮次 `ROUNDS`、`MIN/MAX_TOKENS`。

不想交互也可 `cp .env.example .env` 手填。

> tokenizer 坑:确认下到的是**真实文件**(`tokenizer.json` MB 级),几百字节的是坏 metadata;缺 `chat_template` 的补上,否则多轮 ShareGPT 无法 tokenize。在线模式脚本已用文件白名单,只取 tokenizer 相关文件、**不下几十 GB 权重**。

---

## 2 · 安装:`make install`

拉镜像;**在线** tokenizer 模式顺带预取到 `./tok`(之后 `run` 完全离线可复现),**离线**模式校验目录。也可跳过:`run` 阶段发现 `./tok` 缺会自动拉。

---

## 3 · 冒烟:`make smoke`

单档 `parallel=4 number=8` 小跑,只看「跑不跑得通」:端点通、tokenizer 数得出 token、无大面积失败。跑不通回查第 1 步,别进扫描。

---

## 4 · 扫并发:`make run`

ShareGPT 真实流量,按 `.env` 的并发档 × 每档数,冷 1 轮 + 暖若干轮。方法学要点:
- **`PARALLEL`/`NUMBER` 逐元素配对**,不是笛卡尔积。
- **short 口径** `--min-tokens/--max-tokens`,给干净可比的 TTFT/TPOT 基线。
- **确定性** `--seed 42`,建议服务端 temperature=0。
- **冷/暖分轮**:round1 冷缓存记冷启动代价,round2+ 暖缓存作稳态。
- 重跑前脚本自动 `rm -rf out/round*`(evalscope 见旧 `benchmark_data.db` 会拒跑)。

---

## 5 · 找拐点:`make parse`

`parse.py` 稳健口径:**丢 round1 冷轮 → 每档再丢前 10 条连接预热 → warm 轮逐请求原始样本池化 → 算一次 p95**(切忌对「每轮 p95」取中位,会非单调)。自定义 SLO:

```bash
TTFT_SLO=1500 ITL_SLO=200 make parse   # 客服口径:TTFT p95≤1.5s、ITL p95≤200ms
```

输出:并发档 × 输出 tok/s × TTFT p95 × ITL p95 × TPOT p50,标出 **◀ 拐点**,明细写 `out/summary.csv`。

---

## 编号踩坑清单(按代价排序)

1. **tokenizer 要真实文件**:在线模式白名单只拉 tokenizer(非权重、非几百字节 metadata);缺 `chat_template` 要补;否则 token 数不出、TPOT/吞吐全错。
2. **调裸 evalscope 要 `--entrypoint evalscope`**(脚本已带),否则命中镜像默认 `python -m runner`。
3. **ShareGPT 用镜像内置路径**(脚本已带 `--dataset share_gpt_en --dataset-path /opt/evalscope-datasets/sharegpt/common_en_70k.jsonl`),无需本机再下。
4. `PARALLEL` 与 `NUMBER` **逐元素配对**,不是笛卡尔积。
5. **重跑先清 `out/round*`**:evalscope 见旧 `benchmark_data.db` 会拒跑(`run.sh` 已内置)。
6. **聚合别对每轮 p95 取中位**(会非单调)→ 丢冷轮 + 池化 warm 逐请求样本。
7. **p95 只在 par ≥ 8 读**;并发 1 的 p95 是冷启动小样本伪影;p99 需 n ≥ 500。
8. 客户端指标**定位不了瓶颈**:归因需同时抓引擎 `/metrics`(KV 占用 / 排队 / 抢占)。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `Makefile` | 入口:`setup / install / smoke / run / parse / clean` |
| `setup.sh` | 交互式向导 → 生成 `.env` |
| `env.sh` | 载入 `.env` + 公共逻辑(tokenizer 在线拉取 / 离线解析) |
| `install.sh` · `run.sh` | 拉镜像预取 / 冒烟 + 并发扫描 |
| `parse.py` | 聚合去冷轮 + 池化,找 SLO 拐点 |
| `.env.example` | 配置模板(`.env` 本身不入库) |
