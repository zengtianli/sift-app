//! What the running app offers its own window (through the FFI) and the `sift`
//! CLI (through the socket) alike: the live settings and the one path that
//! changes them, the status report, and quitting the way ⌘Q does.

use crate::{
    config::{Config, ConfigEdit},
    engine::{Engine, EngineState, unix_now},
};
use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    io::Read,
    path::{Path, PathBuf},
    sync::{Arc, Mutex, atomic::Ordering},
};

/// Reports `SMAppService.mainApp.status.rawValue` from the app process
/// (0 not registered, 1 enabled, 2 requires approval, 3 not found).
pub type LoginItemProbe = extern "C" fn() -> i32;

/// What only the app process can do for the `sift` CLI, in the app's own code and with
/// the app's own permissions: moving files to the Trash, the global shortcut, the login
/// item (Sources/AppActions.swift, the functions the window's menu and Settings buttons
/// call). One JSON request in, one JSON reply out as a `malloc`ed C string that the
/// caller frees with `free`; NULL when nothing could be answered. Called on the socket
/// thread of the request.
pub type AppActionHandler = extern "C" fn(*const c_char) -> *mut c_char;

unsafe extern "C" {
    fn free(p: *mut c_void);
}

pub struct Service {
    /// Its `settings()` are the live settings. The Settings window and `sift config set`
    /// both change them through `apply_settings`/`apply_edit` under that one lock, so
    /// `status` never reports a stale copy and concurrent edits never drop each other.
    pub engine: Arc<Engine>,
    login_item: Mutex<Option<LoginItemProbe>>,
    app_action: Mutex<Option<AppActionHandler>>,
    quit: Box<dyn Fn() + Send + Sync>,
}

/// Result of a settings change (also what `--dry-run` would do).
#[derive(Debug, Serialize)]
pub struct SettingsChange {
    /// The settings differ from the running ones.
    pub changed: bool,
    /// A full re-index from scratch was started (searches wait until the walk finishes).
    pub reindexing: bool,
    /// `config.json` was written.
    pub saved: bool,
    pub dry_run: bool,
    pub config: Config,
}

impl Service {
    /// `quit` must end the process the way ⌘Q does (the app maps SIGTERM to
    /// `NSApp.terminate`, which saves the index); tests pass a flag setter.
    pub fn new(engine: Arc<Engine>, quit: Box<dyn Fn() + Send + Sync>) -> Arc<Self> {
        Arc::new(Self {
            engine,
            login_item: Mutex::new(None),
            app_action: Mutex::new(None),
            quit,
        })
    }

    pub fn config(&self) -> Config {
        self.engine.settings().lock().unwrap().clone()
    }

    pub fn support_dir(&self) -> PathBuf {
        self.engine.settings().lock().unwrap().support_dir.clone()
    }

    pub fn set_login_item_probe(&self, probe: Option<LoginItemProbe>) {
        *self.login_item.lock().unwrap() = probe;
    }

    pub fn set_app_action_handler(&self, handler: Option<AppActionHandler>) {
        *self.app_action.lock().unwrap() = handler;
    }

    /// `sift trash`, `sift hotkey …`, `sift login-item …`: handed to the app as they came.
    /// The reply is the app's own JSON object (`ok`, and on failure `code` and `error`).
    pub fn app_action(&self, request: &Value) -> Result<Value> {
        // Copied out, so the lock is not held while the app works (a Trash move can take a while).
        let handler = *self.app_action.lock().unwrap();
        let Some(handler) = handler else {
            return Ok(json!({"ok": false, "code": "unavailable",
                             "error": "this Sift instance has no window actions (trash, hotkey, login item)"}));
        };
        let request = CString::new(request.to_string()).context("the request holds a NUL byte")?;
        let reply = handler(request.as_ptr());
        if reply.is_null() {
            anyhow::bail!("Sift gave no answer");
        }
        let text = unsafe { CStr::from_ptr(reply) }.to_string_lossy().into_owned();
        unsafe { free(reply.cast()) };
        serde_json::from_str(&text).context("bad answer from Sift")
    }

