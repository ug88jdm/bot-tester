"""Entry point: python -m ottd_bot --config config.toml"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import tomllib
from pathlib import Path

from .admin import AdminClient
from .agent import Agent, AgentConfig
from .bot import BotConfig, ChatBot
from .gslink import GSLink

log = logging.getLogger("ottd_bot")


def load_config(path: Path | None) -> dict:
    if path is None:
        return {}
    with open(path, "rb") as f:
        return tomllib.load(f)


def build(cfg: dict) -> tuple[AdminClient, ChatBot]:
    server = cfg.get("server", {})
    password = os.environ.get("OTTD_ADMIN_PASSWORD") or server.get("admin_password", "")
    if not password:
        raise SystemExit("No admin password: set server.admin_password in the config or OTTD_ADMIN_PASSWORD.")
    admin = AdminClient(server.get("host", "127.0.0.1"), int(server.get("admin_port", 3977)), password,
                        name=server.get("admin_name", "ottd-chatbot"))
    gs = GSLink(admin)

    llm = cfg.get("llm", {})
    agent = None
    if llm.get("enabled", True):
        if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN") or llm.get("allow_profile_auth")):
            log.warning("ANTHROPIC_API_KEY not set - using the rule-based parser (set llm.enabled=false to silence)")
        else:
            agent = Agent(AgentConfig(
                model=llm.get("model", "claude-opus-5-5"),
                effort=llm.get("effort", "medium"),
                max_steps=int(llm.get("max_steps", 12)),
                use_fallbacks=bool(llm.get("server_side_fallbacks", True)),
            ))

    b = cfg.get("bot", {})
    fixed = b.get("fixed_company")
    bot = ChatBot(admin, gs, agent, BotConfig(
        prefix=b.get("prefix", "!bot"),
        reply=b.get("reply", "private"),
        cooldown_seconds=float(b.get("cooldown_seconds", 5)),
        history_turns=int(b.get("history_turns", 4)),
        fixed_company=(int(fixed) - 1) if fixed else None,  # config uses the in-game 1-based number
        allowed_players=list(b.get("allowed_players", [])),
    ))
    return admin, bot


def main() -> None:
    ap = argparse.ArgumentParser(description="Natural-language construction bot for OpenTTD multiplayer servers")
    ap.add_argument("--config", type=Path, help="TOML config file (see config.example.toml)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    admin, _bot = build(load_config(args.config))
    try:
        asyncio.run(admin.run_forever())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
