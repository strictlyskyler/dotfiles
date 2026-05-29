#!/usr/bin/env python3
"""Apply Skyler's Hermes defaults to an existing ~/.hermes config.

Hermes setup owns the base config file. This patcher keeps the machine-local
file usable with the self-hosted orphic-lens model without committing secrets or
the full generated config into dotfiles.
"""
from __future__ import annotations

import sys
import json
from pathlib import Path

import yaml


MODEL = "Qwen_Qwen3-14B-Q4_K_M.gguf"
MODEL_ALIASES = ("qwen3:8b", "qwen3:14b", MODEL)
LLM_BASE_URL = "http://orphic-lens:11434/v1"
HONCHO_BASE_URL = "http://orphic-lens:8100"
CONTEXT_LENGTH = 65_536


def load_yaml(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open() as handle:
        data = yaml.safe_load(handle) or {}
    return data if isinstance(data, dict) else {}


def save_yaml(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        yaml.safe_dump(data, handle, sort_keys=False, allow_unicode=True)


def ensure_dict(parent: dict, key: str) -> dict:
    value = parent.get(key)
    if not isinstance(value, dict):
        value = {}
        parent[key] = value
    return value


def patch_llm_block(block: dict) -> None:
    block["provider"] = "custom"
    block["model"] = MODEL
    block["base_url"] = LLM_BASE_URL
    block.setdefault("api_key", "")


def patch_config(config_path: Path) -> bool:
    created = not config_path.exists()
    data = load_yaml(config_path)

    agent = ensure_dict(data, "agent")
    agent["reasoning_effort"] = "low"

    clarify = ensure_dict(data, "clarify")
    clarify["timeout"] = 15

    platform_toolsets = ensure_dict(data, "platform_toolsets")
    cli_toolsets = platform_toolsets.get("cli")
    if isinstance(cli_toolsets, list):
        platform_toolsets["cli"] = [
            "clarify",
            *[item for item in cli_toolsets if item != "clarify"],
        ]

    model = ensure_dict(data, "model")
    model["default"] = MODEL
    model["provider"] = "custom"
    model["base_url"] = LLM_BASE_URL
    model["context_length"] = CONTEXT_LENGTH
    model["ollama_num_ctx"] = CONTEXT_LENGTH
    model["max_tokens"] = 1024

    compression = ensure_dict(data, "compression")
    compression["summary_model"] = MODEL
    compression["summary_provider"] = "custom"
    compression["summary_base_url"] = LLM_BASE_URL

    auxiliary = ensure_dict(data, "auxiliary")
    for name in (
        "vision",
        "web_extract",
        "compression",
        "session_search",
        "skills_hub",
        "approval",
        "mcp",
        "flush_memories",
    ):
        patch_llm_block(ensure_dict(auxiliary, name))
    ensure_dict(auxiliary, "compression")["context_length"] = CONTEXT_LENGTH

    delegation = ensure_dict(data, "delegation")
    delegation["model"] = MODEL
    delegation["provider"] = "custom"
    delegation["base_url"] = LLM_BASE_URL
    delegation.setdefault("api_key", "")
    delegation["reasoning_effort"] = "low"

    providers = data.get("custom_providers")
    if not isinstance(providers, list):
        providers = []
        data["custom_providers"] = providers
    provider = next(
        (
            item
            for item in providers
            if isinstance(item, dict)
            and (
                item.get("name") == "orphic-lens"
                or item.get("base_url") == LLM_BASE_URL
            )
        ),
        None,
    )
    if provider is None:
        provider = {"name": "orphic-lens"}
        providers.append(provider)
    provider["name"] = "orphic-lens"
    provider["base_url"] = LLM_BASE_URL
    models = ensure_dict(provider, "models")
    for alias in MODEL_ALIASES:
        ensure_dict(models, alias)["context_length"] = CONTEXT_LENGTH

    save_yaml(config_path, data)
    print(
        "OK    Hermes config "
        + ("created from orphic-lens defaults" if created else "model/context defaults")
    )
    return True


def patch_honcho_config(honcho_path: Path) -> None:
    created = not honcho_path.exists()
    if created:
        data: dict = {}
    else:
        with honcho_path.open() as handle:
            data = json.load(handle)
    data["baseUrl"] = HONCHO_BASE_URL
    hosts = ensure_dict(data, "hosts")
    hermes = ensure_dict(hosts, "hermes")
    hermes["enabled"] = True
    hermes["workspace"] = "hermes"
    hermes["peerName"] = "skyler"
    hermes["aiPeer"] = "hermes"
    hermes["memoryMode"] = "auto"
    hermes["recallMode"] = "tools"
    hermes["dialecticReasoningLevel"] = "minimal"
    honcho_path.parent.mkdir(parents=True, exist_ok=True)
    with honcho_path.open("w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    print("OK    Hermes Honcho config " + ("created" if created else "updated"))


def main() -> int:
    hermes_home = Path(sys.argv[1]).expanduser() if len(sys.argv) > 1 else Path.home() / ".hermes"
    hermes_home.mkdir(parents=True, exist_ok=True)
    patch_config(hermes_home / "config.yaml")
    patch_honcho_config(hermes_home / "honcho.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
