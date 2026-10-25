# Automation server

The engine can be driven by another program: virtual keyboard and mouse
input, a clock that can be paused and stepped, screenshots, Lua evaluation
and a listing of the UI. It exists so that tools, and AI agents in
particular, can play the game to check a change, without a person at the
keyboard.

It has two parts:

- **The server**, the `automation` cargo feature of `phx`. It's an HTTP
  server inside the game, in `engine/lib/phx/src/automation/`.
- **`tools/ltr-mcp`**, an [MCP](https://modelcontextprotocol.io) server that
  launches the game and exposes the API as tools for Claude Code. It owns the
  game process, so builds, crashes and restarts come back as tool results.

## Running with the server

```bash
cargo run -p ltr --features automation -- --automation 0 --seed 12345 --autostart
```

`--automation <port>` starts the server; port `0` picks a free one. The game
logs the address it listens on:

```
INFO Automation server listening on http://127.0.0.1:52417
```

Flags for an automation run:

| Flag | Effect |
|------|--------|
| `--automation <port>` | Serve the API. Required for the flags below to apply |
| `--window-size WxH` | Physical window size, default `1280x720`. Scripts can't resize the window or make it fullscreen |
| `--play-along` | Run like a normal game you can play alongside the client. See below |
| `--pref-dir <path>` | Settings directory, so the run never reads or writes your real settings |

`--seed <n>` and `--autostart` work in any run. `--seed` makes New Game build
the same world every time, and `--autostart` skips the main menu straight
into a New Game. Seeds above 2^53 lose precision, because Lua numbers are
doubles.

### What an automation run changes

By default a run is isolated, so it can run unattended without getting in
anyone's way:

- **Input** comes only from the API. Real keyboard, mouse, gamepad and window
  focus events are ignored, so the user's typing and mouse can't interfere.
  `Window:isFocused()` is always true.
- **The window** opens inactive and behind other windows, at
  `--window-size`. The game never takes focus, grabs the cursor or moves it.
  When a script warps the cursor, the virtual mouse moves instead.
- **The scale factor** is 1, so UI layout and screenshot pixels don't depend
  on the monitor's DPI.
- **Audio** is muted.
- **Frames** are paced at 60 per second, or 10 while paused with nothing to
  do. Steps and fast waits run as fast as they can.

### Playing along

`--play-along` runs the game normally, so a person can play it while the
client drives it too, for stepping through a feature together. The window,
cursor, focus and sound behave as in a normal run, so the main game goes
fullscreen. Real input works and mixes with API input; whichever moves the
mouse last wins. `--window-size` doesn't apply, so screenshots are the size
of the window.

The clock starts at `realtime` and frames aren't capped, as in a normal run.
The other clocks work as in an isolated run.

## API

Every endpoint takes an optional JSON body, by `POST` or `GET`, and returns
JSON. The one exception is `/screenshot`, which returns a PNG.

```bash
curl -s -d '{"key": "Escape"}' http://127.0.0.1:52417/key
```

Commands run on the main thread between frames. Commands that read state
(`status`, `lua`, `ui`, `clock`) answer right away. Commands that need frames
to pass answer once they have: input, `step`, `wait` and `screenshot`.
Requests are handled one at a time.

Every JSON reply includes `frame` (frames completed), `time` (seconds of game
time, which respects the game's own pause and time acceleration) and
`clock`. Errors come back as `{"error": "..."}` with status 400.

Coordinates are window pixels with the origin at the top left, the same as
a screenshot at scale 1.

| Endpoint | Arguments | Reply |
|----------|-----------|-------|
| `status` | | `window` size, `dt`, `fps` |
| `clock` | `mode`: `realtime`, `fixed` or `paused`; `dt` | `dt` |
| `step` | `frames` or `seconds`; `hold`: list of keys | `frames` |
| `wait` | `until`: Lua expression; `timeout` in frames (600); `fast` | `met`, `value`, `frames` |
| `lua` | `code`; `depth` (4) | `result` |
| `ui` | `text` filter; `all` | `widgets` |
| `key` | `key`; `action`: `tap`, `down` or `up`; `frames` (1) | |
| `mouse` | `x, y` move; `dx, dy` raw delta for `frames`; `button` + `action`; `scroll` | |
| `click` | `text`, or `x, y`; `button` (`Left`) | `x`, `y`, `target` |
| `type` | `text` | |
| `screenshot` | `scale` in (0, 1]; `region` `[x, y, w, h]`; `save` path | PNG, or JSON with `path` when saving |
| `quit` | | |

### Clock

- `fixed`, the default unless playing along: every frame advances exactly
  `dt` (1/60 s), however long it takes to render. With a seed this makes runs repeatable, apart
  from work that finishes on worker threads.
- `paused`: frames keep rendering, so screenshots and the UI stay live, but
  time doesn't advance. `step` advances it, as does `wait` with `fast`.
- `realtime`: frame time is wall-clock time, as in a normal run.

The clock replaces the frame delta in `EventBus`. The game's own pause and
time acceleration scale it as usual.

### Input

Input goes through the same `Input` calls as window events, so scripts can't
tell it from real input. Key names are `Button` names (`KeyboardW`,
`MouseLeft`) or short forms (`W`, `Escape`, `F1`, `1`). A tap holds the key
for `frames` frames and then releases it. The reply comes once the release
has been applied.

`click` takes three frames: move, press, release. HmGui decides what's under
the mouse from the previous frame's layout, so the press can't come in the
same frame as the move. `click` with `text` picks the best visible widget:
exact matches before partial ones, then interactive widgets, the topmost
layer and the smallest rect.

Mouse movement (`dx, dy`) is zeroed by `Input::reset` every frame, so it is
re-applied on each of `frames` frames. First-person steering reads it.

### Lua

`lua` and `wait` run on the main thread. Code is evaluated as an expression
when it parses as one (`GameState.state`), and otherwise as a chunk
(`local n = 0 ... return n`). The game's `GlobalRestrict` raises on reading an
undefined global or creating one, so use locals or `rawset(_G, ...)`.

Results become JSON. Sequences become arrays and other tables objects, down
to `depth` levels and at most 100 entries per table. Functions, FFI values
such as `Vec3f`, cycles and deeper tables become their `tostring`.

### Lua helpers

`lua` and `wait` code can use the global `Automation`, the module in
`script/Shared/Tools/Automation.lua`, loaded on first use. Targets are
entities or text matched against entity names, nearest first (`"Planet"`,
`"Station 1"`). Distances and speeds are physics units, and fields ending in
`Hud` format them the way the HUD does.

| Helper | Does |
|--------|------|
| `state()` | Game state, pause, camera mode, pause menu, map, HUD, focus and window |
| `ship()` | The player ship entity |
| `entities{match=, within=, near=, limit=}` | Entities with a rigid body, nearest first |
| `find(text)` | The nearest entity whose name contains `text` |
| `nav(target)` | Distance to the target's surface, speed, and the target's direction in the ship's frame |
| `aimAt(target)` | Turn the ship to face the target instantly |
| `placeNear(target, altitude)` | Move the ship to `altitude` above the target's surface, facing it |
| `flyTo(target)` | Queue a FlyTo action, flown by the game's autopilot |
| `face(target)` | Queue turning the ship to face the target |
| `wait(seconds)` | Queue holding still for `seconds` of game time |
| `push(action)`, `queue(action)` | Interrupt with, or queue, any action from `Automation.Actions` |
| `actions()` | The ship's actions, the running one first |
| `idle()` | True once the ship has no actions left |
| `autopilot()` | Autopilot state, including whether it's steering around an obstacle |
| `stop()` | Clear the ship's actions and disengage the autopilot |
| `keyFor(action, negative)` | Name of the key bound to an input action, as the `action` tool uses |

`placeNear` and `aimAt` set up a scene instantly. `flyTo`, `face` and `wait`
use the game's own action stack, the same orders an NPC would run, so a
sequence reads in order: `Automation.flyTo('Station 1')`, then
`Automation.wait(2)`, then wait on `Automation.idle()`.

### UI

`ui` lists the widgets of the last laid-out HmGui frame. By default it lists
only what matters for driving the UI: interactive widgets (those that check
for the mouse) labelled with the text inside them, and other visible text.
`all` lists every widget. The in-game HUD isn't HmGui, so only screenshots
show it.

## The MCP server

`tools/ltr-mcp/server.py` uses the Python MCP SDK. One-time setup, from the
repository root:

```bash
python -m venv tools/ltr-mcp/.venv
tools/ltr-mcp/.venv/Scripts/python -m pip install -r tools/ltr-mcp/requirements.txt
claude mcp add --scope local ltr -- "$PWD/tools/ltr-mcp/.venv/Scripts/python.exe" "$PWD/tools/ltr-mcp/server.py"
```

On macOS and Linux the interpreter is `.venv/bin/python`. `--scope local`
keeps the registration in your own Claude Code config rather than the
repository.

Local scope is keyed by the project path exactly as written, drive letter
case included. On Windows, VS Code opens the folder as `c:\...` while
terminals use `C:\...`, so register from the spelling your sessions use, or
from both:

```bash
cmd //c "cd /d c:\path\to\lt-redux && claude mcp add --scope local ltr -- ..."
```

The tools mirror the API, plus:

- `build`: `cargo build -p ltr --features automation`. It stops a running
  game first, because Windows locks its binaries.
- `launch`: start the game and wait for its first frame. An isolated run gets
  a fresh settings folder. `play_along` runs with your own settings, in the
  foreground.
- `stop`
- `logs`: the game log, filtered by level or regex. The full log is
  `target/automation/ltr.log`.
- `action`: press the key bound to an input action such as
  `ShipActions.Dock`, so tests follow the bindings rather than hardcoding
  keys.

Input tools and `step` and `wait` take `screenshot` to capture the frame
after they finish. Each reply lists new warnings and errors from the game log.

On Windows the game runs in a job object tied to the MCP server, so closing
Claude Code never leaves a hidden game running.
