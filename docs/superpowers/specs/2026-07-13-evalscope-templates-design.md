# evalscope 测试模板 — 设计文档

> 日期:2026-07-13 · 范围:runbook/evalscope 的模板化改造(离线 Docker 版)
> 目标读者:runbook 维护者 + 后续接 aiperf / guidellm / vegeta / helm 的人

## 1 · 背景与目标

`runbook/evalscope` 现在是**单条硬编码流程**(`setup → install → smoke → run → parse`):
数据集写死 `share_gpt_en`,负载参数(并发/请求数/token 档)散落在 `.env`,prompt 长度
根本没暴露,SLO 阈值只活在 `parse.py` 的环境变量里。想换一个测试场景,只能手改脚本。

平台侧(`modeldoctor/packages/tool-adapters`)早已把压测抽象成**场景(scenario)**:
`inference`(TTFT/TPOT 基线)、`capacity`(SLO 驱动阶梯)、`engine-kv-cache`(KV/前缀缓存
A/B)等,每个场景绑定一组工具与参数约束(见 `scenarios.ts`);evalscope 适配器
(`evalscope/schema.ts` + `runtime.ts`)持有完整旋钮集:`dataset`、`min/maxPromptLength`、
`min/maxTokens`、`parallel`、`number`、`apiPath`、`stream`、`seed`。

**本设计把平台的 scenario 概念"导出"成离线可照抄的模板**,让 `make run` 能选模板;
并**提前规划目录**,使后续 aiperf / guidellm / vegeta 以及 helm 部署沿用同一形态。

### 目标
1. evalscope 支持**多个测试模板**(不同场景 / 指定 SLO),`make run` 可选。
2. 命令收敛到 **`config / smoke / run / parse`(+ `clean`)**,删掉 `setup` 与 `install`。
3. **彻底移除 `.env`**,配置全部进 YAML;本地配置由 `make config` 交互生成。
4. **每次 `run` 产出独立目录**,互不覆盖、可横向对比。
5. 目录结构为后续工具与 helm 预留,不返工。

### 非目标
- 本次只做 **evalscope**;aiperf / guidellm / vegeta / helm 仅规划占位,不实现(见 §11)。
- 不做 Web UI、不接平台 API;runbook 保持 make + 脚本、方法为主、工具中立。

## 2 · 目录规划

```
runbook/
  README.md
  SCENARIOS.md                  # ← 新增:跨工具共享的场景词表(从 modeldoctor 导出)
  docs/superpowers/specs/       # 设计文档
  evalscope/
    Makefile                    # 入口:config / smoke / run / parse / clean
    config.sh                   # ← 由 setup.sh 改名:交互 → 写 config.yaml
    conf.py                     # ← 新增:零依赖 YAML 加载器(config+template→shell export)
    lib.sh                      # ← 由 env.sh 改名:ensure_image / ensure_tokenizer 等 shell 逻辑
    run.sh                      # 泛化:按 sweep 轴扫描,每次落独立 out/<run-id>/
    parse.py                    # 泛化:按 sweep 轴分组,读 run.json 自描述
    templates/                  # ← 新增:committed 场景预设库
      inference-baseline.yaml
      long-context-kv.yaml
      chat-slo.yaml
      throughput-max.yaml
      context-length.yaml
    config.example.yaml         # ← 新增:config.yaml 模板(入库)
    config.yaml                 # 本地配置(gitignored,make config 生成)
    tok/                        # tokenizer(gitignored)
    out/                        # 压测产物(gitignored),out/<run-id>/ + out/latest
  aiperf/    guidellm/    vegeta/   # 后续,同一形态(各自 templates/ + conf.py + Makefile)
  helm/                             # 后续:离线 helm chart 部署
```

**两类 YAML,职责分离**(这是整套设计的核心约束,源于仓库脱敏红线):

| | `templates/*.yaml` | `config.yaml` |
|---|---|---|
| 内容 | 场景预设:数据集 / sweep / token 档 / 轮次 / SLO | 端点 URL/MODEL/KEY + tokenizer + 选哪个模板 + 覆盖项 |
| 是否入库 | **入库**(可共享照抄,无端点无密钥) | **不入库**(gitignored,含真实端点/密钥) |
| 谁生成 | 手写 / 从平台导出 | `make config` 交互生成 |

`config.yaml` 是**薄覆盖层**:只引用模板名 + 存连接信息,**不内联模板内容**——否则 load
参数会有两个来源、易漂移。

