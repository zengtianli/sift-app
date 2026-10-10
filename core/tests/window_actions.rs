//! `sift trash`, `sift hotkey …` and `sift login-item …` end to end against a real engine and socket, with a
//! stand-in for the app's own code. A test binary of its own: it starts an engine in this process, and so does
//! tests/cli.rs. Two engines in one process get in each other's way (with both in cli.rs and the default parallel
//! run, the other test's index rebuild never reached ready; taking turns still left it with an empty index now and
//! then). The app hosts one engine per process, and so does each test binary.

use serde_json::Value;
use sift_core::{
    config::Config,
    engine::Engine,
    ipc,
    service::Service,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::atomic::{AtomicBool, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    // Canonical path: FSEvents reports /private/var/... for /var/... temp dirs.
    let base = fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir = base.join(format!("sift-cli-{tag}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// What the stand-in app was asked, and the little state it keeps (the stored shortcut, the login item).
static ASKED: std::sync::Mutex<Vec<Value>> = std::sync::Mutex::new(Vec::new());
static SHORTCUT: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);
static LOGIN: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn strdup(s: *const std::ffi::c_char) -> *mut std::ffi::c_char;
}

/// Stands in for Sources/AppActions.swift: answers in its shapes without touching a file, a key or a login item.
/// `stuck` in a path cannot be moved; cmd+a (0:1048576) is refused by "the system".
extern "C" fn stand_in_app(request: *const std::ffi::c_char) -> *mut std::ffi::c_char {
    let text = unsafe { std::ffi::CStr::from_ptr(request) }.to_string_lossy().into_owned();
    let request: Value = serde_json::from_str(&text).unwrap();
    ASKED.lock().unwrap().push(request.clone());
    let shortcut = |changed: Option<bool>| {
        let stored = SHORTCUT.lock().unwrap().clone();
        let refused = stored.as_deref() == Some("0:1048576");
        let mut reply = serde_json::json!({"ok": true, "stored": stored, "display": stored.as_ref().map(|_| "⌘?"),
                                           "registered": stored.is_some() && !refused, "in_use": refused});
        if let Some(changed) = changed {
            reply["changed"] = changed.into();
        }
        reply
    };
    let login = |on: bool| serde_json::json!({"ok": true, "login_item": if on { "enabled" } else { "not_registered" }, "enabled": on});
    let reply = match request["action"].as_str().unwrap_or_default() {
        "trash" => {
            let paths: Vec<String> = request["paths"].as_array().unwrap().iter().map(|p| p.as_str().unwrap().to_owned()).collect();
            let (stuck, moved): (Vec<_>, Vec<_>) = paths.iter().partition(|p| p.contains("stuck"));
            let trashed: Vec<Value> = moved.iter().map(|p| serde_json::json!({"path": p, "trash_path": format!("/Trash{p}")})).collect();
            if request["confirmed"] != true {
                serde_json::json!({"ok": false, "code": "confirmation_required", "error": "not confirmed"})
            } else if stuck.is_empty() {
                serde_json::json!({"ok": true, "trashed": trashed})
            } else {
                let failed: Vec<Value> = stuck.iter().map(|p| serde_json::json!({"path": p, "error": "in use"})).collect();
                serde_json::json!({"ok": false, "code": "trash_failed", "error": format!("{} of {} could not be moved to the Trash: in use", stuck.len(), paths.len()),
                                   "trashed": trashed, "failed": failed})
            }
        }
        "hotkey" => shortcut(None),
        "hotkey_set" => {
            let wanted = match request["preset"].as_str() {
                Some("cardinal") => Some("49:1179648".to_owned()),
                _ => request["stored"].as_str().map(str::to_owned),
            };
            // The recorder's rule, as the app applies it: a modifier other than shift alone.
            let usable = wanted.as_deref().and_then(|w| w.split_once(':')).and_then(|(_, m)| m.parse::<u64>().ok()).is_some_and(|m| m != 0 && m != 1 << 17);
            if usable {
                let changed = *SHORTCUT.lock().unwrap() != wanted;
                *SHORTCUT.lock().unwrap() = wanted;
                shortcut(Some(changed))
            } else {
                serde_json::json!({"ok": false, "code": "invalid_shortcut", "error": "needs a modifier"})
            }
        }
        "hotkey_clear" => {
            let changed = SHORTCUT.lock().unwrap().take().is_some();
            shortcut(Some(changed))
        }
        "login_item" => login(LOGIN.load(Ordering::SeqCst)),
        "login_item_set" => {
            let on = request["on"] == true;
            let mut reply = login(on);
            reply["changed"] = (LOGIN.swap(on, Ordering::SeqCst) != on).into();
            reply
        }
        "refuse" => serde_json::json!({"ok": false, "code": "login_item_failed", "error": "Operation not permitted", "login_item": "not_registered", "enabled": false}),
        other => serde_json::json!({"ok": false, "code": "usage", "error": format!("unknown action {other}")}),
    };
    let reply = std::ffi::CString::new(reply.to_string()).unwrap();
    unsafe { strdup(reply.as_ptr()) }
}

/// `sift trash`, `sift hotkey …` and `sift login-item …` reach the app's own code over the socket (here a
/// stand-in for Sources/AppActions.swift): what is sent, what is printed, the exit codes, and what the CLI
/// decides before anything is sent. Nothing here can move a file: the stand-in only answers.
#[test]
fn window_actions_go_to_the_running_app() {
    let root = unique_dir("actions-root");
    let support = unique_dir("actions-support");
    let home = unique_dir("actions-home");
    fs::write(root.join("a.txt"), "a").unwrap();
    fs::write(root.join("b.txt"), "b").unwrap();
    fs::write(root.join("stuck.txt"), "s").unwrap();
    std::os::unix::fs::symlink(root.join("a.txt"), root.join("link")).unwrap();
    let config = Config { root: root.clone(), ignore_paths: vec![], include_paths: vec![], support_dir: support.clone() }.normalized();
    config.save().unwrap();
    let engine = Engine::start(config);
    // No wait for the index: nothing here searches. (Waiting for Ready made this test fail now and then: on a root
    // made a moment ago the engine can come up RebuildRequired and stay there until the app asks for the repair.)
    let service = Service::new(engine.clone(), Box::new(|| {}));
    let server = ipc::Server::start(service.clone()).unwrap();
    let run = |args: &[&str], cwd: &Path| {
        let out = Command::new(env!("CARGO_BIN_EXE_sift")).args(args).env("SIFT_SUPPORT_DIR", &support).env("HOME", &home)
            .env("SIFT_PREFS_DOMAIN", home.join("no-such-prefs")).current_dir(cwd).output().expect("run sift");
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    };
    let json = |args: &[&str], want: i32| -> Value {
        let (rc, out, err) = run(args, &root);
        assert_eq!(rc, want, "sift {args:?}: stdout={out} stderr={err}");
        serde_json::from_str(out.trim()).unwrap_or_else(|e| panic!("sift {args:?} printed no JSON ({e}): {out}"))
    };
    let asked = || std::mem::take(&mut *ASKED.lock().unwrap());
    let path = |name: &str| root.join(name).to_string_lossy().into_owned();

    // An instance without the app's handler (it never registered one) says so; nothing crashes.
    let v = json(&["trash", &path("a.txt"), "--yes", "--json"], 2);
    assert_eq!((v["code"].clone(), v["command"].clone(), v["exit"].clone()), ("unavailable".into(), "trash".into(), 2.into()), "{v}");
    service.set_app_action_handler(Some(stand_in_app));

    // trash: decided here before anything is sent — no path, no --yes, a missing path, the root, the home folder.
    let v = json(&["trash", &path("a.txt"), "--json"], 2);
    assert_eq!((v["ok"].clone(), v["code"].clone(), v["paths"].clone()), (false.into(), "confirmation_required".into(), serde_json::json!([path("a.txt")])), "{v}");
    let v = json(&["trash", &path("absent.txt"), &path("a.txt"), "--yes", "--json"], 1);
    assert_eq!((v["code"].clone(), v["missing"].clone(), v["exit"].clone()), ("not_found".into(), serde_json::json!([path("absent.txt")]), 1.into()), "{v}");
    for refused in ["/", home.to_str().unwrap(), "/..", &format!("{}/x/..", home.display())] {
        let (rc, out, err) = run(&["trash", refused, "--yes", "--json"], &root);
        assert_eq!(rc, 2, "sift trash {refused}: {out}");
        assert!(err.contains("refusing"), "{err}");
    }
    assert!(asked().is_empty(), "a refused trash reached the app");
    // Sent as typed: absolute, a relative one from where the command ran, a link as the link, each once.
    let v = json(&["trash", "b.txt", &path("a.txt"), "./b.txt", "link", "--yes"], 0);
    assert_eq!((v["ok"].clone(), v["command"].clone(), v["count"].clone()), (true.into(), "trash".into(), 3.into()), "{v}");
    assert_eq!(v["trashed"][2], serde_json::json!({"path": path("link"), "trash_path": format!("/Trash{}", path("link"))}));
    assert_eq!(asked(), vec![serde_json::json!({"action": "trash", "confirmed": true, "paths": [path("b.txt"), path("a.txt"), path("link")]})]);
    // What the system could not move: exit 1, with what did move and what stayed.
    let v = json(&["trash", &path("a.txt"), &path("stuck.txt"), "--yes", "--json"], 1);
    assert_eq!((v["ok"].clone(), v["code"].clone(), v["exit"].clone(), v["command"].clone()), (false.into(), "trash_failed".into(), 1.into(), "trash".into()), "{v}");
    assert_eq!((v["trashed"][0]["path"].clone(), v["failed"].clone()), (path("a.txt").into(), serde_json::json!([{"path": path("stuck.txt"), "error": "in use"}])), "{v}");
    let (rc, out, err) = run(&["trash", &path("stuck.txt"), "--yes"], &root);
    assert_eq!((rc, out.as_str()), (1, ""), "without --json a failure is only on stderr");
    assert!(err.starts_with("sift: 1 of 1 could not be moved"), "{err}");
    asked();

    // hotkey: the preset is the app's own constant; a named combination is sent in the stored form.
    let v = json(&["hotkey", "--json"], 0);
    assert_eq!((v["hotkey"].clone(), v["registered"].clone(), v["in_use"].clone(), v["running"].clone()), (Value::Null, false.into(), false.into(), true.into()), "{v}");
    let v = json(&["hotkey", "set", "cardinal"], 0);
    assert_eq!(v, serde_json::json!({"ok": true, "command": "hotkey set", "running": true, "registered": true, "in_use": false, "changed": true,
                                     "hotkey": {"stored": "49:1179648", "combo": "cmd+shift+space", "display": "⌘?"}}));
    assert_eq!(json(&["hotkey", "set", "CMD+Shift+Space", "--json"], 0)["changed"], false);
    // Typed in any order and by any of the names; printed the way `status` has always printed gui.hotkey.
    assert_eq!(json(&["hotkey", "set", "control+alt+k"], 0)["hotkey"]["combo"], "option+ctrl+k");
    assert_eq!(json(&["hotkey", "set", "cmd+keycode96"], 0)["hotkey"]["stored"], "96:1048576");
    assert_eq!(json(&["hotkey", "set", "40:786432"], 0)["hotkey"]["combo"], "option+ctrl+k");
    assert_eq!(asked().iter().map(|r| r.to_string()).collect::<Vec<_>>(), vec![
        r#"{"action":"hotkey"}"#, r#"{"action":"hotkey_set","preset":"cardinal"}"#, r#"{"action":"hotkey_set","stored":"49:1179648"}"#,
        r#"{"action":"hotkey_set","stored":"40:786432"}"#, r#"{"action":"hotkey_set","stored":"96:1048576"}"#, r#"{"action":"hotkey_set","stored":"40:786432"}"#,
    ]);
    // The app's own rule (shift alone, no modifier) comes back as invalid_shortcut, exit 2.
    for word in ["shift+a", "a"] {
        let v = json(&["hotkey", "set", word, "--json"], 2);
        assert_eq!((v["code"].clone(), v["command"].clone()), ("invalid_shortcut".into(), "hotkey set".into()), "{v}");
    }
    // Refused by the system: stored all the same, as in the window, and the command fails with the state.
    let v = json(&["hotkey", "set", "cmd+a", "--json"], 1);
    assert_eq!((v["ok"].clone(), v["code"].clone(), v["in_use"].clone(), v["registered"].clone(), v["hotkey"]["stored"].clone(), v["exit"].clone()),
               (false.into(), "in_use".into(), true.into(), false.into(), "0:1048576".into(), 1.into()), "{v}");
    let v = json(&["hotkey", "--json"], 0);
    assert_eq!((v["in_use"].clone(), v["hotkey"]["combo"].clone()), (true.into(), "cmd+a".into()), "{v}");
    let (rc, out, _) = run(&["hotkey"], &root);
    assert_eq!((rc, out.as_str()), (0, "shortcut: ⌘?  cmd+a\nregistered: no\nin use by another app: yes\n"));
    let v = json(&["hotkey", "clear"], 0);
    assert_eq!((v["hotkey"].clone(), v["changed"].clone(), v["command"].clone()), (Value::Null, true.into(), "hotkey clear".into()), "{v}");
    assert_eq!(json(&["hotkey", "clear", "--json"], 0)["changed"], false);
    assert_eq!(run(&["hotkey"], &root).1, "shortcut: not set\nregistered: no\nin use by another app: no\n");
    asked();

    // login-item: show, on, on again, off; anything else is a usage error that is not sent.
    let v = json(&["login-item", "--json"], 0);
    assert_eq!(v, serde_json::json!({"ok": true, "command": "login-item", "running": true, "login_item": "not_registered", "enabled": false}));
    let v = json(&["login-item", "on"], 0);
    assert_eq!(v, serde_json::json!({"ok": true, "command": "login-item", "running": true, "action": "on", "login_item": "enabled", "enabled": true, "changed": true}));
    assert_eq!(json(&["login-item", "on", "--json"], 0)["changed"], false);
    assert_eq!(run(&["login-item"], &root).1, "login item: enabled\n");
    let v = json(&["login-item", "off"], 0);
    assert_eq!((v["action"].clone(), v["login_item"].clone(), v["changed"].clone()), ("off".into(), "not_registered".into(), true.into()), "{v}");
    assert_eq!(asked().len(), 5);
    assert_eq!(run(&["login-item", "maybe"], &root).0, 2);
    assert!(asked().is_empty());

    // No Sift for this folder: the writes refuse with exit 3, the two reads report it like `status` does.
    let down = unique_dir("actions-down");
    let stopped = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_sift")).args(args).env("SIFT_SUPPORT_DIR", &down)
            .env("SIFT_PREFS_DOMAIN", home.join("no-such-prefs")).output().expect("run sift");
        (out.status.code().unwrap_or(-1), serde_json::from_slice::<Value>(&out.stdout).unwrap_or_default())
    };
    for args in [vec!["trash", root.join("a.txt").to_str().unwrap(), "--yes", "--json"], vec!["hotkey", "set", "cardinal", "--json"],
                 vec!["hotkey", "clear", "--json"], vec!["login-item", "on", "--json"]] {
        let (rc, v) = stopped(&args);
        assert_eq!((rc, v["ok"].clone(), v["code"].clone(), v["running"].clone(), v["exit"].clone()), (3, false.into(), "not_running".into(), false.into(), 3.into()), "sift {args:?}: {v}");
    }
    let (rc, v) = stopped(&["hotkey", "--json"]);
    assert_eq!((rc, v["ok"].clone(), v["running"].clone(), v["exit"].clone(), v["hotkey"].clone(), v["registered"].clone(), v["in_use"].clone()),
               (3, true.into(), false.into(), 3.into(), Value::Null, Value::Null, Value::Null), "{v}");
    let (rc, v) = stopped(&["login-item", "--json"]);
    assert_eq!((rc, v["ok"].clone(), v["running"].clone(), v["login_item"].clone()), (3, true.into(), false.into(), Value::Null), "{v}");
    assert!(asked().is_empty() && fs::read_dir(&down).unwrap().count() == 0);
    // Every file is where it was: the stand-in only answered.
    for name in ["a.txt", "b.txt", "stuck.txt", "link"] {
        assert!(fs::symlink_metadata(root.join(name)).is_ok(), "{name} is gone");
    }

    // A running Sift from before these commands (build 12 or earlier) is named as such, not as a usage error.
    drop(server);
    engine.shutdown();
    {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        let socket = sift_core::config::socket_path_in(&down);
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut line = String::new();
                let _ = BufReader::new(&stream).read_line(&mut line);
                let _ = writeln!(stream, "{}", serde_json::json!({"ok": false, "error": "unknown op \"app\""}));
            }
        });
        for args in [vec!["hotkey", "--json"], vec!["login-item", "on", "--json"], vec!["trash", root.join("a.txt").to_str().unwrap(), "--yes", "--json"]] {
            let (rc, v) = stopped(&args);
            assert_eq!((rc, v["code"].clone(), v["exit"].clone()), (1, "app_outdated".into(), 1.into()), "sift {args:?}: {v}");
            assert!(v["error"].as_str().unwrap().contains("quit and reopen"), "{v}");
        }
        let _ = fs::remove_file(&socket);
    }
    for dir in [&root, &support, &home, &down] {
        let _ = fs::remove_dir_all(dir);
    }
}