    /// The single settings-change path: normalize, save `config.json`, and re-index
    /// when the settings changed. The Settings window's Save (FFI) and
    /// `sift config set` (socket) both land here.
    pub fn apply_settings(&self, new: Config, dry_run: bool) -> Result<SettingsChange> {
        let mut current = self.engine.settings().lock().unwrap();
        Self::apply_locked(&self.engine, &mut current, new, dry_run)
    }

    /// `sift config set`: the edit is applied to the live settings inside the same lock
    /// as the save and re-index, so a concurrent edit or a Settings Save is never lost.
    pub fn apply_edit(&self, edit: &ConfigEdit, dry_run: bool) -> Result<SettingsChange> {
        let mut current = self.engine.settings().lock().unwrap();
        let next = edit.apply(&current)?;
        Self::apply_locked(&self.engine, &mut current, next, dry_run)
    }

    fn apply_locked(engine: &Engine, current: &mut Config, new: Config, dry_run: bool) -> Result<SettingsChange> {
        let mut new = new;
        new.support_dir = current.support_dir.clone();
        let new = new.validated()?;
        let changed = new != *current;
        if changed && engine.status.paused.load(Ordering::Relaxed) { anyhow::bail!("索引已暂停，请先恢复后修改索引范围；原配置未修改"); }
        if dry_run {
            return Ok(SettingsChange { changed, reindexing: false, saved: false, dry_run: true, config: new });
        }
        // Saved even when unchanged, as the window always did: a hand-edited file
        // is replaced by what the user confirmed.
        new.save()?;
        engine.status.configuration_error.lock().unwrap().clear();
        if changed {
            *current = new.clone();
            engine.reconfigure(new.clone());
        }
        Ok(SettingsChange { changed, reindexing: changed, saved: true, dry_run: false, config: new })
    }

    /// Why quitting now would lose work, if it would: a full walk (manual re-index,
    /// settings change, first index) is cancelled by quitting, the last snapshot is
    /// kept and the index is marked for rebuilding. ⌘Q in the window still quits.
    pub fn quit_blocker(&self) -> Option<String> {
        (self.engine.status.state() == EngineState::Scanning).then(|| {
            format!(
                "a full re-index is running ({} entries so far); quitting now cancels it, keeps the last \
                 saved snapshot and marks the index for rebuilding at the next start. Wait for it \
                 (`sift status`, state ready) or pass --force",
                self.engine.status.files.load(Ordering::Relaxed)
            )
        })
    }

    /// Everything the window's status bar and Settings show, as one JSON object.
    /// Key names up to `now` are a stable contract (Chapter's readiness check parses them).
    pub fn status_json(&self) -> Value {
        let s = &self.engine.status;
        let config = self.config();
        json!({
            "ok": true,
            "live": true,
            "pid": std::process::id(),
            "state": s.state().as_str(),
            "files": s.files.load(Ordering::Relaxed),
            "events": s.events.load(Ordering::Relaxed),
            "rescans": s.rescans.load(Ordering::Relaxed),
            "walks": s.walks.load(Ordering::Relaxed),
            "last_walk": s.last_walk.load(Ordering::Relaxed),
            "rebuild_required": s.rebuild_required.load(Ordering::Relaxed),
            "rebuild_reason": *s.rebuild_reason.lock().unwrap(),
            "repairing": s.repairing.load(Ordering::Relaxed),
            "paused": s.paused.load(Ordering::Relaxed),
            "auto_repair": s.auto_repair.load(Ordering::Relaxed),
            "auto_snapshot": s.auto_snapshot.load(Ordering::Relaxed),
            "index_revision": s.index_revision.load(Ordering::Relaxed),
            "configuration_error": *s.configuration_error.lock().unwrap(),
            "runtime_error": *s.runtime_error.lock().unwrap(),
            "snapshot_writes": s.flushes.load(Ordering::Relaxed),
            "last_snapshot": s.last_flush.load(Ordering::Relaxed),
            "unsaved_changes": s.dirty.load(Ordering::Relaxed),
            "root": config.root,
            "ignore_paths": config.ignore_paths,
            "include_paths": config.include_paths,
            "support_dir": config.support_dir,
            "full_disk_access": has_full_disk_access(),
            "login_item": self.login_item(),
            "app": std::env::current_exe().ok().and_then(|exe| bundle_info(&exe)),
            "now": unix_now(),
        })
    }

