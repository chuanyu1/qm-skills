#!/usr/bin/env python3
"""Submit and resume MinerU v3 PDF parsing tasks without long-lived processes."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import urlparse


SCRIPT_PATH = "skills/mineru-v3-pdf-parser/scripts/mineru.py"
SUPPORTED_BACKENDS = ("pipeline", "vlm-auto-engine", "hybrid-auto-engine")
SUPPORTED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"}


class MineruError(RuntimeError):
    pass


def positive_int_env(name: str, default: int, maximum: int | None = None) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as exc:
        raise MineruError(f"{name} 必须是正整数") from exc
    if value < 1 or (maximum is not None and value > maximum):
        suffix = f"且不能超过 {maximum}" if maximum is not None else ""
        raise MineruError(f"{name} 必须是正整数{suffix}")
    return value


def api_base_url() -> str:
    value = os.environ.get("MINERU_API_URL", "").strip().rstrip("/")
    if not value:
        raise MineruError("缺少 MINERU_API_URL；请管理员通过 QM Sandbox env 配置 MinerU 服务地址")
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.query or parsed.fragment:
        raise MineruError("MINERU_API_URL 必须是完整的 http:// 或 https:// 基础地址")
    return value


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise MineruError(f"找不到任务文件: {path}") from exc
    except json.JSONDecodeError as exc:
        raise MineruError(f"任务文件不是有效 JSON: {path}") from exc
    if not isinstance(value, dict):
        raise MineruError(f"任务文件必须是 JSON 对象: {path}")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", suffix=".tmp", delete=False
    ) as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(path)


def curl_json(method: str, url: str, timeout: int, form: list[str] | None = None) -> tuple[int, dict[str, Any]]:
    with tempfile.NamedTemporaryFile(delete=False) as handle:
        response_path = Path(handle.name)
    command = [
        "curl",
        "--silent",
        "--show-error",
        "--max-time",
        str(timeout),
        "--request",
        method,
        "--output",
        str(response_path),
        "--write-out",
        "%{http_code}",
    ]
    for item in form or []:
        command.extend(["--form-string" if item.startswith("=") else "--form", item.lstrip("=")])
    command.append(url)
    try:
        try:
            completed = subprocess.run(command, check=False, capture_output=True, text=True)
        except OSError as exc:
            raise MineruError(f"无法启动 curl: {exc}") from exc
        if completed.returncode != 0:
            detail = completed.stderr.strip() or f"curl exit {completed.returncode}"
            raise MineruError(f"无法连接 MinerU 服务: {detail}")
        try:
            status = int(completed.stdout.strip())
        except ValueError as exc:
            raise MineruError("curl 未返回有效 HTTP 状态码") from exc
        raw = response_path.read_text(encoding="utf-8", errors="replace")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise MineruError(f"MinerU 返回非 JSON 响应，HTTP {status}") from exc
        if not isinstance(body, dict):
            raise MineruError(f"MinerU 返回的 JSON 不是对象，HTTP {status}")
        return status, body
    finally:
        response_path.unlink(missing_ok=True)


def require_status(actual: int, expected: int, body: dict[str, Any], action: str) -> None:
    if actual != expected:
        compact = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        raise MineruError(f"MinerU {action}失败，HTTP {actual}: {compact}")


def health(base: str, timeout: int) -> dict[str, Any]:
    status, body = curl_json("GET", f"{base}/health", timeout)
    require_status(status, 200, body, "健康检查")
    if body.get("status") != "healthy":
        raise MineruError(f"MinerU 健康检查未返回 healthy: {json.dumps(body, ensure_ascii=False)}")
    return body


def next_command(output_dir: Path) -> list[str]:
    return ["python3", SCRIPT_PATH, "resume", str(output_dir)]


def job_context(output_dir_raw: str) -> tuple[Path, str]:
    output_dir = Path(output_dir_raw)
    submission = read_json(output_dir / "submission.json")
    task_id = submission.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        raise MineruError(f"submission.json 缺少 task_id: {output_dir}")
    return output_dir, task_id


def query_status(base: str, timeout: int, output_dir: Path, task_id: str) -> dict[str, Any]:
    status, body = curl_json("GET", f"{base}/tasks/{task_id}", timeout)
    require_status(status, 200, body, f"查询任务 {task_id}")
    state = body.get("status")
    if state not in {"pending", "processing", "completed", "failed"}:
        raise MineruError(f"MinerU 任务 {task_id} 返回未知状态: {state!r}")
    write_json(output_dir / "task.json", body)
    if state == "failed":
        raise MineruError(f"MinerU 任务 {task_id} 失败: {body.get('error') or 'unknown error'}")
    return body


def collect_result(base: str, timeout: int, output_dir: Path, task_id: str) -> dict[str, Any]:
    status, result = curl_json("GET", f"{base}/tasks/{task_id}/result", timeout)
    require_status(status, 200, result, f"获取任务 {task_id} 结果")
    results = result.get("results")
    if not isinstance(results, dict) or not results:
        raise MineruError("MinerU 结果缺少非空 results 对象")
    first = next(iter(results.values()))
    if not isinstance(first, dict):
        raise MineruError("MinerU results 中的文件结果不是对象")
    markdown = first.get("md_content", "")
    if not isinstance(markdown, str):
        raise MineruError("MinerU md_content 不是字符串")
    write_json(output_dir / "result.json", result)
    (output_dir / "parsed.md").write_text(markdown, encoding="utf-8")
    request = read_json(output_dir / "request.json")
    return {
        "ok": True,
        "ready": True,
        "task_id": task_id,
        "status": "completed",
        "version": result.get("version", "unknown"),
        "backend": result.get("backend", "unknown"),
        "parse_method": request.get("parseMethod", "unknown"),
        "markdown_chars": len(markdown),
        "files": {
            "markdown": str(output_dir / "parsed.md"),
            "result": str(output_dir / "result.json"),
            "task": str(output_dir / "task.json"),
            "request": str(output_dir / "request.json"),
            "submission": str(output_dir / "submission.json"),
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="MinerU v3 resumable PDF and image parser")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("health", help="check MinerU service health")

    for command in ("submit", "parse"):
        submit = subparsers.add_parser(
            command,
            help="submit a task and return immediately" + (" (compatibility alias)" if command == "parse" else ""),
        )
        submit.add_argument("input_file")
        submit.add_argument("output_dir")
        submit.add_argument("--method", choices=("auto", "txt", "ocr"), default="auto")
        submit.add_argument("--lang", action="append", dest="languages")
        submit.add_argument("--backend", choices=SUPPORTED_BACKENDS, default="hybrid-auto-engine")
        submit.add_argument("--start-page", type=int, default=0)
        submit.add_argument("--end-page", type=int, default=99999)
        submit.add_argument("--formula", choices=("true", "false"), default="true")
        submit.add_argument("--table", choices=("true", "false"), default="true")

    for command, help_text in (
        ("status", "query a task once without waiting"),
        ("collect", "collect a completed task, or return not-ready"),
        ("resume", "query once and collect automatically when complete"),
    ):
        action = subparsers.add_parser(command, help=help_text)
        action.add_argument("output_dir")
    return parser


def submit_task(args: argparse.Namespace, base: str, timeout: int) -> None:
    input_file = Path(args.input_file)
    output_dir = Path(args.output_dir)
    if not input_file.is_file() or input_file.stat().st_size == 0:
        raise MineruError(f"输入文件不存在或为空: {input_file}")
    extension = input_file.suffix.lower()
    if extension not in SUPPORTED_EXTENSIONS:
        raise MineruError("仅支持 PDF、PNG、JPEG、TIFF、BMP 或 WebP")
    if args.start_page < 0 or args.end_page < args.start_page:
        raise MineruError("页码必须从 0 开始，且 --end-page 不能小于 --start-page")
    existing = output_dir / "submission.json"
    if existing.exists():
        prior = read_json(existing)
        if prior.get("task_id"):
            raise MineruError(f"输出目录已有任务 {prior['task_id']}；请运行 resume，避免重复提交")

    output_dir.mkdir(parents=True, exist_ok=True)
    health(base, timeout)
    languages = args.languages or ["ch"]
    for language in languages:
        if not re.fullmatch(r"[a-z_]+", language):
            raise MineruError(f"无效的 OCR 语言: {language}")
    request = {
        "input": input_file.name,
        "backend": args.backend,
        "parseMethod": args.method,
        "languages": languages,
        "formulaEnable": args.formula == "true",
        "tableEnable": args.table == "true",
        "startPage": args.start_page,
        "endPage": args.end_page,
    }
    write_json(output_dir / "request.json", request)
    mime_type = mimetypes.guess_type(input_file.name)[0] or "application/octet-stream"
    with tempfile.TemporaryDirectory(prefix="mineru-upload-") as temporary_dir:
        safe_upload = Path(temporary_dir) / f"input{extension}"
        shutil.copyfile(input_file, safe_upload)
        form = [
            f"files=@{safe_upload};type={mime_type};filename=input{extension}",
            f"=backend={args.backend}",
            f"=parse_method={args.method}",
            f"=formula_enable={args.formula}",
            f"=table_enable={args.table}",
            "=return_md=true",
            "=return_middle_json=false",
            "=return_model_output=false",
            "=return_content_list=false",
            "=return_images=false",
            "=response_format_zip=false",
            "=return_original_file=false",
            f"=start_page_id={args.start_page}",
            f"=end_page_id={args.end_page}",
            *[f"=lang_list={language}" for language in languages],
        ]
        status, submission = curl_json("POST", f"{base}/tasks", timeout, form=form)
    require_status(status, 202, submission, "提交任务")
    task_id = submission.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        raise MineruError("MinerU 提交成功响应中缺少 task_id")
    write_json(existing, submission)
    emit(
        {
            "ok": True,
            "ready": False,
            "action": "submitted",
            "task_id": task_id,
            "status": submission.get("status", "pending"),
            "output_dir": str(output_dir),
            "next_command": next_command(output_dir),
            "note": "任务已由 MinerU 服务持有；无需后台进程，不要重复提交。",
        }
    )


def resume_task(command: str, output_dir_raw: str, base: str, timeout: int, retry_after: int) -> None:
    output_dir, task_id = job_context(output_dir_raw)
    task = query_status(base, timeout, output_dir, task_id)
    state = task["status"]
    if command == "status" or state != "completed":
        emit(
            {
                "ok": True,
                "ready": state == "completed",
                "task_id": task_id,
                "status": state,
                "queued_ahead": task.get("queued_ahead"),
                "retry_after_seconds": 0 if state == "completed" else retry_after,
                "next_command": (
                    ["python3", SCRIPT_PATH, "collect", str(output_dir)]
                    if state == "completed"
                    else next_command(output_dir)
                ),
            }
        )
        return
    emit(collect_result(base, timeout, output_dir, task_id))


def main() -> int:
    args = build_parser().parse_args()
    try:
        base = api_base_url()
        timeout = positive_int_env("MINERU_HTTP_TIMEOUT_SECONDS", 120)
        retry_after = positive_int_env("MINERU_RETRY_AFTER_SECONDS", 15, maximum=300)
        if args.command == "health":
            emit(health(base, timeout))
        elif args.command in {"submit", "parse"}:
            submit_task(args, base, timeout)
        else:
            resume_task(args.command, args.output_dir, base, timeout, retry_after)
        return 0
    except MineruError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
