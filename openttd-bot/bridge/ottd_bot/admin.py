"""Minimal asyncio client for the OpenTTD admin port.

Implements only what the bot needs: joining, subscribing to chat / client /
company / game-script updates, sending chat, and exchanging game-script JSON.

Wire format: every packet is ``uint16 size`` (little endian, includes the
3-byte header), ``uint8 type``, then the payload. Strings are UTF-8 and NUL
terminated. Layouts follow ``src/network/network_admin.cpp`` in OpenTTD.
"""

from __future__ import annotations

import asyncio
import logging
import struct
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from enum import IntEnum

log = logging.getLogger(__name__)

COMPANY_SPECTATOR = 255
CLIENT_ID_SERVER = 1
MAX_CHAT_BYTES = 899  # NETWORK_CHAT_LENGTH (900) including the NUL
MAX_GS_JSON_BYTES = 8999  # NETWORK_GAMESCRIPT_JSON_LENGTH (9000) including the NUL


class Pkt(IntEnum):
    ADMIN_JOIN = 0
    ADMIN_QUIT = 1
    ADMIN_UPDATE_FREQUENCY = 2
    ADMIN_POLL = 3
    ADMIN_CHAT = 4
    ADMIN_RCON = 5
    ADMIN_GAMESCRIPT = 6
    ADMIN_PING = 7

    SERVER_FULL = 100
    SERVER_BANNED = 101
    SERVER_ERROR = 102
    SERVER_PROTOCOL = 103
    SERVER_WELCOME = 104
    SERVER_NEWGAME = 105
    SERVER_SHUTDOWN = 106
    SERVER_DATE = 107
    SERVER_CLIENT_JOIN = 108
    SERVER_CLIENT_INFO = 109
    SERVER_CLIENT_UPDATE = 110
    SERVER_CLIENT_QUIT = 111
    SERVER_CLIENT_ERROR = 112
    SERVER_COMPANY_NEW = 113
    SERVER_COMPANY_INFO = 114
    SERVER_COMPANY_UPDATE = 115
    SERVER_COMPANY_REMOVE = 116
    SERVER_COMPANY_ECONOMY = 117
    SERVER_COMPANY_STATS = 118
    SERVER_CHAT = 119
    SERVER_RCON = 120
    SERVER_CONSOLE = 121
    SERVER_CMD_NAMES = 122
    SERVER_CMD_LOGGING_OLD = 123
    SERVER_GAMESCRIPT = 124
    SERVER_RCON_END = 125
    SERVER_PONG = 126
    SERVER_CMD_LOGGING = 127
    SERVER_AUTH_REQUEST = 128
    SERVER_ENABLE_ENCRYPTION = 129


class UpdateType(IntEnum):
    DATE = 0
    CLIENT_INFO = 1
    COMPANY_INFO = 2
    COMPANY_ECONOMY = 3
    COMPANY_STATS = 4
    CHAT = 5
    CONSOLE = 6
    CMD_NAMES = 7
    CMD_LOGGING = 8
    GAMESCRIPT = 9


FREQ_POLL = 0x01
FREQ_AUTOMATIC = 0x40


class NetAction(IntEnum):
    CLIENT_JOIN = 0
    CLIENT_LEAVE = 1
    SERVER_MESSAGE = 2
    CHAT_BROADCAST = 3
    CHAT_TEAM = 4
    CHAT_CLIENT = 5
    GIVE_MONEY = 6
    CLIENT_NAME_CHANGE = 7
    COMPANY_SPECTATOR = 8
    COMPANY_JOIN = 9
    COMPANY_NEW = 10
    CLIENT_KICKED = 11
    CHAT_EXTERNAL = 12


class DestType(IntEnum):
    BROADCAST = 0
    TEAM = 1
    CLIENT = 2


class AdminError(Exception):
    pass


# --------------------------------------------------------------------------- #
# Packet encoding
# --------------------------------------------------------------------------- #


class Writer:
    def __init__(self, ptype: int):
        self.ptype = ptype
        self.buf = bytearray()

    def u8(self, v: int) -> Writer:
        self.buf += struct.pack("<B", v)
        return self

    def u16(self, v: int) -> Writer:
        self.buf += struct.pack("<H", v)
        return self

    def u32(self, v: int) -> Writer:
        self.buf += struct.pack("<I", v)
        return self

    def string(self, s: str) -> Writer:
        self.buf += s.encode("utf-8") + b"\0"
        return self

    def build(self) -> bytes:
        return struct.pack("<HB", len(self.buf) + 3, self.ptype) + bytes(self.buf)


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def _take(self, n: int) -> bytes:
        if self.pos + n > len(self.data):
            raise AdminError("truncated packet")
        b = self.data[self.pos : self.pos + n]
        self.pos += n
        return b

    def u8(self) -> int:
        return self._take(1)[0]

    def boolean(self) -> bool:
        return self.u8() != 0

    def u16(self) -> int:
        return struct.unpack("<H", self._take(2))[0]

    def u32(self) -> int:
        return struct.unpack("<I", self._take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self._take(8))[0]

    def string(self) -> str:
        end = self.data.find(b"\0", self.pos)
        if end < 0:
            raise AdminError("unterminated string")
        s = self.data[self.pos : end].decode("utf-8", errors="replace")
        self.pos = end + 1
        return s

    def remaining(self) -> int:
        return len(self.data) - self.pos


