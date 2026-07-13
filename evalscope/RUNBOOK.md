# evalscope 压测 RUNBOOK(镜像版)

> 形态:**我们的 evalscope 镜像**(内置 evalscope 1.7.0 + ShareGPT 70k)+ **外挂 tokenizer**(本机 `-v` 挂载)+ **OpenAI 兼容端点**。
> 客户端不需要 GPU、不加载权重,只要能连到被测端点 + 一个 tokenizer 数 token。
>
> 配套脚本:`env.sh`(配置)· `run.sh`(扫并发)· `parse.py`(聚合找拐点)。

## 0 · 前置事实(镜像里有什么)

| 项 | 值 |
|---|---|
| 镜像 | `md-runner-evalscope:b6a824c-sharegpt2`(evalscope 1.7.0,`[perf]` extra) |
| 内置 ShareGPT | `/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl`(70k 真实多轮英文) |
| 其它内置集 | `/opt/evalscope-datasets/longalpaca.txt`、`/opt/evalscope-datasets/openqa/open_qa.jsonl` |
| 镜像默认 ENTRYPOINT | `python -m runner` → **调裸 evalscope 必须加 `--entrypoint evalscope`** |
| **不在镜像里** | **tokenizer**(按被测模型外挂) + **被测端点三要素**(URL/MODEL/KEY) |

> 说明:committed 的 base Dockerfile 只烤了 longalpaca + openqa;**ShareGPT 是 `-sharegpt2` 变体**,`common_en_70k.jsonl` 已落在上表路径。自证:
>
> ```bash
> docker run --rm --entrypoint ls "$IMG" /opt/evalscope-datasets/sharegpt
> ```

---

## 1 · 拿 tokenizer(外挂,不是权重)

只下 3 个文件到本机 `./tok/`,**别下几十 GB 权重**:

```bash
mkdir -p tok
# 从 modelscope / HF 只取这三个(以 DeepSeek-V4-Flash 为例):
#   config.json  tokenizer_config.json  tokenizer.json
# 校验:tokenizer.json 应是 MB 级;几百字节的是坏 metadata,删掉重下。
ls -la tok/     # 期望看到 3 个真实文件
```

**坑**:若 `tokenizer_config.json` 缺 `chat_template`(部分权重库剥掉了),多轮 ShareGPT 无法 tokenize → 手动补上该模型的 chat_template。

---

## 2 · 配置(只需改这一处)

三要素放 `.secret.env`(gitignored):

```bash
# .secret.env
export URL="http://<LAN-IP>:<port>/v1/chat/completions"   # 完整 chat/completions 路径
export MODEL="<服务端注册的模型名>"
export KEY="EMPTY"                                          # 网关无 key 就 EMPTY
```

`env.sh` 已就绪,核心变量:

```bash
export IMG="md-runner-evalscope:b6a824c-sharegpt2"
export SG="/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl"  # 镜像内 ShareGPT
export TOK="$RB/tok"        # 外挂 tokenizer 目录
export OUT="$RB/out"
export PAR="4 8 16 32"      # 并发档
export NUM="60 80 120 160"  # 与 PAR 逐元素配对(非笛卡尔积);演示规模
export ROUNDS="3"           # round1=冷缓存,2/3=暖缓存
```

---

## 3 · 冒烟(先坐实全链路,单档)

```bash
source ./env.sh
docker run --rm -v "$TOK:/tok" --entrypoint evalscope "$IMG" \
  perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
       --tokenizer-path /tok \
       --dataset share_gpt_en --dataset-path "$SG" \
       --parallel 4 --number 8 \
       --max-tokens 256 --min-tokens 128 --stream --seed 42
```

只看「跑不跑得通」:端点通、tokenizer 数得出 token、无大面积失败。跑不通回查第 1–2 步,别进扫描。

---

## 4 · 扫并发

```bash
./run.sh
```

`run.sh` 核心调用(每轮一次,round1 冷 / 其余暖):

```bash
docker run --rm -v "$TOK:/tok" -v "$OUT:/work/out" --entrypoint evalscope "$IMG" \
  perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
       --tokenizer-path /tok \
       --dataset share_gpt_en --dataset-path "$SG" \
       --parallel $PAR --number $NUM \
       --max-tokens 256 --min-tokens 128 \
       --stream --seed 42 \
       --outputs-dir "/work/out/round$r" --name sweep --no-timestamp
```

方法学要点(不遵守 p95 就是噪声):
- **`--parallel`/`--number` 逐元素配对**,不是笛卡尔积。
- **short 口径**:`--min-tokens 128 --max-tokens 256`,给干净可比的 TTFT/TPOT 基线。
- **确定性**:全程 `--seed 42`,建议服务端 temperature=0。
- **冷/暖分轮**:round1 冷缓存记冷启动代价,round2+ 暖缓存作稳态。
- **重跑前 `rm -rf out/round*`**:evalscope 见旧 `benchmark_data.db` 会拒跑(`run.sh` 已内置)。

---

## 5 · 聚合找拐点

```bash
TTFT_SLO=1500 ITL_SLO=200 python3 parse.py   # 客服 SLO:TTFT p95≤1.5s、ITL p95≤200ms
```

`parse.py` 稳健口径:**丢 round1 冷轮 → 每档再丢前 10 条连接预热 → 把 warm 轮逐请求原始样本池化 → 算一次 p95**(切忌对「每轮 p95」取中位,会非单调)。原始样本取自各 `parallel_*/benchmark_data.db`。

输出:并发档 × 输出 tok/s × TTFT p95 × ITL p95 × TPOT p50,并标出 **◀ 拐点**(同时满足两条 SLO 的最高并发),明细写 `out/summary.csv`。

---

## 编号踩坑清单(按代价排序)

1. **tokenizer 是外挂的**:`--tokenizer-path /tok` 指向真实 3 文件目录(非权重、非几百字节 metadata);缺 `chat_template` 要补;否则 token 数不出、TPOT/吞吐全错。
2. **调裸 evalscope 要 `--entrypoint evalscope`**,否则命中镜像默认 `python -m runner`。
3. **ShareGPT 用镜像内置路径** `--dataset share_gpt_en --dataset-path /opt/evalscope-datasets/sharegpt/common_en_70k.jsonl` —— 无需本机再下。
4. `--parallel` 与 `--number` **逐元素配对**,不是笛卡尔积;写错会跑出与预期不符的并发点。
5. **重跑先 `rm -rf out/round*`**:evalscope 见旧 `benchmark_data.db` 会拒跑。
6. **聚合别对每轮 p95 取中位**(会非单调)→ 丢冷轮 + 池化 warm 逐请求样本,算一次 p95。
7. **p95 只在 par ≥ 8 读**;并发 1 的 p95 是冷启动小样本伪影;p99 需 n ≥ 500。
8. 客户端指标**定位不了瓶颈**:归因需同时抓引擎 `/metrics`(KV 占用 / 排队 / 抢占)。

---

一句话流程:`拿 tokenizer → 填 .secret.env → 冒烟 → ./run.sh 扫并发 → python3 parse.py 找拐点`。全程只挂 tokenizer,ShareGPT 与 evalscope 都在镜像里。
