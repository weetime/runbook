# runbook

私有化部署大模型服务的**压测 / 评测 runbook 合集** —— 每个子目录一套可直接照抄的流程(命令 + 脚本),方法为主、工具中立。

## 目录

| 子目录 | 内容 |
|---|---|
| [`evalscope/`](./evalscope) | 用我们的 evalscope 镜像(内置 ShareGPT)+ 外挂 tokenizer(在线拉 / 离线挂),对 OpenAI 兼容端点做并发扫描,找 SLO 拐点 |

> 后续会持续新增(guidellm / aiperf / tau-bench 等),每套独立一个子目录。

## 用法

每套 runbook 都是 `make` 驱动:

```bash
cd evalscope
make setup      # 交互式一步步填端点 / tokenizer / 负载 → 生成 .env
make install    # 拉镜像 +(在线模式)预取 tokenizer
make smoke      # 冒烟
make run        # 扫并发
make parse      # 找 SLO 拐点
```

镜像公开在 `ghcr.io/weetime/`,`make install` 自动拉取。详见各子目录 `RUNBOOK.md`。

## 脱敏红线(提交前必读)

本仓库公开可见,**任何真实端点、密钥、内网信息都不得入库**。约定:

- **真实值只写进 `.env`**(`make setup` 生成,已被 `.gitignore` 忽略),仓库里只放 `.env.example` 模板。
- **`tok/`(tokenizer)与 `out/`(压测产物)不入库** —— 产物里会内嵌真实端点/模型名。
- 脚本与文档一律用 `$URL` / `$MODEL` / `$KEY` 变量或 `<占位符>`,不硬编码 IP / key / 内网主机名。
- 提交前自查:`git grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}|sk-|api[_-]?key' -- ':!*.example'` 应无命中。
