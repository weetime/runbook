# evalscope 测试模板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 runbook/evalscope 从单条硬编码流程改造成模板驱动:committed 场景模板库 + 本地 `config.yaml`,`make run` 可选模板,每次 run 产出独立目录。

**Architecture:** 两类 YAML —— `templates/*.yaml`(入库场景预设,含 sweep 轴 + SLO)与 `config.yaml`(gitignored,端点/tokenizer/选模板)。一个零依赖 `conf.py` 把两者合并输出 shell export 或 JSON;`run.sh` 按 sweep 轴(`parallel` / `prompt_len`)扫描并落 `out/<run-id>/`;`parse.py` 读 `run.json` 自描述、按轴分组找 SLO 拐点。命令收敛到 `config / smoke / run / parse / clean`。

**Tech Stack:** bash + GNU make + python3(仅 stdlib)+ Docker(`ghcr.io/weetime/md-runner-evalscope`,内置 evalscope 1.7.0)。

## Global Constraints

- **零第三方依赖**:所有 python 只用 stdlib(不得 `import yaml` / `numpy` / `pytest`)。`conf.py` 自带 YAML 子集解析器。
- **脱敏红线**:`config.yaml` / `tok/` / `out/` 不入库;`templates/*.yaml`、`config.example.yaml`、`SCENARIOS.md`、脚本、文档均无真实端点/密钥。`run.json` 不含 key。
- **镜像**:默认 `ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2`;调裸 evalscope 必须 `--entrypoint evalscope`。
- **数据集内置路径**(容器内,只读):`longalpaca`→`line_by_line` `/opt/evalscope-datasets/longalpaca.txt`(长度单位=**字符**);`openqa`→`openqa` `/opt/evalscope-datasets/openqa/open_qa.jsonl`;`share_gpt_en/zh`→同名 reader `/opt/evalscope-datasets/sharegpt/common_{en,zh}_70k.jsonl`;`random`→`random`(合成,无文件,长度单位=**token**,`min==max` 得定长)。
- **YAML 子集约定**:模板/配置用块映射 + flow 列表 `[a, b]` + flow 映射 `{k: v}`;**不使用块序列(`- item`)**、锚点、多行标量。缩进 2 空格。
- **sweep 轴**:`parallel`(evalscope 原生多档 ladder,单次 docker run)或 `prompt_len`(shell 逐长度 loop)。
- **run-id 格式**:`$(date +%Y%m%d-%H%M%S)-<template>`。
- 参考设计文档:`docs/superpowers/specs/2026-07-13-evalscope-templates-design.md`。

---

### Task 1: `conf.py` —— 零依赖加载器(YAML 子集解析 + 合并 + 输出)

**Files:**
- Create: `evalscope/conf.py`
- Test: `evalscope/conf_test.py`

**Interfaces:**
- Produces(供 `run.sh`/`smoke` `eval "$(python3 conf.py)"`):导出 `URL MODEL KEY TOKENIZER_MODE {TOKENIZER_ID TOKENIZER_SOURCE | TOKENIZER_PATH} IMG TEMPLATE DS_READER DS_PATH AXIS PARALLEL NUMBER PROMPT_LENS [PROMPT_MIN PROMPT_MAX] MIN_TOKENS MAX_TOKENS ROUNDS SEED TTFT_SLO ITL_SLO`。`PARALLEL/NUMBER/PROMPT_LENS` 为空格连接串。
- Produces(供 `run.sh` 写 `run.json`):`python3 conf.py --json` 打印合并后配置(无 key、无 `_` 前缀内部键)。
- Consumes:`./config.yaml`(或 `$CONFIG`)、`./templates/<name>.yaml`(或 `$TEMPLATES_DIR/<name>.yaml`)、环境覆盖白名单 `TEMPLATE PARALLEL NUMBER ROUNDS PROMPT_LENS MIN_TOKENS MAX_TOKENS SEED KEY`。

- [ ] **Step 1: 写失败测试 `evalscope/conf_test.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""conf.py 单元测试:YAML 子集解析 + 合并/校验/输出。跑:python3 conf_test.py"""
import os, sys, json, tempfile, subprocess, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import conf  # noqa: E402

PARALLEL_TPL = """\
name: t-par
desc: 并发轴样例
scenario: inference
dataset: share_gpt_en
sweep:
  axis: parallel
  parallel: [4, 8, 16]
  number: [60, 80, 120]
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 1500, itl_p95_ms: 200}
"""

LEN_TPL = """\
name: t-len
desc: 长度轴样例
scenario: context-length
dataset: random
sweep:
  axis: prompt_len
  prompt_lens: [1024, 8192, 32768]
  parallel: 8
  number: 64
tokens: {min: 128, max: 256}
rounds: 2
seed: 7
slo: {ttft_p95_ms: 5000, itl_p95_ms: 300}
"""

LONGALPACA_TPL = """\
name: t-la
desc: longalpaca 定窗
scenario: engine-kv-cache
dataset: longalpaca
prompt_len: [8000, 9000]
sweep:
  axis: parallel
  parallel: [1, 8]
  number: [30, 80]
tokens: {min: 160, max: 200}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 3000, itl_p95_ms: 250}
"""

CONFIG = """\
endpoint:
  url: http://HOST:8000/v1/chat/completions
  model: my-model
  key: EMPTY
tokenizer:
  mode: online
  id: org/model
  source: modelscope
template: t-par
"""

class YamlTests(unittest.TestCase):
    def test_scalar_types(self):
        self.assertEqual(conf._scalar("128"), 128)
        self.assertEqual(conf._scalar("1.5"), 1.5)
        self.assertEqual(conf._scalar("true"), True)
        self.assertEqual(conf._scalar('"hi"'), "hi")
        self.assertEqual(conf._scalar("share_gpt_en"), "share_gpt_en")
        self.assertEqual(conf._scalar("[4, 8, 16]"), [4, 8, 16])
        self.assertEqual(conf._scalar("{min: 1, max: 2}"), {"min": 1, "max": 2})

    def test_parse_nested(self):
        d = conf.parse_yaml(PARALLEL_TPL)
        self.assertEqual(d["name"], "t-par")
        self.assertEqual(d["sweep"]["axis"], "parallel")
        self.assertEqual(d["sweep"]["parallel"], [4, 8, 16])
        self.assertEqual(d["tokens"], {"min": 128, "max": 256})
        self.assertEqual(d["slo"]["itl_p95_ms"], 200)

    def test_comment_and_blank(self):
        d = conf.parse_yaml("a: 1  # trailing\n\n# whole line\nb: 2\n")
        self.assertEqual(d, {"a": 1, "b": 2})

class ResolveTests(unittest.TestCase):
    def _dir(self, config=CONFIG, templates=None):
        d = tempfile.mkdtemp()
        tdir = os.path.join(d, "templates"); os.makedirs(tdir)
        for name, body in (templates or {"t-par": PARALLEL_TPL}).items():
            open(os.path.join(tdir, name + ".yaml"), "w").write(body)
        open(os.path.join(d, "config.yaml"), "w").write(config)
        return d, tdir

    def _resolve(self, env):
        old = dict(os.environ)
        try:
            os.environ.update(env)
            return conf.resolve()
        finally:
            os.environ.clear(); os.environ.update(old)

    def test_parallel_axis(self):
        d, tdir = self._dir()
        r = self._resolve({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir})
        self.assertEqual(r["axis"], "parallel")
        self.assertEqual(r["parallel"], [4, 8, 16])
        self.assertEqual(r["prompt_lens"], [])
        self.assertEqual(r["ds_reader"], "share_gpt_en")
        self.assertEqual(r["slo"]["ttft_p95_ms"], 1500)

    def test_len_axis(self):
        d, tdir = self._dir(config=CONFIG.replace("template: t-par", "template: t-len"),
                            templates={"t-len": LEN_TPL})
        r = self._resolve({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir})
        self.assertEqual(r["axis"], "prompt_len")
        self.assertEqual(r["prompt_lens"], [1024, 8192, 32768])
        self.assertEqual(r["parallel"], [8]); self.assertEqual(r["number"], [64])
        self.assertEqual(r["ds_reader"], "random")

    def test_longalpaca_prompt_len(self):
        d, tdir = self._dir(config=CONFIG.replace("template: t-par", "template: t-la"),
                            templates={"t-la": LONGALPACA_TPL})
        r = self._resolve({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir})
        self.assertEqual(r["prompt_len"], [8000, 9000])

    def test_env_override(self):
        d, tdir = self._dir()
        r = self._resolve({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir,
                          "PARALLEL": "8 16", "ROUNDS": "1", "KEY": "sk-x"})
        self.assertEqual(r["parallel"], [8, 16])
        self.assertEqual(r["rounds"], 1)
        self.assertEqual(r["_key"], "sk-x")

    def test_unequal_lists_fail(self):
        bad = PARALLEL_TPL.replace("number: [60, 80, 120]", "number: [60, 80]")
        d, tdir = self._dir(templates={"t-par": bad})
        with self.assertRaises(SystemExit):
            self._resolve({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir})

    def test_exports_and_json(self):
        d, tdir = self._dir()
        env = dict(os.environ); env.update({"CONFIG": os.path.join(d, "config.yaml"), "TEMPLATES_DIR": tdir})
        exp = subprocess.run([sys.executable, os.path.join(HERE, "conf.py")],
                             env=env, capture_output=True, text=True)
        self.assertIn('export AXIS=parallel', exp.stdout)
        self.assertIn('export PARALLEL=', exp.stdout)
        self.assertIn('export DS_PATH=', exp.stdout)
        js = subprocess.run([sys.executable, os.path.join(HERE, "conf.py"), "--json"],
                            env=env, capture_output=True, text=True)
        obj = json.loads(js.stdout)
        self.assertEqual(obj["axis"], "parallel")
        self.assertNotIn("_key", obj)  # 密钥不进 json

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd evalscope && python3 conf_test.py`
Expected: FAIL —— `ModuleNotFoundError: No module named 'conf'`(conf.py 尚未创建)。

