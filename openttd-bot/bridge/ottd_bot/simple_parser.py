"""Rule-based fallback interpreter for when no LLM is configured.

Understands a handful of fixed phrasings, for example:
    coal line between Fenwick Coal Mine and Smallton Power Station
    rail line from fenwick mine to smallton power
    truck route from Oakham Forest to Oakham Sawmill with 4 trucks
    add 2 trucks to route 3
    status | routes | help
"""

from __future__ import annotations

import json
import re
from typing import Any

from .tools import ToolExecutor

HELP = (
    "Try: 'coal line between <mine> and <power station>', "
    "'truck route from <a> to <b> with 3 trucks', 'add 2 trucks to route 1', 'routes', 'status'."
)

_ROUTE_RE = re.compile(
    r"^(?:please\s+)?(?:build|make|establish|create|set up|connect)?\s*(?:an?\s+|the\s+)?"
    r"(?P<cargo>[a-z_ ]+?)?\s*"
    r"(?P<kind>rail(?:way)?\s+line|train\s+line|line|railway|truck\s+route|road\s+route|trucks?|route)\s+"
    r"(?:between|from)\s+(?P<a>.+?)\s+(?:and|to)\s+(?P<b>.+?)"
    r"(?:\s+with\s+(?P<n>\d+)\s+trucks?)?\s*[.!]?$",
    re.IGNORECASE,
)
_ADD_RE = re.compile(r"^add\s+(?P<n>\d+)\s+trucks?\s+to\s+route\s+#?(?P<r>\d+)", re.IGNORECASE)

# Words that describe a place type rather than identify it; dropped if the full name finds nothing.
_GENERIC = {"the", "mine", "station", "power", "plant", "industry", "factory", "near", "at", "in", "by", "of"}


def _clean(name: str) -> str:
    return re.sub(r"[^\w\s'-]", " ", name).strip()


async def _resolve(executor: ToolExecutor, name: str) -> tuple[dict | None, str | None]:
    """Find one industry matching a loose name. Returns (industry, error message)."""
    query = _clean(name)
    attempts = [query]
    reduced = " ".join(w for w in query.split() if w.lower() not in _GENERIC)
    if reduced and reduced != query:
        attempts.append(reduced)
    for q in attempts:
        text, is_error = await executor.run("find_industries", {"query": q, "limit": 6})
        if is_error:
            return None, text
        data = json.loads(text)
        found = data["industries"]
        if not found:
            continue
        exact = [i for i in found if i["name"].lower() == query.lower()]
        if len(exact) == 1 or len(found) == 1:
            return (exact or found)[0], None
        names = "; ".join(f"{i['name']} ({i['x']},{i['y']})" for i in found[:4])
        return None, f"'{name}' is ambiguous: {names}. Please use the full name."
    return None, f"I couldn't find an industry matching '{name}'."


def _money(v: int) -> str:
    if abs(v) >= 1_000_000:
        return f"£{v / 1_000_000:.1f}M"
    if abs(v) >= 1_000:
        return f"£{v / 1_000:.0f}k"
    return f"£{v}"


async def handle(request: str, executor: ToolExecutor) -> str:
    text = request.strip()
    low = text.lower()
    if low in ("help", "?", ""):
        return HELP
    if low in ("status", "money", "company"):
        out, err = await executor.run("get_company_status", {})
        if err:
            return out
        d = json.loads(out)
        return f"{d['name']}: balance {_money(d['bank_balance'])}, loan {_money(d['loan'])}/{_money(d['max_loan'])}, {d['vehicles']} vehicles."
    if low in ("routes", "list routes", "my routes"):
        out, err = await executor.run("list_my_routes", {})
        if err:
            return out
        routes = json.loads(out)["routes"]
        if not routes:
            return "No bot-built routes yet."
        return " | ".join(
            f"#{r['id']} {r['kind']} {r['cargo']} {r['from']} -> {r['to']}: {r['vehicles']} veh, {_money(r['profit_last_year'])} last yr"
            for r in routes
        )

    m = _ADD_RE.match(text)
    if m:
        out, err = await executor.run("add_trucks", {"route_id": int(m["r"]), "count": int(m["n"])})
        if err:
            return out
        d = json.loads(out)
        return f"Added {d['added']} truck(s) to route #{d['route_id']} (now {d['vehicles']})."

    m = _ROUTE_RE.match(text)
    if not m:
        return "I didn't understand that. " + HELP
    kind = m["kind"].lower()
    use_trucks = "truck" in kind or "road" in kind
    src, err = await _resolve(executor, m["a"])
    if err:
        return err
    dst, err = await _resolve(executor, m["b"])
    if err:
        return err
    args: dict[str, Any] = {"source_industry_id": src["id"], "dest_industry_id": dst["id"]}
    cargo = (m["cargo"] or "").strip()
    if cargo and cargo.lower() not in ("a", "an", "the", "rail", "train", "truck", "road", "new"):
        args["cargo"] = cargo  # the game script resolves labels ("COAL") and names ("iron ore")
    if use_trucks:
        if m["n"]:
            args["trucks"] = int(m["n"])
        out, err = await executor.run("build_truck_route", args)
    else:
        out, err = await executor.run("build_rail_line", args)
    if err:
        if "cargo" in args and "Unknown cargo" in out:
            args.pop("cargo")
            out, err = await executor.run("build_truck_route" if use_trucks else "build_rail_line", args)
        if err:
            return out
    d = json.loads(out)
    what = f"{d['trucks']} x {d['truck_model']}" if use_trucks else f"{d['locomotive']} + {d['wagons']} wagons"
    return f"Route #{d['route_id']} built: {d['cargo']} {d['source']} -> {d['dest']}, {what}, cost {_money(d['cost'])}."
