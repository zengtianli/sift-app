//! Local socket so the `sift` CLI can query the running app's live index.
//!
//! One JSON request line per connection, one JSON response line back. The
//! socket lives in the user's support dir with 0600 permissions.

use crate::{
    config::ConfigEdit,
    engine::{Engine, Row, SortKey},
    service::Service,
};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{BufRead, BufReader, BufWriter, Write},
    os::unix::{fs::PermissionsExt, net::{UnixListener, UnixStream}},
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Request {
    pub op: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub query: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dir: Option<String>,
    #[serde(default)]
    pub case_insensitive: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sort: Option<String>,
    #[serde(default)]
    pub desc: bool,
    #[serde(default)]
    pub offset: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
    /// `configure`: the change to apply to the live settings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edit: Option<ConfigEdit>,
    /// `configure`: report what would change without saving.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub dry_run: bool,
    /// `quit`: quit even while a full re-index is running (it is cancelled).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub force: bool,
    /// `app`: what the app itself is asked to do (`Service::app_action`), e.g.
    /// `{"action":"trash","paths":[…],"confirmed":true}`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Hit {
    pub path: String,
    pub kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mtime: Option<u32>,
    /// Creation time (the window's "Created" column), unix seconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ctime: Option<u32>,
}

impl From<Row> for Hit {
    fn from(row: Row) -> Self {
        Hit {
            path: row.path.to_string_lossy().into_owned(),
            kind: match row.kind {
                0 => "file",
                1 => "dir",
                2 => "symlink",
                _ => "unknown",
            },
            size: (row.state == 0 && row.kind != 1).then_some(row.size),
            mtime: (row.mtime != 0).then_some(row.mtime),
            ctime: (row.ctime != 0).then_some(row.ctime),
        }
    }
}

pub struct Server {
    path: PathBuf,
    stop: Arc<AtomicBool>,
}

impl Server {
    pub fn start(service: Arc<Service>) -> Result<Self> {
        let path = service.config().socket_path();
        if UnixStream::connect(&path).is_ok() {
            bail!("another Sift instance owns {}", path.display());
        }
        let _ = std::fs::remove_file(&path);
        let listener =
            UnixListener::bind(&path).with_context(|| format!("bind {}", path.display()))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        std::thread::Builder::new()
            .name("sift-ipc".into())
            .spawn(move || {
                for stream in listener.incoming() {
                    if thread_stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let Ok(stream) = stream else { continue };
                    let service = service.clone();
                    let _ = std::thread::Builder::new()
                        .name("sift-ipc-conn".into())
                        .spawn(move || {
                            let _ = serve(stream, &service);
                        });
                }
            })?;
        Ok(Self { path, stop })
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        // Wake the accept loop so it sees the stop flag.
        let _ = UnixStream::connect(&self.path);
        let _ = std::fs::remove_file(&self.path);
    }
}

fn serve(stream: UnixStream, service: &Service) -> Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut line = String::new();
    if reader.read_line(&mut line)? == 0 {
        return Ok(());
    }
    let mut stream = BufWriter::new(stream);
    let mut quit_after_reply = false;
    let response = match serde_json::from_str::<Request>(&line) {
        Ok(req) if req.op == "search" => match search(req, &service.engine, &mut stream) {
            Ok(()) => return Ok(()),
            Err(e) => json!({"ok": false, "error": format!("{e:#}")}),
        },
        Ok(req) if req.op == "quit" => match service.quit_blocker().filter(|_| !req.force) {
            Some(reason) => json!({"ok": false, "error": reason, "state": "scanning", "pid": std::process::id()}),
            None => {
                quit_after_reply = true;
                json!({"ok": true, "pid": std::process::id()})
            }
        },
        Ok(req) => handle(req, service).unwrap_or_else(|e| json!({"ok": false, "error": format!("{e:#}")})),
        Err(e) => json!({"ok": false, "error": format!("bad request: {e}")}),
    };
    serde_json::to_writer(&mut stream, &response)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    drop(stream);
    if quit_after_reply {
        // Same path as ⌘Q: the app terminates, saves the index, then exits.
        service.request_quit();
    }
    Ok(())
}

fn handle(req: Request, service: &Service) -> Result<Value> {
    let engine = &service.engine;
    match req.op.as_str() {
        "status" => Ok(service.status_json()),
        "control" => service.control(&req.action.unwrap_or_else(|| json!({"action":"status"}))),
        "rescan" => {
            if engine.status.paused.load(Ordering::Relaxed) { bail!("索引已暂停，请先运行 sift index resume"); }
            // Callers wait for `walks` to pass this value (a manual walk resets `rescans`).
            let walks = engine.status.walks.load(Ordering::Relaxed);
            engine.rescan();
            Ok(json!({"ok": true, "walks_before": walks}))
        }
        "flush" => Ok(json!({"ok": true, "written": engine.flush()?})),
        "configure" => {
            let edit = req.edit.context("configure needs an edit")?;
            let walks = engine.status.walks.load(Ordering::Relaxed);
            let change = service.apply_edit(&edit, req.dry_run)?;
            let mut out = serde_json::to_value(&change)?;
            out["ok"] = json!(true);
            out["walks_before"] = json!(walks);
            Ok(out)
        }
        "app" => service.app_action(&req.action.context("app needs an action")?),
        other => bail!("unknown op {other:?}"),
    }
}

/// Rows are resolved in chunks so a huge result set (`--limit 0` on a broad
/// query) never holds the engine thread for long: app searches and file
/// events interleave between chunks. The response line is written as it is
/// built, and a client that went away stops the work at the next chunk.
const ROW_CHUNK: usize = 4096;