- [ ] **Step 3: 写实现 `evalscope/conf.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""解析 config.yaml + templates/<name>.yaml,合并后输出 shell export(默认)或 JSON(--json)。
零依赖:内置 YAML 子集解析器(标量 / flow 列表 [..] / flow 映射 {..} / 一层块映射)。"""
import os, sys, json, shlex

RB = os.path.dirname(os.path.abspath(__file__))

DATASETS = {
    "longalpaca":   ("line_by_line", "/opt/evalscope-datasets/longalpaca.txt"),
    "openqa":       ("openqa",       "/opt/evalscope-datasets/openqa/open_qa.jsonl"),
    "share_gpt_en": ("share_gpt_en", "/opt/evalscope-datasets/sharegpt/common_en_70k.jsonl"),
    "share_gpt_zh": ("share_gpt_zh", "/opt/evalscope-datasets/sharegpt/common_zh_70k.jsonl"),
    "random":       ("random",       ""),
}
DEFAULT_IMG = "ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2"

# ---------- YAML 子集解析 ----------
def _split(s):
    """按顶层逗号切分,忽略 []{} 内的逗号。"""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip() != "":
        out.append(cur)
    return out

def _scalar(s):
    s = s.strip()
    if s == "":
        return None
    if (s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'"):
        return s[1:-1]
    if s[0] == "[" and s[-1] == "]":
        return [_scalar(x) for x in _split(s[1:-1])]
    if s[0] == "{" and s[-1] == "}":
        d = {}
        for part in _split(s[1:-1]):
            k, _, v = part.partition(":")
            d[k.strip()] = _scalar(v)
        return d
    low = s.lower()
    if low in ("true", "false"):
        return low == "true"
    if low in ("null", "~"):
        return None
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s

def _strip_comment(line):
    depth, q, out = 0, None, ""
    for ch in line:
        if q:
            out += ch
            if ch == q:
                q = None
            continue
        if ch in "\"'":
            q = ch; out += ch; continue
        if ch in "[{":
            depth += 1
        elif ch in "]}":
            depth -= 1
        if ch == "#" and depth == 0:
            break
        out += ch
    return out.rstrip()

def _indent(line):
    return len(line) - len(line.lstrip(" "))

def _block(lines, i, indent):
    d = {}
    while i < len(lines):
        if _indent(lines[i]) < indent:
            break
        key, _, rest = lines[i].strip().partition(":")
        key, rest = key.strip(), rest.strip()
        if rest == "":
            if i + 1 < len(lines) and _indent(lines[i + 1]) > indent:
                child, i = _block(lines, i + 1, _indent(lines[i + 1]))
                d[key] = child
            else:
                d[key] = None; i += 1
        else:
            d[key] = _scalar(rest); i += 1
    return d, i

def parse_yaml(text):
    lines = [l for l in (_strip_comment(r) for r in text.splitlines()) if l.strip() != ""]
    if not lines:
        return {}
    val, _ = _block(lines, 0, _indent(lines[0]))
    return val

# ---------- 合并 / 校验 ----------
def _load(path):
    with open(path, "r", encoding="utf-8") as f:
        return parse_yaml(f.read())

def _envlist(name, default):
    v = os.environ.get(name)
    if v is None:
        return default
    return [int(x) if x.lstrip("-").isdigit() else x for x in v.split()]

def resolve():
    cfg_path = os.environ.get("CONFIG", os.path.join(RB, "config.yaml"))
    if not os.path.exists(cfg_path):
        sys.exit("✗ 未找到 config.yaml —— 先跑:make config")
    cfg = _load(cfg_path)
    ep = cfg.get("endpoint") or {}
    tk = cfg.get("tokenizer") or {}
    ov = cfg.get("overrides") or {}

    tdir = os.environ.get("TEMPLATES_DIR", os.path.join(RB, "templates"))
    tmpl_name = os.environ.get("TEMPLATE") or cfg.get("template")
    if not tmpl_name:
        sys.exit("✗ config.yaml 缺 template,且未传 TEMPLATE=")
    tpath = os.path.join(tdir, tmpl_name + ".yaml")
    if not os.path.exists(tpath):
        sys.exit(f"✗ 模板不存在:{tpath}")
    t = _load(tpath)

    sweep = dict(t.get("sweep") or {})
    for k in ("axis", "parallel", "number", "prompt_lens"):
        if k in ov:
            sweep[k] = ov[k]
    axis = sweep.get("axis")
    dataset = ov.get("dataset", t.get("dataset"))
    tokens = t.get("tokens") or {}
    slo = t.get("slo") or {}

    if axis not in ("parallel", "prompt_len"):
        sys.exit(f"✗ 模板 sweep.axis 非法:{axis}")
    if dataset not in DATASETS:
        sys.exit(f"✗ 未知 dataset:{dataset}")
    if axis == "parallel":
        par, num = sweep.get("parallel"), sweep.get("number")
        if not isinstance(par, list) or not isinstance(num, list) or len(par) != len(num):
            sys.exit("✗ parallel 轴:sweep.parallel 与 sweep.number 必须为等长列表")
    else:
        pls = sweep.get("prompt_lens")
        if not isinstance(pls, list) or not pls:
            sys.exit("✗ prompt_len 轴:sweep.prompt_lens 必须为非空列表")
    if not ep.get("url") or not ep.get("model"):
        sys.exit("✗ config.yaml endpoint 缺 url/model")
    mode = tk.get("mode", "online")
    if mode == "online" and not tk.get("id"):
        sys.exit("✗ tokenizer online 模式缺 id")
    if mode == "offline" and not tk.get("path"):
        sys.exit("✗ tokenizer offline 模式缺 path")

    reader, dpath = DATASETS[dataset]
    r = {
        "template": tmpl_name, "scenario": t.get("scenario", ""),
        "dataset": dataset, "ds_reader": reader, "ds_path": dpath,
        "axis": axis,
        "rounds": int(os.environ.get("ROUNDS", ov.get("rounds", t.get("rounds", 3)))),
        "seed": int(os.environ.get("SEED", ov.get("seed", t.get("seed", 42)))),
        "min_tokens": int(os.environ.get("MIN_TOKENS", tokens.get("min"))),
        "max_tokens": int(os.environ.get("MAX_TOKENS", tokens.get("max"))),
        "slo": {"ttft_p95_ms": slo.get("ttft_p95_ms"), "itl_p95_ms": slo.get("itl_p95_ms")},
        "model": ep.get("model"), "image": cfg.get("image", DEFAULT_IMG),
    }
    if axis == "parallel":
        r["parallel"] = _envlist("PARALLEL", sweep["parallel"])
        r["number"] = _envlist("NUMBER", sweep["number"])
        r["prompt_lens"] = []
        if t.get("prompt_len"):
            r["prompt_len"] = t["prompt_len"]
    else:
        r["parallel"] = [sweep["parallel"]]
        r["number"] = [sweep["number"]]
        r["prompt_lens"] = _envlist("PROMPT_LENS", sweep["prompt_lens"])
    r["_url"] = ep["url"]
    r["_key"] = os.environ.get("KEY", ep.get("key", "EMPTY"))
    r["_tok"] = {"mode": mode, "id": tk.get("id"),
                 "source": tk.get("source", "modelscope"), "path": tk.get("path")}
    return r

# ---------- 输出 ----------
def emit_exports(r):
    q = lambda v: shlex.quote(str(v))
    join = lambda xs: " ".join(str(x) for x in xs)
    L = [
        f'export URL={q(r["_url"])}', f'export MODEL={q(r["model"])}', f'export KEY={q(r["_key"])}',
        f'export TOKENIZER_MODE={q(r["_tok"]["mode"])}',
    ]
    if r["_tok"]["mode"] == "online":
        L += [f'export TOKENIZER_ID={q(r["_tok"]["id"])}', f'export TOKENIZER_SOURCE={q(r["_tok"]["source"])}']
    else:
        L += [f'export TOKENIZER_PATH={q(r["_tok"]["path"])}']
    L += [
        f'export IMG={q(r["image"])}', f'export TEMPLATE={q(r["template"])}',
        f'export DS_READER={q(r["ds_reader"])}', f'export DS_PATH={q(r["ds_path"])}',
        f'export AXIS={q(r["axis"])}',
        f'export PARALLEL={q(join(r["parallel"]))}', f'export NUMBER={q(join(r["number"]))}',
        f'export PROMPT_LENS={q(join(r["prompt_lens"]))}',
    ]
    if r.get("prompt_len"):
        L += [f'export PROMPT_MIN={q(r["prompt_len"][0])}', f'export PROMPT_MAX={q(r["prompt_len"][1])}']
    L += [
        f'export MIN_TOKENS={q(r["min_tokens"])}', f'export MAX_TOKENS={q(r["max_tokens"])}',
        f'export ROUNDS={q(r["rounds"])}', f'export SEED={q(r["seed"])}',
        f'export TTFT_SLO={q(r["slo"]["ttft_p95_ms"])}', f'export ITL_SLO={q(r["slo"]["itl_p95_ms"])}',
    ]
    return "\n".join(L)

def run_json(r):
    return json.dumps({k: v for k, v in r.items() if not k.startswith("_")},
                      ensure_ascii=False, indent=2)

if __name__ == "__main__":
    res = resolve()
    print(run_json(res) if (len(sys.argv) > 1 and sys.argv[1] == "--json") else emit_exports(res))
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd evalscope && python3 conf_test.py`
Expected: PASS —— `Ran 9 tests ... OK`。

