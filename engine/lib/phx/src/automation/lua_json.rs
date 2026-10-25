use std::collections::HashSet;
use std::ffi::c_void;

use mlua::{Function, Lua, MultiValue, Table};
use serde_json::{Map, Value};
use tracing::warn;

pub(super) const DEFAULT_DEPTH: usize = 4;
const MAX_ENTRIES: usize = 100;
const MAX_NODES: usize = 5000;

/// Make script/Shared/Tools/Automation.lua the global `Automation`, loading it on first use.
/// A broken module only logs, so the rest of Lua still works while it's being edited.
pub(super) fn expose_helpers(lua: &Lua) {
    let result = lua
        .load(
            "if rawget(_G, 'Automation') == nil then \
             rawset(_G, 'Automation', require('Shared.Tools.Automation')) end",
        )
        .set_name("=automation")
        .exec();
    if let Err(err) = result {
        warn!("Automation helpers failed to load: {err}");
    }
}

/// Run `code` as an expression if it parses as one, otherwise as a chunk.
pub(super) fn eval(lua: &Lua, code: &str, depth: usize) -> Result<Value, String> {
    expose_helpers(lua);
    let chunk = lua
        .load(format!("return {code}"))
        .set_name("=automation")
        .into_function()
        .or_else(|_| lua.load(code).set_name("=automation").into_function())
        .map_err(|err| err.to_string())?;

    let globals = lua.globals();
    let xpcall: Function = globals.get("xpcall").map_err(|err| err.to_string())?;
    let traceback: Function = globals
        .get::<Table>("debug")
        .and_then(|debug| debug.get("traceback"))
        .map_err(|err| err.to_string())?;

    let mut results = xpcall
        .call::<MultiValue>((chunk, traceback))
        .map_err(|err| err.to_string())?
        .into_iter();
    let ok = matches!(results.next(), Some(mlua::Value::Boolean(true)));
    let values: Vec<mlua::Value> = results.collect();

    if !ok {
        return Err(match values.first() {
            Some(mlua::Value::String(message)) => message.to_string_lossy(),
            other => format!("{other:?}"),
        });
    }

    Ok(match values.as_slice() {
        [] => Value::Null,
        [value] => to_json(lua, value, depth),
        values => Value::Array(
            values
                .iter()
                .map(|value| to_json(lua, value, depth))
                .collect(),
        ),
    })
}

/// Tables become arrays or objects down to `depth`; anything else that JSON
/// can't hold (functions, FFI values, deeper tables) becomes its `tostring`.
pub(super) fn to_json(lua: &Lua, value: &mlua::Value, depth: usize) -> Value {
    let mut converter = Converter {
        tostring: lua.globals().get("tostring").ok(),
        max_depth: depth,
        nodes: 0,
        open_tables: HashSet::new(),
    };
    converter.convert(value, 0)
}

struct Converter {
    tostring: Option<Function>,
    max_depth: usize,
    nodes: usize,
    open_tables: HashSet<*const c_void>,
}

impl Converter {
    fn convert(&mut self, value: &mlua::Value, depth: usize) -> Value {
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return Value::String("…".into());
        }

        match value {
            mlua::Value::Nil => Value::Null,
            mlua::Value::Boolean(b) => Value::Bool(*b),
            mlua::Value::Integer(i) => Value::from(*i),
            mlua::Value::Number(n) => serde_json::Number::from_f64(*n)
                .map_or_else(|| Value::String(n.to_string()), Value::Number),
            mlua::Value::String(s) => Value::String(s.to_string_lossy()),
            mlua::Value::Table(table) => self.table(table, depth),
            other => Value::String(self.describe(other)),
        }
    }

    fn table(&mut self, table: &Table, depth: usize) -> Value {
        let pointer = table.to_pointer();
        // A table that is already open is a cycle.
        if depth >= self.max_depth || !self.open_tables.insert(pointer) {
            return Value::String(self.describe(&mlua::Value::Table(table.clone())));
        }

        let pairs: Vec<(mlua::Value, mlua::Value)> = table
            .pairs::<mlua::Value, mlua::Value>()
            .filter_map(Result::ok)
            .collect();
        let len = table.raw_len();
        let is_array = len > 0
            && pairs.len() == len
            && pairs
                .iter()
                .all(|(key, _)| index(key).is_some_and(|i| i >= 1 && i <= len));

        let result = if is_array {
            let mut items: Vec<Value> = (1..=len.min(MAX_ENTRIES))
                .map(|i| {
                    let item = table.raw_get(i).unwrap_or(mlua::Value::Nil);
                    self.convert(&item, depth + 1)
                })
                .collect();
            if len > MAX_ENTRIES {
                items.push(Value::String(format!("… {} more", len - MAX_ENTRIES)));
            }
            Value::Array(items)
        } else {
            let mut map = Map::new();
            for (key, value) in pairs.iter().take(MAX_ENTRIES) {
                let key = self.key(key);
                let value = self.convert(value, depth + 1);
                map.insert(key, value);
            }
            if pairs.len() > MAX_ENTRIES {
                map.insert(
                    "…".into(),
                    Value::String(format!("{} more", pairs.len() - MAX_ENTRIES)),
                );
            }
            Value::Object(map)
        };

        self.open_tables.remove(&pointer);
        result
    }

    fn key(&self, key: &mlua::Value) -> String {
        match key {
            mlua::Value::String(s) => s.to_string_lossy(),
            mlua::Value::Integer(i) => i.to_string(),
            mlua::Value::Number(n) => n.to_string(),
            mlua::Value::Boolean(b) => b.to_string(),
            other => self.describe(other),
        }
    }

    fn describe(&self, value: &mlua::Value) -> String {
        self.tostring
            .as_ref()
            .and_then(|tostring| tostring.call::<String>(value.clone()).ok())
            .unwrap_or_else(|| value.type_name().to_string())
    }
}

fn index(key: &mlua::Value) -> Option<usize> {
    match key {
        mlua::Value::Integer(i) => usize::try_from(*i).ok(),
        mlua::Value::Number(n) if n.fract() == 0.0 && *n >= 0.0 => Some(*n as usize),
        _ => None,
    }
}