def truncate_utf8(s: str, max_bytes: int) -> str:
    b = s.encode("utf-8")
    if len(b) <= max_bytes:
        return s
    return b[:max_bytes].decode("utf-8", errors="ignore")


# --------------------------------------------------------------------------- #
# Client
# --------------------------------------------------------------------------- #


@dataclass
class ClientInfo:
    client_id: int
    name: str
    company: int  # 0-based company index, COMPANY_SPECTATOR for spectators


@dataclass
class ChatMessage:
    action: NetAction
    dest_type: DestType
    client_id: int
    text: str


ChatHandler = Callable[[ChatMessage], Awaitable[None]]
GSHandler = Callable[[str], None]


class AdminClient:
    """Connects to the admin port, tracks clients/companies and dispatches events."""

    def __init__(self, host: str, port: int, password: str, name: str = "ottd-chatbot", version: str = "1.0"):
        self.host = host
        self.port = port
        self.password = password
        self.name = name
        self.version = version
        self.clients: dict[int, ClientInfo] = {}
        self.companies: dict[int, str] = {}
        self.server_name = ""
        self.on_chat: ChatHandler | None = None
        self.on_gamescript: GSHandler | None = None
        self.on_connected: Callable[[], Awaitable[None]] | None = None
        self._reader: asyncio.StreamReader | None = None
        self._writer: asyncio.StreamWriter | None = None
        self._welcomed = asyncio.Event()
        self._tasks: set[asyncio.Task] = set()

    # -- connection ---------------------------------------------------------

    @property
    def connected(self) -> bool:
        return self._writer is not None and self._welcomed.is_set()

    async def run_forever(self, retry_delay: float = 5.0) -> None:
        """Connect and process packets, reconnecting when the link drops."""
        while True:
            try:
                await self.connect()
                await self.read_loop()
            except (OSError, asyncio.IncompleteReadError, AdminError) as e:
                log.warning("admin connection lost: %s", e)
            finally:
                await self.close()
            log.info("reconnecting in %.0fs", retry_delay)
            await asyncio.sleep(retry_delay)

    async def connect(self) -> None:
        log.info("connecting to admin port %s:%d", self.host, self.port)
        self._reader, self._writer = await asyncio.open_connection(self.host, self.port)
        self._welcomed.clear()
        self._send(Writer(Pkt.ADMIN_JOIN).string(self.password).string(self.name).string(self.version))

    async def close(self) -> None:
        w, self._writer = self._writer, None
        self._welcomed.clear()
        if w is not None:
            try:
                w.close()
                await w.wait_closed()
            except OSError:
                pass

    async def read_loop(self) -> None:
        assert self._reader is not None
        while True:
            header = await self._reader.readexactly(3)
            size, ptype = struct.unpack("<HB", header)
            if size < 3:
                raise AdminError(f"bad packet size {size}")
            payload = await self._reader.readexactly(size - 3)
            await self._dispatch(ptype, Reader(payload))

    def _send(self, w: Writer) -> None:
        if self._writer is None:
            raise AdminError("not connected")
        self._writer.write(w.build())

    # -- outgoing -----------------------------------------------------------

    def subscribe(self, update: UpdateType, freq: int = FREQ_AUTOMATIC) -> None:
        self._send(Writer(Pkt.ADMIN_UPDATE_FREQUENCY).u16(update).u16(freq))

    def poll(self, update: UpdateType, d1: int = 0xFFFFFFFF) -> None:
        self._send(Writer(Pkt.ADMIN_POLL).u8(update).u32(d1))

    def send_chat(self, text: str, client_id: int | None = None, team: int | None = None) -> None:
        """Send a chat line: private to a client, to a company team, or broadcast."""
        text = truncate_utf8(text, MAX_CHAT_BYTES)
        if client_id is not None:
            w = Writer(Pkt.ADMIN_CHAT).u8(NetAction.CHAT_CLIENT).u8(DestType.CLIENT).u32(client_id)
        elif team is not None:
            w = Writer(Pkt.ADMIN_CHAT).u8(NetAction.CHAT_TEAM).u8(DestType.TEAM).u32(team)
        else:
            w = Writer(Pkt.ADMIN_CHAT).u8(NetAction.CHAT_BROADCAST).u8(DestType.BROADCAST).u32(0)
        self._send(w.string(text))

    def send_gamescript(self, json_text: str) -> None:
        if len(json_text.encode("utf-8")) > MAX_GS_JSON_BYTES:
            raise AdminError("game script message too large")
        self._send(Writer(Pkt.ADMIN_GAMESCRIPT).string(json_text))

    async def drain(self) -> None:
        if self._writer is not None:
            await self._writer.drain()

    # -- incoming -----------------------------------------------------------

    async def _dispatch(self, ptype: int, r: Reader) -> None:
        if ptype == Pkt.SERVER_PROTOCOL:
            log.debug("admin protocol version %d", r.u8())
        elif ptype == Pkt.SERVER_WELCOME:
            self.server_name = r.string()
            revision = r.string()
            log.info("joined server '%s' (OpenTTD %s)", self.server_name, revision)
            self._welcomed.set()
            for update in (UpdateType.CHAT, UpdateType.CLIENT_INFO, UpdateType.COMPANY_INFO, UpdateType.GAMESCRIPT):
                self.subscribe(update)
            self.poll(UpdateType.CLIENT_INFO)
            self.poll(UpdateType.COMPANY_INFO)
            if self.on_connected:
                self._spawn(self.on_connected())
        elif ptype in (Pkt.SERVER_FULL, Pkt.SERVER_BANNED):
            raise AdminError("server refused admin connection (full or banned)")
        elif ptype == Pkt.SERVER_ERROR:
            code = r.u8()
            raise AdminError(
                f"server error {code} (wrong admin_password, or OpenTTD 15+ needs "
                "allow_insecure_admin_login = true in the [network] section of openttd.cfg)"
            )
        elif ptype == Pkt.SERVER_AUTH_REQUEST:
            raise AdminError(
                "server requested secure authentication; set allow_insecure_admin_login = true "
                "in the [network] section of openttd.cfg"
            )
        elif ptype == Pkt.SERVER_NEWGAME:
            log.info("server started a new game")
            self.clients.clear()
            self.companies.clear()
        elif ptype == Pkt.SERVER_SHUTDOWN:
            raise AdminError("server shutting down")
        elif ptype == Pkt.SERVER_CLIENT_INFO:
            cid = r.u32()
            r.string()  # address
            name = r.string()
            r.u8()  # language (unused)
            r.u32()  # join date
            company = r.u8()
            self.clients[cid] = ClientInfo(cid, name, company)
        elif ptype == Pkt.SERVER_CLIENT_UPDATE:
            cid = r.u32()
            name = r.string()
            company = r.u8()
            self.clients[cid] = ClientInfo(cid, name, company)
        elif ptype in (Pkt.SERVER_CLIENT_QUIT, Pkt.SERVER_CLIENT_ERROR):
            self.clients.pop(r.u32(), None)
        elif ptype == Pkt.SERVER_CLIENT_JOIN:
            self.poll(UpdateType.CLIENT_INFO, r.u32())
        elif ptype in (Pkt.SERVER_COMPANY_INFO, Pkt.SERVER_COMPANY_UPDATE):
            cid = r.u8()
            self.companies[cid] = r.string()
        elif ptype == Pkt.SERVER_COMPANY_NEW:
            self.poll(UpdateType.COMPANY_INFO, r.u8())
        elif ptype == Pkt.SERVER_COMPANY_REMOVE:
            self.companies.pop(r.u8(), None)
        elif ptype == Pkt.SERVER_CHAT:
            action = r.u8()
            dest = r.u8()
            cid = r.u32()
            text = r.string()
            if cid == CLIENT_ID_SERVER:
                return
            try:
                msg = ChatMessage(NetAction(action), DestType(dest), cid, text)
            except ValueError:
                return
            if self.on_chat:
                self._spawn(self.on_chat(msg))
        elif ptype == Pkt.SERVER_GAMESCRIPT:
            text = r.string()
            if self.on_gamescript:
                self.on_gamescript(text)
        # Everything else (date, economy, console, ...) is ignored.

    def _spawn(self, coro: Awaitable[None]) -> None:
        task = asyncio.ensure_future(coro)
        self._tasks.add(task)
        task.add_done_callback(self._task_done)

    def _task_done(self, task: asyncio.Task) -> None:
        self._tasks.discard(task)
        if not task.cancelled() and task.exception() is not None:
            log.error("handler failed", exc_info=task.exception())
