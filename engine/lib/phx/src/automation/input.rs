use glam::Vec2;
use winit::event::DeviceId;

use crate::input::{Button, Input};

pub(super) enum InputEvent {
    Button(Button, bool),
    MouseMove(Vec2),
    MouseDelta(Vec2),
    Scroll(Vec2),
    Text(String),
}

/// Input events waiting for the frame they apply at.
#[derive(Default)]
pub(super) struct VirtualInput {
    events: Vec<(u64, InputEvent)>,
    text_time: f64,
}

impl VirtualInput {
    pub fn schedule(&mut self, frame: u64, event: InputEvent) {
        self.events.push((frame, event));
    }

    pub fn is_idle(&self) -> bool {
        self.events.is_empty()
    }

    /// Feed the events due at `frame` through the same `Input` calls window events use.
    pub fn apply(&mut self, frame: u64, input: &mut Input) {
        let device = DeviceId::dummy();
        let (due, later) = std::mem::take(&mut self.events)
            .into_iter()
            .partition(|(at, _)| *at <= frame);
        self.events = later;

        for (_, event) in due {
            match event {
                InputEvent::Button(button, pressed) => {
                    if let Some(key) = button.as_keyboard_button() {
                        input.update_keyboard(device, |state| state.update(key, pressed));
                    } else if let Some(control) = button.as_mouse_control() {
                        input.update_mouse(device, |state| state.update_button(control, pressed));
                    }
                }
                InputEvent::MouseMove(pos) => {
                    input.update_mouse(device, |state| state.update_position(pos.x, pos.y));
                }
                InputEvent::MouseDelta(delta) => {
                    input.update_mouse(device, |state| state.update_raw_delta(delta.x, delta.y));
                }
                InputEvent::Scroll(amount) => {
                    input
                        .update_mouse(device, |state| state.update_scroll_line(amount.x, amount.y));
                }
                InputEvent::Text(text) => {
                    // KeyboardState drops text that follows the previous text within its
                    // typing delay, so each event gets its own moment.
                    self.text_time += 1.0;
                    let time = self.text_time;
                    input.update_keyboard(device, |state| state.set_text(&text, time));
                }
            }
        }
    }
}

/// A keyboard key or mouse button by its `Button` name (`KeyboardW`, `MouseLeft`) or a
/// short form (`W`, `Space`, `F1`, `1`), ignoring case.
pub(super) fn parse_key(name: &str) -> Option<Button> {
    let prefixes = ["", "Keyboard", "KeyboardKey", "Mouse"];
    prefixes
        .iter()
        .find_map(|prefix| find_button(&format!("{prefix}{name}")))
        .filter(is_digital)
}

/// Like `parse_key`, but `Left` means the mouse button rather than the arrow key.
pub(super) fn parse_mouse_button(name: &str) -> Option<Button> {
    find_button(&format!("Mouse{name}"))
        .or_else(|| find_button(name))
        .filter(|button| button.as_mouse_control().is_some())
        .filter(is_digital)
}

fn find_button(name: &str) -> Option<Button> {
    Button::ALL
        .iter()
        .copied()
        .find(|button| button.to_string().eq_ignore_ascii_case(name))
}

fn is_digital(button: &Button) -> bool {
    button.as_keyboard_button().is_some()
        || button
            .as_mouse_control()
            .is_some_and(|control| control.is_button())
}
