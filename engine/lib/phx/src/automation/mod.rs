//! Automation server for tools such as tools/ltr-mcp; see doc/AUTOMATION.md. Requests
//! run on the main thread between frames: `begin_frame` serves them until the frame is
//! due, and `end_frame` answers the ones that wait for frames to pass.

mod capture;
mod input;
mod lua_json;
mod server;
mod ui;

use std::time::{Duration, Instant};

use crossbeam::channel::{Receiver, RecvTimeoutError, Sender};
use glam::Vec2;
use internal::AutomationSettings;
use mlua::Function;
use serde_json::{Value, json};
use winit::event::DeviceId;

use self::capture::CaptureOptions;
use self::input::{InputEvent, VirtualInput};
use self::server::{Capture, Reply, Request};
use crate::engine::Engine;
use crate::input::Button;

const FRAME_INTERVAL: Duration = Duration::from_micros(16_667);
/// Frame interval while paused with nothing to do: the window stays live without heating the GPU.
const IDLE_INTERVAL: Duration = Duration::from_millis(100);

#[derive(Clone, Copy, PartialEq, Eq)]
enum Clock {
    /// Frames advance by wall-clock time, as in a normal run.
    Realtime,
    /// Every frame advances exactly `dt`.
    Fixed,
    /// Frames keep rendering, but time only advances during `step` and fast `wait`.
    Paused,
}

impl Clock {
    fn name(self) -> &'static str {
        match self {
            Self::Realtime => "realtime",
            Self::Fixed => "fixed",
            Self::Paused => "paused",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        match name {
            "realtime" => Some(Self::Realtime),
            "fixed" => Some(Self::Fixed),
            "paused" => Some(Self::Paused),
            _ => None,
        }
    }
}

enum Until {
    /// This many frames have completed.
    Frame(u64),
    /// The predicate returns a truthy value, or `deadline` frames have completed.
    Lua {
        predicate: Function,
        started: u64,
        deadline: u64,
        fast: bool,
    },
}

struct Wait {
    until: Until,
    result: Value,
    reply: Sender<Reply>,
}

/// `Ok(Some)` replies now, `Ok(None)` means the reply comes from `end_frame`.
type Outcome = Result<Option<Value>, String>;

pub struct Automation {
    requests: Receiver<Request>,
    play_along: bool,
    clock: Clock,
    dt: f64,
    /// Frames completed so far, which is also the index of the frame being built.
    frame: u64,
    time: f64,
    /// Frames to run back to back; while paused, these advance time.
    fast_frames: u64,
    next_frame_at: Instant,
    last_frame_at: Instant,
    frame_seconds: f64,
    input: VirtualInput,
    waits: Vec<Wait>,
    captures: Vec<(CaptureOptions, Sender<Reply>)>,
}

impl Automation {
    pub fn start(settings: &AutomationSettings) -> Self {
        Self {
            requests: server::start(settings.port),
            play_along: settings.play_along,
            clock: if settings.play_along {
                Clock::Realtime
            } else {
                Clock::Fixed
            },
            dt: 1.0 / 60.0,
            frame: 0,
            time: 0.0,
            fast_frames: 0,
            next_frame_at: Instant::now(),
            last_frame_at: Instant::now(),
            frame_seconds: 0.0,
            input: VirtualInput::default(),
            waits: vec![],
            captures: vec![],
        }
    }

    /// Serve requests until this frame is due, then set its clock and input.
    pub fn begin_frame(&mut self, engine: &mut Engine) {
        // An isolated run ignores window events, so CursorEntered never arrives.
        if self.frame == 0 && !self.play_along {
            engine
                .input
                .update_mouse(DeviceId::dummy(), |state| state.update_in_window(true));
        }

        self.serve(engine);

        let dt = match self.clock {
            Clock::Realtime => None,
            Clock::Paused if self.fast_frames == 0 => Some(0.0),
            Clock::Fixed | Clock::Paused => Some(self.dt),
        };
        engine.event_bus.set_fixed_delta(dt);
        self.input.apply(self.frame, &mut engine.input);
    }

