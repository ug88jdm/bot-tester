"""Request/response layer on top of the admin port's game-script JSON channel."""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from typing import Any

from .admin import AdminClient, AdminError

log = logging.getLogger(__name__)

ProgressCallback = Callable[[str], None]


class GSCommandError(Exception):
    """The game script ran the command and reported a failure."""


class GSUnavailable(Exception):
    """The game script did not answer (not installed, not running, or timed out)."""


class GSLink:
    def __init__(self, admin: AdminClient):
        self.admin = admin
        self._next_id = 1
        self._pending: dict[int, tuple[asyncio.Future, ProgressCallback | None]] = {}
        self.gs_version: int | None = None
        admin.on_gamescript = self.handle_message

    async def call(
        self,
        cmd: str,
        args: dict[str, Any] | None = None,
        *,
        timeout: float = 30.0,
        on_progress: ProgressCallback | None = None,
    ) -> Any:
        """Send a command to the game script and wait for its result data."""
        rid = self._next_id
        self._next_id += 1
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[rid] = (fut, on_progress)
        try:
            self.admin.send_gamescript(json.dumps({"id": rid, "cmd": cmd, "args": args or {}}, separators=(",", ":")))
            await self.admin.drain()
            msg = await asyncio.wait_for(fut, timeout)
        except TimeoutError:
            raise GSUnavailable(
                f"game script did not answer '{cmd}' within {timeout:.0f}s - is the ChatBot game script running?"
            ) from None
        except (AdminError, OSError) as e:
            raise GSUnavailable(f"not connected to the server: {e}") from None
        finally:
            self._pending.pop(rid, None)
        if not msg.get("ok"):
            raise GSCommandError(msg.get("error") or "unknown error")
        return msg.get("data")

    def handle_message(self, text: str) -> None:
        try:
            msg = json.loads(text)
        except json.JSONDecodeError:
            log.warning("bad JSON from game script: %r", text[:200])
            return
        if not isinstance(msg, dict):
            return
        mtype = msg.get("type")
        if mtype == "hello":
            self.gs_version = msg.get("version")
            log.info("ChatBot game script is running (protocol %s)", self.gs_version)
            return
        entry = self._pending.get(msg.get("id"))
        if entry is None:
            return
        fut, on_progress = entry
        if mtype == "progress":
            if on_progress and msg.get("msg"):
                try:
                    on_progress(str(msg["msg"]))
                except Exception:  # never let a chat failure break the link
                    log.exception("progress callback failed")
        elif mtype == "result" and not fut.done():
            fut.set_result(msg)
