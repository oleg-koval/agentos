"""Observer-only Hermes hooks for the local AgentOS runtime."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import threading
from typing import Any


def native_event_command() -> str:
    """Prefer the signed package binary over PATH-shadowed legacy copies."""
    packaged = "/usr/bin/agentos-native-event"
    if os.access(packaged, os.X_OK):
        return packaged
    return shutil.which("agentos-native-event") or "agentos-native-event"


def _forward(event_name: str, **fields: Any) -> None:
    file_change = fields.get("file_change")
    if not isinstance(file_change, dict):
        file_change = {}
    task = fields.get("task")
    if not isinstance(task, dict):
        task = {}
    usage = fields.get("usage")
    if not isinstance(usage, dict):
        usage = {}
    artifact = fields.get("artifact")
    if not isinstance(artifact, dict):
        artifact = {}

    def stringify(value: Any) -> str:
        if isinstance(value, (dict, list)):
            return json.dumps(value, sort_keys=True, separators=(",", ":"))
        return str(value)

    def text_value(*names: str) -> str:
        for name in names:
            value = fields.get(name)
            if value is None:
                value = file_change.get(name)
            if value is None:
                continue
            return stringify(value)
        return ""

    def nested_text(container: dict[str, Any], *names: str) -> str:
        for name in names:
            value = container.get(name)
            if value is not None:
                return stringify(value)
        return ""

    payload = {
        "hook_event_name": event_name,
        "session_id": str(fields.get("session_id") or fields.get("session_key") or ""),
        "cwd": os.getcwd(),
        "tool_name": str(fields.get("tool_name") or ""),
        "tool_call_id": str(fields.get("tool_call_id") or ""),
        "approval_id": str(fields.get("approval_id") or fields.get("request_id") or ""),
        "status": str(fields.get("status") or ""),
        "choice": str(fields.get("choice") or ""),
        "model": str(fields.get("model") or ""),
        "task_id": text_value("task_id") or nested_text(task, "id", "task_id"),
        "task_title": text_value("task_title", "prompt_title") or nested_text(task, "title", "name"),
        "artifact_kind": text_value("artifact_kind") or nested_text(artifact, "kind"),
        "artifact_path": text_value("artifact_path") or nested_text(artifact, "path"),
        "artifact_url": text_value("artifact_url") or nested_text(artifact, "url"),
        "input_tokens": usage.get("input_tokens", fields.get("input_tokens", 0)),
        "output_tokens": usage.get("output_tokens", fields.get("output_tokens", 0)),
        "total_tokens": usage.get("total_tokens", fields.get("total_tokens", 0)),
        "approval_reason": text_value("approval_reason", "reason"),
        "file_path": text_value("file_path", "path"),
        "operation": text_value("file_operation", "operation", "change_type"),
        "before": text_value("before", "old_path", "old_string"),
        "after": text_value("after", "new_path", "new_string"),
        "old_path": text_value("old_path", "previous_path"),
        "new_path": text_value("new_path", "current_path"),
    }

    def run() -> None:
        try:
            subprocess.run(
                [native_event_command(), "--agent", "hermes"],
                input=json.dumps(payload),
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=3,
            )
        except (OSError, subprocess.TimeoutExpired):
            return

    threading.Thread(target=run, daemon=True).start()


def on_session_start(**kwargs: Any) -> None:
    _forward("on_session_start", **kwargs)


def on_session_end(**kwargs: Any) -> None:
    _forward("on_session_end", **kwargs)


def on_session_finalize(**kwargs: Any) -> None:
    _forward("on_session_finalize", **kwargs)


def pre_tool_call(**kwargs: Any) -> None:
    _forward("pre_tool_call", **kwargs)


def post_tool_call(**kwargs: Any) -> None:
    _forward("post_tool_call", **kwargs)


def pre_approval_request(**kwargs: Any) -> None:
    _forward("pre_approval_request", **kwargs)


def post_approval_response(**kwargs: Any) -> None:
    _forward("post_approval_response", **kwargs)


def subagent_start(**kwargs: Any) -> None:
    _forward("subagent_start", **kwargs)


def subagent_stop(**kwargs: Any) -> None:
    _forward("subagent_stop", **kwargs)


def register(ctx: Any) -> None:
    for name, callback in {
        "on_session_start": on_session_start,
        "on_session_end": on_session_end,
        "on_session_finalize": on_session_finalize,
        "pre_tool_call": pre_tool_call,
        "post_tool_call": post_tool_call,
        "pre_approval_request": pre_approval_request,
        "post_approval_response": post_approval_response,
        "subagent_start": subagent_start,
        "subagent_stop": subagent_stop,
    }.items():
        ctx.register_hook(name, callback)
