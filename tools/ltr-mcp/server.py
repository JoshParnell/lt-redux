"""MCP server that launches Limit Theory Redux and drives it through the
engine's automation API (doc/AUTOMATION.md).

The bridge owns the game process, so builds, crashes and restarts come back as
tool results instead of a dead connection.
"""

import atexit
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError

REPO = Path(__file__).resolve().parents[2]
LOG_PATH = REPO / "target" / "automation" / "ltr.log"
EXE = "ltr.exe" if os.name == "nt" else "ltr"
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0

PORT_LINE = re.compile(r"Automation server listening on http://127\.0\.0\.1:(\d+)")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
LEVEL = re.compile(r"^\s*(TRACE|DEBUG|INFO|WARN|ERROR)\b")
LEVELS = ["trace", "debug", "info", "warn", "error"]

INSTRUCTIONS = """\
Drives Limit Theory Redux for testing changes. Typical loop: build, launch, act
(key/click/mouse/type/step), observe (screenshot/ui/state via lua), stop.

- The game runs in an inactive window behind the user's windows and ignores the
  real mouse and keyboard, so it never disturbs them. launch(foreground=True)
  shows it normally.
- Coordinates are window pixels, origin at the top left, same as screenshots
  taken at scale 1.
- The clock starts "fixed" (every frame advances 1/60 s). "paused" freezes time
  while frames keep rendering; step advances it. Input actions count frames.
- lua runs on the game's main thread between frames. Code is evaluated as an
  expression when it parses as one. The game forbids creating globals, so use
  locals or rawset(_G, ...). Results come back as JSON.
- Every reply starts with the frame, game time and clock, and lists new
  warnings and errors from the game log.
- Rebuild (build) after changing Rust code; Lua changes only need a relaunch.
"""


class GameError(ToolError):
    pass


