#!/usr/bin/env bash

set -euo pipefail

readonly CREDENTIAL_SLUG="tavily"
readonly TAVILY_SEARCH_URL="https://api.tavily.com/search"

usage() {
  cat <<'EOF'
Tavily search through the QM credential broker

Usage:
  tavily.sh search  <query> [max_results] [--deep]
  tavily.sh extract <query> [max_results]

Examples:
  tavily.sh search "latest AI news" 5
  tavily.sh search "Bitcoin market analysis" 8 --deep
  tavily.sh extract "OpenAI API documentation" 3
EOF
}

fail() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "需要命令 $1，但当前 Sandbox 中未安装"
}

command_name="${1:-}"
case "$command_name" in
  search|extract) ;;
  -h|--help|help|"")
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "未知操作: $command_name"
    ;;
esac
shift

query="${1:-}"
[[ -n "$query" ]] || fail "搜索问题不能为空"
shift

max_results=5
deep=false
max_results_seen=false

for arg in "$@"; do
  case "$arg" in
    --deep)
      deep=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      if [[ "$arg" =~ ^[0-9]+$ ]] && [[ "$max_results_seen" == false ]]; then
        max_results="$arg"
        max_results_seen=true
      else
        fail "无效参数: $arg"
      fi
      ;;
  esac
done

(( max_results >= 1 && max_results <= 20 )) || fail "max_results 必须是 1 到 20 的整数"

require_command curl
require_command jq

[[ -n "${AGENT_API_URL:-}" ]] || fail "缺少 AGENT_API_URL；此脚本只能在 QM Agent Sandbox 中运行"
[[ -n "${AGENT_CREDENTIAL_TOKEN:-}" ]] || fail "缺少 AGENT_CREDENTIAL_TOKEN；当前会话可能未获授权使用服务凭据 tavily"

search_depth="basic"
include_raw_content=false
if [[ "$command_name" == "extract" || "$deep" == true ]]; then
  search_depth="advanced"
fi
if [[ "$command_name" == "extract" ]]; then
  include_raw_content=true
fi

upstream_body="$({
  jq -cn \
    --arg query "$query" \
    --arg search_depth "$search_depth" \
    --argjson max_results "$max_results" \
    --argjson include_raw_content "$include_raw_content" \
    '{
      query: $query,
      max_results: $max_results,
      search_depth: $search_depth,
      include_answer: true,
      include_raw_content: $include_raw_content
    }'
})"

broker_request="$({
  jq -cn \
    --arg credential "$CREDENTIAL_SLUG" \
    --arg url "$TAVILY_SEARCH_URL" \
    --arg body "$upstream_body" \
    '{
      credential: $credential,
      method: "POST",
      url: $url,
      headers: {"content-type": "application/json"},
      body: $body
    }'
})"

timeout_seconds="${TAVILY_TIMEOUT_SECONDS:-45}"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || fail "TAVILY_TIMEOUT_SECONDS 必须是正整数"
(( timeout_seconds >= 1 && timeout_seconds <= 300 )) || fail "TAVILY_TIMEOUT_SECONDS 必须介于 1 和 300 秒"

broker_endpoint="${AGENT_API_URL%/}/v1/credentials/broker"
if ! broker_response="$(
  curl --silent --show-error \
    --max-time "$timeout_seconds" \
    --request POST \
    --header "x-agent-capability: ${AGENT_CREDENTIAL_TOKEN}" \
    --header "content-type: application/json" \
    --data "$broker_request" \
    "$broker_endpoint"
)"; then
  fail "无法连接 QM 凭据代理"
fi

if ! jq -e . >/dev/null 2>&1 <<<"$broker_response"; then
  fail "QM 凭据代理返回了非 JSON 响应"
fi

if broker_error="$(jq -r '.error // empty' <<<"$broker_response")" && [[ -n "$broker_error" ]]; then
  broker_message="$(jq -r '.message // "credential broker request failed"' <<<"$broker_response")"
  fail "QM 凭据代理拒绝请求 ($broker_error): $broker_message"
fi

upstream_status="$(jq -r '.status // 0' <<<"$broker_response")"
[[ "$upstream_status" =~ ^[0-9]+$ ]] || fail "QM 凭据代理返回了无效的上游状态码"

upstream_response="$(jq -r '.body // empty' <<<"$broker_response")"
if (( upstream_status < 200 || upstream_status >= 300 )); then
  printf 'Tavily 请求失败，HTTP %s\n' "$upstream_status" >&2
  if jq -e . >/dev/null 2>&1 <<<"$upstream_response"; then
    jq . <<<"$upstream_response" >&2
  else
    printf '%s\n' "$upstream_response" >&2
  fi
  exit 1
fi

if ! jq -e . >/dev/null 2>&1 <<<"$upstream_response"; then
  fail "Tavily 返回了非 JSON 响应"
fi

if [[ "$command_name" == "extract" ]]; then
  jq '{
    query,
    answer,
    results: [(.results // [])[] | {
      title,
      url,
      content,
      raw_content: (
        if (.raw_content | type) == "string"
        then .raw_content[0:4000]
        else .raw_content
        end
      ),
      score
    }],
    response_time,
    usage,
    request_id
  }' <<<"$upstream_response"
else
  jq '{
    query,
    answer,
    results: [(.results // [])[] | {
      title,
      url,
      content,
      score
    }],
    response_time,
    usage,
    request_id
  }' <<<"$upstream_response"
fi
