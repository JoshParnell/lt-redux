//! HTTP front end. Each request is handed to the main thread, which replies
//! once it has run the command; screenshots are encoded back here.

use std::io::Cursor;
use std::thread;

use crossbeam::channel::{Receiver, Sender, bounded, unbounded};
use serde_json::{Value, json};
use tiny_http::{Header, Response, Server};
use tracing::{info, warn};

use super::capture::{self, CaptureOptions};

pub(super) struct Request {
    pub command: String,
    pub args: Value,
    pub reply: Sender<Reply>,
}

pub(super) enum Reply {
    Json(Value),
    Error(String),
    Capture(Capture),
}

/// A back buffer readback in flight.
pub(super) struct Capture {
    pub width: u32,
    pub height: u32,
    pub pixels: Receiver<Vec<u8>>,
    pub options: CaptureOptions,
    pub meta: Value,
}

type HttpResponse = Response<Cursor<Vec<u8>>>;

pub(super) fn start(port: u16) -> Receiver<Request> {
    let server = Server::http(("127.0.0.1", port))
        .unwrap_or_else(|err| panic!("Cannot start the automation server on port {port}: {err}"));
    let port = server
        .server_addr()
        .to_ip()
        .map_or(port, |addr| addr.port());
    // tools/ltr-mcp reads the port from this line.
    info!("Automation server listening on http://127.0.0.1:{port}");

    let (tx, rx) = unbounded();
    thread::Builder::new()
        .name("Automation".into())
        .spawn(move || serve(server, tx))
        .expect("Failed to spawn the automation server");
    rx
}

fn serve(server: Server, requests: Sender<Request>) {
    for mut request in server.incoming_requests() {
        let command = request.url().trim_start_matches('/');
        let command = command.split('?').next().unwrap_or_default().to_string();

        let mut body = String::new();
        let response = match request.as_reader().read_to_string(&mut body) {
            Err(err) => error_response(400, &format!("Cannot read the request: {err}")),
            Ok(_) => match parse_args(&body) {
                Ok(args) => run(&requests, command, args),
                Err(err) => error_response(400, &err),
            },
        };

        if let Err(err) = request.respond(response) {
            warn!("Automation: failed to respond: {err}");
        }
    }
}

fn parse_args(body: &str) -> Result<Value, String> {
    if body.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(body).map_err(|err| format!("Invalid JSON: {err}"))
}

fn run(requests: &Sender<Request>, command: String, args: Value) -> HttpResponse {
    let (reply, replies) = bounded(1);
    if requests
        .send(Request {
            command,
            args,
            reply,
        })
        .is_err()
    {
        return error_response(503, "The game is shutting down");
    }

    match replies.recv() {
        Ok(Reply::Json(value)) => json_response(200, &value),
        Ok(Reply::Error(message)) => error_response(400, &message),
        Ok(Reply::Capture(capture)) => finish_capture(capture),
        Err(_) => error_response(503, "The game stopped before replying"),
    }
}

fn finish_capture(capture: Capture) -> HttpResponse {
    let Ok(pixels) = capture.pixels.recv() else {
        return error_response(500, "The renderer stopped before the screenshot was read");
    };
    let png = match capture::encode(&pixels, capture.width, capture.height, &capture.options) {
        Ok(png) => png,
        Err(err) => return error_response(500, &err),
    };

    let mut meta = capture.meta;
    meta["width"] = png.width.into();
    meta["height"] = png.height.into();

    match &capture.options.save {
        Some(path) => match std::fs::write(path, &png.data) {
            Ok(()) => {
                meta["path"] = path.as_str().into();
                json_response(200, &meta)
            }
            Err(err) => error_response(500, &format!("Cannot write {path}: {err}")),
        },
        None => Response::from_data(png.data)
            .with_header(header("Content-Type", "image/png"))
            .with_header(header("X-Automation", &meta.to_string())),
    }
}

fn json_response(status: u16, value: &Value) -> HttpResponse {
    Response::from_data(value.to_string().into_bytes())
        .with_status_code(status)
        .with_header(header("Content-Type", "application/json"))
}

fn error_response(status: u16, message: &str) -> HttpResponse {
    json_response(status, &json!({ "error": message }))
}

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("Invalid header")
}