- [ ] **Step 5: 提交**

```bash
git add evalscope/conf.py evalscope/conf_test.py
git commit -m "feat(evalscope): conf.py 零依赖 YAML 加载器(config+template→exports/json)"
```

---

### Task 2: 场景模板库 `templates/*.yaml`

**Files:**
- Create: `evalscope/templates/inference-baseline.yaml`
- Create: `evalscope/templates/long-context-kv.yaml`
- Create: `evalscope/templates/chat-slo.yaml`
- Create: `evalscope/templates/throughput-max.yaml`
- Create: `evalscope/templates/context-length.yaml`

**Interfaces:**
- Consumes:Task 1 的 `conf.py`(每个模板须能被 `conf.py` 解析、校验通过)。
- Produces:`make config` 扫 `templates/*.yaml` 的 `name`/`desc` 列出可选模板;`run.sh` 按 `AXIS` 分派。

- [ ] **Step 1: 写 5 个模板文件**

`evalscope/templates/inference-baseline.yaml`:
```yaml
name: inference-baseline
desc: ShareGPT 真实流量、short 口径,TTFT/TPOT 基线并发扫描
scenario: inference
dataset: share_gpt_en
sweep:
  axis: parallel
  parallel: [4, 8, 16, 32]
  number: [60, 80, 120, 160]
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 1500, itl_p95_ms: 200}
```

`evalscope/templates/long-context-kv.yaml`:
```yaml
name: long-context-kv
desc: longalpaca 8K 长 prompt、冷/暖 A/B,看 KV/前缀缓存命中与稳态
scenario: engine-kv-cache
dataset: longalpaca
prompt_len: [8000, 9000]        # 单位=字符(longalpaca line_by_line reader)
sweep:
  axis: parallel
  parallel: [1, 8, 16, 32]
  number: [30, 80, 120, 160]
tokens: {min: 160, max: 200}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 3000, itl_p95_ms: 250}
```

`evalscope/templates/chat-slo.yaml`:
```yaml
name: chat-slo
desc: 客服口径 SLO(TTFT p95≤1.5s / ITL p95≤200ms),找满足 SLO 的最大并发
scenario: inference
dataset: share_gpt_en
sweep:
  axis: parallel
  parallel: [4, 8, 16, 32, 48]
  number: [60, 80, 120, 160, 200]
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 1500, itl_p95_ms: 200}
```

`evalscope/templates/throughput-max.yaml`:
```yaml
name: throughput-max
desc: 高并发压满、放宽 SLO,测峰值吞吐(tok/s)与饱和点
scenario: capacity
dataset: share_gpt_en
sweep:
  axis: parallel
  parallel: [16, 32, 64, 128]
  number: [160, 320, 640, 1280]
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 8000, itl_p95_ms: 500}
```

`evalscope/templates/context-length.yaml`:
```yaml
name: context-length
desc: 输入长度敏感性 — TTFT/吞吐随 prompt 长度衰减(1K/8K/32K/128K,单位=token)
scenario: context-length
dataset: random
sweep:
  axis: prompt_len
  prompt_lens: [1024, 8192, 32768, 131072]
  parallel: 8
  number: 64
tokens: {min: 128, max: 256}
rounds: 3
seed: 42
slo: {ttft_p95_ms: 5000, itl_p95_ms: 300}
```

- [ ] **Step 2: 校验每个模板都能被 conf.py 解析(用临时 config 指定各模板)**