    /// Answer what this frame completed and queue screenshots of it.
    pub fn end_frame(&mut self, engine: &mut Engine) {
        self.frame += 1;
        self.time += engine.event_bus.delta_time();
        self.fast_frames = self.fast_frames.saturating_sub(1);

        let now = Instant::now();
        let elapsed = now.duration_since(self.last_frame_at).as_secs_f64();
        self.frame_seconds += (elapsed - self.frame_seconds) * 0.1;
        self.last_frame_at = now;

        for wait in std::mem::take(&mut self.waits) {
            if let Some(wait) = self.check(wait, engine) {
                self.waits.push(wait);
            }
        }

        let captures = std::mem::take(&mut self.captures);
        if !captures.is_empty() {
            let width = engine.window.physical_width();
            let height = engine.window.physical_height();
            for (options, reply) in captures {
                let pixels = engine
                    .renderer
                    .request_backbuffer_pixels(width as i32, height as i32);
                let _ = reply.send(Reply::Capture(Capture {
                    width,
                    height,
                    pixels,
                    options,
                    meta: self.stamp(json!({})),
                }));
            }
        }
    }

    fn serve(&mut self, engine: &mut Engine) {
        loop {
            let timeout = if self.fast_frames > 0 {
                Duration::ZERO
            } else {
                self.next_frame_at.saturating_duration_since(Instant::now())
            };

            match self.requests.recv_timeout(timeout) {
                Ok(request) => {
                    self.handle(request, engine);
                    if !self.waits.is_empty() || !self.captures.is_empty() {
                        break;
                    }
                }
                Err(RecvTimeoutError::Timeout) => break,
                Err(RecvTimeoutError::Disconnected) => {
                    std::thread::sleep(timeout);
                    break;
                }
            }
        }

        let busy = !self.waits.is_empty() || !self.input.is_idle();
        let interval = if self.clock == Clock::Paused && !busy {
            IDLE_INTERVAL
        } else if self.clock == Clock::Realtime && self.play_along {
            // Uncapped, like a normal run; the present mode still applies.
            Duration::ZERO
        } else {
            FRAME_INTERVAL
        };
        let now = Instant::now();
        self.next_frame_at = if self.fast_frames > 0 {
            now
        } else {
            now + interval
        };
    }

    fn handle(&mut self, request: Request, engine: &mut Engine) {
        let Request {
            command,
            args,
            reply,
        } = request;

        let outcome = match command.as_str() {
            "status" => Ok(Some(self.status(engine))),
            "clock" => self.set_clock(&args),
            "step" => self.step(&args, &reply),
            "wait" => self.wait(&args, &reply, engine),
            "lua" => self.lua(&args, engine),
            "ui" => Ok(Some(self.ui(&args, engine))),
            "key" => self.key(&args, &reply),
            "mouse" => self.mouse(&args, &reply),
            "click" => self.click(&args, &reply, engine),
            "type" => self.type_text(&args, &reply),
            "screenshot" => CaptureOptions::parse(&args).map(|options| {
                self.captures.push((options, reply.clone()));
                None
            }),
            "quit" => {
                engine.exit();
                Ok(Some(json!({})))
            }
            _ => Err(format!("Unknown command '{command}'")),
        };

        match outcome {
            Ok(Some(value)) => self.send(&reply, value),
            Ok(None) => {}
            Err(message) => {
                let _ = reply.send(Reply::Error(message));
            }
        }
    }

    fn send(&self, reply: &Sender<Reply>, value: Value) {
        let _ = reply.send(Reply::Json(self.stamp(value)));
    }

    fn stamp(&self, mut value: Value) -> Value {
        if let Value::Object(map) = &mut value {
            map.insert("frame".into(), self.frame.into());
            map.insert("time".into(), json!((self.time * 1000.0).round() / 1000.0));
            map.insert("clock".into(), self.clock.name().into());
        }
        value
    }

    fn reply_after(&mut self, frame: u64, result: Value, reply: &Sender<Reply>) {
        self.waits.push(Wait {
            until: Until::Frame(frame + 1),
            result,
            reply: reply.clone(),
        });
    }

    fn check(&mut self, wait: Wait, engine: &Engine) -> Option<Wait> {
        let outcome = match &wait.until {
            Until::Frame(frame) => (self.frame >= *frame).then(|| Ok(wait.result.clone())),
            Until::Lua {
                predicate,
                started,
                deadline,
                fast,
            } => match predicate.call::<mlua::Value>(()) {
                Err(err) => Some(Err(err.to_string())),
                Ok(value) => {
                    let met = !matches!(value, mlua::Value::Nil | mlua::Value::Boolean(false));
                    (met || self.frame >= *deadline).then(|| {
                        if *fast {
                            self.fast_frames = 0;
                        }
                        let lua = engine.lua.as_ref();
                        Ok(json!({
                            "met": met,
                            "value": lua_json::to_json(&lua, &value, lua_json::DEFAULT_DEPTH),
                            "frames": self.frame - started,
                        }))
                    })
                }
            },
        };

        match outcome {
            None => Some(wait),
            Some(Ok(value)) => {
                self.send(&wait.reply, value);
                None
            }
            Some(Err(message)) => {
                let _ = wait.reply.send(Reply::Error(message));
                None
            }
        }
    }

