# QM Skills

Skills adapted for the QM agent platform.

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