## 3 · 模板 Schema(`templates/*.yaml`)

模板的核心是一个 **sweep 轴**:声明"扫哪个变量、其余固定"。两种轴覆盖全部场景。

### 3.1 `axis: parallel`(扫并发,现状行为)

```yaml
name: inference-baseline
desc: ShareGPT 真实流量、short 口径,TTFT/TPOT 基线并发扫描
scenario: inference               # 对应 SCENARIOS.md 词表
dataset: share_gpt_en             # longalpaca|openqa|random|share_gpt_en|share_gpt_zh
sweep:
  axis: parallel
  parallel: [4, 8, 16, 32]
  number:   [60, 80, 120, 160]    # 与 parallel 逐元素配对(非笛卡尔积)
tokens: {min: 128, max: 256}      # 输出档 --min/max-tokens
rounds: 3                         # round1 冷缓存,其余暖缓存
seed: 42
slo: {ttft_p95_ms: 1500, itl_p95_ms: 200}
```

### 3.2 `axis: prompt_len`(扫输入长度,新增)

```yaml
name: context-length
desc: 输入长度敏感性 — TTFT/吞吐随 prompt 长度衰减(1K/8K/32K/128K)
scenario: context-length
dataset: random                   # 合成,精确控制 prompt 长度
sweep:
  axis: prompt_len
  prompt_lens: [1024, 8192, 32768, 131072]   # 每档一个 prompt 长度
  parallel: 8                     # 固定
  number: 64                      # 固定
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 5000, itl_p95_ms: 300}
```

### 3.3 字段约定

| 字段 | 说明 |
|---|---|
| `name` | 模板名,须与文件名一致(`context-length.yaml` → `name: context-length`) |
| `desc` | 一行中文描述,`make config` 列表与报告抬头用 |
| `scenario` | SCENARIOS.md 词表里的场景 id(可追溯到平台) |
| `dataset` | evalscope 数据集逻辑名,映射见 §3.4 |
| `sweep.axis` | `parallel` \| `prompt_len` |
| `sweep.parallel` / `sweep.number` | 轴=parallel 时为**等长列表**(逐元素配对);轴=prompt_len 时为标量 |
| `sweep.prompt_lens` | 轴=prompt_len 时的长度列表(单位见 §3.4 备注) |
| `tokens.{min,max}` | 输出 token 档 |
| `rounds` | 冷/暖轮数,round1 恒为冷缓存 |
| `seed` | 确定性 prompt 采样(冷/暖 A/B 可复现) |
| `slo.{ttft_p95_ms,itl_p95_ms}` | 该场景默认 SLO,`parse.py` 找拐点用 |

### 3.4 数据集 → evalscope flag 映射(沿用平台 runtime.ts)

- `longalpaca` → `--dataset line_by_line --dataset-path /opt/evalscope-datasets/longalpaca.txt`
  (`--min/max-prompt-length` 单位为**字符**)
- `openqa` → `--dataset openqa --dataset-path /opt/evalscope-datasets/openqa/open_qa.jsonl`
- `share_gpt_en/zh` → `--dataset share_gpt_en|share_gpt_zh --dataset-path /opt/.../common_*_70k.jsonl`
- `random` → `--dataset random`(合成,无文件)

> **实现待验证项(random 的长度语义)**:`context-length` 用 `random` 精确控制 prompt 长度。
> evalscope `random` 数据集的 prompt 长度旗标与单位(`--min/max-prompt-length` 是 token
> 还是 char,是否需 `--prefix-length`)须在实现时对着镜像内 evalscope 版本核实,并据此把
> `prompt_lens` 的单位在模板注释里写清。若 128K 超出镜像默认上限,需在实现中确认 evalscope
> 是否放行、或分档降级。

## 4 · 本地配置 Schema(`config.yaml`,gitignored)

```yaml
# config.yaml — make config 生成,不入库(含真实端点/密钥)
endpoint:
  url: https://HOST/v1/chat/completions   # 完整 URL(含 /v1/... 路径)
  model: DeepSeek-V3                       # 服务端注册名
  key: EMPTY                               # 无鉴权填 EMPTY
tokenizer:
  mode: online                             # online | offline
  id: deepseek-ai/DeepSeek-V3              # online:模型仓库 id
  source: modelscope                       # online:modelscope | hf
  # path: /data/tok                        # offline:本机 tokenizer 目录
template: inference-baseline               # 默认选用的模板
image: ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2   # 可省,有内置默认
overrides:                                 # 可选:覆盖所选模板的 load 参数
  # rounds: 2
  # parallel: [8, 16]
```