    fn status(&self, engine: &Engine) -> Value {
        let fps = if self.frame_seconds > 0.0 {
            (1.0 / self.frame_seconds).round()
        } else {
            0.0
        };
        json!({
            "window": [engine.window.physical_width(), engine.window.physical_height()],
            "dt": self.dt,
            "fps": fps,
        })
    }

    fn set_clock(&mut self, args: &Value) -> Outcome {
        if let Some(name) = arg_str(args, "mode") {
            self.clock = Clock::parse(name)
                .ok_or_else(|| format!("Unknown clock '{name}' (realtime, fixed or paused)"))?;
        }
        if let Some(dt) = args.get("dt").and_then(Value::as_f64) {
            if dt <= 0.0 {
                return Err("dt must be positive".into());
            }
            self.dt = dt;
        }
        Ok(Some(json!({ "dt": self.dt })))
    }

    fn step(&mut self, args: &Value, reply: &Sender<Reply>) -> Outcome {
        let frames = match args.get("seconds").and_then(Value::as_f64) {
            Some(seconds) => (seconds / self.dt).round().max(0.0) as u64,
            None => arg_u64(args, "frames", 1)?,
        };
        let hold = args
            .get("hold")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|name| {
                let name = name.as_str().unwrap_or_default();
                input::parse_key(name).ok_or_else(|| format!("Unknown key '{name}'"))
            })
            .collect::<Result<Vec<_>, _>>()?;

        if frames == 0 {
            return Ok(Some(json!({ "frames": 0 })));
        }

        let at = self.frame;
        for &button in &hold {
            self.input.schedule(at, InputEvent::Button(button, true));
            self.input
                .schedule(at + frames, InputEvent::Button(button, false));
        }
        self.fast_frames += frames;

