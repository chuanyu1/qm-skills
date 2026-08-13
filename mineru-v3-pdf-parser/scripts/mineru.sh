#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Parse PDF or image files through the MinerU v3 asynchronous API.

Usage:
  mineru.sh health
  mineru.sh parse <input-file> <output-dir> [options]

Options:
  --method <auto|txt|ocr>          Parsing method (default: auto)
  --lang <language>                OCR language; repeatable (default: ch)
  --backend <backend>              Parsing backend (default: hybrid-auto-engine)
  --start-page <zero-based-page>   First page, inclusive (default: 0)
  --end-page <zero-based-page>     Last page, inclusive (default: 99999)
  --formula <true|false>            Enable formula parsing (default: true)
  --table <true|false>              Enable table parsing (default: true)
  -h, --help                       Show this help

Environment:
  MINERU_API_URL                    API base URL (required; configured by QM admin)
  MINERU_TIMEOUT_SECONDS            Overall parse timeout (default: 1800)
  MINERU_POLL_INTERVAL_SECONDS      Poll interval (default: 3)
  MINERU_HTTP_TIMEOUT_SECONDS       Per-request timeout (default: 60)
EOF
}

fail() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "需要命令 $1，但当前 Sandbox 中未安装"
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_boolean() {
  [[ "$1" == "true" || "$1" == "false" ]]
}

print_http_error() {
  local status="$1"
  local response_file="$2"
  if jq -e . "$response_file" >/dev/null 2>&1; then
    printf 'MinerU 请求失败，HTTP %s: %s\n' "$status" "$(jq -c . "$response_file")" >&2
  else
    printf 'MinerU 请求失败，HTTP %s，响应不是 JSON\n' "$status" >&2
  fi
}

require_api_url() {
  [[ -n "$api_url" ]] || fail "缺少 MINERU_API_URL；请管理员通过 QM Sandbox env 配置 MinerU 服务地址"
  [[ "$api_url" =~ ^https?://[^[:space:]]+$ ]] \
    || fail "MINERU_API_URL 必须是完整的 http:// 或 https:// 地址"
}

api_url="${MINERU_API_URL:-}"
api_url="${api_url%/}"
http_timeout="${MINERU_HTTP_TIMEOUT_SECONDS:-60}"
is_positive_integer "$http_timeout" || fail "MINERU_HTTP_TIMEOUT_SECONDS 必须是正整数"

command_name="${1:-}"
case "$command_name" in
  -h|--help|help|"")
    usage
    exit 0
    ;;
  health)
    require_api_url
    require_command curl
    require_command jq
    health_response="$(curl --silent --show-error --fail --max-time "$http_timeout" "$api_url/health")" \
      || fail "无法连接 MinerU 健康检查: $api_url/health"
    jq -e '.status == "healthy"' >/dev/null <<<"$health_response" \
      || fail "MinerU 健康检查未返回 healthy: $(jq -c . <<<"$health_response" 2>/dev/null || printf '%s' "$health_response")"
    jq . <<<"$health_response"
    exit 0
    ;;
  parse)
    ;;
  *)
    usage >&2
    fail "未知操作: $command_name"
    ;;
esac
shift

require_api_url
require_command curl
require_command jq

input_file="${1:-}"
output_dir="${2:-}"
[[ -n "$input_file" && -n "$output_dir" ]] || {
  usage >&2
  fail "parse 需要输入文件和输出目录"
}
shift 2

method="auto"
backend="hybrid-auto-engine"
start_page=0
end_page=99999
formula_enable=true
table_enable=true
languages=()

