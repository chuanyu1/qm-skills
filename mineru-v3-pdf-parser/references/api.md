# MinerU v3 API 参考

## 服务

- 服务地址：由 QM 管理员通过 `MINERU_API_URL` 注入
- 实测版本：`3.0.4`
- OpenAPI：`GET ${MINERU_API_URL}/openapi.json`
- 健康检查：`GET ${MINERU_API_URL}/health`

脚本不保存主机、端口或认证信息，也不发送固定认证头。如果部署以后启用认证，应由管理员使用 QM Service credential Broker 扩展调用流程，不要把凭据写入 Skill。

## 异步接口

推荐使用异步流程：

1. `POST /tasks`：以 `multipart/form-data` 上传文件，HTTP 202 返回 `task_id`。
2. `GET /tasks/{task_id}`：返回 `pending`、`processing`、`completed` 或 `failed`。
3. `GET /tasks/{task_id}/result`：任务完成后取得结果。

同步接口 `POST /file_parse` 接受相同字段，但长文档容易超过单次请求等待时间。

## 上传字段

| 字段 | 默认值 | 说明 |
| --- | --- | --- |
| `files` | 必填 | PDF 或图片，可重复提交该字段 |
| `lang_list` | `ch` | OCR 语言，可重复提交该字段 |
| `backend` | `hybrid-auto-engine` | 解析后端 |
| `parse_method` | `auto` | `auto`、`txt` 或 `ocr` |
| `formula_enable` | `true` | 识别公式 |
| `table_enable` | `true` | 识别表格 |
| `return_md` | `true` | 返回 Markdown |
| `return_middle_json` | `false` | 返回中间 JSON |
| `return_model_output` | `false` | 返回模型原始输出 |
| `return_content_list` | `false` | 返回内容列表 |
| `return_images` | `false` | 返回提取图片 |
| `response_format_zip` | `false` | 返回 ZIP 而非 JSON |
| `return_original_file` | `false` | ZIP 中包含原文件，仅 ZIP 模式有效 |
| `start_page_id` | `0` | 起始页，从 0 开始 |
| `end_page_id` | `99999` | 结束页，从 0 开始，包含该页 |

后端选项：

- `pipeline`：通用、多语言、无幻觉。
- `vlm-auto-engine`：本地高精度，仅中英文。
- `vlm-http-client`：远程 OpenAI 兼容服务，仅中英文，需要 `server_url`。
- `hybrid-auto-engine`：本地高精度、多语言，默认推荐。
- `hybrid-http-client`：远程 OpenAI 兼容服务、多语言，需要 `server_url`。

## OCR 语言

- `ch`：简体中文、英文、繁体中文。
- `ch_lite`、`ch_server`、`japan`、`chinese_cht`：中文、英文、繁体中文、日文。
- `en`：英文。
- `korean`：韩文、英文。
- `latin`：法文、德文、西班牙文、葡萄牙文、越南文等拉丁字母语言。
- `arabic`：阿拉伯文、波斯文、维吾尔文、乌尔都文等。
- `east_slavic`：俄文、白俄罗斯文、乌克兰文、英文。
- `cyrillic`：西里尔字母语言。
- `devanagari`：印地文、马拉地文、尼泊尔文等。
- 另有 `ta`、`te`、`ka`、`th`、`el`。

## 实测响应

提交任务：

```json
{
  "task_id": "uuid",
  "status": "pending",
  "backend": "hybrid-auto-engine",
  "status_url": "<base-url>/tasks/uuid",
  "result_url": "<base-url>/tasks/uuid/result",
  "queued_ahead": 0
}
```

完成结果：

```json
{
  "backend": "hybrid-auto-engine",
  "version": "3.0.4",
  "results": {
    "input": {
      "md_content": "..."
    }
  }
}
```

OpenAPI 没有声明成功响应的具体 schema，因此调用方必须检查 JSON 实际字段，而不能只依赖生成客户端类型。