`config.example.yaml` 是同结构的占位模板(入库),用 `<HOST>` / `EMPTY` 等占位,不含真实值。

## 5 · 零依赖加载器 `conf.py`

> **实现补充(2026-07-13,python 落容器)**:为让**宿主只需 `bash + make + docker`**,
> `conf.py` 与 `parse.py` 不在宿主跑,而是**在已必需的镜像内执行**(镜像自带 python3+sqlite):
> `lib.sh` 提供 `pyc()`(`docker run -v "$RB:/rb" -w /rb --entrypoint python $BOOT_IMG …`,
> 转发覆盖用环境变量),`run.sh` 用 `eval "$(pyc conf.py)"`,`parse.sh` 用 `pyc parse.py`。
> 宿主零 python 依赖。单元测试(`conf_test.py`/`parse_test.py`)仍用宿主 python(仅开发期)。

**为什么不用 PyYAML**:离线环境不保证有第三方库,而 `parse.py` 已确立"纯 python3
stdlib"是本仓库风格。模板/配置是简单 YAML 子集(标量、列表、一层嵌套),用一个 ~50 行的
子集解析器即可,零依赖、可复现。

### 职责
1. 读 `./config.yaml`(缺失 → 报错并提示 `make config`)。
2. 定模板名:`$TEMPLATE`(命令行 override)优先,否则 `config.template`。
3. 读 `templates/<name>.yaml`。
4. **合并(优先级 低→高)**:模板默认 → `config.overrides` → 命令行环境变量(白名单)。
5. **校验**:`axis ∈ {parallel, prompt_len}`;轴=parallel 时 `parallel`/`number` 等长;
   端点三要素齐全;数据集在枚举内。
6. 输出 shell `export` 行(列表以空格连接,正确引号)。

### 输出契约(供 `run.sh` / `smoke` `eval`)
```
export URL=... MODEL=... KEY=...
export TOKENIZER_MODE=online TOKENIZER_ID=... TOKENIZER_SOURCE=modelscope   # 或 TOKENIZER_PATH
export IMG=...
export TEMPLATE=inference-baseline DATASET=share_gpt_en
export AXIS=parallel
export PARALLEL="4 8 16 32" NUMBER="60 80 120 160"     # parallel 轴
export PROMPT_LENS="1024 8192 32768 131072"            # prompt_len 轴(另一轴时为空)
export MIN_TOKENS=128 MAX_TOKENS=256
export ROUNDS=3 SEED=42
export TTFT_SLO=1500 ITL_SLO=200
```

命令行 override 走环境变量白名单(`TEMPLATE PARALLEL NUMBER ROUNDS PROMPT_LENS
MIN_TOKENS MAX_TOKENS KEY SEED`):`make run TEMPLATE=chat-slo PARALLEL="8 16"` 即覆盖。

## 6 · 命令(Makefile)

| 命令 | 作用 |
|---|---|
| `make config` | 交互填端点 / tokenizer / 选模板 → 写 `config.yaml`;结尾 `docker pull` 镜像 +(在线)预取 tokenizer 验连通(**吸收原 `install`**) |
| `make smoke` | 所选模板单档小跑(`parallel=4 number=8`,`prompt_len` 轴取最短一档),验链路;镜像缺则懒拉 |
| `make run` | 按模板全量扫,产出独立 `out/<run-id>/` |
| `make parse` | 解析最新一次 run(默认 `out/latest`,或 `make parse RUN=<id>`)找 SLO 拐点 |
| `make clean` | 清 `out/*` |

`make`(默认目标 help)列出以上;可用模板在 `make config` 交互时列出(扫 `templates/*.yaml`
的 `desc`)。`make setup` / `make install` 移除。

镜像/ tokenizer 懒加载:`smoke`/`run` 开头 `ensure_image`(`docker image inspect $IMG ||
docker pull $IMG`)+ `ensure_tokenizer`(沿用现有在线拉/离线校验逻辑)。

## 7 · 每次 run 独立产物

**run-id** = `<时间戳>-<模板名>`,如 `20260713-153012-context-length`(时间戳取
`date +%Y%m%d-%H%M%S`)。