Run:
```bash
cd evalscope
cat > /tmp/rb-config.yaml <<'EOF'
endpoint: {url: http://HOST:8000/v1/chat/completions, model: m, key: EMPTY}
tokenizer: {mode: online, id: org/m, source: modelscope}
template: inference-baseline
EOF
for t in inference-baseline long-context-kv chat-slo throughput-max context-length; do
  echo "== $t =="
  CONFIG=/tmp/rb-config.yaml TEMPLATE=$t python3 conf.py --json | python3 -c 'import sys,json;d=json.load(sys.stdin);print(" axis=",d["axis"],"ds=",d["ds_reader"],"slo=",d["slo"])'
done
```
Expected: 5 个模板全部打印一行 `axis= ... ds= ... slo= {...}`,无 `✗` 报错;`context-length` 显示 `axis= prompt_len ds= random`。

- [ ] **Step 3: 提交**

```bash
git add evalscope/templates/
git commit -m "feat(evalscope): 首批 5 场景模板(inference/kv/chat-slo/throughput/context-length)"
```

---

### Task 3: `config.example.yaml` + `.gitignore`

**Files:**
- Create: `evalscope/config.example.yaml`
- Modify: `.gitignore`
- Delete: `evalscope/.env.example`

**Interfaces:**
- Produces:`config.example.yaml` 是 `config.yaml` 的入库模板;`.gitignore` 保证 `config.yaml` 不入库但放行 `config.example.yaml`。

- [ ] **Step 1: 写 `evalscope/config.example.yaml`**

```yaml
# 复制为 config.yaml 手填,或直接跑 `make config` 交互生成。
# config.yaml 不入库(见 .gitignore);本文件是入库模板,不得含真实端点/密钥。
endpoint:
  url: http://<LAN-IP>:<port>/v1/chat/completions   # 被测端点完整 chat/completions 路径
  model: <服务端注册的模型名>
  key: EMPTY                                          # 网关 key;无则 EMPTY

# Tokenizer(evalscope 数 token 用,不是权重):online 二填其一
tokenizer:
  mode: online                     # online | offline
  id: <org/model,如 deepseek-ai/DeepSeek-V3>
  source: modelscope               # modelscope | hf(hf 走 HF_ENDPOINT,默认 hf-mirror.com)
  # mode: offline
  # path: /abs/path/to/tok         # offline:本机已有 tokenizer 目录(含 tokenizer.json)

template: inference-baseline       # 选用哪个模板(make config 会列出可选)

# image: ghcr.io/weetime/md-runner-evalscope:b6a824c-sharegpt2   # 可选,有内置默认
# overrides:                       # 可选:覆盖所选模板的 load 参数
#   rounds: 2
#   parallel: [8, 16]
```

- [ ] **Step 2: 更新 `.gitignore`(在顶部脱敏段追加 config.yaml 规则)**

把根 `.gitignore` 第 1–7 行区块改为:
```
# 脱敏红线:真实端点/密钥、tokenizer、压测产物一律不入库
.env
**/.env
config.yaml
**/config.yaml
!config.example.yaml
!**/config.example.yaml
tok/
**/tok/
out/
**/out/
```

- [ ] **Step 3: 删除旧模板并核对忽略规则**

Run:
```bash
git rm evalscope/.env.example
touch evalscope/config.yaml
git status --porcelain evalscope/config.yaml evalscope/config.example.yaml
```
Expected: `config.yaml` **不出现**在输出里(被忽略);`config.example.yaml` 显示为 `A`(已追踪)。随后 `rm evalscope/config.yaml`(测试残留)。

- [ ] **Step 4: 提交**

```bash
git add .gitignore evalscope/config.example.yaml
git commit -m "feat(evalscope): config.example.yaml 取代 .env.example + gitignore 收 config.yaml"
```

---

### Task 4: `lib.sh`(由 env.sh 改名)+ `ensure_image`;删除 install.sh

**Files:**
- Rename: `evalscope/env.sh` → `evalscope/lib.sh`
- Delete: `evalscope/install.sh`

**Interfaces:**
- Consumes:由 `conf.py` eval 出的 `IMG TOKENIZER_MODE TOKENIZER_ID TOKENIZER_SOURCE TOKENIZER_PATH`(调用方须先 `eval "$(python3 conf.py)"` 再调这些函数)。
- Produces:`ensure_image`(镜像缺则 pull);`ensure_tokenizer`(导出 `TOK_DIR`,校验含 tokenizer + chat_template);`fetch_tokenizer`。

- [ ] **Step 1: 改名**

```bash
git mv evalscope/env.sh evalscope/lib.sh
git rm evalscope/install.sh
```

- [ ] **Step 2: 改写 `evalscope/lib.sh`**

把开头「载入 .env + 校验 + 导出 IMG/SG/负载参数」的段落(原 4–28 行)整体替换为下面内容;`TOK_PATTERNS`、`_have_tokenizer`、`_have_chat_template`、`fetch_tokenizer`、`ensure_tokenizer` 原样保留(即原文件 30 行至文件末尾)。新开头:

```bash
#!/usr/bin/env bash
# evalscope runbook · 公共 shell 逻辑(被 run.sh source)。
# 变量装载由 conf.py 负责:调用方须先 `eval "$(python3 conf.py)"` 再用这里的函数。
export RB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 镜像缺则拉取(吸收原 install)。IMG 由 conf.py 导出。
ensure_image() {
  : "${IMG:?IMG 未设置(应由 conf.py 导出)}"
  docker image inspect "$IMG" >/dev/null 2>&1 || { echo "↓ 拉取镜像:$IMG"; docker pull "$IMG"; }
}
```

保留段落从原 `# 在线拉取时只取 tokenizer 相关文件...`(原 30 行)起,到文件结尾 `ensure_tokenizer()` 全部逻辑不动。删除原文件里对 `SG`、`PARALLEL`、`NUMBER`、`ROUNDS`、`MIN_TOKENS`、`MAX_TOKENS`、`OUT` 的 export(这些已归 conf.py / run.sh)。

- [ ] **Step 3: 语法校验**

Run: `cd evalscope && bash -n lib.sh && echo OK`
Expected: `OK`(无语法错误)。

- [ ] **Step 4: 提交**

```bash
git add -A evalscope/lib.sh
git commit -m "refactor(evalscope): env.sh→lib.sh + ensure_image,删 install.sh(变量装载归 conf.py)"
```

---

### Task 5: `run.sh` 重写(sweep 轴 + run-id + run.json)

**Files:**
- Modify: `evalscope/run.sh`(整体重写)

**Interfaces:**
- Consumes:`lib.sh`(`ensure_image`/`ensure_tokenizer`,后者导出 `TOK_DIR`);`conf.py` 的 exports 与 `--json`。
- Produces:`./run.sh`(全量扫,落 `out/<run-id>/round*/...` + `out/<run-id>/run.json` + `out/latest` 符号链接);`./run.sh smoke`(单档冒烟,落 `out/smoke/`)。

- [ ] **Step 1: 写测试 shim `evalscope/run_smoke_test.sh`(用假 docker 断言 argv)**