fn search(req: Request, engine: &Engine, out: &mut impl Write) -> Result<()> {
    let sort = match req.sort.as_deref() {
        None => None,
        Some(s) => Some(SortKey::parse(s).with_context(|| format!("unknown sort key {s:?}"))?),
    };
    if let Some(limit) = req.limit.filter(|limit| *limit <= ROW_CHUNK) {
        let page = engine.search_page(req.dir, req.query, req.case_insensitive, sort, req.desc, req.offset, limit)?;
        let s = &engine.status;
        let hits: Vec<_> = page.rows.into_iter().map(|node| Hit::from(Row::from(node))).collect();
        let mut value = json!({"ok": true, "live": true, "total": page.total, "offset": page.offset,
            "search_ms": page.took.as_secs_f64() * 1000.0, "case_insensitive": req.case_insensitive,
            "state": s.state().as_str(), "rebuild_required": s.rebuild_required.load(Ordering::Relaxed),
            "repairing": s.repairing.load(Ordering::Relaxed), "results": hits});
        if let Some(loosened) = page.loosened { value["loosened"] = json!(loosened); }
        serde_json::to_writer(&mut *out, &value)?;
        out.write_all(b"\n")?;
        out.flush()?;
        return Ok(());
    }
    let Some((outcome, took, revision)) = engine.search_versioned(req.dir, req.query, req.case_insensitive, false)? else {
        bail!("search was superseded by a newer one");
    };
    let case_insensitive = req.case_insensitive;
    let mut indices = outcome.nodes.unwrap_or_default();
    if let Some(key) = sort {
        indices = engine
            .sort_at(indices, key, req.desc, false, Some(revision))
            .context("index changed during sorting; retry the search")?;
    } else if req.desc {
        indices.reverse();
    }
    let total = indices.len();
    let start = req.offset.min(total);
    let end = req.limit.map_or(total, |l| start.saturating_add(l).min(total));
    // Engine-side search time, as the app's status bar shows it (no queueing or I/O).
    let search_ms = took.as_secs_f64() * 1000.0;
    // The index health travels with the results, so an agent sees when they may be
    // incomplete (the window shows the same warning next to its list).
    let s = &engine.status;
    write!(
        out,
        r#"{{"live":true,"total":{total},"offset":{start},"search_ms":{search_ms:.3},"case_insensitive":{case_insensitive},"state":"{}","rebuild_required":{},"repairing":{}"#,
        s.state().as_str(),
        s.rebuild_required.load(Ordering::Relaxed),
        s.repairing.load(Ordering::Relaxed),
    )?;
    if let Some(loosened) = outcome.loosened {
        out.write_all(b",\"loosened\":")?;
        serde_json::to_writer(&mut *out, &loosened)?;
    }
    out.write_all(b",\"results\":[")?;
    let mut first = true;
    let mut changed = false;
    for chunk in indices[start..end].chunks(ROW_CHUNK) {
        let rows = engine.nodes_at(chunk.to_vec(), Some(revision));
        if rows.len() != chunk.len() { changed = true; break; }
        for node in rows {
            if !first {
                out.write_all(b",")?;
            }
            first = false;
            serde_json::to_writer(&mut *out, &Hit::from(Row::from(node)))?;
        }
        out.flush()?;
    }
    if changed { out.write_all(b"],\"ok\":false,\"error\":\"index changed while reading results; retry the search\",\"retryable\":true}\n")?; }
    else { out.write_all(b"],\"ok\":true}\n")?; }
    out.flush()?;
    Ok(())
}

/// Sends one request to a running app. `Ok(None)` means no app is listening.
pub fn request(socket: &Path, req: &Request) -> Result<Option<Value>> {
    request_within(socket, req, None)
}

/// The reply did not arrive within the caller's limit (the index may be loading
/// or a full walk may be holding the engine).
#[derive(Debug)]
pub struct TimedOut(pub Duration);

impl std::fmt::Display for TimedOut {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no reply from Sift within {:?} (index loading or rebuilding? see `sift status`)", self.0)
    }
}

impl std::error::Error for TimedOut {}

/// Access was denied, so the client cannot infer whether an app is listening.
#[derive(Debug)]
pub struct SocketBlocked {
    path: PathBuf,
    source: std::io::Error,
}

impl std::fmt::Display for SocketBlocked {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "access to Sift socket {} was blocked: {}; retry outside the guard: ~/Dev/tools/dev/lib/tools/cc/guarded-bin/outside-guard -- sift …", self.path.display(), self.source)
    }
}

impl std::error::Error for SocketBlocked {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> { Some(&self.source) }
}

/// Like `request`, but gives up after `timeout` (then the error is `TimedOut`).
pub fn request_within(socket: &Path, req: &Request, timeout: Option<Duration>) -> Result<Option<Value>> {
    let mut stream = match UnixStream::connect(socket) {
        Ok(s) => s,
        Err(e) if matches!(e.kind(), std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused) => return Ok(None),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied || matches!(e.raw_os_error(), Some(1 | 13)) =>
            return Err(SocketBlocked { path: socket.to_owned(), source: e }.into()),
        Err(e) => return Err(e).with_context(|| format!("connect to {}", socket.display())),
    };
    stream.set_read_timeout(timeout)?;
    serde_json::to_writer(&mut stream, req)?;
    stream.write_all(b"\n")?;
    stream.shutdown(std::net::Shutdown::Write)?;
    let mut line = String::new();
    if let Err(e) = BufReader::new(stream).read_line(&mut line) {
        if let Some(limit) = timeout.filter(|_| matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut)) {
            return Err(TimedOut(limit).into());
        }
        return Err(e.into());
    }
    Ok(Some(serde_json::from_str(&line).context("bad response from Sift")?))
}