    fn login_item(&self) -> Option<&'static str> {
        let probe = (*self.login_item.lock().unwrap())?;
        Some(match probe() {
            0 => "not_registered",
            1 => "enabled",
            2 => "requires_approval",
            3 => "not_found",
            _ => "unknown",
        })
    }

    pub fn request_quit(&self) {
        (self.quit)();
    }

    pub fn control(&self, request: &Value) -> Result<Value> {
        let action = request["action"].as_str().unwrap_or("status");
        match action {
            "status" => {},
            "cancel" => self.engine.cancel_scan(),
            "pause" | "resume" | "set" => {
                let repair = request.get("auto_repair").map(|v| v.as_bool().context("auto_repair 必须是布尔值")).transpose()?;
                let snapshot = request.get("auto_snapshot").map(|v| v.as_bool().context("auto_snapshot 必须是布尔值")).transpose()?;
                self.engine.edit_policy(|policy| {
                    if action == "pause" { policy.paused = true; }
                    if action == "resume" { policy.paused = false; }
                    if let Some(v) = repair { policy.auto_repair = v; }
                    if let Some(v) = snapshot { policy.auto_snapshot = v; }
                })?;
            },
            _ => anyhow::bail!("unknown index action {action:?}"),
        }
        Ok(self.status_json())
    }
}

/// Full Disk Access, probed by reading one byte of a TCC-protected file. TCC judges
/// the calling process, so only the app's own answer (over the socket) means
/// "Sift has access"; the window's footer button uses the same probe.
pub fn has_full_disk_access() -> bool {
    let Some(home) = std::env::var_os("HOME") else { return false };
    let probe = Path::new(&home).join("Library/Application Support/com.apple.TCC/TCC.db");
    let mut byte = [0u8; 1];
    std::fs::File::open(probe)
        .and_then(|mut f| f.read(&mut byte))
        .is_ok_and(|n| n == 1)
}

/// Version facts of the `.app` that contains `exe` (the app's own executable, or
/// the CLI at `Contents/Resources/bin/sift`); `None` outside a bundle.
#[derive(Debug, Clone, Serialize)]
pub struct BundleInfo {
    pub path: PathBuf,
    pub identifier: Option<String>,
    pub version: Option<String>,
    pub build: Option<String>,
}

pub fn bundle_info(exe: &Path) -> Option<BundleInfo> {
    let exe = std::fs::canonicalize(exe).ok()?;
    let bundle = exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app"))?;
    let xml = std::fs::read_to_string(bundle.join("Contents/Info.plist")).ok()?;
    Some(BundleInfo {
        path: bundle.to_path_buf(),
        identifier: plist_string(&xml, "CFBundleIdentifier"),
        version: plist_string(&xml, "CFBundleShortVersionString"),
        build: plist_string(&xml, "CFBundleVersion"),
    })
}

/// `<key>name</key><string>value</string>` from the bundle's XML Info.plist
/// (build.sh copies it as written; a full plist parser would add ~0.2 MB to
/// both the CLI and the app for three strings).
fn plist_string(xml: &str, key: &str) -> Option<String> {
    let after = &xml[xml.find(&format!("<key>{key}</key>"))? + key.len() + 11..];
    let value = after.trim_start().strip_prefix("<string>")?;
    let value = &value[..value.find("</string>")?];
    Some(value.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&"))
}

#[cfg(test)]
mod tests {
    use super::plist_string;

    #[test]
    fn reads_strings_from_an_xml_info_plist() {
        let xml = "<dict>\n\t<key>CFBundleVersion</key>\n\t<string>8</string>\n\t<key>CFBundleName</key><string>A &amp; B</string></dict>";
        assert_eq!(plist_string(xml, "CFBundleVersion").as_deref(), Some("8"));
        assert_eq!(plist_string(xml, "CFBundleName").as_deref(), Some("A & B"));
        assert_eq!(plist_string(xml, "CFBundleIdentifier"), None);
    }
}
