# QM Skill 添加、凭据配置与权限控制指南

本文面向 QM 组织管理员，说明如何添加包含 `SKILL.md`、脚本和其他附件的 Skill，如何安全配置第三方 API Key，以及如何只允许指定用户或团队使用该能力。

示例仓库：<https://github.com/chuanyu1/qm-skills>

## 1. 核心概念

QM 中应把以下三件事分开管理：

1. **Skill Pack**：Git 仓库来源，负责版本、同步和升级。
2. **Skill Scope**：Skill 对哪些个人、团队或组织可见。
3. **Service Credential ACL**：哪些个人或团队能调用共享凭据。这才是保护第三方 API Key 的强制授权边界。

建议 Skill Scope 与 Service Credential ACL 使用相同范围。否则可能出现用户能看到 Skill，但调用时收到 `not_entitled` 的情况。

## 2. Skill 仓库结构

QM 支持非单文件 Skill，不需要把脚本合并进 `SKILL.md`：

```text
qm-skills/
├── README.md
└── tavily/
    ├── SKILL.md
    └── scripts/
        └── tavily.sh
```

导入后会在 Agent 工作区中物化为：

```text
skills/tavily/SKILL.md
skills/tavily/scripts/tavily.sh
```

因此 Skill 文档应使用稳定路径执行附件：

```bash
bash skills/tavily/scripts/tavily.sh search "query" 5
```

不要假设当前目录就是 Skill 目录，也不要依赖 Git 可执行位。

## 3. 注册 Skill Pack

进入 **Admin → Skills**：

1. 在 Register pack 中输入仓库 HTTPS URL。
2. 可在 Advanced 中指定分支或固定提交 SHA。
3. 点击 **Register**。
4. 注册成功后点击 **Browse**。
5. 勾选需要导入的 Skill。
6. 选择目标个人、团队或组织 Scope。
7. 点击 **Import**。

常规仓库地址：

```text
https://github.com/chuanyu1/qm-skills.git
```

固定提交可实现可重复部署；跟随 `main` 则便于后续直接 Sync。

### 导入个人 Skill 创建器

`create-skill-for-qm` 是组织级基础 Skill，负责指导 Agent 通过 QM self-API 创建数据库持久化的单文件个人 Skill。建议管理员将它导入 `org:local`，让所有已授权用户都能使用创建流程；它本身不会让用户获得组织管理权限。

导入并新建个人会话后，用以下请求验收：

> 请使用 create-skill-for-qm，为我创建一个名为 check-public-link 的个人 Skill，并返回平台生成的 Skill ID、published 状态和 personal scope。

验收时确认：

1. Agent 返回的平台记录包含 `verified: true`、`status: published` 和 `scopeId: personal:<当前邮箱>`。
2. 当前邮箱登录 `/skills` 后能看到新 Skill；切换成另一个邮箱后不应看到它。
3. 新建个人会话后，工作区中出现 `skills/check-public-link/SKILL.md`。
4. 在频道或群聊内执行时，创建器应拒绝并提示改到个人会话，避免把共享范围误报为个人范围。

`POST /v1/skills` 当前只支持 `name`、`description` 和 `body`。需要脚本或附件的 Skill 仍必须作为 Git Skill Pack 由管理员导入到指定范围。

### 导入 MinerU v3 PDF 解析器

`mineru-v3-pdf-parser` 解析 PDF 和图片，特别适合扫描版 PDF。公开 Skill Pack 不保存内部主机、端口或凭据；管理员必须先配置 `MINERU_API_URL`。

进入 **Admin → Governance → Credentials → Shared service credentials**，添加以下记录：

| 字段 | 配置值 |
| --- | --- |
| Slug | `mineru-api-url` |
| Display name | `MinerU API URL` |
| Delivery | `Sandbox env` |
| Env var | `MINERU_API_URL` |
| Secret | 完整的内部 MinerU 基础地址，不带末尾 `/` |
| Enabled | 开启 |

保存后新建会话；已运行的 Sandbox 不会自动获得新环境变量。`Sandbox env` 会把该值注入组织内所有内部会话，个人/团队 Grant 不会限制 Env 投递。Skill Scope 只控制 Skill 的发现和物化，不是 MinerU 的访问控制。如果服务地址也需要按用户保密或授权，应改为启用 MinerU 认证并使用 Broker，或在网络层限制来源。

导入到目标 Scope 后，新建会话并依次验收：

