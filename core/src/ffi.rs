//! C ABI consumed by the Swift app. See `include/sift_core.h`.
//!
//! Ownership: every `*_new`/`sift_search` result is freed by its matching
//! `*_free`. Strings returned to Swift are freed with `sift_string_free`.

use crate::{
    config::Config,
    engine::{Engine, Row, SortKey},
    ipc,
    service::{self, AppActionHandler, LoginItemProbe, Service},
};
use search_cache::SlabIndex;
use std::{
    ffi::{CStr, CString, c_char},
    os::unix::ffi::OsStrExt,
    path::PathBuf,
    ptr,
    sync::{Arc, Once, atomic::Ordering},
};

pub struct SiftEngine {
    engine: Arc<Engine>,
    service: Arc<Service>,
    server: Option<ipc::Server>,
}

pub struct SiftResults {
    indices: Vec<SlabIndex>,
    highlights: String,
    loosened: Option<String>,
    micros: u64,
    revision: u64,
}

#[repr(C)]
pub struct SiftStatus {
    pub state: u8,
    pub dirty: bool,
    pub files: u64,
    pub events: u64,
    pub rescans: u64,
    pub flushes: u64,
    pub last_flush: u64,
}

#[repr(C)]
pub struct SiftRow {
    /// NUL-terminated UTF-8 (lossy) path, owned by the row buffer.
    pub path: *mut c_char,
    pub size: i64,
    pub mtime: u32,
    pub ctime: u32,
    /// 0 file, 1 dir, 2 symlink, 3 unknown.
    pub kind: u8,
    /// 0 metadata known, 1 not fetched, 2 inaccessible.
    pub state: u8,
}

pub const SIFT_OK: i32 = 0;
pub const SIFT_CANCELLED: i32 = 1;
pub const SIFT_ERROR: i32 = 2;

fn init_logging() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let filter = tracing_subscriber::EnvFilter::try_from_env("SIFT_LOG")
            // The index core logs every filesystem event at info; formatting
            // those on a busy disk is wasted CPU, so only Sift's own info shows.
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn,sift_core=info"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_writer(std::io::stderr)
            .try_init();
    });
}

unsafe fn opt_str(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn to_c(s: &str) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}

/// Loads `config.json` from `support_dir` (or the default dir when NULL),
/// starts the engine and the CLI socket. Returns NULL if another writer owns it.
///
/// # Safety
/// `support_dir` must be NULL or a valid C string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_start(support_dir: *const c_char) -> *mut SiftEngine {
    init_logging();
    let dir = unsafe { opt_str(support_dir) }
        .map(PathBuf::from)
        .unwrap_or_else(Config::default_support_dir);
    let (config, problem) = match Config::load(&dir) {
        Ok(config) => (config, String::new()),
        Err(e) => {
            let message = format!("配置无法读取，已保留最后有效范围；没有有效备份时不搜索磁盘。请在设置中修复：{e:#}");
            tracing::warn!("{message}");
            (Config::recover(&dir), message)
        }
    };
    let _ = std::fs::create_dir_all(&dir);
    let engine = match Engine::try_start(config) {
        Ok(engine) => engine,
        Err(e) => { tracing::warn!("cannot start Sift: {e:#}"); return ptr::null_mut(); }
    };
    *engine.status.configuration_error.lock().unwrap() = problem;
    // `sift quit` ends the app exactly like ⌘Q: the app maps SIGTERM to
    // NSApp.terminate, whose applicationWillTerminate saves the index.
    let service = Service::new(engine.clone(), Box::new(|| unsafe {
        kill(std::process::id() as i32, SIGTERM);
    }));
    // No socket in a read-only run, and none where the app says so (`SIFT_NO_IPC`): the
    // sandboxed Mac App Store build ships without the `sift` CLI, so nothing would connect.
    let no_socket = std::env::var_os("SIFT_READONLY").is_some() || std::env::var_os("SIFT_NO_IPC").is_some();
    let server = if no_socket { None } else { ipc::Server::start(service.clone())
        .map_err(|e| tracing::warn!("CLI socket unavailable: {e:#}"))
        .ok() };
    Box::into_raw(Box::new(SiftEngine {
        engine,
        service,
        server,
    }))
}

const SIGTERM: i32 = 15;
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

/// Flushes a changed index, stops the engine and frees it.
///
/// # Safety
/// `engine` must come from `sift_engine_start` and not be used afterwards.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_shutdown(engine: *mut SiftEngine) {
    if engine.is_null() {
        return;
    }
    let engine = unsafe { Box::from_raw(engine) };
    drop(engine.server);
    engine.engine.shutdown();
}

