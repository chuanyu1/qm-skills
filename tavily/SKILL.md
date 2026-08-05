---
name: tavily
description: Tavily 实时联网搜索（文件型 Skill，不是同名函数工具）。需要联网搜索、查证最新资料、新闻或网页来源时，必须先用 execute 读取 skills/tavily/SKILL.md，再按文档运行 bash skills/tavily/scripts/tavily.sh。
requiredCapabilities:
  - egress:api.tavily.com
---

# Tavily 网络搜索

通过 QM 服务凭据代理调用 Tavily。真实 API Key 只在 QM 服务端注入，不得询问、读取、回显或写入 Tavily API Key。

## 何时使用

- 用户明确要求搜索互联网、查找来源或核实事实。
- 问题依赖最新新闻、价格、版本、政策、人物或其他可能变化的信息。
- 回答需要可核查的网页链接。

稳定且无需联网即可可靠回答的问题，不要为了使用工具而搜索。

## 命令

从 Agent 工作区根目录运行。脚本作为 Skill 附件物化在 `skills/tavily/` 下；不要使用不确定的 `./scripts/...` 相对路径。

基础搜索：

```bash
bash skills/tavily/scripts/tavily.sh search "搜索问题" 5
```

深度搜索（消耗通常更高）：

```bash
bash skills/tavily/scripts/tavily.sh search "搜索问题" 5 --deep
```

搜索并返回较长的原始网页内容片段：

```bash
bash skills/tavily/scripts/tavily.sh extract "搜索问题" 5
```

结果数量可取 1–20，默认 5。

## 回答要求

1. 根据用户问题选择尽量具体的搜索词。
2. 优先使用相关性高、可信、直接支持结论的结果。
3. 区分搜索结果中的事实和自己的推断。
4. 回答中附上实际使用的来源 URL；不要编造标题或链接。
5. 对时间敏感内容注明信息日期。
6. 若结果不足，调整查询后再搜索一次，不要无依据补全。

## 错误处理

- 如果提示缺少 `AGENT_CREDENTIAL_TOKEN`，说明当前用户或会话没有获授权使用 QM 服务凭据 `tavily`，请管理员检查 Service credential 的 Share with 设置。
- 如果返回 `not_entitled`，不要尝试绕过 Broker，也不要要求用户把 API Key 发到对话中。
- 如果 Tavily 返回 401/403，提醒管理员更新后台保存的 Tavily Key。
- 如果返回 429，说明达到速率或额度限制，应减少请求并稍后重试。
