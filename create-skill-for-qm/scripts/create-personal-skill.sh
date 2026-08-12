#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Create and verify a durable personal skill through the QM self-API.

Usage:
  create-personal-skill.sh --name <name> --description <text> --body-file <path>

Example:
  create-personal-skill.sh \
    --name check-public-link \
    --description "Check a public URL before delivery." \
    --body-file work/check-public-link.md
EOF
}

fail() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "需要命令 $1，但当前 Sandbox 中未安装"
}

name=""
description=""
body_file=""

while (( $# > 0 )); do
  case "$1" in
    --name)
      (( $# >= 2 )) || fail "--name 缺少值"
      name="$2"
      shift 2
      ;;
    --description)
      (( $# >= 2 )) || fail "--description 缺少值"
      description="$2"
      shift 2
      ;;
    --body-file)
      (( $# >= 2 )) || fail "--body-file 缺少值"
      body_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数: $1"
      ;;
  esac
done

[[ -n "$name" ]] || fail "--name 不能为空"
[[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "--name 只能使用小写字母、数字和单个连字符分段"
(( ${#name} <= 64 )) || fail "--name 不能超过 64 个字符"
[[ -n "${description//[[:space:]]/}" ]] || fail "--description 不能为空"
[[ -n "$body_file" ]] || fail "--body-file 不能为空"
[[ -f "$body_file" ]] || fail "找不到正文文件: $body_file"
[[ -s "$body_file" ]] || fail "正文文件不能为空: $body_file"

require_command curl
require_command jq
require_command mktemp

[[ -n "${AGENT_API_URL:-}" ]] || fail "缺少 AGENT_API_URL；此脚本只能在 QM Agent Sandbox 中运行"
[[ -n "${AGENT_API_TOKEN:-}" ]] || fail "缺少 AGENT_API_TOKEN；请在新的 QM 会话中重试"

timeout_seconds="${QM_SKILL_API_TIMEOUT_SECONDS:-30}"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || fail "QM_SKILL_API_TIMEOUT_SECONDS 必须是正整数"
(( timeout_seconds >= 1 && timeout_seconds <= 300 )) || fail "QM_SKILL_API_TIMEOUT_SECONDS 必须介于 1 和 300 秒"

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

api_base="${AGENT_API_URL%/}"
auth_header="x-agent-capability: ${AGENT_API_TOKEN}"

request() {
  local method="$1"
  local url="$2"
  local output_file="$3"
  local data_file="${4:-}"
  local status
  local -a args=(
    --silent
    --show-error
    --max-time "$timeout_seconds"
    --request "$method"
    --header "$auth_header"
    --output "$output_file"
    --write-out '%{http_code}'
  )
  if [[ -n "$data_file" ]]; then
    args+=(--header 'content-type: application/json' --data-binary "@$data_file")
  fi
  if ! status="$(curl "${args[@]}" "$url")"; then
    fail "无法连接 QM self-API"
  fi
  printf '%s' "$status"
}

print_api_error() {
  local status="$1"
  local response_file="$2"
  local error_code message
  if jq -e . "$response_file" >/dev/null 2>&1; then
    error_code="$(jq -r '.error // "unknown_error"' "$response_file")"
    message="$(jq -r '.message // "QM request failed"' "$response_file")"
    printf 'QM self-API 请求失败，HTTP %s (%s): %s\n' "$status" "$error_code" "$message" >&2
  else
    printf 'QM self-API 请求失败，HTTP %s，且返回内容不是 JSON\n' "$status" >&2
  fi
}

discovery_file="$tmp_dir/apis.json"
discovery_status="$(request GET "$api_base/v1/apis" "$discovery_file")"
if [[ ! "$discovery_status" =~ ^2[0-9][0-9]$ ]]; then
  print_api_error "$discovery_status" "$discovery_file"
  exit 1
fi
jq -e . "$discovery_file" >/dev/null 2>&1 || fail "QM /v1/apis 返回了非 JSON 响应"

actor_id="$(jq -r '.actorId // empty' "$discovery_file")"
scope_id="$(jq -r '.scopeId // empty' "$discovery_file")"
[[ -n "$actor_id" ]] || fail "QM /v1/apis 未返回 actorId"
[[ "$scope_id" == personal:* ]] || fail "当前会话范围是 $scope_id，不是 personal:*；请在用户自己的个人聊天中重新创建"

payload_file="$tmp_dir/create.json"
jq -cn \
  --arg name "$name" \
  --arg description "$description" \
  --rawfile body "$body_file" \
  '{name: $name, description: $description, body: $body}' >"$payload_file"

create_file="$tmp_dir/created.json"
create_status="$(request POST "$api_base/v1/skills" "$create_file" "$payload_file")"
if [[ "$create_status" == "409" ]]; then
  print_api_error "$create_status" "$create_file"
  fail "同名 Skill 已存在；请从 /skills 确认其 ID 后执行显式更新，不要自动改名或覆盖"
fi
if [[ "$create_status" != "201" ]]; then
  print_api_error "$create_status" "$create_file"
  exit 1
fi
jq -e . "$create_file" >/dev/null 2>&1 || fail "QM 创建接口返回了非 JSON 响应"

skill_id="$(jq -r '.skill.id // empty' "$create_file")"
[[ -n "$skill_id" ]] || fail "QM 创建成功响应中缺少 Skill ID"

detail_file="$tmp_dir/detail.json"
detail_status="$(request GET "$api_base/v1/skills/$skill_id" "$detail_file")"
if [[ "$detail_status" != "200" ]]; then
  print_api_error "$detail_status" "$detail_file"
  fail "Skill 已返回 ID $skill_id，但回读验证失败；不要宣称创建完成"
fi
jq -e . "$detail_file" >/dev/null 2>&1 || fail "QM Skill 详情接口返回了非 JSON 响应"

if ! jq -e \
  --arg id "$skill_id" \
  --arg name "$name" \
  --arg scope "$scope_id" \
  --rawfile body "$body_file" \
  '.skill.id == $id and .skill.name == $name and .skill.scopeId == $scope and .skill.status == "published" and .skill.body == $body' \
  "$detail_file" >/dev/null; then
  fail "回读结果与提交内容不一致；Skill ID 为 $skill_id，请交给管理员审计"
fi

jq -n \
  --arg id "$skill_id" \
  --arg name "$name" \
  --arg actorId "$actor_id" \
  --arg scopeId "$scope_id" \
  --arg status "$(jq -r '.skill.status' "$detail_file")" \
  --argjson version "$(jq '.skill.version' "$detail_file")" \
  '{
    ok: true,
    verified: true,
    id: $id,
    name: $name,
    actorId: $actorId,
    scopeId: $scopeId,
    status: $status,
    version: $version,
    skillsPage: "/skills"
  }'