/// # Safety
/// `engine` and `out` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_status(engine: *const SiftEngine, out: *mut SiftStatus) {
    let (Some(engine), Some(out)) = (unsafe { engine.as_ref() }, unsafe { out.as_mut() }) else {
        return;
    };
    let s = &engine.engine.status;
    *out = SiftStatus {
        state: s.state() as u8,
        dirty: s.dirty.load(Ordering::Relaxed),
        files: s.files.load(Ordering::Relaxed) as u64,
        events: s.events.load(Ordering::Relaxed) as u64,
        rescans: s.rescans.load(Ordering::Relaxed),
        flushes: s.flushes.load(Ordering::Relaxed),
        last_flush: s.last_flush.load(Ordering::Relaxed),
    };
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_details(engine: *const SiftEngine) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else { return ptr::null_mut(); };
    to_c(&engine.service.status_json().to_string())
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_remote_status(support_dir: *const c_char) -> *mut c_char {
    let directory = unsafe { opt_str(support_dir) }.map(std::path::PathBuf::from).unwrap_or_else(Config::default_support_dir);
    let request = crate::ipc::Request { op:"status".into(),..Default::default() };
    let value = match crate::ipc::request_within(&crate::config::socket_path_in(&directory),&request,Some(std::time::Duration::from_secs(5))) {
        Ok(Some(value)) => value,
        Ok(None) => serde_json::json!({"ok":true,"running":false}),
        Err(e) => serde_json::json!({"ok":false,"error":format!("{e:#}")}),
    };
    to_c(&value.to_string())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_control(engine: *const SiftEngine, json: *const c_char) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else { return ptr::null_mut(); };
    let result = unsafe { opt_str(json) }.ok_or_else(|| anyhow::anyhow!("missing control request"))
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).map_err(Into::into))
        .and_then(|v| engine.service.control(&v));
    to_c(&result.unwrap_or_else(|e| serde_json::json!({"ok":false,"error":format!("{e:#}")})).to_string())
}

/// Runs a search. Blocks until the index is loaded. On `SIFT_OK` returns a
/// result set; on `SIFT_ERROR` `*error` receives a message (free it).
///
/// # Safety
/// Pointers must be valid; strings may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_search(
    engine: *const SiftEngine,
    query: *const c_char,
    directory: *const c_char,
    case_insensitive: bool,
    code: *mut i32,
    error: *mut *mut c_char,
) -> *mut SiftResults {
    let set_code = |c: i32| {
        if let Some(code) = unsafe { code.as_mut() } {
            *code = c;
        }
    };
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        set_code(SIFT_ERROR);
        return ptr::null_mut();
    };
    let query = unsafe { opt_str(query) };
    let directory = unsafe { opt_str(directory) };
    match engine.engine.search_versioned(directory, query, case_insensitive, true) {
        Ok(Some((outcome, took, revision))) => {
            set_code(SIFT_OK);
            Box::into_raw(Box::new(SiftResults {
                indices: outcome.nodes.unwrap_or_default(),
                highlights: outcome.highlights.join("\n"),
                loosened: outcome.loosened,
                micros: took.as_micros() as u64,
                revision,
            }))
        }
        Ok(None) => {
            set_code(SIFT_CANCELLED);
            ptr::null_mut()
        }
        Err(e) => {
            set_code(SIFT_ERROR);
            if let Some(error) = unsafe { error.as_mut() } {
                *error = to_c(&format!("{e:#}"));
            }
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `results` must be valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_len(results: *const SiftResults) -> u64 {
    unsafe { results.as_ref() }.map_or(0, |r| r.indices.len() as u64)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_locate(engine: *const SiftEngine, results: *const SiftResults, paths_json: *const c_char) -> *mut c_char {
    let (Some(engine), Some(results)) = (unsafe { engine.as_ref() }, unsafe { results.as_ref() }) else { return ptr::null_mut(); };
    let paths = unsafe { opt_str(paths_json) }.and_then(|s| serde_json::from_str::<Vec<std::path::PathBuf>>(&s).ok()).unwrap_or_default();
    if paths.is_empty() { return to_c("[]"); }
    to_c(&serde_json::to_string(&engine.engine.locate(results.indices.clone(), paths, results.revision)).unwrap_or_else(|_| "[]".into()))
}

/// Microseconds the search took on the index thread, excluding time spent
/// waiting for the index to load or for earlier commands.
///
/// # Safety
/// `results` must be valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_micros(results: *const SiftResults) -> u64 {
    unsafe { results.as_ref() }.map_or(0, |r| r.micros)
}

/// Newline-separated highlight needles. Free with `sift_string_free`.
///
/// # Safety
/// `results` must be valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_highlights(results: *const SiftResults) -> *mut c_char {
    unsafe { results.as_ref() }.map_or(ptr::null_mut(), |r| to_c(&r.highlights))
}

/// Actual fallback query, or NULL for a strict search. Free with `sift_string_free`.
///
/// # Safety
/// `results` must be valid or NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_loosened(results: *const SiftResults) -> *mut c_char {
    unsafe { results.as_ref() }.and_then(|r| r.loosened.as_deref()).map_or(ptr::null_mut(), to_c)
}

/// Sorts the result set in place. Returns false when a newer search cancelled it.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_sort(
    engine: *const SiftEngine,
    results: *mut SiftResults,
    key: u8,
    descending: bool,
) -> bool {
    let (Some(engine), Some(results), Some(key)) = (
        unsafe { engine.as_ref() },
        unsafe { results.as_mut() },
        SortKey::from_u8(key),
    ) else {
        return false;
    };
    match engine
        .engine
        .sort_at(std::mem::take(&mut results.indices), key, descending, true, Some(results.revision))
    {
        Some(sorted) => {
            results.indices = sorted;
            true
        }
        None => false,
    }
}