        // A hold ends with a release frame, so the reply shows the keys up again.
        let last = if hold.is_empty() {
            at + frames - 1
        } else {
            at + frames
        };
        self.reply_after(last, json!({ "frames": frames }), reply);
        Ok(None)
    }

    fn wait(&mut self, args: &Value, reply: &Sender<Reply>, engine: &Engine) -> Outcome {
        let condition = arg_str(args, "until").ok_or("until is required")?;
        let timeout = arg_u64(args, "timeout", 600)?;
        let fast = args.get("fast").and_then(Value::as_bool).unwrap_or(false);

        let lua = engine.lua.as_ref();
        lua_json::expose_helpers(&lua);
        let predicate = lua
            .load(format!("return ({condition})"))
            .set_name("=wait")
            .into_function()
            .map_err(|err| err.to_string())?;

        if fast {
            self.fast_frames = self.fast_frames.max(timeout);
        }
        self.waits.push(Wait {
            until: Until::Lua {
                predicate,
                started: self.frame,
                deadline: self.frame + timeout,
                fast,
            },
            result: Value::Null,
            reply: reply.clone(),
        });
        Ok(None)
    }

    fn lua(&mut self, args: &Value, engine: &Engine) -> Outcome {
        let code = arg_str(args, "code").ok_or("code is required")?;
        let depth = arg_u64(args, "depth", lua_json::DEFAULT_DEPTH as u64)? as usize;
        let result = lua_json::eval(&engine.lua.as_ref(), code, depth)?;
        Ok(Some(json!({ "result": result })))
    }

    fn ui(&self, args: &Value, engine: &Engine) -> Value {
        let all = args.get("all").and_then(Value::as_bool).unwrap_or(false);
        let filter = arg_str(args, "text").map(str::to_lowercase);
        let widgets: Vec<Value> = ui::collect(&engine.hmgui, all)
            .iter()
            .filter(|widget| {
                filter
                    .as_ref()
                    .is_none_or(|filter| widget.text.to_lowercase().contains(filter))
            })
            .map(ui::UiWidget::to_json)
            .collect();
        json!({ "widgets": widgets })
    }

    fn key(&mut self, args: &Value, reply: &Sender<Reply>) -> Outcome {
        let name = arg_str(args, "key").ok_or("key is required")?;
        let button = input::parse_key(name).ok_or_else(|| format!("Unknown key '{name}'"))?;
        let last = self.press(button, args)?;
        self.reply_after(last, json!({}), reply);
        Ok(None)
    }

    fn mouse(&mut self, args: &Value, reply: &Sender<Reply>) -> Outcome {
        let at = self.frame;
        let mut last = at;

        if let Some(pos) = arg_pair(args, "x", "y")? {
            self.input.schedule(at, InputEvent::MouseMove(pos));
        }
        if let Some(delta) = arg_pair(args, "dx", "dy")? {
            let frames = arg_u64(args, "frames", 1)?.max(1);
            for frame in at..at + frames {
                self.input.schedule(frame, InputEvent::MouseDelta(delta));
            }
            last = last.max(at + frames - 1);
        }
        if let Some(scroll) = args.get("scroll").and_then(Value::as_f64) {
            self.input
                .schedule(at, InputEvent::Scroll(Vec2::new(0.0, scroll as f32)));
        }
        if let Some(name) = arg_str(args, "button") {
            let button = input::parse_mouse_button(name)
                .ok_or_else(|| format!("Unknown mouse button '{name}'"))?;
            last = last.max(self.press(button, args)?);
        }

        self.reply_after(last, json!({}), reply);
        Ok(None)
    }

    /// Schedule a tap held for `frames`, a press or a release; returns its last frame.
    fn press(&mut self, button: Button, args: &Value) -> Result<u64, String> {
        let at = self.frame;
        match arg_str(args, "action").unwrap_or("tap") {
            "tap" => {
                let frames = arg_u64(args, "frames", 1)?.max(1);
                self.input.schedule(at, InputEvent::Button(button, true));
                self.input
                    .schedule(at + frames, InputEvent::Button(button, false));
                Ok(at + frames)
            }
            "down" => {
                self.input.schedule(at, InputEvent::Button(button, true));
                Ok(at)
            }
            "up" => {
                self.input.schedule(at, InputEvent::Button(button, false));
                Ok(at)
            }
            action => Err(format!("Unknown action '{action}' (tap, down or up)")),
        }
    }

    fn click(&mut self, args: &Value, reply: &Sender<Reply>, engine: &Engine) -> Outcome {
        let (pos, target) = match arg_str(args, "text") {
            Some(text) => {
                let widget = ui::find(&engine.hmgui, text)
                    .ok_or_else(|| format!("No visible UI text matches '{text}'"))?;
                (widget.center(), widget.to_json())
            }
            None => (
                arg_pair(args, "x", "y")?.ok_or("click needs text, or x and y")?,
                Value::Null,
            ),
        };
        let name = arg_str(args, "button").unwrap_or("Left");
        let button = input::parse_mouse_button(name)
            .ok_or_else(|| format!("Unknown mouse button '{name}'"))?;

        // HmGui works out what's under the mouse from the previous frame's
        // layout, so the press comes a frame after the move.
        let at = self.frame;
        self.input.schedule(at, InputEvent::MouseMove(pos));
        self.input
            .schedule(at + 1, InputEvent::Button(button, true));
        self.input
            .schedule(at + 2, InputEvent::Button(button, false));

        let result = json!({ "x": pos.x.round(), "y": pos.y.round(), "target": target });
        self.reply_after(at + 2, result, reply);
        Ok(None)
    }

    fn type_text(&mut self, args: &Value, reply: &Sender<Reply>) -> Outcome {
        let text = arg_str(args, "text").ok_or("text is required")?;
        let at = self.frame;
        let mut last = at;
        for (i, ch) in text.chars().enumerate() {
            last = at + i as u64;
            self.input.schedule(last, InputEvent::Text(ch.to_string()));
        }
        self.reply_after(last, json!({}), reply);
        Ok(None)
    }
}

fn arg_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key).and_then(Value::as_str)
}

fn arg_u64(args: &Value, key: &str, default: u64) -> Result<u64, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| format!("{key} must be a non-negative integer")),
    }
}

fn arg_pair(args: &Value, x: &str, y: &str) -> Result<Option<Vec2>, String> {
    match (
        args.get(x).and_then(Value::as_f64),
        args.get(y).and_then(Value::as_f64),
    ) {
        (Some(x), Some(y)) => Ok(Some(Vec2::new(x as f32, y as f32))),
        (None, None) => Ok(None),
        _ => Err(format!("{x} and {y} go together")),
    }
}
