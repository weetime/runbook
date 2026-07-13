#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""conf.py 单元测试:YAML 子集解析 + 合并/校验/输出。跑:python3 conf_test.py"""
import os, sys, json, tempfile, subprocess, unittest
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)          # 上级目录含 conf.py
sys.path.insert(0, ROOT)
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
        exp = subprocess.run([sys.executable, os.path.join(ROOT, "conf.py")],
                             env=env, capture_output=True, text=True)
        self.assertIn('export AXIS=parallel', exp.stdout)
        self.assertIn('export PARALLEL=', exp.stdout)
        self.assertIn('export DS_PATH=', exp.stdout)
        js = subprocess.run([sys.executable, os.path.join(ROOT, "conf.py"), "--json"],
                            env=env, capture_output=True, text=True)
        obj = json.loads(js.stdout)
        self.assertEqual(obj["axis"], "parallel")
        self.assertNotIn("_key", obj)  # 密钥不进 json

if __name__ == "__main__":
    unittest.main()