```bash
#!/usr/bin/env bash
# 用假 docker + 离线 tokenizer fixture 验证 run.sh smoke 组出的 evalscope argv。
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# 假 docker:image inspect 返回 0(跳过 pull);perf 调用把 argv 落盘
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

# 离线 tokenizer fixture(带 chat_template,过 ensure_tokenizer 校验)
mkdir -p "$TMP/tok"
printf '{}' > "$TMP/tok/tokenizer.json"
printf '{}' > "$TMP/tok/chat_template.jinja"

cat > "$TMP/config.yaml" <<EOF
endpoint: {url: http://HOST:8000/v1/chat/completions, model: m, key: EMPTY}
tokenizer: {mode: offline, path: $TMP/tok}
template: context-length
EOF

export RB_DOCKER_LOG="$TMP/argv.log"
PATH="$TMP:$PATH" CONFIG="$TMP/config.yaml" ./run.sh smoke

grep -q -- '--dataset' "$TMP/argv.log" || { echo "FAIL: 缺 --dataset"; exit 1; }
grep -q -- 'random'    "$TMP/argv.log" || { echo "FAIL: 缺 random reader"; exit 1; }
grep -q -- '--min-prompt-length' "$TMP/argv.log" || { echo "FAIL: prompt_len 轴应传 --min-prompt-length"; exit 1; }
grep -q -- '1024' "$TMP/argv.log" || { echo "FAIL: smoke 应取最短长度 1024"; exit 1; }
grep -q -- '/work/out/smoke' "$TMP/argv.log" || { echo "FAIL: smoke 输出目录不对"; exit 1; }
echo "run.sh smoke argv OK"
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd evalscope && bash run_smoke_test.sh`
Expected: FAIL(run.sh 尚是旧版,无 `conf.py`/`--min-prompt-length` 逐长度逻辑,断言不过或报错)。

- [ ] **Step 3: 重写 `evalscope/run.sh`**

```bash
#!/usr/bin/env bash
# run:按模板 sweep 轴扫描,每次落独立 out/<run-id>/。`./run.sh smoke` 单档冒烟。
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh
eval "$(python3 conf.py)"          # 载入 URL/MODEL/KEY/IMG/AXIS/PARALLEL/... 等
ensure_image
ensure_tokenizer                   # 导出 TOK_DIR

DOUT="$PWD/out"; mkdir -p "$DOUT"

# 单次 evalscope 调用。$1=容器内 outputs-dir,其余=额外 flag(并发档 / prompt 长度)
_evalscope() {
  local outdir="$1"; shift
  docker run --rm -v "$TOK_DIR:/tok:ro" -v "$DOUT:/work/out" --entrypoint evalscope "$IMG" \
    perf --url "$URL" --api openai --model "$MODEL" --api-key "$KEY" \
      --tokenizer-path /tok \
      --dataset "$DS_READER" ${DS_PATH:+--dataset-path "$DS_PATH"} \
      --min-tokens "$MIN_TOKENS" --max-tokens "$MAX_TOKENS" \
      --stream --seed "$SEED" \
      --name sweep --no-timestamp --outputs-dir "$outdir" "$@"
}

# 冒烟:单档小跑,不写 run-id / run.json
if [ "${1:-run}" = "smoke" ]; then
  echo "==> 冒烟:单档 parallel=4 number=8(只看跑不跑得通)"
  rm -rf "$DOUT/smoke"
  if [ "$AXIS" = "prompt_len" ]; then
    L="$(printf '%s\n' $PROMPT_LENS | sort -n | head -1)"
    _evalscope "/work/out/smoke" --parallel 4 --number 8 --min-prompt-length "$L" --max-prompt-length "$L"
  else
    _evalscope "/work/out/smoke" --parallel 4 --number 8 \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo "==> 冒烟通过即可 make run"
  exit 0
fi

# 全量扫:独立 run 目录
RUN_ID="$(date +%Y%m%d-%H%M%S)-$TEMPLATE"
RDIR="$DOUT/$RUN_ID"; mkdir -p "$RDIR"
python3 conf.py --json > "$RDIR/run.json"
ln -sfn "$RUN_ID" "$DOUT/latest"

echo "被测端点: $URL"
echo "模型:     $MODEL"
echo "模板:     $TEMPLATE(轴=$AXIS)| 轮次: $ROUNDS(round1=冷缓存)"
echo "产物:     out/$RUN_ID(out/latest → 之)"
echo

for r in $(seq 1 "$ROUNDS"); do
  tag=$([ "$r" -eq 1 ] && echo 冷缓存 || echo 暖缓存)
  echo "========== 第 $r/$ROUNDS 轮($tag)=========="
  if [ "$AXIS" = "prompt_len" ]; then
    for L in $PROMPT_LENS; do
      echo "---------- 输入长度 $L ----------"
      _evalscope "/work/out/$RUN_ID/round$r/len$L" \
        --parallel $PARALLEL --number $NUMBER \
        --min-prompt-length "$L" --max-prompt-length "$L"
    done
  else
    _evalscope "/work/out/$RUN_ID/round$r" \
      --parallel $PARALLEL --number $NUMBER \
      ${PROMPT_MIN:+--min-prompt-length "$PROMPT_MIN" --max-prompt-length "$PROMPT_MAX"}
  fi
  echo
done
echo "==> 全部完成 → make parse(默认解析 out/latest)"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd evalscope && bash run_smoke_test.sh`
Expected: `run.sh smoke argv OK`。

- [ ] **Step 5: 提交**

```bash
git add evalscope/run.sh evalscope/run_smoke_test.sh
git commit -m "feat(evalscope): run.sh 按 sweep 轴扫描 + 独立 run 目录 + run.json"
```

---

### Task 6: `parse.py` 重写(按轴分组 + 读 run.json)

**Files:**
- Modify: `evalscope/parse.py`(整体重写)
- Test: `evalscope/parse_test.py`

**Interfaces:**
- Consumes:`out/<run-id>/run.json`(`axis` + `slo`);evalscope 产物 `round*/[len*/]sweep/parallel_*/benchmark_{data.db,summary.json}`。
- Produces:`python3 parse.py [run_dir]`(默认 `out/latest`,或 `RUN=<id>`);打印分档表 + SLO 拐点;写 `<run_dir>/summary.csv`。

- [ ] **Step 1: 写测试 `evalscope/parse_test.py`(构造含 sqlite 的 fixture run 目录)**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""parse.py 集成测试:构造两轴 fixture run 目录(冷 round1 + 暖 round2),断言分组与拐点。"""
import os, sys, json, sqlite3, tempfile, subprocess, unittest
HERE = os.path.dirname(os.path.abspath(__file__))

def make_db(path, ttft_s, itl_s, n=30):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    con = sqlite3.connect(path)
    con.execute("create table result(start_time real, first_chunk_latency real, "
                "inter_token_latencies text, time_per_output_token real, latency real)")
    for i in range(n):
        con.execute("insert into result values (?,?,?,?,?)",
                    (float(i), ttft_s, json.dumps([itl_s, itl_s]), itl_s, ttft_s + itl_s * 10))
    con.commit(); con.close()

def make_summary(path, out_tps=100.0, req_rps=1.0):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump({"Output Throughput (tok/s)": out_tps, "Req Throughput (req/s)": req_rps}, open(path, "w"))

class ParseTests(unittest.TestCase):
    def _run(self, d):
        return subprocess.run([sys.executable, os.path.join(HERE, "parse.py"), d],
                              capture_output=True, text=True)

    def test_parallel_axis_knee(self):
        d = tempfile.mkdtemp()
        json.dump({"axis": "parallel", "template": "t",
                   "slo": {"ttft_p95_ms": 1500, "itl_p95_ms": 200}}, open(os.path.join(d, "run.json"), "w"))
        # par 8 达标(itl 100ms)、par 16 越线(itl 300ms);两轮,round1 冷被丢
        for rnd, ttft in ((1, 2.0), (2, 0.5)):
            for par, itl in ((8, 0.10), (16, 0.30)):
                base = os.path.join(d, f"round{rnd}", "sweep", f"parallel_{par}_number_80")
                make_db(os.path.join(base, "benchmark_data.db"), ttft, itl)
                make_summary(os.path.join(base, "benchmark_summary.json"))
        r = self._run(d)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("拐点", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(d, "summary.csv")))

    def test_prompt_len_axis(self):
        d = tempfile.mkdtemp()
        json.dump({"axis": "prompt_len", "template": "context-length",
                   "slo": {"ttft_p95_ms": 5000, "itl_p95_ms": 300}}, open(os.path.join(d, "run.json"), "w"))
        for rnd, ttft in ((1, 3.0), (2, 1.0)):
            for L, itl in ((1024, 0.10), (32768, 0.20)):
                base = os.path.join(d, f"round{rnd}", f"len{L}", "sweep", "parallel_8_number_64")
                make_db(os.path.join(base, "benchmark_data.db"), ttft, itl)
                make_summary(os.path.join(base, "benchmark_summary.json"))
        r = self._run(d)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("输入长度", r.stdout)   # 表头随轴切换

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd evalscope && python3 parse_test.py`
Expected: FAIL —— `test_prompt_len_axis` 断言 `"输入长度"` 不通过(旧 parse.py 只会按并发、且从固定 `out/` 读、表头写死「并发」)。

- [ ] **Step 3: 重写 `evalscope/parse.py`**

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""聚合 + 找 SLO 拐点。按 run.json 的 sweep 轴分组(并发 或 输入长度)。
稳健口径:丢 round1(冷缓存)→ 每档丢前 WARMUP_DROP 条连接预热 → 暖轮逐请求原始样本汇池 →
在池上算一次 p50/p95(不对每轮 p95 取中位,那样非单调)。样本取自各档 benchmark_data.db。"""
import os, glob, json, sqlite3, re, csv, sys

