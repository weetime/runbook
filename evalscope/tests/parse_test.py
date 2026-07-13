#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""parse.py 集成测试:构造两轴 fixture run 目录(冷 round1 + 暖 round2),断言分组与拐点。"""
import os, sys, json, sqlite3, tempfile, subprocess, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 上级目录含 parse.py

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
    def _run(self, d, axis, ttft_slo, itl_slo):
        env = dict(os.environ)
        env.update({"AXIS": axis, "TTFT_SLO": str(ttft_slo), "ITL_SLO": str(itl_slo), "TEMPLATE": "t"})
        return subprocess.run([sys.executable, os.path.join(ROOT, "parse.py"), d],
                              env=env, capture_output=True, text=True)

    def test_parallel_axis_knee(self):
        d = tempfile.mkdtemp()
        # par 8 达标(itl 100ms)、par 16 越线(itl 300ms);两轮,round1 冷被丢
        for rnd, ttft in ((1, 2.0), (2, 0.5)):
            for par, itl in ((8, 0.10), (16, 0.30)):
                base = os.path.join(d, f"round{rnd}", "sweep", f"parallel_{par}_number_80")
                make_db(os.path.join(base, "benchmark_data.db"), ttft, itl)
                make_summary(os.path.join(base, "benchmark_summary.json"))
        r = self._run(d, "parallel", 1500, 200)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("拐点", r.stdout)
        self.assertTrue(os.path.exists(os.path.join(d, "summary.csv")))

    def test_prompt_len_axis_autodetect(self):
        # 不传 AXIS,靠目录结构(round*/len*)自动识别为长度轴
        d = tempfile.mkdtemp()
        for rnd, ttft in ((1, 3.0), (2, 1.0)):
            for L, itl in ((1024, 0.10), (32768, 0.20)):
                base = os.path.join(d, f"round{rnd}", f"len{L}", "sweep", "parallel_8_number_64")
                make_db(os.path.join(base, "benchmark_data.db"), ttft, itl)
                make_summary(os.path.join(base, "benchmark_summary.json"))
        env = dict(os.environ)
        for k in ("AXIS", "TTFT_SLO", "ITL_SLO"):
            env.pop(k, None)
        r = subprocess.run([sys.executable, os.path.join(ROOT, "parse.py"), d],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("输入长度", r.stdout)   # 表头随轴切换(自动识别)

if __name__ == "__main__":
    unittest.main()