/// Fills up to `count` rows starting at `start` into `out` and returns how many
/// were written. Free the rows with `sift_rows_free(out, written)`.
///
/// # Safety
/// `out` must have room for `count` rows.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_rows(
    engine: *const SiftEngine,
    results: *const SiftResults,
    start: u64,
    count: u64,
    out: *mut SiftRow,
) -> u64 {
    let (Some(engine), Some(results)) = (unsafe { engine.as_ref() }, unsafe { results.as_ref() })
    else {
        return 0;
    };
    if out.is_null() {
        return 0;
    }
    let len = results.indices.len();
    let start = (start as usize).min(len);
    let end = start.saturating_add(count as usize).min(len);
    let rows = engine.engine.nodes_at(results.indices[start..end].to_vec(), Some(results.revision));
    let written = rows.len();
    for (i, node) in rows.into_iter().enumerate() {
        let row = Row::from(node);
        let path = CString::new(row.path.as_os_str().as_bytes().to_vec())
            .unwrap_or_default()
            .into_raw();
        unsafe {
            out.add(i).write(SiftRow {
                path,
                size: row.size,
                mtime: row.mtime,
                ctime: row.ctime,
                kind: row.kind,
                state: row.state,
            });
        }
    }
    written as u64
}

/// # Safety
/// `rows` must hold `count` rows filled by `sift_results_rows`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_rows_free(rows: *mut SiftRow, count: u64) {
    if rows.is_null() {
        return;
    }
    for i in 0..count as usize {
        let row = unsafe { &mut *rows.add(i) };
        if !row.path.is_null() {
            drop(unsafe { CString::from_raw(row.path) });
            row.path = ptr::null_mut();
        }
    }
}

/// # Safety
/// `results` must come from `sift_search` or be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_results_free(results: *mut SiftResults) {
    if !results.is_null() {
        drop(unsafe { Box::from_raw(results) });
    }
}

/// # Safety
/// `s` must come from this library or be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

/// # Safety
/// `engine` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_rescan(engine: *const SiftEngine) {
    if let Some(engine) = unsafe { engine.as_ref() } {
        engine.engine.rescan();
    }
}

/// Current settings as JSON (`root`, `ignore_paths`, `include_paths`).
///
/// # Safety
/// `engine` must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_config_json(engine: *const SiftEngine) -> *mut c_char {
    let Some(engine) = (unsafe { engine.as_ref() }) else {
        return ptr::null_mut();
    };
    let config = engine.service.config();
    to_c(&serde_json::to_string(&config).unwrap_or_default())
}

/// Saves new settings (same JSON shape) and re-indexes when they changed.
/// Returns false and sets `*error` when the JSON is invalid.
///
/// # Safety
/// Pointers must be valid.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_config_update(
    engine: *mut SiftEngine,
    json: *const c_char,
    error: *mut *mut c_char,
) -> bool {
    let fail = |msg: String| {
        if let Some(error) = unsafe { error.as_mut() } {
            *error = to_c(&msg);
        }
        false
    };
    let Some(engine) = (unsafe { engine.as_mut() }) else {
        return fail("engine is null".into());
    };
    let Some(json) = (unsafe { opt_str(json) }) else {
        return fail("empty settings".into());
    };
    let config: Config = match serde_json::from_str(&json) {
        Ok(c) => c,
        Err(e) => return fail(format!("invalid settings: {e}")),
    };
    // Same path as `sift config set`: normalize, save, re-index when changed.
    match engine.service.apply_settings(config, false) {
        Ok(_) => true,
        Err(e) => fail(format!("{e:#}")),
    }
}

/// Whether this process can read a TCC-protected file (Full Disk Access). The
/// window's footer button and `sift status` use this one probe.
#[unsafe(no_mangle)]
pub extern "C" fn sift_full_disk_access() -> bool {
    service::has_full_disk_access()
}

/// Lets `sift status` report the login item: the app passes a function returning
/// `SMAppService.mainApp.status.rawValue`, called on the socket thread per request.
///
/// # Safety
/// `engine` must be valid; `probe` must be NULL or callable from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_set_login_item_probe(
    engine: *const SiftEngine,
    probe: Option<LoginItemProbe>,
) {
    if let Some(engine) = unsafe { engine.as_ref() } {
        engine.service.set_login_item_probe(probe);
    }
}

/// Lets `sift trash`, `sift hotkey …` and `sift login-item …` reach the app: one JSON
/// request in, one JSON reply out as a `malloc`ed C string (`strdup`), freed here.
///
/// # Safety
/// `engine` must be valid; `handler` must be NULL or callable from any thread.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sift_engine_set_action_handler(
    engine: *const SiftEngine,
    handler: Option<AppActionHandler>,
) {
    if let Some(engine) = unsafe { engine.as_ref() } {
        engine.service.set_app_action_handler(handler);
    }
}
