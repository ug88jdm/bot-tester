"""Tools exposed to the language model, and their mapping onto game-script commands.

The company is never a tool parameter: the bridge injects the company of the
player who sent the chat message, so a player can only build for themselves.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .gslink import GSCommandError, GSLink, GSUnavailable

QUICK_TIMEOUT = 30.0
BUILD_TIMEOUT = 900.0  # pathfinding on big maps plus queueing can take minutes


def _schema(props: dict[str, Any], required: list[str] | None = None) -> dict[str, Any]:
    return {
        "type": "object",
        "properties": props,
        "required": required or [],
        "additionalProperties": False,
    }


CARGO_PROP = {
    "type": "string",
    "description": "Cargo label such as COAL, IORE, WOOD, OIL_, GOOD, GRAI, LVST, STEL. Omit to use the cargo both industries have in common.",
}

TOOLS: list[dict[str, Any]] = [
    {
        "name": "find_industries",
        "description": (
            "Search the map's industries. 'query' words must all appear in the industry name, type or nearest "
            "town (e.g. 'Fenwick coal', 'power station'). Returns id, name, type, tile x/y, nearest town, "
            "produced cargo with last month's production and % transported, and accepted cargo labels. "
            "Use this to turn names players mention into industry ids. Results are paged."
        ),
        "input_schema": _schema(
            {
                "query": {"type": "string", "description": "Words to match, e.g. 'Smallville coal mine'."},
                "cargo": CARGO_PROP,
                "role": {"type": "string", "enum": ["produces", "accepts", "any"], "description": "With cargo: filter by producing or accepting it."},
                "offset": {"type": "integer", "minimum": 0},
                "limit": {"type": "integer", "minimum": 1, "maximum": 40},
            }
        ),
    },
    {
        "name": "find_towns",
        "description": "Search towns by name (largest first). Returns id, name, population and tile x/y.",
        "input_schema": _schema(
            {
                "query": {"type": "string"},
                "limit": {"type": "integer", "minimum": 1, "maximum": 40},
            }
        ),
    },
    {
        "name": "get_company_status",
        "description": "The requesting player's company: name, bank balance, loan, max loan, vehicle count and number of bot-built routes.",
        "input_schema": _schema({}),
    },
    {
        "name": "list_my_routes",
        "description": "Routes the bot has built for this company, with vehicle counts and profits.",
        "input_schema": _schema({}),
    },
    {
        "name": "build_rail_line",
        "description": (
            "Build a complete freight railway between two industries for the player's company: a terminus "
            "station at each end, single track found by a pathfinder (with bridges where needed), a depot, "
            "and one locomotive with as many wagons as fit, set to full-load at the source and unload at "
            "the destination. Raises the loan automatically if needed. The line is single track, so it "
            "carries exactly one train. With dry_run=true nothing is built and the estimated cost is "
            "returned. Can take a minute or more on large maps."
        ),
        "input_schema": _schema(
            {
                "source_industry_id": {"type": "integer"},
                "dest_industry_id": {"type": "integer"},
                "cargo": CARGO_PROP,
                "platform_length": {"type": "integer", "minimum": 2, "maximum": 7, "description": "Station/train length in tiles (default 4)."},
                "dry_run": {"type": "boolean"},
            },
            ["source_industry_id", "dest_industry_id"],
        ),
    },
    {
        "name": "build_truck_route",
        "description": (
            "Build a road freight route between two industries for the player's company: a truck stop at "
            "each end, road between them (reusing existing roads), a depot, and N trucks with full-load "
            "orders. Best for short distances (under ~40 tiles). dry_run=true returns the estimate only."
        ),
        "input_schema": _schema(
            {
                "source_industry_id": {"type": "integer"},
                "dest_industry_id": {"type": "integer"},
                "cargo": CARGO_PROP,
                "trucks": {"type": "integer", "minimum": 1, "maximum": 15, "description": "Number of trucks (default 3)."},
                "dry_run": {"type": "boolean"},
            },
            ["source_industry_id", "dest_industry_id"],
        ),
    },
    {
        "name": "add_trucks",
        "description": "Add trucks to an existing bot-built truck route (sharing its orders). Rail lines cannot take more trains.",
        "input_schema": _schema(
            {
                "route_id": {"type": "integer"},
                "count": {"type": "integer", "minimum": 1, "maximum": 10},
            },
            ["route_id", "count"],
        ),
    },
]


@dataclass
class _Mapping:
    cmd: str
    build: Callable[[dict[str, Any], int], dict[str, Any]]
    timeout: float


def _pick(d: dict[str, Any], *keys: str) -> dict[str, Any]:
    return {k: d[k] for k in keys if k in d and d[k] is not None}


MAPPINGS: dict[str, _Mapping] = {
    "find_industries": _Mapping("list_industries", lambda i, c: _pick(i, "query", "cargo", "role", "offset", "limit"), QUICK_TIMEOUT),
    "find_towns": _Mapping("list_towns", lambda i, c: _pick(i, "query", "limit"), QUICK_TIMEOUT),
    "get_company_status": _Mapping("company_info", lambda i, c: {"company": c}, QUICK_TIMEOUT),
    "list_my_routes": _Mapping("list_routes", lambda i, c: {"company": c}, QUICK_TIMEOUT),
    "build_rail_line": _Mapping(
        "build_rail_line",
        lambda i, c: {
            "company": c,
            "source": i["source_industry_id"],
            "dest": i["dest_industry_id"],
            **_pick(i, "cargo", "platform_length", "dry_run"),
        },
        BUILD_TIMEOUT,
    ),
    "build_truck_route": _Mapping(
        "build_road_route",
        lambda i, c: {
            "company": c,
            "source": i["source_industry_id"],
            "dest": i["dest_industry_id"],
            **_pick(i, "cargo", "trucks", "dry_run"),
        },
        BUILD_TIMEOUT,
    ),
    "add_trucks": _Mapping("add_vehicles", lambda i, c: {"company": c, **_pick(i, "route_id", "count")}, BUILD_TIMEOUT),
}


class ToolExecutor:
    def __init__(self, gs: GSLink, company: int, on_progress: Callable[[str], None] | None = None):
        self.gs = gs
        self.company = company
        self.on_progress = on_progress

    async def run(self, name: str, tool_input: dict[str, Any]) -> tuple[str, bool]:
        """Execute a tool call. Returns (result text, is_error)."""
        mapping = MAPPINGS.get(name)
        if mapping is None:
            return f"Unknown tool {name}", True
        try:
            args = mapping.build(tool_input, self.company)
        except KeyError as e:
            return f"Missing required argument {e}", True
        try:
            data = await self.gs.call(mapping.cmd, args, timeout=mapping.timeout, on_progress=self.on_progress)
        except GSCommandError as e:
            return f"Failed: {e}", True
        except GSUnavailable as e:
            return str(e), True
        return json.dumps(data, separators=(",", ":")), False
