#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""步骤 5-6:聚合 + 找 SLO 拐点。
稳健口径:丢弃 round1(冷缓存),把 round2+ 的**逐请求原始样本**汇池(每轮再丢前 10 条连接预热),
在池上算一次 p50/p95 —— 而不是对每轮各自 60~160 样本的 p95 取中位(那样 p95 抖得厉害、会非单调)。
原始样本取自各 parallel 目录的 benchmark_data.db(first_chunk_latency=TTFT,inter_token_latencies=ITL)。"""
import os, glob, json, sqlite3, re, csv, sys

RB = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RB, "out")
TTFT_SLO = float(os.environ.get("TTFT_SLO", 1500))   # p95 首 token 延迟阈值 (ms)
ITL_SLO  = float(os.environ.get("ITL_SLO", 200))     # p95 出字间隔阈值 (ms;≈5 tok/s 流式底线)
WARMUP_DROP = int(os.environ.get("WARMUP_DROP", 10)) # 每轮每档丢弃的连接预热请求数

def pct(v, p):
    v = sorted(x for x in v if x == x)
    if not v: return float("nan")
    k = (len(v)-1)*p/100; f = int(k)
    return v[f] if f+1 >= len(v) else v[f] + (v[f+1]-v[f])*(k-f)

def rounds_present():
    return sorted(int(re.search(r"round(\d+)", d).group(1))
                  for d in glob.glob(os.path.join(OUT, "round*")) if re.search(r"round(\d+)", d))

def parallels():
    ps=set()
    for f in glob.glob(os.path.join(OUT, "round*", "sweep", "parallel_*_number_*")):
        m=re.search(r"parallel_(\d+)_number_(\d+)", f)
        if m: ps.add(int(m.group(1)))
    return sorted(ps)

def pool(rounds, c):
    """池化指定轮次里并发档 c 的逐请求 TTFT/ITL/TPOT(ms)与 E2E(s)。"""
    ttft=[]; itl=[]; tpot=[]; e2e=[]
    for r in rounds:
        for db in glob.glob(os.path.join(OUT, f"round{r}", "sweep", f"parallel_{c}_number_*", "benchmark_data.db")):
            try:
                rows=sqlite3.connect(db).execute(
                    "select first_chunk_latency, inter_token_latencies, time_per_output_token, latency from result order by start_time").fetchall()
            except Exception: continue
            for fcl, itls, tp, lat in rows[WARMUP_DROP:]:
                if fcl: ttft.append(fcl*1000)
                if tp:  tpot.append(tp*1000)
                if lat: e2e.append(lat)               # 端到端 (s)
                if itls:
                    try:
                        arr=json.loads(itls) if itls.strip().startswith("[") else [float(x) for x in re.split(r"[,\s]+", itls.strip()) if x]
                        itl += [x*1000 for x in arr if x]
                    except Exception: pass
    return ttft, itl, tpot, e2e

def throughput(rounds, c):
    """输出/请求吞吐:取 warm 轮 summary 的均值(吞吐是速率,稳定,不必池化)。"""
    outs=[]; reqs=[]
    for r in rounds:
        for f in glob.glob(os.path.join(OUT, f"round{r}", "sweep", f"parallel_{c}_number_*", "benchmark_summary.json")):
            s=json.load(open(f))
            try: outs.append(float(s.get("Output Throughput (tok/s)")))
            except Exception: pass
            try: reqs.append(float(s.get("Req Throughput (req/s)")))
            except Exception: pass
    return (sum(outs)/len(outs) if outs else float("nan"),
            sum(reqs)/len(reqs) if reqs else float("nan"))

allr = rounds_present()
warm = [r for r in allr if r != 1] or allr        # 丢冷缓存 round1;若只有 1 轮则退化用它
pars = parallels()
if not pars: sys.exit(f"没有结果:{OUT}(先跑 ./run.sh)")

rows=[]
for c in pars:
    tt, it, tp, e2 = pool(warm, c)
    ct, _, _, _    = pool([1], c) if 1 in allr else ([], [], [], [])
    otps, rps  = throughput(warm, c)
    rows.append({"c":c, "n":len(tt), "tps":otps, "rps":rps,
                 "ttft95":pct(tt,95), "ttft50":pct(tt,50),
                 "itl95":pct(it,95), "itl50":pct(it,50),
                 "tpot50":pct(tp,50), "e2e50":pct(e2,50),
                 "cold95":pct(ct,95) if ct else float("nan")})

# SLO 拐点
knee=None
for r in rows:
    if r["ttft95"]<=TTFT_SLO and r["itl95"]<=ITL_SLO: knee=r
knee_c = knee["c"] if knee else None

# 报告
print(f"\n  被测:DeepSeek-V4-Flash-INT8 · ShareGPT 真实流量 · warm 轮池化(丢 round1 冷缓存 + 每档预热 {WARMUP_DROP} 条)\n")
hdr=f"  {'并发':>4} │ {'池样本':>6} │ {'输出tok/s':>9} {'req/s':>6} │ {'TTFT p95':>9} {'ITL p95':>8} {'TPOT p50':>9}"
print(hdr); print("  "+"─"*(len(hdr)-2))
csv_rows=[["parallel","pool_n","out_tps","req_rps","ttft_p50_ms","ttft_p95_ms",
           "itl_p50_ms","itl_p95_ms","tpot_ms","e2e_p50_s","cold_ttft_p95_ms"]]
for r in rows:
    knee_mark = " ◀ 拐点" if (knee and r["c"]==knee_c) else ""
    over = knee_c is not None and r["c"]>knee_c
    itl = f"\033[91m{r['itl95']:>6.0f}\033[0m" if r["itl95"]>ITL_SLO else f"{r['itl95']:>6.0f}"
    print(f"  {r['c']:>4} │ {r['n']:>6} │ {r['tps']:>9.0f} {r['rps']:>6.2f} │ {r['ttft95']:>7.0f}ms {itl}ms {r['tpot50']:>7.1f}ms{knee_mark}")
    csv_rows.append([r["c"], r["n"], f"{r['tps']:.0f}", f"{r['rps']:.2f}",
                     f"{r['ttft50']:.0f}", f"{r['ttft95']:.0f}",
                     f"{r['itl50']:.0f}", f"{r['itl95']:.0f}", f"{r['tpot50']:.1f}", f"{r['e2e50']:.1f}",
                     f"{r['cold95']:.0f}" if r['cold95']==r['cold95'] else ""])
print("  "+"─"*(len(hdr)-2))
if knee:
    print(f"\n  ✦ SLO 拐点(p95 TTFT≤{TTFT_SLO:.0f}ms 且 p95 ITL≤{ITL_SLO:.0f}ms)= 并发 {knee_c}")
    print(f"    → 该档输出吞吐 {knee['tps']:.0f} tok/s、{knee['rps']:.2f} req/s。峰值档({rows[-1]['c']})虽有 {rows[-1]['tps']:.0f} tok/s,但 ITL p95 已达 {rows[-1]['itl95']:.0f}ms,越过 SLO。")
else:
    print(f"\n  ✦ 无档同时满足 SLO —— 最低并发已越线。")
if any(r["cold95"]==r["cold95"] for r in rows):
    cold_line=" / ".join(f"{r['c']}:{r['cold95']:.0f}ms" for r in rows if r['cold95']==r['cold95'])
    print(f"  ⓘ 冷启动(round1)TTFT p95:{cold_line} —— 明显高于稳态,故必须预热后再测。")

with open(os.path.join(OUT, "summary.csv"), "w", newline="") as fh:
    csv.writer(fh).writerows(csv_rows)
print(f"\n  → 明细已写 {os.path.join(OUT, 'summary.csv')}\n")
