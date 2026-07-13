# runbook

私有化部署大模型服务的**压测 / 评测 runbook 合集** —— 每个子目录一套可直接照抄的流程(命令 + 脚本),方法为主、工具中立。

## 目录

| 子目录 / 文件 | 内容 |
|---|---|
| [`evalscope/`](./evalscope) | 用我们的 evalscope 镜像(内置 ShareGPT)+ 外挂 tokenizer(在线拉 / 离线挂),对 OpenAI 兼容端点做**模板化**压测(选场景 / 指定 SLO),找 SLO 拐点 |
| [`SCENARIOS.md`](./SCENARIOS.md) | 跨工具共享的**场景词表**(inference / capacity / engine-kv-cache / context-length …),从平台导出 |

> 后续会持续新增(guidellm / aiperf / tau-bench 等),每套独立一个子目录、共用同一套模板形态。

## 用法

每套 runbook 都是 `make` 驱动:

```bash
cd evalscope
make config     # 交互填端点 / tokenizer / 选模板 → 生成 config.yaml
make smoke      # 冒烟
make run        # 按模板扫描(可 make run TEMPLATE=chat-slo 覆盖)
make parse      # 找 SLO 拐点(解析最新一次 run)
```

镜像公开在 `ghcr.io/weetime/`,`make smoke`/`make run` 缺镜像会自动拉取。详见各子目录 `RUNBOOK.md`。

## 脱敏红线(提交前必读)

本仓库公开可见,**任何真实端点、密钥、内网信息都不得入库**。约定:

- **真实值只写进 `config.yaml`**(`make config` 生成,已被 `.gitignore` 忽略),仓库里只放 `config.example.yaml` 模板。
- **`tok/`(tokenizer)与 `out/`(压测产物)不入库** —— 产物里会内嵌真实端点/模型名。
- 脚本与文档一律用 `$URL` / `$MODEL` / `$KEY` 变量或 `<占位符>`,不硬编码 IP / key / 内网主机名。
- 提交前自查:`git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|sk-|api[_-]?key' -- ':!*.example'` 应无命中。