class Game:
    def __init__(self):
        self.process = None
        self.port = None
        self.port_ready = threading.Event()
        self.lock = threading.Lock()
        self.lines = deque(maxlen=20000)
        self.line_count = 0
        self.reported = 0
        self.job = None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def launch(self, args):
        self.stop()
        with self.lock:
            self.lines.clear()
            self.line_count = 0
            self.reported = 0
        self.port = None
        self.port_ready.clear()

        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        startupinfo = None
        if os.name == "nt":
            # Windows applies this to the game's first ShowWindow, whatever the engine asks for.
            startupinfo = subprocess.STARTUPINFO(dwFlags=subprocess.STARTF_USESHOWWINDOW, wShowWindow=4)  # SW_SHOWNOACTIVATE
        self.process = subprocess.Popen(
            args,
            cwd=REPO,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            creationflags=NO_WINDOW,
            startupinfo=startupinfo,
        )
        self._tie_to_bridge(self.process)
        threading.Thread(target=self._read, args=(self.process,), daemon=True).start()

        deadline = time.monotonic() + 60
        while not self.port_ready.wait(0.2):
            self.check_alive()
            if time.monotonic() > deadline:
                self.stop()
                raise GameError("The game never started its automation server.\n" + self.tail(30))

    def stop(self):
        process, self.process = self.process, None
        if process is None or process.poll() is not None:
            return None
        try:
            self._post("quit", {}, timeout=5)
            process.wait(timeout=10)
        except Exception:
            process.kill()
            process.wait()
        return process.returncode

    def check_alive(self):
        if self.process is None:
            raise GameError("The game isn't running. Call launch first.")
        code = self.process.poll()
        if code is not None:
            self.process = None
            raise GameError(f"The game exited with code {code}.\n" + self.tail(40))

    def request(self, command, args=None, timeout=60):
        self.check_alive()
        try:
            return self._post(command, args or {}, timeout)
        except urllib.error.HTTPError as err:
            body = err.read()
            try:
                message = json.loads(body).get("error", body.decode())
            except ValueError:
                message = body.decode(errors="replace")
            raise GameError(ANSI.sub("", message)) from None
        except (urllib.error.URLError, OSError) as err:
            # A dropped connection usually means the game is exiting; give it a moment.
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            self.check_alive()
            raise GameError(f"No reply from the game: {err}") from None

    def _post(self, command, args, timeout):
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/{command}",
            data=json.dumps(args).encode(),
            headers={"Content-Type": "application/json"},
        )
        with self.opener.open(request, timeout=timeout) as response:
            body = response.read()
            if response.headers.get_content_type() == "image/png":
                return json.loads(response.headers.get("X-Automation", "{}")), body
            return json.loads(body)

    def _read(self, process):
        with open(LOG_PATH, "w", encoding="utf-8") as log:
            for raw in process.stdout:
                line = ANSI.sub("", raw.decode("utf-8", errors="replace").rstrip("\r\n"))
                log.write(line + "\n")
                log.flush()
                with self.lock:
                    self.lines.append(line)
                    self.line_count += 1
                match = PORT_LINE.search(line)
                if match:
                    self.port = int(match.group(1))
                    self.port_ready.set()

    def _tie_to_bridge(self, process):
        """On Windows, put the game in a job that dies with this process, so a
        closed Claude Code session never leaves a hidden game running."""
        if os.name != "nt":
            return
        import ctypes
        from ctypes import wintypes

        class IoCounters(ctypes.Structure):
            _fields_ = [(name, ctypes.c_ulonglong) for name in (
                "ReadOperationCount", "WriteOperationCount", "OtherOperationCount",
                "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class BasicLimits(ctypes.Structure):
            _fields_ = [
                ("PerProcessUserTimeLimit", ctypes.c_int64),
                ("PerJobUserTimeLimit", ctypes.c_int64),
                ("LimitFlags", wintypes.DWORD),
                ("MinimumWorkingSetSize", ctypes.c_size_t),
                ("MaximumWorkingSetSize", ctypes.c_size_t),
                ("ActiveProcessLimit", wintypes.DWORD),
                ("Affinity", ctypes.c_size_t),
                ("PriorityClass", wintypes.DWORD),
                ("SchedulingClass", wintypes.DWORD),
            ]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [
                ("BasicLimitInformation", BasicLimits),
                ("IoInfo", IoCounters),
                ("ProcessMemoryLimit", ctypes.c_size_t),
                ("JobMemoryLimit", ctypes.c_size_t),
                ("PeakProcessMemoryUsed", ctypes.c_size_t),
                ("PeakJobMemoryUsed", ctypes.c_size_t),
            ]

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateJobObjectW.restype = wintypes.HANDLE
        if self.job is None:
            self.job = kernel32.CreateJobObjectW(None, None)
            limits = ExtendedLimits()
            limits.BasicLimitInformation.LimitFlags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            kernel32.SetInformationJobObject(
                wintypes.HANDLE(self.job), 9, ctypes.byref(limits), ctypes.sizeof(limits)
            )
        kernel32.AssignProcessToJobObject(wintypes.HANDLE(self.job), wintypes.HANDLE(process._handle))

    def tail(self, count, min_level="trace", grep=None):
        with self.lock:
            lines = list(self.lines)
        floor = LEVELS.index(min_level)
        picked = [line for line in lines if level_of(line) >= floor and (grep is None or grep.search(line))]
        return "\n".join(picked[-count:])

    def new_problems(self):
        with self.lock:
            fresh = min(self.line_count - self.reported, len(self.lines))
            lines = list(self.lines)[len(self.lines) - fresh:] if fresh else []
            self.reported = self.line_count
        return [line for line in lines if level_of(line) >= LEVELS.index("warn")]


def level_of(line):
    match = LEVEL.match(line)
    level = LEVELS.index(match.group(1).lower()) if match else LEVELS.index("info")
    # Lua errors and panics are printed, or logged at info by the Lua error handler.
    if level == LEVELS.index("info") and re.search(r"panic|error|stack traceback", line, re.IGNORECASE):
        return LEVELS.index("error")
    return level


game = Game()
atexit.register(game.stop)
server = MCPServer("ltr", instructions=INSTRUCTIONS)


def tool(fn):
    return server.tool(structured_output=False)(fn)


def report(result, image=None):
    """Lead with where the game is in time, then the reply and any new log problems."""
    result = dict(result)
    header = f"frame {result.pop('frame', '?')}, time {result.pop('time', '?')}s, clock {result.pop('clock', '?')}"
    parts = [header]
    if result:
        parts.append(json.dumps(result, ensure_ascii=False))
    problems = game.new_problems()
    if problems:
        shown = problems[-10:]
        parts.append(
            f"{len(problems)} new warnings and errors in the game log"
            + (f", last {len(shown)}" if len(shown) < len(problems) else "")
            + ":\n" + "\n".join(shown)
        )
    text = "\n".join(parts)
    return [text, Image(data=image, format="png")] if image else text


def act(command, args, screenshot, timeout=60):
    result = game.request(command, args, timeout)
    if not screenshot:
        return report(result)
    meta, png = game.request("screenshot", {})
    details = {key: value for key, value in result.items() if key not in ("frame", "time", "clock")}
    return report({**meta, **details}, png)


def frame_timeout(frames):
    return 30 + frames / 10


@tool
def build(release: bool = False):
    """Build ltr with the automation feature. Stops a running game first, since
    Windows locks its binaries. Debug builds are much faster to build."""
    game.stop()
    command = ["cargo", "build", "-p", "ltr", "--features", "automation"]
    if release:
        command.append("--release")
    result = subprocess.run(
        command,
        cwd=REPO,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env={**os.environ, "CARGO_TERM_COLOR": "never"},
        creationflags=NO_WINDOW,
    )
    lines = (result.stdout + result.stderr).strip().splitlines()
    if result.returncode != 0:
        raise GameError("Build failed:\n" + "\n".join(lines[-80:]))
    warnings = sum(1 for line in lines if line.startswith("warning"))
    return f"{lines[-1] if lines else 'Built.'}\n{warnings} warning lines."


@tool
def launch(
    app: str = "",
    seed: int | None = None,
    autostart: bool = False,
    width: int = 1280,
    height: int = 720,
    clock: str = "fixed",
    foreground: bool = False,
    release: bool = False,
    pref_dir: str = "",
    args: list[str] | None = None,
):
    """Start the game (stopping any running one) and wait for its first frame.

    app: a state under script/States/App or its Tests folder, e.g. "SolarSystemPlayable";
    empty runs the main game. seed and autostart skip the main menu into a
    reproducible New Game. pref_dir defaults to a fresh scratch folder, so the
    user's settings are never touched. args are extra ltr flags.
    """
    exe = REPO / "target" / ("release" if release else "debug") / EXE
    if not exe.exists():
        raise GameError(f"{exe} doesn't exist. Run build first.")
    command = [
        str(exe), "--automation", "0", "--no-color",
        "--window-size", f"{width}x{height}",
        "--pref-dir", pref_dir or tempfile.mkdtemp(prefix="ltr-prefs-"),
    ]
    if foreground:
        command.append("--foreground")
    if seed is not None:
        command += ["--seed", str(seed)]
    if autostart:
        command.append("--autostart")
    command += args or []
    if app:
        command.append(app)

    game.launch(command)
    game.request("status", timeout=300)
    game.request("clock", {"mode": clock})
    return report(game.request("status"))


@tool
def stop():
    """Quit the game, killing it if it doesn't exit within a few seconds."""
    code = game.stop()
    return "The game wasn't running." if code is None else f"The game exited with code {code}."


@tool
def status():
    """Frame, time, clock, window size and frame rate of the running game."""
    return report(game.request("status"))


@tool
def logs(tail: int = 60, level: str = "info", grep: str = ""):
    """Recent game log lines at or above level (trace, debug, info, warn, error),
    optionally filtered by a regex. The full log is target/automation/ltr.log."""
    if level not in LEVELS:
        raise GameError(f"level must be one of {', '.join(LEVELS)}")
    pattern = re.compile(grep, re.IGNORECASE) if grep else None
    text = game.tail(tail, level, pattern)
    with game.lock:
        game.reported = game.line_count
    return text or "No matching log lines."


@tool
def screenshot(scale: float = 1.0, region: list[int] | None = None):
    """Capture the next frame. scale in (0, 1] shrinks it; region is
    [x, y, width, height] in window pixels."""
    args = {"scale": scale}
    if region:
        args["region"] = region
    meta, png = game.request("screenshot", args)
    return report(meta, png)


@tool
def ui(text: str = "", all: bool = False):
    """List the HmGui widgets of the last frame: interactive ones labelled with the
    text inside them, plus other visible text, with rects [x, y, w, h].
    text filters by substring; all lists every widget, including hidden ones."""
    return report(game.request("ui", {"text": text, "all": all}))


@tool
def lua(code: str, depth: int = 4):
    """Run Lua in the game between frames and return the result as JSON.
    Tables are expanded depth levels deep."""
    return report(game.request("lua", {"code": code, "depth": depth}))


@tool
def key(key: str, action: str = "tap", frames: int = 1, screenshot: bool = False):
    """Press a key: tap (hold for frames, then release), down or up. Names are
    phx Button names (KeyboardW, KeyboardEscape) or short forms (W, Escape, F1, 1).
    Returns after the input has been applied."""
    args = {"key": key, "action": action, "frames": frames}
    return act("key", args, screenshot, frame_timeout(frames))


@tool
def mouse(
    x: float | None = None,
    y: float | None = None,
    dx: float | None = None,
    dy: float | None = None,
    frames: int = 1,
    button: str = "",
    action: str = "tap",
    scroll: float = 0,
    screenshot: bool = False,
):
    """Low-level mouse input, all starting this frame: move to x, y; apply a raw
    delta dx, dy on each of frames frames (first-person steering reads it);
    press button (Left, Right, Middle) with action tap, down or up; scroll lines."""
    args = {"frames": frames, "action": action}
    if x is not None or y is not None:
        args |= {"x": x, "y": y}
    if dx is not None or dy is not None:
        args |= {"dx": dx or 0, "dy": dy or 0}
    if button:
        args["button"] = button
    if scroll:
        args["scroll"] = scroll
    return act("mouse", args, screenshot, frame_timeout(frames))


@tool
def click(
    text: str = "",
    x: float | None = None,
    y: float | None = None,
    button: str = "Left",
    screenshot: bool = False,
):
    """Click a UI widget by its visible text (exact match preferred, then
    substring), or at x, y. Takes three frames: move, press, release."""
    args = {"button": button}
    if text:
        args["text"] = text
    else:
        args |= {"x": x, "y": y}
    return act("click", args, screenshot)


@server.tool(name="type", structured_output=False)
def type_text(text: str, screenshot: bool = False):
    """Type text into the focused text field, one character per frame."""
    return act("type", {"text": text}, screenshot, frame_timeout(len(text)))


@tool
def step(frames: int = 0, seconds: float = 0, hold: list[str] | None = None, screenshot: bool = False):
    """Advance the game frames frames (or seconds of game time), as fast as
    possible. Time advances even when the clock is paused. hold lists keys held
    down for the whole step."""
    args = {"hold": hold or []}
    if seconds:
        args["seconds"] = seconds
    else:
        args["frames"] = frames or 1
    return act("step", args, screenshot, frame_timeout(frames or seconds * 60))


@tool
def clock(mode: str = "", dt: float = 0):
    """Set the clock: realtime (wall-clock frame time), fixed (every frame
    advances dt, default 1/60 s) or paused (time frozen, frames still render)."""
    args = {}
    if mode:
        args["mode"] = mode
    if dt:
        args["dt"] = dt
    return report(game.request("clock", args))


@tool
def wait(until: str, timeout: int = 600, fast: bool = False, screenshot: bool = False):
    """Run frames until the Lua expression until is truthy, or timeout frames
    pass. fast runs them back to back, advancing time even when paused."""
    args = {"until": until, "timeout": timeout, "fast": fast}
    return act("wait", args, screenshot, frame_timeout(timeout))


if __name__ == "__main__":
    server.run()