1. 要求 Agent 执行 `bash skills/mineru-v3-pdf-parser/scripts/mineru.sh health`，确认返回 `status: healthy`。
2. 上传一份不含敏感信息的扫描测试 PDF，明确要求使用 `--method ocr`。
3. 确认脚本返回 `status: completed` 且 `markdown_chars` 大于 0。
4. 确认 Agent 能把 `parsed.md` 作为文件附件交付，而不是只返回 Sandbox 路径。

如果健康检查提示缺少变量，检查 Env var 是否精确填写为 `MINERU_API_URL`、记录是否启用，并新建会话。如果连接失败，检查管理员保存的地址、QM Sandbox 到 MinerU 的路由和防火墙。若以后启用 Egress enforcement，应仅放行实际 MinerU 主机和端口；若 MinerU 后续启用 Token，应通过 QM Service credential Broker 管理，不要把密钥写入 Skill 仓库。

### GitHub 链路超时

如果 Status 显示：

```text
error — git clone timed out after 60000ms
```

说明 QM 服务器直连 GitHub 超时，不是 Skill 格式错误。对公开仓库可改用经过验证的 GitHub 加速 URL：

```text
https://ghfast.top/https://github.com/chuanyu1/qm-skills.git
```

第三方加速地址会看到公开仓库 URL，因此只应用于公开仓库。私有仓库不要经过公共镜像，应使用组织认可的网络代理和 Deploy Token。

### 内网自建 Git 仓库

当前 QM 的 Skill Pack 拉取器只接受**不含用户名、密码或 Token 的 HTTPS URL**，并会拒绝解析到内网、回环或链路本地地址的主机。这是防止管理员界面的 Git URL 被利用进行服务端请求伪造（SSRF）的安全边界。

因此下面两种地址均不能直接注册：

```text
git-user@private-git-host:group/qm-skills.git
http://private-git-host:3000/group/qm-skills.git
```

- 第一种是 SSH/scp 形式，不是 HTTPS。
- 第二种既是 HTTP，又指向私有 IP。
- 即使改成 `https://private-git-host:3000/...`，默认仍会被私网地址校验拒绝。

如需正式支持自建 Git，建议做受控扩展，而不是全局关闭私网保护：

1. 为 Git 服务配置受信 HTTPS 域名，例如 `git.example.internal`，由内网反向代理终止 TLS。
2. 在 QM 增加管理员配置的私有 Git 主机/端口 allowlist，只放行明确主机，例如 `git.example.internal:443`。
3. 继续禁止重定向到未授权主机，并在 DNS 解析后再次校验目标地址。
4. 私有仓库通过 QM 服务端保存的只读 Deploy Token/Deploy Key 取用；不要把 `Administrator`、密码或 Token 写进仓库 URL。
5. 对该 allowlist、凭据使用、同步与失败事件保留审计日志。

在完成该扩展前，可继续把公开 Skill 镜像到 GitHub；私有内容不要经过公共 GitHub 加速服务。

## 4. 配置 Tavily 服务凭据

进入 **Admin → Governance → Credentials → Shared service credentials**，添加或编辑：

| 字段 | 配置值 |
| --- | --- |
| Slug | `tavily` |
| Display name | `Tavily Search` |
| Delivery | `Broker` |
| Env var | 留空；输入框中的 `STEEL_API_KEY` 是示例占位符，只在 `Sandbox env` 投递时使用 |
| Destination host | `api.tavily.com` |
| Secret | Tavily API Key，只在此处录入 |
| Authentication header | `Authorization`，留空也使用该默认值 |
| Value prefix | `Bearer`，留空也使用该默认值 |
| Allowed methods | `POST` |
| Allowed path prefixes | `/search` |
| Enabled | 开启 |

保存前确认右侧 Effective capability：

```text
State: Enabled
Host: api.tavily.com and its subdomains
Auth: Authorization header · prefix “Bearer”
Methods: POST
Paths: /search
Secret: Stored secret retained / Secret set
```

不要使用 **Sandbox env**。Env 交付会把凭据注入 Sandbox；Broker 模式下该字段不参与调用，密钥保留在 Core 内，并可通过个人或团队 ACL 精确控制。

## 5. 权限控制

### 只允许指定用户

在凭据的 **Principals with access** 中：

1. 选择 **Only selected people or teams**。
2. 输入用户的 principal ID，例如：

   ```text
   user@example.com
   ```

3. 在 Effective capability 中确认 Access 显示：

   ```text
   personal:user@example.com
   ```

4. 保存后，凭据列表应显示 `1 principal`，而不是 `Organization-wide`。

### 按团队授权

