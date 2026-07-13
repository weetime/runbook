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