RB = os.path.dirname(os.path.abspath(__file__))

def _run_dir():
    if len(sys.argv) > 1 and sys.argv[1]:
        return sys.argv[1]
    base = os.path.join(RB, "out")
    rid = os.environ.get("RUN")
    if rid:
        return os.path.join(base, rid)
    latest = os.path.join(base, "latest")
    return latest if os.path.exists(latest) else base

OUT = _run_dir()
_meta = {}
_mp = os.path.join(OUT, "run.json")
if os.path.exists(_mp):
    _meta = json.load(open(_mp))
AXIS = _meta.get("axis", "parallel")
_slo = _meta.get("slo") or {}
TTFT_SLO = float(os.environ.get("TTFT_SLO", _slo.get("ttft_p95_ms") or 1500))
ITL_SLO  = float(os.environ.get("ITL_SLO",  _slo.get("itl_p95_ms")  or 200))
WARMUP_DROP = int(os.environ.get("WARMUP_DROP", 10))
IS_LEN = (AXIS == "prompt_len")
LABEL = "输入长度" if IS_LEN else "并发"

def pct(v, p):
    v = sorted(x for x in v if x == x)
    if not v:
        return float("nan")
    k = (len(v) - 1) * p / 100; f = int(k)
    return v[f] if f + 1 >= len(v) else v[f] + (v[f + 1] - v[f]) * (k - f)

def rounds_present():
    return sorted(int(re.search(r"round(\d+)", d).group(1))
                  for d in glob.glob(os.path.join(OUT, "round*")) if re.search(r"round(\d+)", d))

def _leaf_glob(round_no, key):
    if IS_LEN:
        return os.path.join(OUT, f"round{round_no}", f"len{key}", "sweep", "parallel_*_number_*")
    return os.path.join(OUT, f"round{round_no}", "sweep", f"parallel_{key}_number_*")

def groups():
    """枚举所有档位的 key(长度轴=各 len 值;并发轴=各 parallel 值)。"""
    keys = set()
    if IS_LEN:
        for f in glob.glob(os.path.join(OUT, "round*", "len*", "sweep", "parallel_*_number_*")):
            m = re.search(r"[/\\]len(\d+)[/\\]", f + os.sep)
            if m:
                keys.add(int(m.group(1)))
    else:
        for f in glob.glob(os.path.join(OUT, "round*", "sweep", "parallel_*_number_*")):
            m = re.search(r"parallel_(\d+)_number_", f)
            if m:
                keys.add(int(m.group(1)))
    return sorted(keys)

def _dbs(round_no, key):
    return glob.glob(os.path.join(_leaf_glob(round_no, key), "benchmark_data.db"))

def _summaries(round_no, key):
    return glob.glob(os.path.join(_leaf_glob(round_no, key), "benchmark_summary.json"))

def pool(rounds, key):
    """池化指定轮次里某档的逐请求 TTFT/ITL/TPOT(ms)与 E2E(s)。"""
    ttft, itl, tpot, e2e = [], [], [], []
    for r in rounds:
        for db in _dbs(r, key):
            try:
                rows = sqlite3.connect(db).execute(
                    "select first_chunk_latency, inter_token_latencies, time_per_output_token, latency "
                    "from result order by start_time").fetchall()
            except Exception:
                continue
            for fcl, itls, tp, lat in rows[WARMUP_DROP:]:
                if fcl: ttft.append(fcl * 1000)
                if tp:  tpot.append(tp * 1000)
                if lat: e2e.append(lat)
                if itls:
                    try:
                        arr = json.loads(itls) if itls.strip().startswith("[") \
                            else [float(x) for x in re.split(r"[,\s]+", itls.strip()) if x]
                        itl += [x * 1000 for x in arr if x]
                    except Exception:
                        pass
    return ttft, itl, tpot, e2e

def throughput(rounds, key):
    outs, reqs = [], []
    for r in rounds:
        for f in _summaries(r, key):
            s = json.load(open(f))
            try: outs.append(float(s.get("Output Throughput (tok/s)")))
            except Exception: pass
            try: reqs.append(float(s.get("Req Throughput (req/s)")))
            except Exception: pass
    return (sum(outs) / len(outs) if outs else float("nan"),
            sum(reqs) / len(reqs) if reqs else float("nan"))

allr = rounds_present()
warm = [r for r in allr if r != 1] or allr
keys = groups()
if not keys:
    sys.exit(f"没有结果:{OUT}(先跑 make run)")

rows = []
for c in keys:
    tt, it, tp, e2 = pool(warm, c)
    ct, _, _, _ = pool([1], c) if 1 in allr else ([], [], [], [])
    otps, rps = throughput(warm, c)
    rows.append({"c": c, "n": len(tt), "tps": otps, "rps": rps,
                 "ttft95": pct(tt, 95), "ttft50": pct(tt, 50),
                 "itl95": pct(it, 95), "itl50": pct(it, 50),
                 "tpot50": pct(tp, 50), "e2e50": pct(e2, 50),
                 "cold95": pct(ct, 95) if ct else float("nan")})

# SLO 拐点:满足 SLO 的最后一档(并发轴=最大并发;长度轴=最长输入)
knee = None
for r in rows:
    if r["ttft95"] <= TTFT_SLO and r["itl95"] <= ITL_SLO:
        knee = r
knee_c = knee["c"] if knee else None

tmpl = _meta.get("template", "?")
print(f"\n  模板:{tmpl}(轴={AXIS})· warm 轮池化(丢 round1 冷缓存 + 每档预热 {WARMUP_DROP} 条)\n")
hdr = f"  {LABEL:>6} │ {'池样本':>6} │ {'输出tok/s':>9} {'req/s':>6} │ {'TTFT p95':>9} {'ITL p95':>8} {'TPOT p50':>9}"
print(hdr); print("  " + "─" * (len(hdr) - 2))
csv_rows = [[AXIS, "pool_n", "out_tps", "req_rps", "ttft_p50_ms", "ttft_p95_ms",
             "itl_p50_ms", "itl_p95_ms", "tpot_ms", "e2e_p50_s", "cold_ttft_p95_ms"]]
