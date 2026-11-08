"""Claude-driven command interpreter: chat text in, tool calls against the game, chat reply out."""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Any

import anthropic

from .tools import TOOLS, ToolExecutor

log = logging.getLogger(__name__)

SYSTEM_PROMPT = """\
You are ChatBot, a construction assistant inside a multiplayer OpenTTD game. Players type requests in \
the in-game chat and you carry them out for that player's own company using the tools.

How to work:
- Players name things loosely ("the coal mine near Fenwick", "mine x", "Smallton power station"). Resolve \
names to ids with find_industries before building. If several industries plausibly match and the request \
does not settle it, list the top 2-4 candidates (name and x,y) and ask which one; never guess an id.
- "Line", "railway" or "train" means build_rail_line. "Trucks", "lorries" or "road" means build_truck_route. \
If the player just says "route" or "connect", use rail when the industries are more than about 40 tiles \
apart and trucks otherwise, and say which you chose.
- Check that the source produces the cargo and the destination accepts it (find_industries shows both). \
If they do not match, explain and suggest a nearby industry that does.
- Build straight away when the request is clear. If the player asks what something would cost, use dry_run. \
The build tools raise the company loan when needed and refuse if even the maximum loan is not enough.
- A bot rail line is single track and runs one train; to carry more, offer a second line or a truck route.
- When a build fails, say why in plain words and suggest what to try (shorter platform, other industry, trucks).
- You can only build for the player's own company. Refuse requests to affect other companies.

Replies go straight into the game chat: plain text only, no markdown, at most about 3 short lines. \
Money values from the tools are in the game's base currency (pounds); write them like 125k or 1.2M. \
Be concise and friendly; report what was built (route id, cost, train or trucks) when done.
"""


@dataclass
class AgentConfig:
    model: str = "claude-opus-5-5"
    effort: str = "medium"
    max_tokens: int = 8000
    max_steps: int = 12
    use_fallbacks: bool = True


class Agent:
    def __init__(self, config: AgentConfig, client: anthropic.AsyncAnthropic | None = None):
        self.config = config
        self.client = client or anthropic.AsyncAnthropic()

    async def handle(self, request: str, context: str, executor: ToolExecutor) -> str:
        """Run one chat request to completion and return the reply text."""
        messages: list[dict[str, Any]] = [
            {"role": "user", "content": f"{context}\n\nPlayer request: {request}"},
        ]
        for _ in range(self.config.max_steps):
            response = await self._create(messages)

            if response.stop_reason == "refusal":
                return "Sorry, I can't help with that one."
            if response.stop_reason == "pause_turn":
                messages.append({"role": "assistant", "content": response.content})
                continue

            # Keep the assistant turn exactly as returned (thinking blocks included).
            messages.append({"role": "assistant", "content": response.content})
            tool_uses = [b for b in response.content if b.type == "tool_use"]
            if response.stop_reason != "tool_use" or not tool_uses:
                text = " ".join(b.text.strip() for b in response.content if b.type == "text" and b.text.strip())
                if response.stop_reason == "max_tokens" and not text:
                    return "Sorry, that request got too long for me - try asking in smaller steps."
                return text or "Done."

            results = []
            for block in tool_uses:
                log.info("tool %s %s", block.name, block.input)
                text, is_error = await executor.run(block.name, dict(block.input))
                log.info("-> %s%s", "ERROR " if is_error else "", text[:300])
                result: dict[str, Any] = {"type": "tool_result", "tool_use_id": block.id, "content": text}
                if is_error:
                    result["is_error"] = True
                results.append(result)
            messages.append({"role": "user", "content": results})

        return "Sorry, that took too many steps - try a more specific request."

    async def _create(self, messages: list[dict[str, Any]]):
        extra_body: dict[str, Any] = {"output_config": {"effort": self.config.effort}}
        kwargs: dict[str, Any] = {}
        if self.config.use_fallbacks:
            # Server-side fallback: if a safety classifier declines, the API retries on a fallback model.
            extra_body["fallbacks"] = "default"
            kwargs["betas"] = ["server-side-fallback-2026-07-01"]
        return await self.client.beta.messages.create(
            model=self.config.model,
            max_tokens=self.config.max_tokens,
            system=[{"type": "text", "text": SYSTEM_PROMPT, "cache_control": {"type": "ephemeral"}}],
            tools=TOOLS,
            messages=messages,
            extra_body=extra_body,
            **kwargs,
        )
