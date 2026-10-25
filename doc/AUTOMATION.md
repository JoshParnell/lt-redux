# Automation server

The engine can be driven by another program: virtual keyboard and mouse
input, a clock that can be paused and stepped, screenshots, Lua evaluation
and a listing of the UI. It exists so that tools, and AI agents in
particular, can play the game to check a change, without a person at the
keyboard.

The server is the `automation` cargo feature of `phx`, an HTTP server
inside the game, in `engine/lib/phx/src/automation/`.

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
| `--foreground` | Show a normal, focused window instead of an inactive one behind other windows |
| `--pref-dir <path>` | Settings directory, so the run never reads or writes your real settings |

`--seed <n>` and `--autostart` work in any run. `--seed` makes New Game build
the same world every time, and `--autostart` skips the main menu straight
into a New Game. Seeds above 2^53 lose precision, because Lua numbers are
doubles.

### What an automation run changes

- **Input** comes only from the API. Real keyboard, mouse, gamepad and window
  focus events are ignored, so the user's typing and mouse can't interfere.
  `Window:isFocused()` is always true.
- **The window** opens inactive and behind other windows, unless
  `--foreground` is given. The game never takes focus, grabs the cursor or
  moves it. When a script warps the cursor, the virtual mouse moves instead.
- **The scale factor** is 1, so UI layout and screenshot pixels don't depend
  on the monitor's DPI.
- **Audio** is muted.
- **Frames** are paced at 60 per second, or 10 while paused with nothing to
  do. Steps and fast waits run as fast as they can.

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

- `fixed`, the default: every frame advances exactly `dt` (1/60 s), however
  long it takes to render. With a seed this makes runs repeatable, apart
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

### UI

`ui` lists the widgets of the last laid-out HmGui frame. By default it lists
only what matters for driving the UI: interactive widgets (those that check
for the mouse) labelled with the text inside them, and other visible text.
`all` lists every widget. The in-game HUD isn't HmGui, so only screenshots
show it.
