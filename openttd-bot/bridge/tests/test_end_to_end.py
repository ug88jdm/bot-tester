"""End-to-end tests: real AdminClient/GSLink/ChatBot against a fake server and a stubbed Claude."""

from __future__ import annotations

import asyncio
import json
from types import SimpleNamespace

import pytest
from fake_server import FakeOpenTTD

from ottd_bot.admin import AdminClient, AdminError, Reader, Writer, truncate_utf8
from ottd_bot.agent import Agent, AgentConfig
from ottd_bot.bot import BotConfig, ChatBot, _split_chat
from ottd_bot.gslink import GSLink


async def wait_for(cond, timeout=5.0):
    deadline = asyncio.get_running_loop().time() + timeout
    while not cond():
        if asyncio.get_running_loop().time() > deadline:
            raise AssertionError("condition not met in time")
        await asyncio.sleep(0.02)


async def start(agent=None, password="secret", **botcfg):
    server = FakeOpenTTD()
    await server.start()
    admin = AdminClient("127.0.0.1", server.port, password)
    gs = GSLink(admin)
    bot = ChatBot(admin, gs, agent, BotConfig(cooldown_seconds=0, **botcfg))
    task = asyncio.create_task(admin.run_forever(retry_delay=0.1))
    await wait_for(lambda: 2 in admin.clients)
    return server, admin, bot, task


async def stop(server, task):
    task.cancel()
    await server.stop()


def texts(server):
    return [c["text"] for c in server.chats_out]


# --------------------------------------------------------------------------- #


def test_packet_roundtrip():
    pkt = Writer(119).u8(3).u8(0).u32(7).string("héllo").build()
    size, ptype = int.from_bytes(pkt[:2], "little"), pkt[2]
    assert size == len(pkt) and ptype == 119
    r = Reader(pkt[3:])
    assert (r.u8(), r.u8(), r.u32(), r.string()) == (3, 0, 7, "héllo")
    assert truncate_utf8("ééé", 5) == "éé"


def test_split_chat():
    lines = _split_chat("word " * 200)
    assert all(len(line) <= 300 for line in lines) and len(lines) > 1


def test_join_subscribe_and_rule_based_build():
    async def run():
        server, admin, bot, task = await start()
        # subscribed to chat(5), client info(1), company info(2) and game script(9), all automatic
        assert {(5, 0x40), (1, 0x40), (2, 0x40), (9, 0x40)} <= set(server.subscriptions)
        assert admin.clients[2].name == "alice" and admin.clients[2].company == 0

        server.send_chat_packet(2, "!bot coal line between Fenwick Coal Mine and Smallton Power Station")
        await wait_for(lambda: any("Route #1 built" in t for t in texts(server)))

        build = [c for c in server.gs_commands if c["cmd"] == "build_rail_line"][0]
        assert build["args"] == {"company": 0, "source": 10, "dest": 20, "cargo": "coal"}
        # progress was relayed privately to alice (action CHAT_CLIENT=5, dest = her client id)
        prog = [c for c in server.chats_out if "Laying" in c["text"]][0]
        assert prog["action"] == 5 and prog["dest"] == 2
        await stop(server, task)

    asyncio.run(run())


def test_ignores_unaddressed_chat_and_rejects_spectators():
    async def run():
        server, admin, bot, task = await start()
        server.send_chat_packet(2, "hello everyone")
        server.send_chat_packet(3, "!bot status")
        await wait_for(lambda: len(server.chats_out) >= 1)
        await asyncio.sleep(0.2)
        assert len(server.chats_out) == 1
        assert "Join or start a company" in server.chats_out[0]["text"]
        assert not [c for c in server.gs_commands if c["cmd"] != "ping"]
        await stop(server, task)

    asyncio.run(run())


def test_private_message_needs_no_prefix_and_ambiguity_is_reported():
    async def run():
        server, admin, bot, task = await start()
        server.send_chat_packet(2, "truck route from fenwick to smallton power station", action=5, dest=2)
        await wait_for(lambda: any("ambiguous" in t for t in texts(server)))
        await stop(server, task)

    asyncio.run(run())


def test_bad_password_raises():
    async def run():
        server = FakeOpenTTD()
        await server.start()
        admin = AdminClient("127.0.0.1", server.port, "wrong")
        await admin.connect()
        with pytest.raises(AdminError, match="allow_insecure_admin_login"):
            await admin.read_loop()
        await admin.close()
        await server.stop()

    asyncio.run(run())


# --------------------------------------------------------------------------- #
# Claude agent with a scripted stand-in for the Messages API


def tool_use(id_, name, inp):
    return SimpleNamespace(type="tool_use", id=id_, name=name, input=inp)


def text(t):
    return SimpleNamespace(type="text", text=t)


class ScriptedClaude:
    """Replays canned responses and records every request it receives."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        self.requests.append(json.loads(json.dumps(kwargs, default=lambda o: o.__dict__)))
        return self.responses.pop(0)


def test_agent_tool_loop_end_to_end():
    claude = ScriptedClaude([
        SimpleNamespace(stop_reason="tool_use", content=[
            text("Looking that up."),
            tool_use("t1", "find_industries", {"query": "Fenwick coal"}),
            tool_use("t2", "find_industries", {"query": "Smallton power"}),
        ]),
        SimpleNamespace(stop_reason="tool_use", content=[
            tool_use("t3", "build_rail_line", {"source_industry_id": 10, "dest_industry_id": 20}),
        ]),
        SimpleNamespace(stop_reason="end_turn", content=[text("Done! Route #1: coal Fenwick -> Smallton, 98k.")]),
    ])
    agent = Agent(AgentConfig(), client=claude)

    async def run():
        server, admin, bot, task = await start(agent=agent)
        server.send_chat_packet(2, "!bot establish a coal line between fenwick mine and smallton power station")
        await wait_for(lambda: any("Route #1" in t for t in texts(server)))
        await stop(server, task)
        return server

    server = asyncio.run(run())

    # Company was injected by the bridge, not chosen by the model.
    build = [c for c in server.gs_commands if c["cmd"] == "build_rail_line"][0]
    assert build["args"]["company"] == 0

    req1, req2, req3 = claude.requests
    assert "alice" in req1["messages"][0]["content"] and "Alice Transport" in req1["messages"][0]["content"]
    assert req1["extra_body"]["fallbacks"] == "default"
    # Both parallel tool results come back in ONE user message, matched by id.
    results = req2["messages"][-1]["content"]
    assert [r["tool_use_id"] for r in results] == ["t1", "t2"]
    assert json.loads(results[0]["content"])["industries"][0]["id"] == 10
    assert req3["messages"][-1]["content"][0]["tool_use_id"] == "t3"


def test_agent_reports_tool_errors_to_model():
    claude = ScriptedClaude([
        SimpleNamespace(stop_reason="tool_use", content=[tool_use("t1", "add_trucks", {"route_id": 9, "count": 2})]),
        SimpleNamespace(stop_reason="end_turn", content=[text("Route 9 isn't a truck route of yours.")]),
    ])
    agent = Agent(AgentConfig(), client=claude)

    async def run():
        server, admin, bot, task = await start(agent=agent)
        server.send_chat_packet(2, "!bot add 2 trucks to route 9")
        await wait_for(lambda: any("Route 9" in t for t in texts(server)))
        await stop(server, task)

    asyncio.run(run())
    result = claude.requests[1]["messages"][-1]["content"][0]
    assert result["is_error"] is True and "unsupported in fake" in result["content"]