while (( $# > 0 )); do
  case "$1" in
    --method)
      (( $# >= 2 )) || fail "--method 缺少值"
      method="$2"
      shift 2
      ;;
    --lang)
      (( $# >= 2 )) || fail "--lang 缺少值"
      languages+=("$2")
      shift 2
      ;;
    --backend)
      (( $# >= 2 )) || fail "--backend 缺少值"
      backend="$2"
      shift 2
      ;;
    --start-page)
      (( $# >= 2 )) || fail "--start-page 缺少值"
      start_page="$2"
      shift 2
      ;;
    --end-page)
      (( $# >= 2 )) || fail "--end-page 缺少值"
      end_page="$2"
      shift 2
      ;;
    --formula)
      (( $# >= 2 )) || fail "--formula 缺少值"
      formula_enable="$2"
      shift 2
      ;;
    --table)
      (( $# >= 2 )) || fail "--table 缺少值"
      table_enable="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "未知参数: $1"
      ;;
  esac
done

[[ -f "$input_file" ]] || fail "找不到输入文件: $input_file"
[[ -s "$input_file" ]] || fail "输入文件为空: $input_file"

case "${input_file##*.}" in
  pdf|PDF) extension="pdf"; mime_type="application/pdf" ;;
  png|PNG) extension="png"; mime_type="image/png" ;;
  jpg|JPG|jpeg|JPEG) extension="jpg"; mime_type="image/jpeg" ;;
  tif|TIF|tiff|TIFF) extension="tiff"; mime_type="image/tiff" ;;
  bmp|BMP) extension="bmp"; mime_type="image/bmp" ;;
  webp|WEBP) extension="webp"; mime_type="image/webp" ;;
  *) fail "仅支持 PDF、PNG、JPEG、TIFF、BMP 或 WebP" ;;
esac

[[ "$method" == "auto" || "$method" == "txt" || "$method" == "ocr" ]] \
  || fail "--method 必须是 auto、txt 或 ocr"
case "$backend" in
  pipeline|vlm-auto-engine|hybrid-auto-engine) ;;
  *) fail "脚本仅支持 pipeline、vlm-auto-engine 或 hybrid-auto-engine；HTTP client 后端需要额外 server_url 配置" ;;