for r in rows:
    knee_mark = " ◀ 拐点" if (knee and r["c"] == knee_c) else ""
    itl = f"\033[91m{r['itl95']:>6.0f}\033[0m" if r["itl95"] > ITL_SLO else f"{r['itl95']:>6.0f}"
    print(f"  {r['c']:>6} │ {r['n']:>6} │ {r['tps']:>9.0f} {r['rps']:>6.2f} │ "
          f"{r['ttft95']:>7.0f}ms {itl}ms {r['tpot50']:>7.1f}ms{knee_mark}")
    csv_rows.append([r["c"], r["n"], f"{r['tps']:.0f}", f"{r['rps']:.2f}",
                     f"{r['ttft50']:.0f}", f"{r['ttft95']:.0f}",
                     f"{r['itl50']:.0f}", f"{r['itl95']:.0f}", f"{r['tpot50']:.1f}", f"{r['e2e50']:.1f}",
                     f"{r['cold95']:.0f}" if r['cold95'] == r['cold95'] else ""])
print("  " + "─" * (len(hdr) - 2))
if knee:
    kind = "最长输入长度" if IS_LEN else "最大并发"
    print(f"\n  ✦ SLO 拐点(p95 TTFT≤{TTFT_SLO:.0f}ms 且 p95 ITL≤{ITL_SLO:.0f}ms)= {LABEL} {knee_c}({kind})")
    print(f"    → 该档输出吞吐 {knee['tps']:.0f} tok/s、{knee['rps']:.2f} req/s。")
else:
    print(f"\n  ✦ 无档同时满足 SLO —— 最低档已越线。")
if any(r["cold95"] == r["cold95"] for r in rows):
    cold_line = " / ".join(f"{r['c']}:{r['cold95']:.0f}ms" for r in rows if r['cold95'] == r['cold95'])
    print(f"  ⓘ 冷启动(round1)TTFT p95:{cold_line} —— 明显高于稳态,故必须预热后再测。")

with open(os.path.join(OUT, "summary.csv"), "w", newline="") as fh:
    csv.writer(fh).writerows(csv_rows)
print(f"\n  → 明细已写 {os.path.join(OUT, 'summary.csv')}\n")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd evalscope && python3 parse_test.py`
Expected: PASS —— `Ran 2 tests ... OK`;`test_prompt_len_axis` 输出含「输入长度」,`test_parallel_axis_knee` 输出含「拐点」且生成 `summary.csv`。

- [ ] **Step 5: 提交**

```bash
git add evalscope/parse.py evalscope/parse_test.py
git commit -m "feat(evalscope): parse.py 按 sweep 轴分组 + 读 run.json 自描述"
```

---

### Task 7: `config.sh`(由 setup.sh 改名)—— 交互写 config.yaml

**Files:**
- Rename: `evalscope/setup.sh` → `evalscope/config.sh`

**Interfaces:**
- Consumes:`templates/*.yaml`(列出 `name`/`desc` 供选)。
- Produces:`evalscope/config.yaml`(端点 + tokenizer + template);结尾提示下一步。

- [ ] **Step 1: 改名**

```bash
git mv evalscope/setup.sh evalscope/config.sh
```

- [ ] **Step 2: 重写 `evalscope/config.sh`**

```bash
#!/usr/bin/env bash
# 交互式向导:一步步填信息 → 生成 config.yaml(不入库)。
set -euo pipefail
cd "$(dirname "$0")"
CFG="$PWD/config.yaml"

if [ -f "$CFG" ]; then
  read -r -p "config.yaml 已存在,覆盖?(y/N) " a
  [[ "$a" =~ ^[Yy]$ ]] || { echo "已取消。"; exit 0; }
fi

ask() { local p="$1" d="${2:-}" v; read -r -p "  $p${d:+ [$d]}: " v; printf '%s' "${v:-$d}"; }

echo "evalscope runbook · 交互式配置 → 生成 config.yaml"
echo
echo "── 被测端点(OpenAI 兼容)──"
URL="";   while [ -z "$URL" ];   do URL=$(ask "端点 URL(完整 /v1/chat/completions,必填)"); done
MODEL=""; while [ -z "$MODEL" ]; do MODEL=$(ask "模型名(服务端注册,必填)"); done
KEY=$(ask "API Key(无则 EMPTY)" "EMPTY")

echo
echo "── Tokenizer(evalscope 数 token 用,不是权重)──"
echo "  1) 在线拉取:填模型仓库 id,自动下 tokenizer 到 ./tok"
echo "  2) 离线目录:填本机已有 tokenizer 目录"
M=$(ask "选择 1/2" "1")
if [ "$M" = "2" ]; then
  TMODE=offline
  TPATH=""; while [ -z "$TPATH" ]; do TPATH=$(ask "tokenizer 目录绝对路径"); done
else
  TMODE=online
  TID="";  while [ -z "$TID" ];  do TID=$(ask "模型仓库 id(如 deepseek-ai/DeepSeek-V3)"); done
  TSRC=$(ask "拉取源 modelscope/hf" "modelscope")
fi

echo
echo "── 选测试模板 ──"
for f in templates/*.yaml; do
  n=$(grep -E '^name:' "$f" | head -1 | sed 's/^name:[[:space:]]*//')
  d=$(grep -E '^desc:' "$f" | head -1 | sed 's/^desc:[[:space:]]*//')
  printf '  · %-18s %s\n' "$n" "$d"
done
TPL=$(ask "模板名" "inference-baseline")
[ -f "templates/$TPL.yaml" ] || { echo "✗ 模板不存在:templates/$TPL.yaml" >&2; exit 1; }

{
  echo "# evalscope runbook · config.sh 生成 —— 含真实端点/密钥,勿入库(见 .gitignore)"
  echo "endpoint:"
  echo "  url: \"$URL\""
  echo "  model: \"$MODEL\""
  echo "  key: \"$KEY\""
  echo "tokenizer:"
  echo "  mode: $TMODE"
  if [ "$TMODE" = offline ]; then
    echo "  path: \"$TPATH\""
  else
    echo "  id: \"$TID\""
    echo "  source: $TSRC"
  fi
  echo "template: $TPL"
} > "$CFG"

echo
echo "✓ 已写 $CFG"
echo "下一步:make smoke && make run && make parse"
```

- [ ] **Step 3: 校验语法 + 生成物能被 conf.py 解析**

Run:
```bash
cd evalscope
bash -n config.sh && echo "syntax OK"
# 无既有 config.yaml 时不发「覆盖?」那步的 y;交互项依次:URL/MODEL/KEY/模式/仓库id/源/模板
printf 'http://HOST:8000/v1/chat/completions\nmy-model\nEMPTY\n1\norg/model\nmodelscope\ncontext-length\n' | ./config.sh
CONFIG="$PWD/config.yaml" python3 conf.py --json | python3 -c 'import sys,json;print("axis=",json.load(sys.stdin)["axis"])'
rm -f config.yaml
```
Expected: `syntax OK`;向导跑完写出 `config.yaml`;末行打印 `axis= prompt_len`(选了 context-length)。清理测试 config.yaml。

- [ ] **Step 4: 提交**

```bash
git add -A evalscope/config.sh
git commit -m "feat(evalscope): setup.sh→config.sh,交互生成 config.yaml + 列模板"
```

---

### Task 8: `Makefile` 收敛到 config/smoke/run/parse/clean

**Files:**
- Modify: `evalscope/Makefile`(整体重写)

**Interfaces:**
- Consumes:`config.sh` `run.sh` `parse.py`。
- Produces:`make config|smoke|run|parse|clean`;`TEMPLATE=`/`RUN=` 透传给底层脚本。

- [ ] **Step 1: 重写 `evalscope/Makefile`**

```makefile
# evalscope 压测 runbook · make help 看所有目标
SHELL := /bin/bash
.DEFAULT_GOAL := help
.PHONY: help config smoke run parse clean

