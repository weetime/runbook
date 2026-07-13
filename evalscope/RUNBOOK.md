# evalscope 压测 RUNBOOK(镜像版 · 模板化)

> 形态:**我们的 evalscope 镜像**(内置 evalscope 1.7.0 + ShareGPT 70k)+ **外挂 tokenizer**(在线拉取或离线目录)+ **OpenAI 兼容端点**。
> 客户端不需要 GPU、不加载权重,只要能连到被测端点 + 一个 tokenizer 数 token。
> **测试场景由模板决定**:选不同模板 = 不同数据集 / 负载形状 / SLO。
>
> **宿主只需 `bash + make + docker`**(无需装 python):配置解析(`conf.py`)与结果聚合(`parse.py`)都在镜像内跑,镜像自带 python3 + sqlite。

## TL;DR

```bash
make config     # 交互式填端点 / tokenizer / 选模板 → 生成 config.yaml
make smoke      # 冒烟:单档小跑,验证全链路
make run        # 按模板扫描,产出独立 out/<run-id>/
make parse      # 聚合去冷轮 + 池化,找 SLO 拐点(默认解析最新一次 run)
```

`make`(或 `make help`)看所有目标。真实端点 / 密钥只落在 `config.yaml`(不入库)。

---

## 0 · 前置事实(镜像里有什么)

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2`(evalscope 1.7.0,`[perf]` extra) |
| 内置 ShareGPT | `/opt/evalscope-datasets/sharegpt/common_{en,zh}_70k.jsonl`(70k 真实多轮) |
| 其它内置集 | `/opt/evalscope-datasets/longalpaca.txt`、`/opt/evalscope-datasets/openqa/open_qa.jsonl` |
| 合成集 | `random`(无文件,按 token 数精确生成 prompt,需 tokenizer)|
| **不在镜像里** | **tokenizer**(在线拉 / 离线挂) + **端点三要素**(URL/MODEL/KEY,进 `config.yaml`) |

---

## 1 · 配置:`make config`(生成 config.yaml + 选模板)

向导逐项引导,回车用默认:

- **端点**:URL(完整 `/v1/chat/completions`)、MODEL(服务端注册名)、KEY(无则 `EMPTY`)。
- **Tokenizer**(数 token 用,不是权重),二选一:
  - **在线** —— 填模型仓库 id(如 `deepseek-ai/DeepSeek-V3`)+ 源(`modelscope` 默认 / `hf` 走 hf-mirror);`smoke`/`run` 阶段自动只拉 tokenizer 文件到 `./tok`。
  - **离线** —— 填本机已有 tokenizer 目录(含 `tokenizer.json` / `config.json`),直接挂载。
- **模板** —— 向导列出所有可用模板,选一个(默认 `inference-baseline`)。

不想交互也可 `cp config.example.yaml config.yaml` 手填。

> tokenizer 坑:确认下到的是**真实文件**(`tokenizer.json` MB 级),几百字节的是坏 metadata;缺 `chat_template` 的补上,否则多轮 ShareGPT 无法 tokenize。在线模式脚本已用文件白名单,只取 tokenizer 相关文件、**不下几十 GB 权重**。

---

## 2 · 测试模板(选场景 / 指定 SLO)

模板 = 一个 **sweep 轴** + 固定旋钮 + 默认 SLO,位于 `templates/*.yaml`。首批 5 个:

| 模板 | 轴 | 数据集 | 用途 |
|---|---|---|---|
| `inference-baseline` | 并发 | share_gpt_en | short 口径 TTFT/TPOT 基线(默认)|
| `long-context-kv` | 并发 | longalpaca(8K)| 长 prompt 冷/暖 A/B,看 KV / 前缀缓存命中 |
| `chat-slo` | 并发 | share_gpt_en | 客服 SLO(TTFT p95≤1.5s / ITL p95≤200ms),找最大并发 |
| `throughput-max` | 并发 | share_gpt_en | 高并发压满、放宽 SLO,测峰值吞吐 |
| `context-length` | **输入长度** | random | 输入长度敏感性 **1K/8K/32K/128K**,看 TTFT/吞吐衰减 |

切换模板:`make run TEMPLATE=chat-slo`(覆盖 config.yaml 的选择);也可临时覆盖负载,如
`make run TEMPLATE=chat-slo PARALLEL="8 16" ROUNDS=2`。

**两种 sweep 轴**:
- `parallel` 轴 —— 扫并发档,evalscope 原生单次多档 ladder。
- `prompt_len` 轴 —— 扫输入长度(`context-length` 专用),逐长度跑;直接产出「大模型性能对输入长度极度敏感」那张 1K→128K 的衰减表。

---

## 3 · 冒烟:`make smoke`

所选模板单档 `parallel=4 number=8` 小跑(`prompt_len` 轴取最短一档),只看「跑不跑得通」:端点通、tokenizer 数得出 token、无大面积失败。镜像缺会自动拉。跑不通回查第 1 步,别进扫描。

---

## 4 · 扫描:`make run`

按模板的轴与旋钮扫,冷 1 轮 + 暖若干轮,**每次产出独立目录** `out/<run-id>/`(`run-id = 时间戳-模板名`),并更新 `out/latest` 符号链接指向它。目录内 `run.json` 自描述(轴 / SLO / 参数),供 `parse` 独立解析。方法学要点:
- **`PARALLEL`/`NUMBER` 逐元素配对**,不是笛卡尔积。
- **确定性** `--seed`,建议服务端 temperature=0。
- **冷/暖分轮**:round1 冷缓存记冷启动代价,round2+ 暖缓存作稳态。
- 每次 run 落新目录,天然绕开 evalscope「见旧 `benchmark_data.db` 拒跑」,**无需手动清理**;要清历史用 `make clean`。

---

## 5 · 找拐点:`make parse`

默认解析 `out/latest`(或 `make parse RUN=<run-id>` 指定历史)。稳健口径:**丢 round1 冷轮 → 每档再丢前 10 条连接预热 → warm 轮逐请求原始样本池化 → 算一次 p95**(切忌对「每轮 p95」取中位,会非单调)。

SLO 默认从模板携带的 `slo` 读,也可覆盖:
```bash
TTFT_SLO=1500 ITL_SLO=200 make parse   # 客服口径覆盖
```

输出:按轴(并发 或 输入长度)× 输出 tok/s × TTFT p95 × ITL p95 × TPOT p50,标出 **◀ 拐点**,明细写 `<run-id>/summary.csv`。

---

## 编号踩坑清单(按代价排序)

1. **tokenizer 要真实文件**:在线模式白名单只拉 tokenizer(非权重、非几百字节 metadata);缺 `chat_template` 要补;否则 token 数不出、TPOT/吞吐全错。
2. **调裸 evalscope 要 `--entrypoint evalscope`**(脚本已带),否则命中镜像默认 `python -m runner`。
3. **数据集用镜像内置路径**(`conf.py` 已按模板映射),无需本机再下。
4. `PARALLEL` 与 `NUMBER` **逐元素配对**,不是笛卡尔积。
5. **每次 run 独立目录**:互不覆盖、可横向对比;要清历史用 `make clean`。
6. **聚合别对每轮 p95 取中位**(会非单调)→ 丢冷轮 + 池化 warm 逐请求样本。
7. **p95 只在 par ≥ 8 读**;并发 1 的 p95 是冷启动小样本伪影;p99 需 n ≥ 500。
8. **`context-length` 用 `random`**:按 token 精确控长,128K 会触到上下文上限(可能 OOM / 严重降速),这正是要测的。
9. 客户端指标**定位不了瓶颈**:归因需同时抓引擎 `/metrics`(KV 占用 / 排队 / 抢占)。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `Makefile` | 入口:`config / smoke / run / parse / clean` |
| `config.sh` | 交互式向导 → 生成 `config.yaml`(端点 + tokenizer + 选模板)|
| `conf.py` | 零依赖加载器:合并 `config.yaml` + `templates/<name>.yaml` → shell export / JSON(**在镜像内跑**)|
| `lib.sh` | 公共 shell 逻辑(`pyc` 镜像内跑 python、`ensure_image` 拉镜像、`ensure_tokenizer` 在线拉/离线校验)|
| `run.sh` | 按 sweep 轴扫描,落独立 `out/<run-id>/` + `run.json` |
| `parse.sh` · `parse.py` | `parse.sh` 在镜像内跑 `parse.py`:聚合去冷轮 + 池化,按轴分组找 SLO 拐点 |
| `templates/*.yaml` | 场景模板库(入库、可共享,无端点/密钥)|
| `config.example.yaml` | `config.yaml` 模板(`config.yaml` 本身不入库)|
