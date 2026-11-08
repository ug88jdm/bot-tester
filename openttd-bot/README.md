# OpenTTD ChatBot

A construction bot for OpenTTD multiplayer servers. Players type requests in the in-game chat and the
bot builds the network for **their own company**:

```
!bot establish a coal line between Fenwick Coal Mine and Smallton Power Station
<ChatBot> Planning COAL line Fenwick Coal Mine -> Smallton Power Station (104 tiles)...
<ChatBot> Laying 131 tiles of track...
<ChatBot> Done! Route #1: coal from Fenwick Coal Mine to Smallton Power Station, 1 train with 7 wagons, cost 98k.
```

## How it works

```
 players ──chat──▶ OpenTTD server ──admin port (TCP 3977)──▶ bridge (Python) ──▶ Claude API
                        ▲                                       │
                        └──── ChatBot Game Script ◀──JSON───────┘
                              (builds as the player's company)
```

* **`gamescript/`** is an OpenTTD Game Script (Squirrel) that runs inside the server. It receives JSON
  commands over the admin port and does the building through `GSCompanyMode`, so the player's company
  owns and pays for everything. It contains:
  * an A* rail pathfinder that never makes 90° turns, checks every piece with a test-mode build, and
    bridges rivers, roads and other tracks;
  * an A* road pathfinder that reuses existing roads;
  * station placement inside the industry's catchment (checking that the destination accepts the cargo),
    a depot, and the vehicles with full-load / unload orders;
  * a cost estimate in test mode before anything is built, an automatic loan increase when needed, and a
    full rollback if any step fails.
* **`bridge/`** is a Python service that connects to the admin port, listens to chat, and hands each
  request to Claude with a set of tools (find industries, build a rail line, build a truck route, ...).
  Claude resolves loose names like "mine x" to industry ids, picks the right tool, and writes the chat
  reply. Without an API key it falls back to a rule-based parser for fixed phrasings.

## What players can ask

| Request | Result |
|---|---|
| `!bot coal line between <mine> and <power station>` | Rail line: 2 stations, track, depot, 1 train |
| `!bot build a truck route from <forest> to <sawmill> with 4 trucks` | Truck stops, road, depot, trucks |
| `!bot how much would a rail line from X to Y cost?` | Estimate only (dry run) |
| `!bot add 2 trucks to route 3` | More trucks on a bot-built truck route |
| `!bot which coal mines near Fenwick aren't served yet?` | Industry search |
| `!bot status` / `!bot routes` | Money, loan, routes and their profits |

Public and team chat must start with `!bot`; private messages to the server need no prefix.
Spectators are told to join a company first.

## Setup

Requirements: **OpenTTD 15 or newer** on the server, and Python 3.11+ for the bridge (it can run on the
same machine or anywhere that can reach the admin port).

### 1. Install the game script

Copy (or symlink) the `gamescript` folder into the server's game script directory under the name
`ChatBot`:

```sh
# Linux; on Windows use Documents\OpenTTD\game, on macOS ~/Documents/OpenTTD/game
cp -r gamescript ~/.local/share/openttd/game/ChatBot
```

### 2. Configure the server (`openttd.cfg`)

```ini
[network]
admin_password = choose-a-long-password
; OpenTTD 15+ only accepts plain-password admin logins when this is enabled.
; Keep the admin port (3977) firewalled to the bridge's host.
allow_insecure_admin_login = true

[game_scripts]
ChatBot =
```

The game script must be selected before the game starts (in the GUI: *AI / Game Script settings*;
on a dedicated server via `[game_scripts]` as above). It can't be added to a running game.

### 3. Run the bridge

```sh
cd bridge
python -m venv .venv && . .venv/bin/activate
pip install -e .
cp config.example.toml config.toml   # set admin_password (or export OTTD_ADMIN_PASSWORD)
export ANTHROPIC_API_KEY=sk-ant-...   # optional; without it only fixed phrasings work
ottd-chatbot --config config.toml
```

You should see `joined server ...` and `game script answered ping`. Then type `!bot help` in game.

### Configuration

See `bridge/config.example.toml`. The main options:

* `llm.model` defaults to `claude-opus-5-5`. `claude-haiku-5-5` costs much less and handles most
  requests fine. Each request costs a few API calls (look up industries, build, reply).
* `bot.reply`: reply `private` (default), to the `team`, or `public`.
* `bot.fixed_company`: make the bot build for one fixed company (for example a company you created for
  it) instead of the sender's.
* `bot.allowed_players`: restrict who may give commands.
* Game script settings (*AI / Game Script settings → ChatBot*): pathfinder effort and maximum bridge length.

## Limitations

* Rail lines are single track with no signals, so each line runs one train. For more capacity, build a
  second line or a truck route; trucks can be added to truck routes at any time.
* Very long routes (hundreds of tiles across rough terrain) can exceed the pathfinder budget. Raise
  *Pathfinder effort* in the game script settings, or pick closer industries.
* The bot remembers its routes in the savegame. Routes it didn't build aren't managed.
* Admin-port login uses the plain password (`allow_insecure_admin_login`); OpenTTD's newer encrypted
  admin handshake isn't implemented.

## Development

```sh
cd bridge && pip install -e ".[test]" && pytest
```

The tests run the real bridge against a fake admin-port server (`tests/fake_server.py`) that speaks the
OpenTTD wire format and imitates the game script, with a stubbed Claude client. The Squirrel game script
has to be tested in a real OpenTTD game.
