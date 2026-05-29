#!/usr/bin/env python3
"""Reapply local Hermes Agent source patches after install/update.

Hermes updates replace ~/.hermes/hermes-agent. Keep Skyler's local provider
fixes reproducible by applying small, idempotent source patches from dotfiles.
"""
from __future__ import annotations

import re
import py_compile
import sys
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> bool:
    text = path.read_text()
    if new in text:
        return False
    if old not in text:
        raise RuntimeError(f"expected snippet not found in {path}")
    path.write_text(text.replace(old, new, 1))
    return True


def regex_replace_once(path: Path, pattern: str, new: str) -> bool:
    text = path.read_text()
    if new in text:
        return False
    # Pass `new` via a callable so re.sub does NOT interpret backslash escapes
    # (e.g. "\n", "\t", "\1") inside the replacement payload. Without this,
    # literal "\n" sequences in CLARIFY_DESCRIPTION get decoded into real
    # newlines and corrupt the target Python source.
    updated, count = re.subn(pattern, lambda _m: new, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise RuntimeError(f"expected pattern not found in {path}")
    path.write_text(updated)
    return True


def patch_chat_completions(root: Path) -> bool:
    path = root / "agent/transports/chat_completions.py"
    old = '''        # Merge any pre-built extra_body additions
        additions = params.get("extra_body_additions")
        if additions:
            extra_body.update(additions)
'''
    new = '''        # Merge any pre-built extra_body additions
        additions = params.get("extra_body_additions")
        if additions:
            extra_body.update(additions)

        # orphic-lens (custom llama.cpp / Qwen): bound per-request thinking so
        # tool-call turns don't spend the whole output budget on hidden
        # reasoning. llama.cpp honors a per-request reasoning_budget for Qwen,
        # which keeps reasoning useful without burning the output cap in loops.
        if params.get("is_custom_provider", False) and "qwen" in (model or "").lower():
            _qwen_reasoning_off = bool(
                reasoning_config
                and isinstance(reasoning_config, dict)
                and (
                    (reasoning_config.get("effort") or "").strip().lower() == "none"
                    or reasoning_config.get("enabled") is False
                )
            )
            if not _qwen_reasoning_off:
                extra_body.setdefault("reasoning_budget", 64)
'''
    return replace_once(path, old, new)


def patch_cli(root: Path) -> bool:
    path = root / "cli.py"
    changed = False
    old = '''            effective_model = model_override or self.model
'''
    new = '''            effective_model = model_override or self.model
            try:
                max_tokens = int((CLI_CONFIG.get("model") or {}).get("max_tokens") or 0) or None
            except (TypeError, ValueError):
                max_tokens = None
'''
    changed |= replace_once(path, old, new)
    old = '''                tool_gen_callback=self._on_tool_gen_start if self.streaming_enabled else None,
            )
'''
    new = '''                tool_gen_callback=self._on_tool_gen_start if self.streaming_enabled else None,
                max_tokens=max_tokens,
            )
'''
    changed |= replace_once(path, old, new)
    return changed


CONCLUDE_SCHEMA = '''CONCLUDE_SCHEMA = {
    "name": "honcho_conclude",
    "description": (
        "Write a conclusion about a peer in Honcho's memory. "
        "Conclusions are persistent facts that build a peer's profile. "
        "Only use this tool when the user explicitly asks you to save, remember, "
        "or persist a fact. Never use it before read-only tools like "
        "honcho_profile, honcho_search, honcho_context, or honcho_reasoning. "
        "Call this tool once with a concise `conclusion` string. "
        "Do not call this tool repeatedly for the same fact."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "conclusion": {
                "type": "string",
                "description": "A factual statement to persist.",
            },
            "delete_id": {
                "type": "string",
                "description": "Advanced: conclusion ID to delete for PII removal. Do not use during normal memory saves.",
            },
            "peer": {
                "type": "string",
                "description": "Peer to query. Built-in aliases: 'user' (default), 'ai'. Or pass any peer ID from this workspace.",
            },
        },
        "required": ["conclusion"],
    },
}
'''


def patch_honcho_plugin(root: Path) -> bool:
    path = root / "plugins/memory/honcho/__init__.py"
    changed = False
    changed |= regex_replace_once(
        path,
        r'CONCLUDE_SCHEMA = \{.*?\n\}\n\n\nALL_TOOL_SCHEMAS',
        CONCLUDE_SCHEMA + "\n\nALL_TOOL_SCHEMAS",
    )
    changed |= replace_once(
        path,
        '''                "honcho_conclude to save facts about the user. "
''',
        '''                "honcho_conclude only when the user explicitly asks you to save or remember a fact. "
''',
    )
    changed |= replace_once(
        path,
        '''                "honcho_conclude to save facts about the user."
''',
        '''                "honcho_conclude only when the user explicitly asks you to save or remember a fact."
''',
    )
    return changed


CLARIFY_DESCRIPTION = '''    "description": (
        "Ask the user a question only when you are genuinely blocked and cannot "
        "make a reasonable default decision. Do not use this tool for optional "
        "feedback, rhetorical follow-ups, or when you can answer directly. "
        "Supports two modes:\\n\\n"
        "1. **Multiple choice** — provide up to 4 choices. The user picks one "
        "or types their own answer via a 5th 'Other' option.\\n"
        "2. **Open-ended** — omit choices entirely. The user types a free-form "
        "response.\\n\\n"
        "Use this tool when:\\n"
        "- The task is ambiguous and you need the user to choose an approach\\n"
        "- A decision has meaningful trade-offs the user should weigh in on\\n\\n"
        "Do NOT use this tool for simple yes/no confirmation of dangerous "
        "commands (the terminal tool handles that). Prefer making a reasonable "
        "default choice yourself when the decision is low-stakes. If the user "
        "asks a direct question, answer it directly instead of clarifying."
    ),
'''


def patch_clarify_tool(root: Path) -> bool:
    path = root / "tools/clarify_tool.py"
    return regex_replace_once(
        path,
        r'    "description": \(\n        "Ask the user a question.*?\n    \),\n',
        CLARIFY_DESCRIPTION,
    )


def main() -> int:
    hermes_home = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / ".hermes"
    root = hermes_home / "hermes-agent"
    if not root.exists():
        print(f"SKIP  Hermes source patches ({root} not found)")
        return 0

    patches = [
        ("agent/transports/chat_completions.py", patch_chat_completions),
        ("cli.py", patch_cli),
        ("plugins/memory/honcho/__init__.py", patch_honcho_plugin),
        ("tools/clarify_tool.py", patch_clarify_tool),
    ]
    changed: list[str] = []
    for label, fn in patches:
        if fn(root):
            changed.append(label)

    for rel in [
        "agent/transports/chat_completions.py",
        "cli.py",
        "plugins/memory/honcho/__init__.py",
        "tools/clarify_tool.py",
    ]:
        py_compile.compile(str(root / rel), doraise=True)

    if changed:
        for rel in changed:
            print(f"PATCH {rel}")
    else:
        print("OK    Hermes source patches already applied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
