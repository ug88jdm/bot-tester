"""A fake OpenTTD admin port plus a scripted stand-in for the ChatBot game script."""

from __future__ import annotations

import asyncio
import json
import struct

from ottd_bot.admin import Pkt, Reader, Writer

INDUSTRIES = [
    {"id": 10, "name": "Fenwick Coal Mine", "type": "Coal Mine", "x": 40, "y": 50, "town": "Fenwick",
     "produces": [{"cargo": "COAL", "last_month": 120, "transported_pct": 0}], "accepts": []},
    {"id": 11, "name": "Fenwick Woods Coal Mine", "type": "Coal Mine", "x": 70, "y": 52, "town": "Fenwick",
     "produces": [{"cargo": "COAL", "last_month": 90, "transported_pct": 0}], "accepts": []},
    {"id": 20, "name": "Smallton Power Station", "type": "Power Station", "x": 140, "y": 60, "town": "Smallton",
     "produces": [], "accepts": ["COAL"]},
]


class FakeOpenTTD:
    def __init__(self, password: str = "secret"):
        self.password = password
        self.port = 0
        self.chats_out: list[dict] = []       # chat lines the bot sent
        self.gs_commands: list[dict] = []     # commands the bot sent to the game script
        self.subscriptions: list[tuple[int, int]] = []
        self._writer: asyncio.StreamWriter | None = None
        self._server: asyncio.base_events.Server | None = None
        self.joined = asyncio.Event()

    async def start(self) -> None:
        self._server = await asyncio.start_server(self._handle, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]

    async def stop(self) -> None:
        if self._writer:
            self._writer.close()
        if self._server:
            self._server.close()
            await self._server.wait_closed()

    def _send(self, w: Writer) -> None:
        assert self._writer is not None
        self._writer.write(w.build())

    def send_chat_packet(self, client_id: int, text: str, action: int = 3, dest: int = 0) -> None:
        """Relay a player's chat line to the admin (action 3 = broadcast, 5 + dest 2 = private to server)."""
        w = Writer(Pkt.SERVER_CHAT).u8(action).u8(dest).u32(client_id).string(text)
        w.buf += struct.pack("<Q", 0)
        self._send(w)

    def gs_send(self, obj: dict) -> None:
        self._send(Writer(Pkt.SERVER_GAMESCRIPT).string(json.dumps(obj)))

    async def _handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._writer = writer
        try:
            while True:
                size, ptype = struct.unpack("<HB", await reader.readexactly(3))
                r = Reader(await reader.readexactly(size - 3))
                await self._on_packet(ptype, r)
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass

    async def _on_packet(self, ptype: int, r: Reader) -> None:
        if ptype == Pkt.ADMIN_JOIN:
            if r.string() != self.password:
                self._send(Writer(Pkt.SERVER_ERROR).u8(4))
                return
            self._send(Writer(Pkt.SERVER_PROTOCOL).u8(3).u8(0))
            w = Writer(Pkt.SERVER_WELCOME).string("Test Server").string("16.0").u8(1).string("")
            w.u32(1234).u8(0).u32(700000).u16(256).u16(256)
            self._send(w)
            self.joined.set()
        elif ptype == Pkt.ADMIN_UPDATE_FREQUENCY:
            self.subscriptions.append((r.u16(), r.u16()))
        elif ptype == Pkt.ADMIN_POLL:
            what = r.u8()
            if what == 1:  # client info
                for cid, name, company in ((2, "alice", 0), (3, "spec", 255)):
                    w = Writer(Pkt.SERVER_CLIENT_INFO).u32(cid).string("10.0.0.1").string(name).u8(0).u32(1).u8(company)
                    self._send(w)
            elif what == 2:  # company info
                self._send(Writer(Pkt.SERVER_COMPANY_INFO).u8(0).string("Alice Transport").string("Alice"))
        elif ptype == Pkt.ADMIN_CHAT:
            self.chats_out.append({"action": r.u8(), "dest_type": r.u8(), "dest": r.u32(), "text": r.string()})
        elif ptype == Pkt.ADMIN_GAMESCRIPT:
            msg = json.loads(r.string())
            self.gs_commands.append(msg)
            self._fake_gs(msg)

    def _fake_gs(self, msg: dict) -> None:
        rid, cmd, args = msg["id"], msg["cmd"], msg["args"]

        def ok(data):
            self.gs_send({"id": rid, "type": "result", "ok": True, "data": data})

        if cmd == "ping":
            ok({"version": 1})
        elif cmd == "list_industries":
            words = (args.get("query") or "").lower().split()
            found = [i for i in INDUSTRIES
                     if all(w in f"{i['name']} {i['type']} {i['town']}".lower() for w in words)]
            ok({"total": len(found), "offset": 0, "industries": found[: args.get("limit", 25)]})
        elif cmd == "company_info":
            ok({"id": args["company"], "name": "Alice Transport", "bank_balance": 250000, "loan": 100000,
                "max_loan": 500000, "vehicles": 2, "bot_routes": 0, "date": "1950-3"})
        elif cmd == "build_rail_line":
            self.gs_send({"id": rid, "type": "progress", "msg": "Laying 120 tiles of track..."})
            ok({"route_id": 1, "cargo": "COAL", "source": "Fenwick Coal Mine", "dest": "Smallton Power Station",
                "locomotive": "Kirby Paul Tank (Steam)", "wagon": "Coal Wagon", "wagons": 7,
                "cost": 98000, "estimated_cost": 95000, "track_tiles": 120, "platform_length": 4})
        else:
            self.gs_send({"id": rid, "type": "result", "ok": False, "error": f"unsupported in fake: {cmd}"})
