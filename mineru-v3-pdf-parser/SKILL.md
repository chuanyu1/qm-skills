---
name: mineru-v3-pdf-parser
description: 使用内网 MinerU v3 API 将 PDF 或图片解析为结构化 Markdown，支持 OCR、表格、公式、图片资产、可恢复异步任务和完整 ZIP 交付。用户要求读取、提取、OCR、转换、总结或分析 PDF，特别是扫描版、图片型、大文件、长耗时、没有文本层、复制文字乱码或普通解析器无法读取的 PDF 时使用；也适用于把 PDF 转成可下载且图片链接不失效的 Markdown 资源包。
---

# 使用 MinerU v3 解析 PDF

通过异步 API 提交文档，并跨多次短调用恢复任务。服务地址必须由管理员通过 `MINERU_API_URL` 注入；仓库不保存内部主机、端口或凭据。

## 执行流程

1. 确认用户已要求处理该文件。PDF 会发送到内网 MinerU 服务；不要上传与请求无关的文件。
2. 判断解析方式：
   - 扫描件、图片型 PDF、没有文本层或复制乱码：使用 `--method ocr`。
   - 原生电子 PDF 且只需文本：使用 `--method txt`。
   - 无法判断或混合文档：使用 `--method auto`。
3. 选择语言。中英混合默认 `ch`；纯英文用 `en`；越南语、法语等拉丁字母语言用 `latin`。完整列表见 [API 参考](references/api.md)。
4. 从 Agent 工作区根目录运行脚本。输出目录必须放在普通工作目录，不要放到只读的 `skills/` 投影目录。
5. 始终先 `submit`，再用相同输出目录执行 `resume`。不要在一次工具调用中长时间轮询，不要启动后台进程，也不要重复上传同一文件。

扫描版 PDF 示例：

```bash
python3 skills/mineru-v3-pdf-parser/scripts/mineru.py submit \
  "uploads/contract.pdf" \
  "work/contract-mineru" \
  --backend pipeline \
  --method ocr \
  --lang ch
```

提交成功会立即返回 `task_id`、`ready: false` 和下一条命令。稍后执行：

```bash
python3 skills/mineru-v3-pdf-parser/scripts/mineru.py resume \
  "work/contract-mineru"
```

若仍在处理，`resume` 返回 `status: pending|processing` 和建议重试间隔，且正常退出；短暂等待后在新的工具调用中再次执行同一命令。若已完成，它会自动保存 Markdown、图片资产、无内嵌 base64 的结果 JSON，并在存在图片时生成 ZIP。MinerU 服务持有任务，Agent 不需要保持 Shell 或后台进程运行。

只要用户仍在等待本次解析，就持续用 `resume` 接续，直到 `ready: true`、明确失败或用户取消。不要把 `pending`、`processing` 或一次 Agent 执行超时当成解析失败，也不要只说“后台运行中”便结束任务。

指定页码范围（从 0 开始，包含首尾页）：

```bash
python3 skills/mineru-v3-pdf-parser/scripts/mineru.py submit \
  "uploads/report.pdf" \
  "work/report-pages-1-10" \
  --method auto \
  --lang ch \
  --start-page 0 \
  --end-page 9
```

服务健康检查：

```bash
python3 skills/mineru-v3-pdf-parser/scripts/mineru.py health
```

## 检查与交付

脚本成功后检查输出目录：

- `parsed.md`：供阅读、总结和交付的 UTF-8 Markdown。
- `images/`：Markdown 引用的图片资产；仅在 MinerU 返回图片时创建。
- `parsed-with-assets.zip`：包含 `parsed.md` 和 `images/` 的完整资源包；仅在存在图片时创建。
- `result.json`：MinerU 结果元数据；图片 base64 已落盘并替换为路径、类型和大小，避免重复占用空间。
- `submission.json`：首次提交返回的任务 ID；后续恢复以它为准。
- `task.json`：最近一次查询的状态、后端和时间信息。
- `request.json`：实际使用的解析选项，不包含凭据。

执行以下检查后再回答用户：

1. 只有 `resume` 输出 `ok: true`、`ready: true`、`status: completed` 后才开始检查和交付。
2. 对非空白文档，确认 `markdown_chars` 大于 0。
3. 阅读 `parsed.md` 的开头、中部和结尾；检查标题层级、段落顺序、表格、页眉页脚和 OCR 字符。
4. 确认 `image_reference_count` 不大于 `image_count`。脚本发现 Markdown 引用了未返回图片时会失败；不要绕过该检查交付残缺文件。
5. 扫描件结果明显缺字或错字时，换用更准确的后端或语言并重跑；中英文使用 `ch`，纯英文使用 `en`。
6. 用户要求总结或分析时，以 `parsed.md` 为来源；保留页码范围和 OCR 可能出错的说明。
7. `image_count > 0` 时，把 `parsed-with-assets.zip` 作为主要下载附件交付；不要只交付单个 Markdown。可同时附上 `parsed.md` 供快速查看，但必须说明独立下载后图片链接不可用。
8. `image_count == 0` 时，直接交付 `parsed.md`。不要只贴 Sandbox 路径或不可点击的文字。

## 选项原则

- 普通文档默认保留 `hybrid-auto-engine`，它是当前服务的高精度、多语言方案。
- 扫描合同、证照和资质材料要求文字忠实时，优先使用 `--backend pipeline --method ocr --lang ch`，降低重复生成风险。
- 默认启用公式和表格识别。只有确认文档不需要时才用 `--formula false` 或 `--table false`。
- 脚本始终请求 `return_images=true`。不要改回 `false`，否则 MinerU 仍可能在 Markdown 中生成 `images/...` 引用，却不返回对应文件。
- 长文档解析可能需要数分钟。每次 `resume` 只查询一次，不占用单次 Agent 执行窗口；任务由 MinerU 服务继续运行。
- `MINERU_API_URL` 是必需配置。通过 `MINERU_HTTP_TIMEOUT_SECONDS` 调整单次 HTTP 超时，通过 `MINERU_RETRY_AFTER_SECONDS` 调整建议重试间隔。
- 不要臆测未返回的文字。OCR 质量不足时明确说明，并建议人工核对关键金额、日期、姓名和合同条款。

## 故障处理

- 缺少 `MINERU_API_URL`：管理员尚未通过 QM Sandbox env 投递服务地址；不要猜测或硬编码地址。
- 健康检查连接失败：当前 Sandbox 无法访问管理员配置的 MinerU 服务，请管理员检查配置、路由、防火墙和 QM Sandbox 网络。
- HTTP 422：文件或参数不符合 API 定义，检查文件格式、页码和语言值。
- 任务 `failed`：报告 MinerU 返回的 `error`，保留任务 ID，不要无限重试。
- 单次调用超时：保留 `submission.json` 和任务 ID，直接用同一输出目录运行 `resume`；不要重新 `submit`。
- 输出目录已有任务：说明该文档已经提交；运行 `resume`，不要删除记录或创建重复任务。
- Markdown 为空：检查文档是否为空白；扫描件应明确使用 `--method ocr` 并选择正确语言。
- Markdown 图片失效：检查 `resume` 是否生成 `images/` 和 `parsed-with-assets.zip`。若提示“引用了未返回的图片”，保留任务 ID 和输出目录并报告服务端返回不完整，不要只交付 Markdown。