输入团队 Scope：

```text
team:<team-id>
```

团队成员在会话创建时获得对应的 Broker entitlement。移除团队授权或禁用凭据后，后续会话不再获得该能力。

### 组织范围授权

只有确实需要所有内部用户使用时，才选择 **Everyone in this organization**。共享付费 API Key 默认不建议组织范围开放。

## 6. 安全模型

Broker 模式下：

- Agent 只能看到凭据 slug `tavily`，看不到真实 API Key。
- QM Core 根据当前 principal 和 Scope 签发短期 capability token。
- Broker 再次验证 credential entitlement。
- 请求被限制到 `api.tavily.com`、`POST` 和 `/search`。
- 成功、失败和拒绝调用均可审计。

未授权会话应收到：

```text
not_entitled
```

不要通过对话、Skill 文件、Git 仓库或 Sandbox 环境变量传递 Tavily Key。

## 7. 功能测试

### 授权用户正向测试

重新开始一个授权用户会话，然后提问：

```text
使用 Tavily 搜索 OpenAI 最近一周的官方更新，列出来源链接和信息日期。
```

预期行为：

1. Agent 识别并使用 `tavily` Skill。
2. 调用：

   ```bash
   bash skills/tavily/scripts/tavily.sh search "..." 5
   ```

3. 返回 Tavily 搜索结果和真实来源 URL。
4. 凭据列表的 successful uses 从 0 增加。
5. Audit 中出现对应 principal、Scope 和 credential 使用记录。

如果使用 MiniMax 等 OpenAI 兼容模型，先在会话日志的 **View context sent to the model** 中确认 `tavily` 出现在 `## Skills` 清单。文件型 Skill 不会显示为一个名为 `tavily` 的函数工具。部分模型会忽略“先读取 SKILL.md”的通用规则，因此 frontmatter `description` 应直接给出安全入口命令，并明确禁止探测环境变量、安装同名 SDK 或索取原始密钥；详细步骤仍保留在 `SKILL.md`。同步 Pack 后必须新建会话复测。

### 未授权用户反向测试

使用未授权账号开启新会话并要求 Tavily 搜索。预期：

- 会话不会获得 `tavily` entitlement；
- Broker 返回 `not_entitled`；
- API Key 不会进入 Sandbox；
- Audit 记录拒绝事件。

### 常见错误

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `AGENT_CREDENTIAL_TOKEN` 缺失 | 当前会话没有任何可用共享 Broker 凭据 | 检查 personal/team grant，并新建会话 |
| `AGENT_API_URL` 缺失 | Core 未配置供 Sandbox 回连的 `PUBLIC_API_URL` | 设置为 Sandbox 可访问的 Core URL，重启 Core 后新建会话 |
| Broker URL 连接失败 | `PUBLIC_API_URL` 在 rootless Docker 内不可达；Linux 上的 `host.docker.internal` 映射不一定能回到宿主机 | 从 Sandbox 对候选地址执行只读健康检查，使用可达的宿主机内网地址；不要改成对公网开放的未保护端口 |
| `not_entitled` | 当前 principal/Scope 未获 `tavily` 授权 | 修正 Share with 范围 |
| Tavily 401/403 | 保存的 API Key 无效或失效 | 在后台替换 Secret |
| Tavily 429 | 额度或速率限制 | 降低调用频率、检查套餐 |
| `git clone timed out after 60000ms` | QM 服务器到 GitHub 链路慢 | 公开仓库使用加速 URL，或配置受信代理 |
| Skill 可见但调用失败 | Skill Scope 与凭据 ACL 不一致 | 对齐两者的个人/团队 Scope |

## 8. 更新与回滚

Skill Pack 记录 Git commit。更新流程：

1. 在 Git 仓库修改 Skill 并完成测试。
2. 推送到约定分支。
3. 在 QM Skills 中执行 Sync。
4. 检查候选 Skill、目标 Scope 和变更摘要。
5. 在测试会话验证后再扩大授权范围。

需要可重复部署时，将 ref 固定到已验证的 commit SHA。回滚时切回旧 SHA 并重新同步。

## 9. 当前部署注意事项

当前 QM 使用 `local-docker` Sandbox，管理后台显示 Egress enforcement 为 `none`。因此域名 allowlist/denylist 目前只是草案，不能充当网络防火墙。

Service Credential Broker 的 host/method/path/ACL 校验仍在 QM Core 强制执行，能够保护共享 Tavily Key；但它不能阻止用户使用自己的密钥访问其他公网服务。
