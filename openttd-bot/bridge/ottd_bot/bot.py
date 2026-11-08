"""Glue: chat messages in, interpreter (Claude or rule-based) in the middle, chat replies out."""

from __future__ import annotations

import asyncio
import logging
import time
from collections import deque
from dataclasses import dataclass, field

from . import simple_parser
from .admin import COMPANY_SPECTATOR, AdminClient, ChatMessage, DestType, NetAction
from .agent import Agent
from .gslink import GSLink
from .tools import ToolExecutor

log = logging.getLogger(__name__)


@dataclass
class BotConfig:
    prefix: str = "!bot"
    reply: str = "private"  # private | team | public
    cooldown_seconds: float = 5.0
    history_turns: int = 4
    fixed_company: int | None = None  # 0-based; build for this company instead of the sender's
    allowed_players: list[str] = field(default_factory=list)  # empty = everyone


class ChatBot:
    def __init__(self, admin: AdminClient, gs: GSLink, agent: Agent | None, config: BotConfig):
        self.admin = admin
        self.gs = gs
        self.agent = agent
        self.config = config
        self._locks: dict[int, asyncio.Lock] = {}
        self._last_request: dict[int, float] = {}
        self._history: dict[int, deque[tuple[str, str]]] = {}
        admin.on_chat = self.on_chat
        admin.on_connected = self.on_connected

    async def on_connected(self) -> None:
        try:
            info = await self.gs.call("ping", timeout=10)
            log.info("game script answered ping: %s", info)
        except Exception as e:  # noqa: BLE001 - only a startup diagnostic
            log.warning("game script not answering yet (%s). Is ChatBot selected as the game script?", e)

    def extract_request(self, msg: ChatMessage) -> str | None:
        """Return the command text if this chat line is addressed to the bot."""
        if msg.action not in (NetAction.CHAT_BROADCAST, NetAction.CHAT_TEAM, NetAction.CHAT_CLIENT):
            return None
        text = msg.text.strip()
        prefix = self.config.prefix.lower()
        if text.lower().startswith(prefix):
            rest = text[len(prefix):]
            if not rest or rest[0] in " :,":
                return rest.lstrip(" :,").strip()
        # Private messages to the server need no prefix.
        if msg.action == NetAction.CHAT_CLIENT and msg.dest_type == DestType.CLIENT:
            return text
        return None

    def reply(self, client_id: int, company: int, text: str) -> None:
        for line in _split_chat(text):
            if self.config.reply == "public":
                self.admin.send_chat(line)
            elif self.config.reply == "team" and company != COMPANY_SPECTATOR:
                self.admin.send_chat(line, team=company)
            else:
                self.admin.send_chat(line, client_id=client_id)

    async def on_chat(self, msg: ChatMessage) -> None:
        request = self.extract_request(msg)
        if request is None:
            return
        client = self.admin.clients.get(msg.client_id)
        if client is None:
            self.admin.poll(1, msg.client_id)  # CLIENT_INFO
            await asyncio.sleep(0.5)
            client = self.admin.clients.get(msg.client_id)
        if client is None:
            return
        name = client.name
        company = self.config.fixed_company if self.config.fixed_company is not None else client.company

        if self.config.allowed_players and name not in self.config.allowed_players:
            self.reply(client.client_id, company, "Sorry, you are not on this bot's list of allowed players.")
            return
        if company == COMPANY_SPECTATOR:
            self.reply(client.client_id, company, "Join or start a company first - I build for your company.")
            return
        if not request:
            self.reply(client.client_id, company, simple_parser.HELP)
            return

        lock = self._locks.setdefault(client.client_id, asyncio.Lock())
        if lock.locked():
            self.reply(client.client_id, company, "Still working on your last request, hang on...")
            return
        now = time.monotonic()
        if now - self._last_request.get(client.client_id, 0) < self.config.cooldown_seconds:
            self.reply(client.client_id, company, "One moment - please wait a few seconds between requests.")
            return
        self._last_request[client.client_id] = now

        async with lock:
            log.info("[%s / company %d] %s", name, company + 1, request)
            executor = ToolExecutor(self.gs, company, on_progress=lambda m: self.reply(client.client_id, company, m))
            try:
                if self.agent is not None:
                    answer = await self.agent.handle(request, self._context(client.client_id, name, company), executor)
                else:
                    answer = await simple_parser.handle(request, executor)
            except Exception as e:
                log.exception("request failed")
                answer = f"Sorry, something went wrong: {e}"
            self._remember(client.client_id, request, answer)
            self.reply(client.client_id, company, answer)

    def _context(self, client_id: int, name: str, company: int) -> str:
        company_name = self.admin.companies.get(company, f"Company {company + 1}")
        lines = [f"Player: {name}. Their company: {company_name} (company #{company + 1})."]
        hist = self._history.get(client_id)
        if hist:
            lines.append("Recent conversation with this player (oldest first):")
            for q, a in hist:
                lines.append(f"  Player: {q}")
                lines.append(f"  You: {a}")
        return "\n".join(lines)

    def _remember(self, client_id: int, request: str, answer: str) -> None:
        hist = self._history.setdefault(client_id, deque(maxlen=self.config.history_turns))
        hist.append((request, answer))


def _split_chat(text: str, width: int = 300) -> list[str]:
    """Split a reply into chat-sized lines."""
    out: list[str] = []
    for para in text.splitlines():
        para = para.strip()
        while len(para) > width:
            cut = para.rfind(" ", 0, width)
            if cut <= 0:
                cut = width
            out.append(para[:cut])
            para = para[cut:].lstrip()
        if para:
            out.append(para)
    return out or ["(no reply)"]
