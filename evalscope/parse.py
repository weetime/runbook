#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""聚合 + 找 SLO 拐点。按 sweep 轴分组(并发 或 输入长度;AXIS 环境变量或目录结构自动识别)。
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

def _detect_axis():
    # 有 round*/len*/ 结构即长度轴,否则并发轴。AXIS 环境变量优先(由 parse.sh 从 run.env 传入)。
    if glob.glob(os.path.join(OUT, "round*", "len*", "sweep", "parallel_*")):
        return "prompt_len"
    return "parallel"

AXIS = os.environ.get("AXIS") or _detect_axis()
TTFT_SLO = float(os.environ.get("TTFT_SLO", 1500))
ITL_SLO  = float(os.environ.get("ITL_SLO", 200))
TEMPLATE = os.environ.get("TEMPLATE", "?")
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

print(f"\n  模板:{TEMPLATE}(轴={AXIS})· warm 轮池化(丢 round1 冷缓存 + 每档预热 {WARMUP_DROP} 条)\n")
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
