# QM Skills

Skills adapted for the QM agent platform.

管理员操作、权限控制、测试与排障请参阅 [QM Skill 添加、凭据配置与权限控制指南](docs/QM_SKILL_ADMIN_GUIDE.md)。

## Create personal skill for QM

The `create-skill-for-qm` foundation skill teaches an agent to register a durable, single-file personal Skill through QM's self-API and verify that it is published in the current `personal:*` scope. It deliberately rejects channel/group scope and never treats files written into the transient `skills/` projection as an installed Skill.

Import `create-skill-for-qm` into the organization scope so every authorized user can invoke it. Users should run the creation request from their personal chat; the resulting native Skill then appears in that exact account's `/skills` page. Different email principals do not share personal Skills.

The current native API accepts only `name`, `description`, and Markdown `body`. Skills that require `scripts/`, `references/`, or `assets/` must remain Git Skill Packs and be imported by an administrator into the intended scope.

Example request after import:

> 请使用 create-skill-for-qm，为我创建一个个人 Skill：在交付网页链接前检查 HTTP 状态、Content-Type 和页面标题，并把平台返回的 Skill ID 和 personal scope 告诉我。

## MinerU v3 PDF parser

The `mineru-v3-pdf-parser` skill parses PDF and image files through the internal MinerU v3 API, with an OCR-first workflow for scanned documents. It uses resumable `submit`/`resume` calls instead of holding one Agent execution open, then writes verified UTF-8 Markdown plus the raw JSON response and task metadata.

The repository contains no internal hostname, port, or credential. A QM administrator must inject the private service base URL as `MINERU_API_URL` through Sandbox env delivery, then import the Skill into the intended scopes. PDF contents are sent to that configured service, so only upload documents the user explicitly asked to process.

Example request after import:

> 请使用 mineru-v3-pdf-parser 对这份扫描版合同执行 OCR，语言选中英文，输出 Markdown，并检查金额、日期和表格是否识别完整。

## Tavily search

The `tavily` skill lets an agent search the web through Tavily without exposing the Tavily API key to the sandbox. The script calls QM's service credential broker, which injects the key on the server and enforces the configured user/team grant, hostname, HTTP method, and path restrictions.

### 1. Configure the service credential

In the QM organization admin page, add a **Service credential** with these values:

| Field | Value |
| --- | --- |
| Slug | `tavily` |
| Name | `Tavily Search` |
| Delivery | `Broker` |
| Host | `api.tavily.com` |
| Authentication header | `Authorization` |
| Value prefix / scheme | `Bearer` |
| Allowed methods | `POST` |
| Allowed path prefixes | `/search` |
| Secret | Your Tavily API key |
| Share with | Only the approved people or teams |

Do not use **Env** delivery. Broker delivery keeps the key out of the agent sandbox and supports per-person/team grants.

### 2. Register this repository as a Skill Pack

In **Admin → Skills**:

1. Register `https://github.com/chuanyu1/qm-skills.git`.
2. Use `main` as the ref, or pin a commit SHA for reproducible deployments.
3. Open **Browse**.
4. Select `tavily` and the target personal/team scopes.
5. Import it.

When the repository changes, use the Skill Pack sync action to update the imported copy.

### 3. Test it

Start a new authorized conversation and ask:

> 使用 Tavily 搜索 OpenAI 最近一周的官方更新，列出来源链接。

The agent runs the materialized script at:

```bash
bash skills/tavily/scripts/tavily.sh search "OpenAI official updates in the last week" 5
```

If the script reports that `AGENT_CREDENTIAL_TOKEN` is missing, the conversation is not entitled to the `tavily` service credential. Check the credential's **Share with** grants.

## Security notes

- No API key is stored in this repository or printed by the script.
- The credential broker pins requests to `api.tavily.com` and can restrict them to `POST /search`.
- Skill visibility and service credential grants should use the same personal/team scopes.
- QM's local Docker sandbox does not enforce domain egress policy. The broker still protects the shared Tavily key, but it is not a general-purpose network firewall.
