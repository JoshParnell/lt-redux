use glam::Vec2;
use serde_json::{Value, json};

use crate::rf::Rf;
use crate::ui::hmgui::{FocusType, HmGui, HmGuiWidget, WidgetItem};

pub(super) struct UiWidget {
    pub kind: &'static str,
    pub text: String,
    pub pos: Vec2,
    pub size: Vec2,
    pub interactive: bool,
    pub hover: bool,
    pub layer: usize,
}

impl UiWidget {
    pub fn center(&self) -> Vec2 {
        self.pos + self.size * 0.5
    }

    pub fn to_json(&self) -> Value {
        json!({
            "kind": self.kind,
            "text": self.text,
            "rect": [self.pos.x.round(), self.pos.y.round(), self.size.x.round(), self.size.y.round()],
            "interactive": self.interactive,
            "hover": self.hover,
        })
    }
}

/// Widgets of the last laid-out GUI frame. Unless `all`, only the visible ones that matter for
/// driving the UI: interactive widgets, labelled with the text inside them, and other text.
pub(super) fn collect(gui: &HmGui, all: bool) -> Vec<UiWidget> {
    let mut widgets = vec![];
    let screen = Rect {
        min: Vec2::ZERO,
        max: gui.screen_size(),
    };
    for (layer, root) in gui.layer_roots().enumerate() {
        visit(gui, root, layer, screen, all, false, &mut widgets);
    }
    widgets
}

/// The best visible match for `text`: exact before partial, then interactive, topmost and smallest.
pub(super) fn find(gui: &HmGui, text: &str) -> Option<UiWidget> {
    let wanted = text.trim().to_lowercase();
    let mut widgets = collect(gui, false);

    let best = |exact: bool| {
        widgets
            .iter()
            .enumerate()
            .filter(|(_, widget)| {
                let text = widget.text.trim().to_lowercase();
                if exact {
                    text == wanted
                } else {
                    text.contains(&wanted)
                }
            })
            .max_by(|(_, a), (_, b)| {
                (a.interactive, a.layer)
                    .cmp(&(b.interactive, b.layer))
                    .then((b.size.x * b.size.y).total_cmp(&(a.size.x * a.size.y)))
            })
            .map(|(index, _)| index)
    };

    let index = best(true).or_else(|| best(false))?;
    Some(widgets.swap_remove(index))
}

#[derive(Clone, Copy)]
struct Rect {
    min: Vec2,
    max: Vec2,
}

impl Rect {
    fn overlaps(&self, pos: Vec2, size: Vec2) -> bool {
        size.x > 0.0
            && size.y > 0.0
            && pos.x < self.max.x
            && pos.y < self.max.y
            && pos.x + size.x > self.min.x
            && pos.y + size.y > self.min.y
    }

    fn intersect(&self, pos: Vec2, size: Vec2) -> Rect {
        Rect {
            min: self.min.max(pos),
            max: self.max.min(pos + size),
        }
    }
}

fn visit(
    gui: &HmGui,
    widget_rf: &Rf<HmGuiWidget>,
    layer: usize,
    clip: Rect,
    all: bool,
    labelled: bool,
    out: &mut Vec<UiWidget>,
) {
    let widget = widget_rf.as_ref();
    let shown = clip.overlaps(widget.pos, widget.size);
    let interactive = widget.mouse_over[FocusType::Mouse as usize];
    let is_text = matches!(widget.item, WidgetItem::Text(_));

    if all || (shown && (interactive || (is_text && !labelled))) {
        let text = match &widget.item {
            WidgetItem::Text(text) => text.text.clone(),
            _ if interactive => {
                let mut texts = vec![];
                gather_text(&widget, &mut texts);
                texts.join(" ")
            }
            _ => String::new(),
        };
        out.push(UiWidget {
            kind: kind(&widget.item),
            text,
            pos: widget.pos,
            size: widget.size,
            interactive,
            hover: interactive && widget.hash == gui.mouse_over_widget_hash(),
            layer,
        });
    }

    if let WidgetItem::Container(container) = &widget.item {
        let clip = if container.clip {
            clip.intersect(widget.pos, widget.size)
        } else {
            clip
        };
        for child in &container.children {
            visit(gui, child, layer, clip, all, labelled || interactive, out);
        }
    }
}

fn gather_text(widget: &HmGuiWidget, texts: &mut Vec<String>) {
    match &widget.item {
        WidgetItem::Text(text) => texts.push(text.text.clone()),
        WidgetItem::Container(container) => {
            for child in &container.children {
                gather_text(&child.as_ref(), texts);
            }
        }
        _ => {}
    }
}

fn kind(item: &WidgetItem) -> &'static str {
    match item {
        WidgetItem::Container(_) => "container",
        WidgetItem::Text(_) => "text",
        WidgetItem::Rect => "rect",
        WidgetItem::Image(_) => "image",
        WidgetItem::TextView(_) => "textview",
    }
}