help: ## 显示帮助
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-9s\033[0m %s\n",$$1,$$2}'

config: ## 交互配端点/tokenizer/选模板 → 写 config.yaml(含拉镜像+预取 tokenizer 由 run/smoke 懒执行)
	@./config.sh

smoke: ## 冒烟:所选模板单档小跑,验全链路(镜像缺则懒拉)
	@./run.sh smoke

run: ## 按模板全量扫,产出独立 out/<run-id>/(可 TEMPLATE=xxx 覆盖)
	@./run.sh

parse: ## 解析最新一次 run(默认 out/latest,或 RUN=<id>),找 SLO 拐点
	@python3 parse.py

clean: ## 清空压测产物(out/*)
	@rm -rf out/* && echo "cleaned"
```

- [ ] **Step 2: 校验目标可列出**

Run: `cd evalscope && make help`
Expected: 列出 `config / smoke / run / parse / clean` 五个目标及中文说明;无 `setup`/`install`。

- [ ] **Step 3: 提交**

```bash
git add evalscope/Makefile
git commit -m "feat(evalscope): Makefile 收敛到 config/smoke/run/parse/clean"
```

---

### Task 9: `SCENARIOS.md` + 文档更新(README / RUNBOOK)

**Files:**
- Create: `SCENARIOS.md`(仓库根)
- Modify: `README.md`(仓库根)
- Modify: `evalscope/RUNBOOK.md`

**Interfaces:**
- Produces:根部场景词表 + 更新后的命令/脱敏说明,与新命令一致。

- [ ] **Step 1: 写 `SCENARIOS.md`(仓库根)**

```markdown
# 场景词表(SCENARIOS)

压测/评测按**场景**组织,跨工具复用同一套 `templates/` 形态。场景定义源自平台
`modeldoctor/packages/tool-adapters/src/scenarios.ts`,这里导出为离线可读版本。

| scenario | 描述 | 涉及工具 | runbook 当前状态 |
|---|---|---|---|
| `inference` | TTFT / TPOT / 单次吞吐基线 | guidellm · evalscope · aiperf | evalscope ✅(inference-baseline / chat-slo)|
| `capacity` | SLO 驱动的负载阶梯扫描 | guidellm | evalscope 近似(throughput-max)|
| `engine-kv-cache` | 引擎 KV / 前缀缓存有效性(冷/暖 A/B)| evalscope · aiperf | evalscope ✅(long-context-kv)|
| `context-length` | 输入长度敏感性(1K/8K/32K/128K,runbook 扩展)| evalscope · aiperf | evalscope ✅(context-length)|
| `gateway` | 网关 / HTTP 链路性能 | vegeta | 规划 |
| `lb-strategy` | 负载均衡策略验证(路由/缓存复用)| aiperf | 规划 |
| `agent` | Agent 多轮工具调用评测(τ³-bench)| tau3 | 规划 |

## 约定

- 每个工具一个子目录,自带 `templates/*.yaml` + `conf.py` + `Makefile`,命令统一为
  `config / smoke / run / parse / clean`。
- 模板 = 一个 sweep 轴(`parallel` 或 `prompt_len`)+ 固定旋钮 + 默认 SLO;详见各子目录
  `RUNBOOK.md` 与 `docs/superpowers/specs/2026-07-13-evalscope-templates-design.md`。
- 后续 helm 部署复用同一批模板 YAML 作为 values 输入(另行设计)。
```

- [ ] **Step 2: 更新根 `README.md`**

把「目录」表格下方与「用法」代码块替换为反映新命令的版本:目录表增加一行
`SCENARIOS.md` 说明;用法块改为
```bash
cd evalscope
make config     # 交互填端点 / tokenizer / 选模板 → 生成 config.yaml
make smoke      # 冒烟
make run        # 按模板扫描(可 make run TEMPLATE=chat-slo 覆盖)
make parse      # 找 SLO 拐点(解析最新一次 run)
```
并把「脱敏红线」小节里出现的 `.env`(第 32 行「真实值只写进 `.env`…」)改述为
`config.yaml`(`make config` 生成,已被 `.gitignore` 忽略),`.env.example` 改为
`config.example.yaml`。其余脱敏条目不变。

- [ ] **Step 3: 更新 `evalscope/RUNBOOK.md`**

- TL;DR 命令块与「文件清单」表按新命令/新文件改写:
  `make config / smoke / run / parse`;文件清单去掉 `setup.sh`/`install.sh`/`.env.example`,
  加入 `config.sh`/`conf.py`/`lib.sh`/`templates/`/`config.example.yaml`。
- 第 1 节「配置」改述为 `make config` 写 `config.yaml`,并说明**选模板**这一步。
- 第 2 节「安装」删除(install 已并入 config/run 懒执行);顺延章节号。
- 新增一节「测试模板」:列 5 个模板一句话用途 + `make run TEMPLATE=<x>` + `context-length`
  的 1K/8K/32K/128K 输入长度敏感性说明 + 每次 run 独立目录(`out/<run-id>/` + `out/latest`)。
- 「找拐点」节说明 SLO 现由模板携带、可 `TTFT_SLO=/ITL_SLO=` 或 `RUN=<id>` 覆盖。

- [ ] **Step 4: 校验链接与命令一致性**

Run:
```bash
cd /Users/fangyong/vllm/runbook
grep -rnE '\bmake (setup|install)\b' README.md evalscope/RUNBOOK.md && echo "残留旧命令(需清)" || echo "无旧命令残留 OK"
test -f SCENARIOS.md && echo "SCENARIOS OK"
```
Expected: `无旧命令残留 OK` 与 `SCENARIOS OK`。

- [ ] **Step 5: 提交**

```bash
git add SCENARIOS.md README.md evalscope/RUNBOOK.md
git commit -m "docs: SCENARIOS 场景词表 + README/RUNBOOK 对齐新命令与模板"
```

---

## 最终集成验证(可选,需一个可达的 OpenAI 兼容端点)

在真实端点上端到端跑一遍,确认全链路:
```bash
cd evalscope
make config                          # 填真实端点 + 选 inference-baseline
make smoke                           # 单档验证
make run TEMPLATE=context-length     # 输入长度敏感性
make parse                           # 看 1K/8K/32K/128K 的 TTFT/吞吐衰减表
ls out/                              # 应见 <时间戳>-context-length/ 与 latest 符号链接
```

## Self-Review Notes

- **Spec 覆盖**:目录规划→Task 2/3/9;模板 schema→Task 2;config.yaml→Task 3/7;conf.py→Task 1;
  命令收敛→Task 8;独立 run 产物→Task 5;run.sh 泛化→Task 5;parse.py 泛化→Task 6;
  首批 5 模板→Task 2;SCENARIOS.md→Task 9;脱敏→Task 3/9;测试→Task 1/5/6。§15 待验证项(random
  长度语义/128K/min==max)已在计划前坐实(tokens、min==max 定长、128K 无插件上限)。
- **类型一致性**:conf.py 导出的 `DS_READER/DS_PATH/AXIS/PARALLEL/NUMBER/PROMPT_LENS/PROMPT_MIN/
  PROMPT_MAX/MIN_TOKENS/MAX_TOKENS/ROUNDS/SEED/TTFT_SLO/ITL_SLO` 与 run.sh 消费的变量名逐一对应;
  run.json 的 `axis`/`slo` 与 parse.py 读取键一致。
- **无占位**:各步骤均含可直接落地的完整代码/命令;无 TBD/TODO/「类似上文」。
```
