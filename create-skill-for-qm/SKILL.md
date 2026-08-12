---
name: create-skill-for-qm
description: 在 QM 中创建、保存和验证个人范围的 Skill。用户要求 Agent 制作、安装、保存、持久化或更新自己的个人 Skill，或者已在会话的 skills/ 目录写了文件但 /skills 页面看不到时，必须使用此 Skill；通过 QM self-API 注册单文件 Skill，并把包含 scripts、references 或 assets 的多文件需求转入 Git Skill Pack 流程。
---

# 为 QM 创建个人 Skill

把可重复使用的流程注册到 QM 数据库，使它出现在用户的 `/skills` 页面，并在后续会话中自动物化。

## 硬性规则

- 不要把 `mkdir skills/<name>`、写入 `skills/<name>/SKILL.md` 或在当前 Sandbox 中测试通过视为安装成功。`skills/` 是平台投影目录，不是注册入口。
- 个人 Skill 必须通过 `POST /v1/skills` 创建，并通过 `GET /v1/skills/:id` 回读验证。
- 不要输出、记录或写入 `AGENT_API_TOKEN`。请求只通过 `x-agent-capability` 请求头传递它。
- 不要伪造 `principalId` 或 `scopeId`。QM 以当前会话 capability 中的身份和范围为准。
- 只有在平台返回 `status: published`、`scopeId: personal:*` 且回读内容一致后，才能告诉用户创建完成。

## 创建流程

1. 确认用户要保存的是可复用操作流程，而不是普通文件、应用或一次性回答。
2. 为 Skill 选择小写连字符名称，例如 `check-public-link`。描述要明确说明功能和触发场景。
3. 编写简洁、命令式的 Markdown 正文。正文不要重复 YAML frontmatter；`name` 和 `description` 由 API 单独提交。
4. 将正文草稿放在普通工作目录，例如 `work/<name>.md`，不要直接写入 `skills/` 投影目录。
5. 从 Agent 工作区根目录运行：

```bash
bash skills/create-skill-for-qm/scripts/create-personal-skill.sh \
  --name "check-public-link" \
  --description "检查公开链接是否可访问；当用户要求交付或验证网页链接时使用。" \
  --body-file "work/check-public-link.md"
```

6. 检查脚本输出。必须同时满足：

   - `ok` 和 `verified` 都为 `true`；
   - `status` 为 `published`；
   - `scopeId` 以 `personal:` 开头；
   - `name` 与请求的名称一致。

7. 告诉用户 Skill 已持久化，并给出返回的 `id`、`name` 和 `scopeId`。提醒用户刷新 `/skills` 页面；已打开的旧会话不会重新装载 Skill，后续使用应新建会话。

## 范围不正确时

脚本会先调用 `GET /v1/apis` 确认当前 capability 的 `scopeId`。若不是 `personal:*`，停止创建，并让用户在自己的个人聊天中重新提出请求。不要在频道或群聊中创建后再声称它是个人 Skill，因为 API 会把 Skill 归属到当前会话范围。

账户邮箱必须完全一致。不同邮箱或别名会被 QM 视为不同 principal，因此一个账号创建的个人 Skill 不会自动出现在另一个账号的 `/skills` 页面。

## 同名、更新与归档

- `409 exists` 表示当前范围已有同名 Skill。不要自动换名制造副本，也不要覆盖未知内容。
- 让用户从 `/skills` 打开现有 Skill，确认是要编辑的对象并取得其 `id`；随后用 `PUT /v1/skills/:id` 提交明确确认过的 `description` 和/或 `body`。
- 使用 `DELETE /v1/skills/:id` 归档，使用 `POST /v1/skills/:id/restore` 恢复。删除或覆盖前必须得到用户明确授权。
- 更新后同样用 `GET /v1/skills/:id` 回读并核对 `status`、`version` 和正文。

## 多文件 Skill

当前 `POST /v1/skills` 只接受 `name`、`description` 和 `body`，不能附带 `scripts/`、`references/` 或 `assets/`。遇到多文件需求时：

1. 在独立 Git 仓库中创建标准 Skill 目录和 `SKILL.md`。
2. 将脚本、参考资料和资源放入对应子目录并测试。
3. 推送 Git 后，由管理员在 **Admin → Skills → Skill Packs** 注册或同步仓库。
4. 在 **Browse** 中选择该 Skill，并导入到指定个人范围。
5. 新建该用户的个人会话验证脚本路径和权限。

不要把多文件 Skill 降级为一次性 Sandbox 文件后声称它已安装。若用户暂时无法让管理员导入，可在征得同意后把流程简化为不带附件的单文件个人 Skill。

## 失败处理

- 缺少 `AGENT_API_URL` 或 `AGENT_API_TOKEN`：当前环境不是完整 QM Agent Sandbox，或 Core 的 `PUBLIC_API_URL` 未正确注入。停止并报告管理员。
- `/v1/apis` 无法访问：报告 HTTP 状态和平台返回的错误消息，不要打印令牌。
- 创建返回 `401/403`：说明 capability 无效、过期或该会话不允许创建；新建会话重试，仍失败则交给管理员排查。
- 创建成功但回读失败：视为未验证，不要宣称完成；保留返回的 Skill ID 供管理员审计。
