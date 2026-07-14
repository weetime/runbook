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

- 每个工具一个子目录,自带 `templates/*.env` + `Makefile`,命令统一为
  `config / smoke / run / parse / clean`;宿主只需 `bash + make + docker`。
- 模板 = 一个 shell 片段:一个 sweep 轴(`parallel` 或 `prompt_len`)+ 该场景的压测参数 + 默认
  SLO,`make run` 时 `source` 进来自动填充。详见各子目录 `RUNBOOK.md` 与
  `docs/superpowers/specs/2026-07-13-evalscope-templates-design.md`。
- 离线集群跑:`make run MODE=k8s` 渲染自包含 yaml(Secret/ConfigMap/Job)→ `kubectl apply`,
  与 docker 同镜像/契约/产物布局(不引入 helm)。
