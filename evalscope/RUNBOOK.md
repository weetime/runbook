# evalscope 压测 RUNBOOK(镜像版 · 模板化)

> 形态:**我们的 evalscope 镜像**(内置 evalscope 1.7.0 + ShareGPT 70k)+ **外挂 tokenizer**(在线拉取或离线目录)+ **OpenAI 兼容端点**。
> 客户端不需要 GPU、不加载权重,只要能连到被测端点 + 一个 tokenizer 数 token。
>
> **核心思路极简**:模板 = 一组压测参数(`templates/<名字>.env`);`make run` 时 `source` 进来**自动填充**,用户不用填任何参数。**宿主只需 `bash + make + docker`**(结果聚合 `parse.py` 在镜像内跑,镜像自带 python3+sqlite)。

## TL;DR

```bash
make config     # 填端点 / tokenizer / 选模板 → 生成 config.env
make smoke      # 冒烟:单档小跑,验证全链路
make run        # 按模板扫描,参数自动填充,产出独立 out/<run-id>/
make parse      # 聚合去冷轮 + 池化,找 SLO 拐点(默认解析最新一次 run)
```

`make`(或 `make help`)看所有目标。真实端点 / 密钥只落在 `config.env`(不入库)。

---

## 0 · 前置事实(镜像里有什么)

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2`(evalscope 1.7.0,`[perf]` extra) |
| 内置 ShareGPT | `/opt/evalscope-datasets/sharegpt/common_{en,zh}_70k.jsonl`(70k 真实多轮) |
| 其它内置集 | `/opt/evalscope-datasets/longalpaca.txt`、`/opt/evalscope-datasets/openqa/open_qa.jsonl` |
| 合成集 | `random`(无文件,按 token 数精确生成 prompt,需 tokenizer) |
| **不在镜像里** | **tokenizer**(在线拉 / 离线挂) + **端点三要素**(URL/MODEL/KEY,进 `config.env`) |

---

## 1 · 配置:`make config`(生成 config.env + 选模板)

向导逐项引导,回车用默认:

- **端点**:URL(完整 `/v1/chat/completions`)、MODEL(服务端注册名)、KEY(无则 `EMPTY`)。
- **Tokenizer**(数 token 用,不是权重),二选一:
  - **在线** —— 填模型仓库 id(如 `deepseek-ai/DeepSeek-V3`)+ 源(`modelscope` 默认 / `hf` 走 hf-mirror);`smoke`/`run` 阶段自动只拉 tokenizer 文件到 `./tok`。
  - **离线** —— 填本机已有 tokenizer 目录(含 `tokenizer.json` / `config.json`)。
- **模板** —— 向导列出所有可用模板,选一个(默认 `inference-baseline`)。**压测参数不用填**。

不想交互也可 `cp config.example.env config.env` 手填。

---

## 2 · 测试模板(选场景 / 指定 SLO)

模板就是一个 shell 片段,列出这次压测的所有参数(`templates/*.env`)。首批 5 个:

| 模板 | 轴 | 数据集 | 用途 |
|---|---|---|---|
| `inference-baseline` | 并发 | share_gpt_en | short 口径 TTFT/TPOT 基线(默认) |
| `long-context-kv` | 并发 | longalpaca(8K) | 长 prompt 冷/暖 A/B,看 KV / 前缀缓存命中 |
| `chat-slo` | 并发 | share_gpt_en | 客服 SLO(TTFT p95≤1.5s / ITL p95≤200ms),找最大并发 |
| `throughput-max` | 并发 | share_gpt_en | 高并发压满、放宽 SLO,测峰值吞吐 |
| `context-length` | **输入长度** | random | 输入长度敏感性 **1K/8K/32K/128K**,看 TTFT/吞吐衰减 |

切换模板:`make run TEMPLATE=chat-slo`(临时覆盖 config.env 的选择)。想改参数?**直接编辑对应
`templates/<名字>.env`**,或复制一份新建自己的场景 —— 模板就是一堆变量,一眼可读。

一个模板长这样(`templates/context-length.env`):
```sh
# 输入长度敏感性 — TTFT/吞吐随 prompt 长度衰减(1K/8K/32K/128K,单位=token)
AXIS=prompt_len
DATASET=random
PROMPT_LENS="1024 8192 32768 131072"
PARALLEL=8
NUMBER=64
MIN_TOKENS=128
MAX_TOKENS=256
ROUNDS=3
SEED=42
TTFT_SLO=5000
ITL_SLO=300
```

**两种 sweep 轴**:`AXIS=parallel` 扫并发(evalscope 原生多档 ladder);`AXIS=prompt_len` 扫输入
长度(`context-length` 专用,逐长度跑),直接产出「性能对输入长度极度敏感」那张 1K→128K 衰减表。

---

## 3 · 冒烟:`make smoke`

所选模板单档 `parallel=4 number=8` 小跑(`prompt_len` 轴取最短一档),只看「跑不跑得通」。镜像缺会自动拉。跑不通回查第 1 步,别进扫描。

---

## 4 · 扫描:`make run`

`source` 所选模板 → 参数全部自动填充 → 按轴扫,冷 1 轮 + 暖若干轮,**每次产出独立目录**
`out/<run-id>/`(`run-id = 时间戳-模板名`),并更新 `out/latest` 符号链接。目录内 `run.env` 自描述
(模板 / 轴 / SLO),供 `parse` 独立解析。要点:

- **`PARALLEL`/`NUMBER` 逐元素配对**,不是笛卡尔积。
- **确定性** `SEED`,建议服务端 temperature=0。
- **冷/暖分轮**:round1 冷缓存记冷启动代价,round2+ 暖缓存作稳态。
- 每次 run 落新目录,天然绕开 evalscope「见旧 `benchmark_data.db` 拒跑」;清历史用 `make clean`。

---

## 5 · 找拐点:`make parse`

默认解析 `out/latest`(或 `make parse RUN=<run-id>` 指定历史)。稳健口径:**丢 round1 冷轮 →
每档再丢前 10 条连接预热 → warm 轮逐请求原始样本池化 → 算一次 p95**(切忌对「每轮 p95」取中位,会非单调)。

SLO 默认从 run 目录的 `run.env` 读,也可覆盖:`TTFT_SLO=1500 ITL_SLO=200 make parse`。

输出:按轴(并发 或 输入长度)× 输出 tok/s × TTFT p95 × ITL p95 × TPOT p50,标出 **◀ 拐点**,
明细写 `<run-id>/summary.csv`。

---

## 编号踩坑清单(按代价排序)

1. **tokenizer 要真实文件**:在线模式白名单只拉 tokenizer(非权重、非几百字节 metadata);缺 `chat_template` 要补;否则 token 数不出、TPOT/吞吐全错。
2. **调裸 evalscope 要 `--entrypoint evalscope`**(脚本已带),否则命中镜像默认 `python -m runner`。
3. **数据集用镜像内置路径**(`lib.sh` 的 `map_dataset` 已按 `DATASET` 映射),无需本机再下。
4. `PARALLEL` 与 `NUMBER` **逐元素配对**,不是笛卡尔积。
5. **每次 run 独立目录**:互不覆盖、可横向对比;清历史用 `make clean`。
6. **聚合别对每轮 p95 取中位**(会非单调)→ 丢冷轮 + 池化 warm 逐请求样本。
7. **p95 只在 par ≥ 8 读**;并发 1 的 p95 是冷启动小样本伪影;p99 需 n ≥ 500。
8. **`context-length` 用 `random`**:按 token 精确控长,128K 会触到上下文上限(可能 OOM / 严重降速),这正是要测的。
9. 客户端指标**定位不了瓶颈**:归因需同时抓引擎 `/metrics`(KV 占用 / 排队 / 抢占)。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `Makefile` | 入口:`config / smoke / run / parse / clean` |
| `config.sh` | 交互式向导 → 生成 `config.env`(端点 + tokenizer + 选模板) |
| `templates/*.env` | 场景模板:一组压测参数(入库、可共享,无端点/密钥) |
| `config.example.env` | `config.env` 模板(`config.env` 本身不入库) |
| `lib.sh` | 公共 shell 逻辑(`map_dataset` 数据集映射、`ensure_image` 拉镜像、`ensure_tokenizer` 拉/校验、`pyc` 镜像内跑 parse) |
| `run.sh` | source 模板 → 按轴扫描,落独立 `out/<run-id>/` + `run.env` |
| `parse.sh` · `parse.py` | `parse.sh` 在镜像内跑 `parse.py`:聚合去冷轮 + 池化,按轴找 SLO 拐点 |
| `tests/` | 开发期单测(`parse_test.py` / `run_smoke_test.sh`),终端用户不需要 |