- 产物落 `out/<run-id>/`,并 `ln -sfn <run-id> out/latest`。
- **自描述**:`run.sh` 在 run 目录写 `run.json`,记录 `{template, scenario, axis, dataset,
  parallel, number, prompt_lens, tokens, rounds, seed, slo, model, timestamp}`(**不含 key**)。
  `parse.py` 据此还原轴与 SLO,无需依赖环境变量 —— 每个 run 目录都能独立解析。
- 好处:不同模板/版本结果互不覆盖、可横向对比;每次全新目录**天然绕开** evalscope
  "见旧 `benchmark_data.db` 拒跑"的坑,**删掉现有 `rm -rf out/round*` hack**。

### 输出目录布局
```
out/<run-id>/
  run.json
  round1/                                  # 冷缓存
    # axis=parallel:
    sweep/parallel_<P>_number_<N>/benchmark_{summary,percentile}.json + benchmark_data.db
    # axis=prompt_len:
    len<L>/sweep/parallel_<P>_number_<N>/benchmark_*.json + benchmark_data.db
  round2/ ...                              # 暖缓存
```

## 8 · `run.sh` 泛化

```
source lib.sh
eval "$(python3 conf.py)"          # 载入所有变量
ensure_image; ensure_tokenizer
RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"; OUT="out/$RUN_ID"; mkdir -p "$OUT"
ln -sfn "$RUN_ID" out/latest
写 run.json
for r in 1..ROUNDS:
  if AXIS=parallel:
    docker run ... --parallel $PARALLEL --number $NUMBER \
      --min-tokens $MIN_TOKENS --max-tokens $MAX_TOKENS --stream --seed $SEED \
      --outputs-dir "$OUT/round$r" --name sweep --no-timestamp
  if AXIS=prompt_len:
    for L in $PROMPT_LENS:
      docker run ... --parallel $PARALLEL --number $NUMBER \
        --min-prompt-length $L --max-prompt-length $L \
        --min-tokens $MIN_TOKENS --max-tokens $MAX_TOKENS --stream --seed $SEED \
        --outputs-dir "$OUT/round$r/len$L" --name sweep --no-timestamp
```

`parallel` 轴保留 evalscope **原生多档 ladder**(单次 docker run 跑完整档、暖机共享,
零回归);`prompt_len` 轴因 evalscope 的 `--min/max-prompt-length` 是标量,shell 逐长度 loop。

`make smoke` 复用同一逻辑,单档小值(`--parallel 4 --number 8`,`prompt_len` 轴取
`prompt_lens` 最短一档),不写 `run.json`、不进 `out/latest`。

## 9 · `parse.py` 泛化

现状按 `parallel` 分组、SLO 从环境变量读。改为:

1. 入参:run 目录(默认 `out/latest`,或 `RUN=<id>` → `out/<id>`)。
2. 读 `run.json` 得 `axis` 与 `slo`(仍允许 `TTFT_SLO`/`ITL_SLO` 环境变量覆盖)。
3. **分组键随轴切换**:
   - `axis=parallel`:glob `round*/sweep/parallel_*_number_*`,按并发分组(现状)。
   - `axis=prompt_len`:glob `round*/len*/sweep/parallel_*`,按长度分组;表头"并发"→"输入长度"。
4. 复用现有稳健口径:丢 round1 冷轮 → 每档丢前 `WARMUP_DROP` 条连接预热 → 暖轮逐请求样本
   池化 → 算一次 p95;吞吐取暖轮 summary 均值。
5. **SLO 拐点语义随轴**:
   - `parallel` 轴:满足 SLO 的**最大并发**(现状)。
   - `prompt_len` 轴:满足 SLO 的**最长输入长度**(再长即越线),直接对应"输入长度敏感性"表。
6. 输出:表 + `◀ 拐点` + `out/<run-id>/summary.csv`。

## 10 · 首批模板(5 个)

| 模板 | 轴 | 数据集 | 要点 | scenario |
|---|---|---|---|---|
| `inference-baseline` | parallel | share_gpt_en | short 口径 TTFT/TPOT 基线(= 现状默认) | inference |
| `long-context-kv` | parallel | longalpaca | 8K 长 prompt、冷/暖 A/B,看 KV/前缀缓存命中与稳态 | engine-kv-cache |
| `chat-slo` | parallel | share_gpt_en | 客服口径 SLO:TTFT p95≤1.5s / ITL p95≤200ms,找最大并发 | inference |
| `throughput-max` | parallel | share_gpt_en | 高并发压满、放宽 SLO,测峰值吞吐(tok/s)与饱和点 | capacity |
| `context-length` | prompt_len | random | 输入长度敏感性 1K/8K/32K/128K,TTFT/吞吐衰减 | context-length |