esac
is_nonnegative_integer "$start_page" || fail "--start-page 必须是非负整数"
is_nonnegative_integer "$end_page" || fail "--end-page 必须是非负整数"
start_page=$((10#$start_page))
end_page=$((10#$end_page))
(( end_page >= start_page )) || fail "--end-page 不能小于 --start-page"
is_boolean "$formula_enable" || fail "--formula 必须是 true 或 false"
is_boolean "$table_enable" || fail "--table 必须是 true 或 false"
if (( ${#languages[@]} == 0 )); then
  languages=("ch")
fi
for language in "${languages[@]}"; do
  [[ "$language" =~ ^[a-z_]+$ ]] || fail "无效的 OCR 语言: $language"
done

overall_timeout="${MINERU_TIMEOUT_SECONDS:-1800}"
poll_interval="${MINERU_POLL_INTERVAL_SECONDS:-3}"
is_positive_integer "$overall_timeout" || fail "MINERU_TIMEOUT_SECONDS 必须是正整数"
is_positive_integer "$poll_interval" || fail "MINERU_POLL_INTERVAL_SECONDS 必须是正整数"
overall_timeout=$((10#$overall_timeout))
poll_interval=$((10#$poll_interval))

require_command basename
require_command cp
require_command date
require_command mkdir
require_command mktemp
require_command rm
require_command sleep

mkdir -p -- "$output_dir"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
upload_file="$tmp_dir/input.$extension"
cp -- "$input_file" "$upload_file"

health_file="$tmp_dir/health.json"
if ! health_status="$(curl --silent --show-error --max-time "$http_timeout" \
  --output "$health_file" --write-out '%{http_code}' "$api_url/health")"; then
  fail "无法连接 MinerU 服务: $api_url"
fi
if [[ "$health_status" != "200" ]] || ! jq -e '.status == "healthy"' "$health_file" >/dev/null 2>&1; then
  print_http_error "$health_status" "$health_file"
  fail "MinerU 服务当前不可用"
fi

request_file="$output_dir/request.json"
jq -n \
  --arg apiUrl "$api_url" \
  --arg input "$(basename -- "$input_file")" \
  --arg backend "$backend" \
  --arg method "$method" \
  --argjson languages "$(printf '%s\n' "${languages[@]}" | jq -R . | jq -s .)" \
  --argjson formulaEnable "$formula_enable" \
  --argjson tableEnable "$table_enable" \
  --argjson startPage "$start_page" \
  --argjson endPage "$end_page" \
  '{
    apiUrl: $apiUrl,
    input: $input,
    backend: $backend,
    parseMethod: $method,
    languages: $languages,
    formulaEnable: $formulaEnable,
    tableEnable: $tableEnable,
    startPage: $startPage,
    endPage: $endPage
  }' >"$request_file"

submit_file="$tmp_dir/submit.json"
form_args=(
  --form "files=@$upload_file;type=$mime_type"
  --form-string "backend=$backend"
  --form-string "parse_method=$method"
  --form-string "formula_enable=$formula_enable"
  --form-string "table_enable=$table_enable"
  --form-string "return_md=true"
  --form-string "return_middle_json=false"
  --form-string "return_model_output=false"
  --form-string "return_content_list=false"
  --form-string "return_images=false"
  --form-string "response_format_zip=false"
  --form-string "return_original_file=false"
  --form-string "start_page_id=$start_page"
  --form-string "end_page_id=$end_page"
)
for language in "${languages[@]}"; do
  form_args+=(--form-string "lang_list=$language")
done

if ! submit_status="$(curl --silent --show-error --max-time "$http_timeout" \
  --request POST "${form_args[@]}" --output "$submit_file" --write-out '%{http_code}' "$api_url/tasks")"; then
  fail "无法向 MinerU 提交解析任务"
fi
if [[ "$submit_status" != "202" ]]; then
  print_http_error "$submit_status" "$submit_file"
  exit 1
fi
jq -e . "$submit_file" >/dev/null 2>&1 || fail "MinerU 提交接口返回了非 JSON 响应"
task_id="$(jq -r '.task_id // empty' "$submit_file")"
[[ -n "$task_id" ]] || fail "MinerU 提交成功响应中缺少 task_id"

status_file="$tmp_dir/status.json"
started_at="$(date +%s)"
while true; do
  if ! status_code="$(curl --silent --show-error --max-time "$http_timeout" \
    --output "$status_file" --write-out '%{http_code}' "$api_url/tasks/$task_id")"; then
    fail "查询 MinerU 任务 $task_id 失败"
  fi
  if [[ "$status_code" != "200" ]]; then
    print_http_error "$status_code" "$status_file"
    exit 1
  fi
  state="$(jq -r '.status // empty' "$status_file")"
  case "$state" in
    completed)
      break
      ;;
    failed)
      cp -- "$status_file" "$output_dir/task.json"
      fail "MinerU 任务 $task_id 失败: $(jq -r '.error // "unknown error"' "$status_file")"
      ;;
    pending|processing)
      ;;
    *)
      fail "MinerU 任务 $task_id 返回未知状态: $state"
      ;;
  esac
  now="$(date +%s)"
  if (( now - started_at >= overall_timeout )); then
    cp -- "$status_file" "$output_dir/task.json"
    fail "等待 MinerU 任务 $task_id 超时；任务没有被取消，可稍后查询"
  fi
  sleep "$poll_interval"
done
cp -- "$status_file" "$output_dir/task.json"

result_file="$output_dir/result.json"
if ! result_status="$(curl --silent --show-error --max-time "$http_timeout" \
  --output "$result_file" --write-out '%{http_code}' "$api_url/tasks/$task_id/result")"; then
  fail "获取 MinerU 任务 $task_id 的结果失败"
fi
if [[ "$result_status" != "200" ]]; then
  print_http_error "$result_status" "$result_file"
  exit 1
fi
jq -e '.results | type == "object" and length > 0' "$result_file" >/dev/null 2>&1 \
  || fail "MinerU 结果缺少非空 results 对象"

markdown_file="$output_dir/parsed.md"
jq -r '.results | to_entries[0].value.md_content // ""' "$result_file" >"$markdown_file"
markdown_chars="$(jq -r '.results | to_entries[0].value.md_content // "" | length' "$result_file")"

jq -n \
  --arg taskId "$task_id" \
  --arg status "$state" \
  --arg version "$(jq -r '.version // "unknown"' "$result_file")" \
  --arg backend "$(jq -r '.backend // "unknown"' "$result_file")" \
  --arg method "$method" \
  --arg markdown "$markdown_file" \
  --arg result "$result_file" \
  --arg task "$output_dir/task.json" \
  --arg request "$request_file" \
  --argjson markdownChars "$markdown_chars" \
  '{
    ok: true,
    task_id: $taskId,
    status: $status,
    version: $version,
    backend: $backend,
    parse_method: $method,
    markdown_chars: $markdownChars,
    files: {
      markdown: $markdown,
      result: $result,
      task: $task,
      request: $request
    }
  }'