## 11 · `SCENARIOS.md`(根部,跨工具词表)

从 `modeldoctor/packages/tool-adapters/src/scenarios.ts` 导出一张表:scenario id → label →
描述 → 涉及工具 → runbook 当前覆盖状态。示例行:

| scenario | 描述 | 工具 | runbook 状态 |
|---|---|---|---|
| inference | TTFT/TPOT/单次吞吐基线 | guidellm · evalscope · aiperf | evalscope ✅ |
| capacity | SLO 驱动的负载阶梯扫描 | guidellm | evalscope 近似(throughput-max)|
| engine-kv-cache | 引擎 KV/前缀缓存有效性 | evalscope · aiperf | evalscope ✅ |
| context-length | 输入长度敏感性(runbook 扩展)| evalscope · aiperf | evalscope ✅ |
| gateway | 网关/HTTP 链路性能 | vegeta | 规划 |
| agent | Agent 多轮工具调用评测 | tau3 | 规划 |

后续工具(aiperf / guidellm / vegeta)沿用同一 `templates/` + `conf.py` + Makefile 形态,
各自实现同名场景;helm 部署另起 `helm/`,复用模板 YAML 作为 values 输入(后续设计)。

## 12 · 脱敏红线

- **入库**:`templates/*.yaml`、`config.example.yaml`、`SCENARIOS.md`、脚本、文档 —— 均无真实值。
- **不入库**(`.gitignore`):`config.yaml`、`tok/`、`out/`。`.gitignore` 增加 `config.yaml`
  与 `config.example.yaml` 的**豁免**(`!config.example.yaml`)。
- `run.json` **不写 key**(只记 model / 端点无密钥字段可选)。
- README 脱敏章节把 `.env` 改述为 `config.yaml`;自查命令不变。

## 13 · 测试

- **`conf.py` 单元测试**(`conf_test.py`,stdlib `unittest`,`python3 conf_test.py`):
  喂样例 `config.yaml` + `templates/*.yaml`,断言 `export` 输出(两种轴、override 优先级、
  缺字段报错、parallel/number 不等长报错)。
- **YAML 子集解析器**:针对标量/列表/嵌套/注释/空行的小样例断言。
- **`parse.py`**:用 fixture(一个含 `run.json` + 假 `benchmark_data.db` 的 run 目录)
  跑两种轴的分组与拐点判定。
- **集成冒烟**:每个模板 `make smoke TEMPLATE=<x>` 过单档链路;`context-length` 冒烟取最短
  长度,防 128K 拖垮。

## 14 · 迁移(文件级改动清单)

| 动作 | 文件 |
|---|---|
| 新增 | `templates/{inference-baseline,long-context-kv,chat-slo,throughput-max,context-length}.yaml`、`conf.py`、`conf_test.py`、`config.example.yaml`、`../SCENARIOS.md` |
| 改名 | `setup.sh` → `config.sh`(改为写 `config.yaml`);`env.sh` → `lib.sh`(去掉变量装载,留 `ensure_image`/`ensure_tokenizer`)|
| 删除 | `install.sh`、`.env.example`(被 `config.example.yaml` 取代)|
| 改写 | `Makefile`(目标收敛)、`run.sh`(sweep 轴 + run-id + run.json)、`parse.py`(按轴分组 + 读 run.json)、`RUNBOOK.md`、`README.md`(命令与脱敏更新)|

## 15 · 待验证 / 风险

1. **evalscope `random` 长度语义**(§3.4 备注):实现前必须核实旗标与单位,决定 `context-length`
   能否精确命中 1K/8K/32K/128K 及 128K 是否越镜像上限。
2. **`--min-prompt-length == --max-prompt-length`** 是否被 evalscope 接受(等值定长)。
3. **`long-context-kv` 的 KV 命中率**依赖被测后端吐 `KV Cache Hit Rate (%)`;后端不吐时该列留空,
   不算失败。
4. **多轴 parse 的 p95 只在样本足够时可信**(现状 `par ≥ 8`、`p99 需 n ≥ 500` 的告诫沿用)。
