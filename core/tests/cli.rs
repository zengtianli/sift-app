//! The `sift` binary end to end against a real engine and socket (the same
//! `Service` the app hosts), on a private support dir: strict parsing and help
//! without side effects, the search/status JSON contract, `config set` through the
//! shared settings path (no stale status), `rescan --wait`, `quit`, and offline
//! search sorting exactly like the live engine.

use serde_json::Value;
use sift_core::{
    config::Config,
    engine::{Engine, EngineState, SortKey},
    ipc,
    offline::Offline,
    service::Service,
};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    // Canonical path: FSEvents reports /private/var/... for /var/... temp dirs.
    let base = fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir = base.join(format!("sift-cli-{tag}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn wait_until(what: &str, timeout: Duration, mut f: impl FnMut() -> bool) {
    let start = Instant::now();
    while !f() {
        assert!(start.elapsed() < timeout, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Runs the built `sift` with this support dir; returns (exit code, stdout, stderr).
fn sift(support: &Path, args: &[&str]) -> (i32, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_sift"))
        .args(args)
        .env("SIFT_SUPPORT_DIR", support)
        .output()
        .expect("run sift");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

fn sift_json(support: &Path, args: &[&str], want_rc: i32) -> Value {
    let (rc, out, err) = sift(support, args);
    assert_eq!(rc, want_rc, "sift {args:?}: stdout={out} stderr={err}");
    serde_json::from_str(out.trim()).unwrap_or_else(|e| panic!("sift {args:?} printed no JSON ({e}): {out}"))
}

fn paths(v: &Value) -> Vec<String> {
    v["results"].as_array().unwrap().iter().map(|h| h["path"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn help_and_strict_parsing_never_run_commands() {
    let support = unique_dir("help");
    // A config.json the app would reject must not break help or version.
    fs::write(support.join("config.json"), "{not json").unwrap();
    for args in [
        vec!["--help"], vec!["help", "rescan"], vec!["search", "--help"], vec!["rescan", "--help"],
        vec!["rescan", "--wait", "5", "-h"], vec!["flush", "--help"], vec!["status", "--help"],
        vec!["config", "set", "--help"], vec!["start", "--help"], vec!["quit", "--help"],
        vec!["version", "--help"], vec!["--version"], vec!["-V"], vec!["help", "config", "set"],
        vec!["quit", "--force", "--help"], vec!["history", "--help"], vec!["help", "history"],
        vec!["history", "--limit", "3", "-h"],
        // The 配置与更新 commands: help is printed here, the app executable is not started.
        vec!["update", "--help"], vec!["update", "check", "-h"], vec!["help", "update"], vec!["help", "update", "check"],
        vec!["config", "status", "--help"], vec!["config", "export", "-o", "x.json", "--help"],
        vec!["config", "import", "x.json", "--yes", "--help"], vec!["config", "sync", "on", "--yes", "-h"],
        vec!["help", "config", "sync"], vec!["update", "install", "--yes", "--help"], vec!["help", "update", "install"],
        // The window's own actions: help is printed here, nothing is sent to an app.
        vec!["trash", "--help"], vec!["trash", "/", "--yes", "-h"], vec!["help", "trash"], vec!["hotkey", "--help"],
        vec!["hotkey", "set", "cardinal", "--help"], vec!["hotkey", "clear", "-h"], vec!["help", "hotkey", "set"],
        vec!["login-item", "--help"], vec!["login-item", "on", "-h"], vec!["help", "login-item"],
    ] {
        let (rc, out, err) = sift(&support, &args);
        assert_eq!(rc, 0, "sift {args:?}: {out} {err}");
        assert!(!out.is_empty(), "sift {args:?} printed nothing");
    }
    // Typos are errors, not query words or silently ignored flags.
    for args in [vec!["search", "--jsn", "readme"], vec!["rescan", "--bogus"], vec!["status", "extra"],
                 vec!["search", "--sort", "bogus", "x"], vec!["search", "-n", "abc", "x"], vec!["nope"],
                 vec!["config", "set"], vec!["rescan", "--wait", "0"], vec!["history", "--bogus"],
                 vec!["history", "extra"], vec!["history", "--limit", "x"], vec!["trash"], vec!["trash", "--yes"],
                 vec!["trash", "--bogus", "x"], vec!["hotkey", "extra"], vec!["hotkey", "set"], vec!["hotkey", "set", "a", "b"],
                 vec!["hotkey", "set", "hyper+k"], vec!["hotkey", "set", "cmd+nokey"], vec!["hotkey", "clear", "x"],
                 vec!["login-item", "maybe"], vec!["login-item", "on", "off"], vec!["login-item", "--bogus"]] {
        assert_eq!(sift(&support, &args).0, 2, "sift {args:?}");
    }
    // With --json, failures still print one JSON object.
    let v = sift_json(&support, &["search", "--json", "--jsn", "x"], 2);
    assert_eq!(v["ok"], false);
    // A broken config.json is reported (exit 2), never mistaken for a stopped app,
    // and `start` refuses it instead of letting the app fall back to indexing `/`.
    let (rc, _, err) = sift(&support, &["status"]);
    assert_eq!(rc, 2);
    assert!(err.contains("config.json"), "{err}");
    let (rc, out, err) = sift(&support, &["start", "--dry-run"]);
    assert_eq!(rc, 2, "{out}");
    assert!(err.contains("config.json") && !out.contains("would_run"), "{err}");
    // Nothing was created by any of these.
    let names: Vec<_> = fs::read_dir(&support).unwrap().map(|e| e.unwrap().file_name()).collect();
    assert_eq!(names, vec![std::ffi::OsString::from("config.json")]);
    let _ = fs::remove_dir_all(&support);
}

/// The top-level help is what an agent reads first: every command as a command (line
/// start, after `sift`), read and write commands, the --json shapes, the exit-code
/// table and what stays in the window.
#[test]
fn top_level_help_is_the_agent_contract() {
    let support = unique_dir("contract");
    let (rc, help, _) = sift(&support, &["--help"]);
    assert_eq!(rc, 0);
    for command in ["search", "status", "config", "config set", "history", "history clear", "rescan", "flush", "start", "quit", "version", "help",
                    "trash", "hotkey", "hotkey set", "hotkey clear", "login-item"] {
        assert!(help.lines().any(|l| l.trim_start().starts_with(&format!("sift {command} "))), "{command} is not listed as a command");
    }
    for part in ["READ COMMANDS", "WRITE COMMANDS", "--json", "EXIT CODES:", "WINDOW ONLY", "仅在窗口中",
                 "\"ok\":false", "  3  Sift.app is not running", "Show in Finder", "Quick Look", "Recording the global shortcut",
                 "Full Disk Access"] {
        assert!(help.contains(part), "top-level help lacks {part:?}");
    }
    // The 配置与更新… window's commands: each at the start of a line, as the shared layer words them.
    for line in ["  config status  ", "  update check  ", "  config export -o <file>  ", "  config import <file> --yes  ",
                 "  config sync on|off --yes  ", "  update install --yes  "] {
        assert!(help.lines().any(|l| l.starts_with(line)), "{line:?} is not listed as a command");
    }
    for part in ["config status  {ok, command,", "sync_status:{text, at, from", "update check   {ok, command,", "update install {ok, command,",
                 "confirmation_required", "file_exists", "not_running", "manual_install", "cleanup_failed", "打开「配置与更新…」窗口",
                 "trash       {ok, command, count, trashed:[{path, trash_path}]}", "hotkey      {ok, command, running, hotkey:",
                 "login-item  {ok, command, running, login_item", "trash_failed", "in_use", "invalid_shortcut", "login_item_failed",
                 "app_outdated", "update install in 720 s"] {
        assert!(help.contains(part), "top-level help lacks {part:?}");
    }
    // Every item of the windows has a command or is listed as window-only: nothing is announced as missing.
    for gone in ["NO COMMAND YET", "暂无命令", "shared lifecycle window", "升级到新版 / 下载新版"] {
        assert!(!help.contains(gone), "top-level help still says {gone:?}");
    }
    let (commands, window_only) = help.split_once("WINDOW ONLY").unwrap();
    assert!(commands.contains("升级到新版：与窗口「升级到新版…」同一条路") && !window_only.contains("升级到新版"));
    assert!(commands.contains("Move to Trash (⌘⌫)") && !window_only.contains("Move to Trash"));
    // One help text for the six, by any of their names.
    let lifecycle = sift(&support, &["help", "update"]).1;
    for args in [vec!["config", "sync", "--help"], vec!["update", "check", "--help"], vec!["help", "config", "export"],
                 vec!["update", "install", "--help"], vec!["help", "update", "install"]] {
        assert_eq!(sift(&support, &args).1, lifecycle, "sift {args:?}");
    }
    assert!(lifecycle.contains("sift config sync on|off --yes [--dry-run] [--json]") && lifecycle.contains("EXIT and code:"));
    assert!(lifecycle.contains("sift update install --yes [--dry-run] [--json]") && lifecycle.contains("sync_status:{text, at, from, live}")
        && !lifecycle.contains("暂无命令"));
    // The window's own actions have one help text per command family.
    let hotkey = sift(&support, &["help", "hotkey"]).1;
    for args in [vec!["hotkey", "--help"], vec!["hotkey", "set", "--help"], vec!["help", "hotkey", "clear"]] {
        assert_eq!(sift(&support, &args).1, hotkey, "sift {args:?}");
    }
    assert!(hotkey.contains("In use by another app") && sift(&support, &["trash", "--help"]).1.contains("--yes")
        && sift(&support, &["login-item", "--help"]).1.contains("Open Sift at login"));
    // Same text without a command and through `help`; none of them touched the support dir.
    assert_eq!(sift(&support, &[]).1, help);
    assert_eq!(sift(&support, &["help"]).1, help);
    assert_eq!(fs::read_dir(&support).unwrap().count(), 0);
    let _ = fs::remove_dir_all(&support);
}

/// `sift history` reads the window's saved recent searches and never writes: here from
/// a private plist (SIFT_PREFS_DOMAIN), so the user's own preferences are not read.
#[test]
fn history_reads_the_saved_recent_searches_only() {
    let support = unique_dir("history");
    let plist = support.join("prefs.plist");
    let long = "长".repeat(200);
    fs::write(&plist, format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
         \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\
         <key>recentSearches</key><array><string>年度报告 ext:docx</string><string>readme !old</string>\
         <string>{long}</string></array><key>caseInsensitive</key><false/><key>hotkey</key><string>49:1179648</string>\
         </dict></plist>\n"
    )).unwrap();
    let before = fs::read(&plist).unwrap();
    let domain = support.join("prefs");
    let run = |args: &[&str], domain: &Path| {
        let out = Command::new(env!("CARGO_BIN_EXE_sift"))
            .args(args)
            .env("SIFT_SUPPORT_DIR", &support)
            .env("SIFT_PREFS_DOMAIN", domain)
            .output()
            .expect("run sift");
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned())
    };
    let (rc, out) = run(&["history", "--json"], &domain);
    assert_eq!(rc, 0, "{out}");
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((v["ok"].clone(), v["total"].clone()), (true.into(), 3.into()));
    assert_eq!(v["items"], serde_json::json!(["年度报告 ext:docx", "readme !old", long]));
    // --limit shortens the list, not the total; the last of two limits wins.
    let (_, out) = run(&["history", "--json", "--limit", "1", "-n", "2"], &domain);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((v["total"].clone(), v["items"].as_array().unwrap().len()), (3.into(), 2));
    assert_eq!(run(&["history", "-n", "1"], &domain), (0, "年度报告 ext:docx\n".to_owned()));
    // 0 means all, as for `search --limit`.
    let (_, out) = run(&["history", "--json", "--limit", "0"], &domain);
    assert_eq!(serde_json::from_str::<Value>(out.trim()).unwrap()["items"].as_array().unwrap().len(), 3);
    // The same private domain feeds the window preferences in `status`.
    let (rc, out) = run(&["status", "--json"], &domain);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!(rc, 3);
    assert_eq!((v["gui"]["case_insensitive"].clone(), v["gui"]["hotkey"]["combo"].clone()), (false.into(), "cmd+shift+space".into()));
    // No saved history is an empty list and still exit 0.
    let (rc, out) = run(&["history", "--json"], &support.join("absent"));
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((rc, v["total"].clone(), v["items"].clone()), (0, 0.into(), serde_json::json!([])));
    // A wrong option fails with the shared failure object.
    let (rc, out) = run(&["history", "--json", "--clear"], &domain);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((rc, v["ok"].clone(), v["exit"].clone()), (2, false.into(), 2.into()));
    assert!(v["error"].as_str().unwrap().contains("--clear"));
    // Read-only: the plist is untouched and nothing else appeared next to it.
    assert_eq!(fs::read(&plist).unwrap(), before);
    assert_eq!(fs::read_dir(&support).unwrap().count(), 1);
    let _ = fs::remove_dir_all(&support);
}

/// `sift history clear --yes` is the ⌘Y menu's Clear Recent Searches: it removes that one
/// preference (here in a private plist) and nothing else, and only with --yes.
#[test]
fn history_clear_removes_the_recent_searches_and_nothing_else() {
    let support = unique_dir("history-clear");
    let plist = support.join("prefs.plist");
    fs::write(&plist, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
         \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict>\
         <key>recentSearches</key><array><string>年度报告 ext:docx</string><string>readme !old</string></array>\
         <key>caseInsensitive</key><false/><key>hotkey</key><string>49:1179648</string></dict></plist>\n").unwrap();
    let before = fs::read(&plist).unwrap();
    let domain = support.join("prefs");
    let run = |args: &[&str]| {
        let out = Command::new(env!("CARGO_BIN_EXE_sift"))
            .args(args)
            .env("SIFT_SUPPORT_DIR", &support)
            .env("SIFT_PREFS_DOMAIN", &domain)
            .output()
            .expect("run sift");
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    };
    let json = |text: &str| serde_json::from_str::<Value>(text.trim()).unwrap_or_else(|e| panic!("no JSON ({e}): {text}"));
    // Without --yes nothing is removed; help and typos never clear either.
    let (rc, out, err) = run(&["history", "clear", "--json"]);
    let v = json(&out);
    assert_eq!((rc, v["ok"].clone(), v["code"].clone(), v["command"].clone(), v["exit"].clone()),
               (2, false.into(), "confirmation_required".into(), "history clear".into(), 2.into()), "{v}");
    assert!(v["error"].as_str().unwrap().contains("--yes") && err.starts_with("sift: "));
    assert_eq!(run(&["history", "clear"]).0, 2);
    assert_eq!(run(&["history", "clear", "--yes", "--help"]).0, 0);
    assert_eq!(run(&["help", "history", "clear"]).0, 0);
    for args in [vec!["history", "clear", "--yes", "extra"], vec!["history", "clear", "--yes", "--bogus"], vec!["history", "--yes"]] {
        assert_eq!(run(&args).0, 2, "sift {args:?}");
    }
    assert_eq!(fs::read(&plist).unwrap(), before);
    assert_eq!(json(&run(&["history", "--json"]).1)["total"], 2);

    // With --yes: one JSON line (with or without --json), the list is gone, the other preferences stay.
    let (rc, out, _) = run(&["history", "clear", "--yes"]);
    assert_eq!((rc, json(&out)), (0, serde_json::json!({"ok": true, "command": "history clear", "cleared": 2})));
    let v = json(&run(&["history", "--json"]).1);
    assert_eq!((v["total"].clone(), v["items"].clone()), (0.into(), serde_json::json!([])));
    let gui = json(&run(&["status", "--json"]).1)["gui"].clone();
    assert_eq!((gui["case_insensitive"].clone(), gui["hotkey"]["combo"].clone()), (false.into(), "cmd+shift+space".into()));
    // Clearing an empty history is success too.
    let (rc, out, _) = run(&["history", "clear", "--yes", "--json"]);
    assert_eq!((rc, json(&out)["cleared"].clone()), (0, 0.into()));
    let _ = fs::remove_dir_all(&support);
}

#[test]
fn not_running_reports_disk_state_and_exit_3() {
    let support = unique_dir("down");
    let v = sift_json(&support, &["status", "--json"], 3);
    assert_eq!((v["ok"].clone(), v["running"].clone(), v["exit"].clone()), (true.into(), false.into(), 3.into()));
    assert!(v["snapshot"].is_null() && v["rebuild_required"] == false && v["gui"].is_object());
    fs::write(support.join("rebuild-required"), "test marker\nflags=UserDropped\n").unwrap();
    let v = sift_json(&support, &["status", "--json"], 3);
    assert_eq!(v["rebuild_required"], true);
    let v = sift_json(&support, &["search", "--json", "x"], 3);
    assert_eq!((v["ok"].clone(), v["running"].clone()), (false.into(), false.into()));
    assert_eq!(sift(&support, &["rescan"]).0, 3);
    assert_eq!(sift(&support, &["config", "set", "--ignore-add", "/tmp/x"]).0, 3);
    // Idempotent: nothing to quit is success.
    assert_eq!(sift_json(&support, &["quit", "--json"], 0)["running"], false);
    // --dry-run works from config.json without the app and writes nothing.
    let v = sift_json(&support, &["config", "set", "--ignore-add", "~/Downloads", "--dry-run"], 0);
    assert_eq!((v["changed"].clone(), v["saved"].clone()), (true.into(), false.into()));
    assert!(!support.join("config.json").exists());
    let _ = fs::remove_dir_all(&support);
}

#[test]
fn live_cli_through_the_shared_service() {
    let root = unique_dir("root");
    let support = unique_dir("support");
    fs::create_dir_all(root.join("docs")).unwrap();
    fs::create_dir_all(root.join("skipme")).unwrap();
    // Mixed case on purpose: byte order and the engine's order differ. Queries use `*.md`
    // so ancestors of the temp root (random /var/folders names) never match.
    for name in ["README.md", "readme-notes.txt", "Zeta.md", "alpha.md", "Alpha-2.md", "beta.MD"] {
        fs::write(root.join("docs").join(name), name).unwrap();
    }
    fs::write(root.join("skipme/hidden-target.md"), "x").unwrap();
    let config = Config { root: root.clone(), ignore_paths: vec![], include_paths: vec![], support_dir: support.clone() }
        .normalized();
    config.save().unwrap();

    let engine = Engine::start(config.clone());
    wait_until("index ready", Duration::from_secs(30), || engine.status.state() == EngineState::Ready);
    let quit = Arc::new(AtomicBool::new(false));
    let flag = quit.clone();
    let service = Service::new(engine.clone(), Box::new(move || flag.store(true, Ordering::SeqCst)));
    let server = ipc::Server::start(service.clone()).unwrap();

    // Search JSON carries the case mode, index health and the Created column.
    let v = sift_json(&support, &["search", "--json", "--limit", "0", "-i", "readme"], 0);
    assert_eq!((v["live"].clone(), v["case_insensitive"].clone(), v["state"].clone()), (true.into(), true.into(), "ready".into()));
    assert_eq!((v["rebuild_required"].clone(), v["repairing"].clone(), v["total"].clone()), (false.into(), false.into(), 2.into()));
    assert!(v["results"][0]["ctime"].as_u64().is_some_and(|c| c > 0), "{v}");
    // The CLI default stays case-sensitive (and says so).
    let v = sift_json(&support, &["search", "--json", "--limit", "0", "--match-case", "readme"], 0);
    assert_eq!(v["case_insensitive"], false);
    assert_eq!(paths(&v), vec![root.join("docs/readme-notes.txt").to_string_lossy()]);

    // Live name sort = the engine's order (ASCII-case-insensitive, then bytes).
    let live_sorted = paths(&sift_json(&support, &["search", "--json", "-n", "0", "-i", "--sort", "name", "*.md"], 0));
    let expected: Vec<String> = ["Alpha-2.md", "alpha.md", "beta.MD", "hidden-target.md", "README.md", "Zeta.md"]
        .iter()
        .map(|n| if *n == "hidden-target.md" { root.join("skipme").join(n) } else { root.join("docs").join(n) })
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    assert_eq!(live_sorted, expected);

    // Status: live settings, walk counter, permission and login-item fields.
    let status = sift_json(&support, &["status", "--json"], 0);
    for key in ["include_paths", "walks", "last_walk", "full_disk_access", "login_item", "app", "gui", "support_dir"] {
        assert!(status.get(key).is_some(), "status lacks {key}: {status}");
    }
    assert_eq!(status["running"], true);
    let walks = status["walks"].as_u64().unwrap();
    assert!(walks >= 1, "the first walk is counted");

    // `rescan --help` prints help and starts nothing.
    assert_eq!(sift(&support, &["rescan", "--help"]).0, 0);
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(sift_json(&support, &["status", "--json"], 0)["walks"], walks);

    // config set: dry run changes nothing on disk or in the app.
    let skip = root.join("skipme");
    let skip_arg = skip.to_str().unwrap();
    let saved = fs::read(support.join("config.json")).unwrap();
    let v = sift_json(&support, &["config", "set", "--ignore-add", skip_arg, "--dry-run"], 0);
    assert_eq!((v["changed"].clone(), v["saved"].clone(), v["dry_run"].clone()), (true.into(), false.into(), true.into()));
    assert_eq!(saved, fs::read(support.join("config.json")).unwrap());
    // Real change: same path as Settings › Save & Re-index; status is current at once.
    let v = sift_json(&support, &["config", "set", "--ignore-add", skip_arg, "--wait", "30"], 0);
    assert_eq!((v["changed"].clone(), v["reindexing"].clone(), v["saved"].clone()), (true.into(), true.into(), true.into()));
    assert_eq!(v["state"], "ready");
    let status = sift_json(&support, &["status", "--json"], 0);
    assert!(status["ignore_paths"].as_array().unwrap().iter().any(|p| p == skip_arg), "{status}");
    assert!(status["walks"].as_u64().unwrap() > walks);
    assert!(Config::load(&support).unwrap().ignore_paths.contains(&skip));
    assert_eq!(sift(&support, &["search", "hidden-target"]).0, 1);
    // The same change again is a no-op (no re-index).
    let v = sift_json(&support, &["config", "set", "--ignore-add", skip_arg], 0);
    assert_eq!((v["changed"].clone(), v["reindexing"].clone()), (false.into(), false.into()));

    // rescan --wait returns after the new walk is ready.
    let before = sift_json(&support, &["status", "--json"], 0)["walks"].as_u64().unwrap();
    let v = sift_json(&support, &["rescan", "--wait", "30"], 0);
    assert_eq!(v["walks_before"], before);
    assert!(v["walks"].as_u64().unwrap() > before && v["state"] == "ready", "{v}");

    // quit replies first, then asks the host to terminate (the app maps this to ⌘Q).
    let v = sift_json(&support, &["quit", "--json"], 0);
    assert_eq!(v["pid"], std::process::id());
    wait_until("quit hook", Duration::from_secs(5), || quit.load(Ordering::SeqCst));
    // Waiting on a process that does not exit times out with exit 4.
    assert_eq!(sift_json(&support, &["quit", "--wait", "0.3", "--json"], 4)["ok"], false);

    // Offline search sorts exactly like the live engine.
    let live_path_sorted = paths(&sift_json(&support, &["search", "--json", "-n", "0", "-i", "--sort", "path", "*.md"], 0));
    let live_name_sorted = paths(&sift_json(&support, &["search", "--json", "-n", "0", "-i", "--sort", "name", "*.md"], 0));
    drop(server);
    engine.shutdown();
    let v = sift_json(&support, &["search", "--offline", "--json", "-n", "0", "-i", "--sort", "name", "*.md"], 0);
    assert_eq!(v["live"], false);
    assert!(v["snapshot"]["bytes"].as_u64().is_some_and(|b| b > 0));
    assert_eq!(paths(&v), live_name_sorted);
    let v = sift_json(&support, &["search", "--offline", "--json", "-n", "0", "-i", "--sort", "path", "*.md"], 0);
    assert_eq!(paths(&v), live_path_sorted);
    // And the library call the offline CLI uses agrees with the engine's comparator.
    let mut offline = Offline::open(&config_after(&support)).unwrap();
    let hits = offline.search(None, Some("*.md".into()), true).unwrap();
    let sorted = offline.sort(hits, SortKey::Name, false);
    let names: Vec<String> = offline.rows(&sorted).into_iter().map(|r| r.path.to_string_lossy().into_owned()).collect();
    assert_eq!(names, live_name_sorted);

    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&support);
}

fn config_after(support: &Path) -> Config {
    Config::load(support).unwrap()
}

/// A running Sift from before `quit` existed answers `unknown op "quit"`; the CLI
/// then sends SIGTERM (the old app's ⌘Q path) to the pid from its status, with the
/// same refusal while a full re-index runs.
#[test]
fn quit_falls_back_to_sigterm_for_an_older_app() {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;
    use std::sync::Mutex;

    let support = unique_dir("oldapp");
    let socket = sift_core::config::socket_path_in(&support);
    let listener = UnixListener::bind(&socket).unwrap();
    // Stands in for the old app's process; reaped here so `--wait` sees it exit.
    let mut child = Command::new("/bin/sleep").arg("60").spawn().unwrap();
    let pid = child.id();
    let exited = Arc::new(AtomicBool::new(false));
    let exited_flag = exited.clone();
    std::thread::spawn(move || {
        let _ = child.wait();
        exited_flag.store(true, Ordering::SeqCst);
    });
    let state = Arc::new(Mutex::new("scanning"));
    let server_state = state.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut line = String::new();
            let _ = BufReader::new(&stream).read_line(&mut line);
            let req: Value = serde_json::from_str(&line).unwrap_or_default();
            // Build 7 knew only status, search, rescan and flush.
            let reply = match req["op"].as_str() {
                Some("status") => serde_json::json!({"ok": true, "live": true, "pid": pid, "files": 42,
                                                     "state": *server_state.lock().unwrap()}),
                Some(op) => serde_json::json!({"ok": false, "error": format!("unknown op {op:?}")}),
                None => serde_json::json!({"ok": false, "error": "bad request"}),
            };
            let _ = writeln!(stream, "{reply}");
        }
    });

    // Mid re-index: refused without --force, and nothing is signalled.
    let v = sift_json(&support, &["quit", "--json"], 2);
    assert!(v["error"].as_str().unwrap().contains("--force"), "{v}");
    std::thread::sleep(Duration::from_millis(200));
    assert!(!exited.load(Ordering::SeqCst));
    // Ready: SIGTERM, and --wait returns once the process is gone.
    *state.lock().unwrap() = "ready";
    let v = sift_json(&support, &["quit", "--wait", "10", "--json"], 0);
    assert_eq!((v["via"].clone(), v["pid"].clone(), v["exited"].clone()), ("SIGTERM".into(), pid.into(), true.into()), "{v}");
    assert!(exited.load(Ordering::SeqCst) || { std::thread::sleep(Duration::from_millis(200)); exited.load(Ordering::SeqCst) });
    let _ = fs::remove_file(&socket);
    let _ = fs::remove_dir_all(&support);
}

/// A stand-in for Sift.app's executable: notes the words and the working directory it
/// was started with, then answers as the first word after the verb says.
fn stub_app(dir: &Path) -> (PathBuf, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let app = dir.join("Stub.app");
    let exe = app.join("Contents/MacOS/Sift");
    fs::create_dir_all(exe.parent().unwrap()).unwrap();
    let log = dir.join("stub.log");
    fs::write(&exe, format!(
        "#!/bin/sh\n{{ printf '%s\\n' \"$@\"; echo \"cwd=$(pwd -P)\"; }} > '{log}'\n\
         case \"$2\" in\n\
           incomplete) echo '{{\"ok\":false,\"command\":\"update incomplete\",\"code\":\"check_incomplete\",\"error\":\"none yet\",\"exit\":1}}'; echo 'sift: none yet' >&2; exit 1;;\n\
           wrong) echo 'sift: usage' >&2; exit 2;;\n\
           hang) exec sleep 30;;\n\
           killed) kill -9 $$;;\n\
           big) i=0; while [ $i -lt 4000 ]; do echo 'a long line of output, more than a pipe buffer holds in the end'; i=$((i+1)); done;;\n\
         esac\n\
         echo '{{\"ok\":true,\"command\":\"'\"$1 $2\"'\"}}'\n",
        log = log.display()
    )).unwrap();
    fs::set_permissions(&exe, fs::Permissions::from_mode(0o755)).unwrap();
    (app, log)
}

/// `config status|export|import|sync` and `update …` go to the app executable word for
/// word and come back byte for byte; only what the forwarding itself decides is said here.
#[test]
fn lifecycle_commands_are_forwarded_to_the_app_executable() {
    let support = unique_dir("lifecycle");
    let work = unique_dir("lifecycle-work");
    let (app, log) = stub_app(&work);
    let run = |args: &[&str], app: Option<&Path>, cwd: &Path| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_sift"));
        command.args(args).env("SIFT_SUPPORT_DIR", &support).env("SIFT_APP_TIMEOUT", "1.5").current_dir(cwd);
        match app {
            Some(app) => command.env("SIFT_APP", app),
            None => command.env_remove("SIFT_APP"),
        };
        let out = command.output().expect("run sift");
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    };
    let direct = |args: &[&str]| {
        let out = Command::new(app.join("Contents/MacOS/Sift")).args(args).current_dir(&work).output().unwrap();
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    };
    let logged = || fs::read_to_string(&log).unwrap_or_default();

    // Words, output and exit code pass through unchanged; the app runs where the command was typed.
    for args in [
        vec!["config", "status", "--json"], vec!["config", "status"], vec!["config", "export", "-o", "out.json", "--force", "--json"],
        vec!["config", "sync", "off", "--yes", "--json"], vec!["config", "sync", "on", "--dry-run", "--json"],
        vec!["config", "sync", "on", "--json"], vec!["config", "import", "in.json", "--json"],
        vec!["update", "check", "--json"], vec!["update", "incomplete", "--json"], vec!["update", "wrong"], vec!["update"],
        // 升级到新版 needs no running Sift to be handed over (the app executable decides everything).
        vec!["update", "install", "--dry-run", "--json"], vec!["update", "install", "--yes", "--json"], vec!["update", "install"],
    ] {
        let _ = fs::remove_file(&log);
        let ours = run(&args, Some(&app), &work);
        assert_eq!(logged(), format!("{}\ncwd={}\n", args.join("\n"), work.display()), "sift {args:?}: {ours:?}");
        assert_eq!(ours, direct(&args), "sift {args:?}");
    }
    assert_eq!(run(&["update", "incomplete", "--json"], Some(&app), &work).0, 1);
    assert_eq!(run(&["update", "wrong"], Some(&app), &work).0, 2);
    let big = run(&["update", "big"], Some(&app), &work);
    assert_eq!((big.0, big.1.lines().count()), (0, 4001));

    // `config import … --yes` and `config sync on --yes` can rewrite config.json: only with the running app.
    for args in [vec!["config", "import", "in.json", "--yes", "--json"], vec!["config", "sync", "on", "--yes", "--json"],
                 vec!["config", "sync", "--yes", "on", "--json"]] {
        let _ = fs::remove_file(&log);
        let (rc, out, err) = run(&args, Some(&app), &work);
        let v: Value = serde_json::from_str(out.trim()).unwrap_or_else(|e| panic!("sift {args:?}: {e}: {out}"));
        assert_eq!((rc, v["ok"].clone(), v["code"].clone(), v["exit"].clone(), v["running"].clone()),
                   (3, false.into(), "not_running".into(), 3.into(), false.into()), "{v}");
        assert_eq!(v["command"], format!("config {}", if args.contains(&"import") { "import" } else { "sync" }));
        assert!(v["error"].as_str().unwrap().contains("sift start") && err.starts_with("sift: "), "{v} {err}");
        assert!(!log.exists(), "sift {args:?} reached the app executable");
    }
    // With an app answering on the socket they are forwarded like the rest.
    {
        use std::io::{BufRead, BufReader, Write};
        use std::os::unix::net::UnixListener;
        let socket = sift_core::config::socket_path_in(&support);
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut line = String::new();
                let _ = BufReader::new(&stream).read_line(&mut line);
                let _ = writeln!(stream, "{}", serde_json::json!({"ok": true, "live": true, "pid": 1, "state": "ready"}));
            }
        });
        for args in [vec!["config", "import", "in.json", "--yes", "--json"], vec!["config", "sync", "on", "--yes", "--json"]] {
            let _ = fs::remove_file(&log);
            let (rc, out, _) = run(&args, Some(&app), &work);
            assert_eq!((rc, serde_json::from_str::<Value>(out.trim()).unwrap()["ok"].clone()), (0, true.into()), "sift {args:?}");
            assert_eq!(logged(), format!("{}\ncwd={}\n", args.join("\n"), work.display()));
        }
        let _ = fs::remove_file(&socket);
    }
    // An app that takes the connection but is too busy to answer (index loading, a full walk) is running too.
    {
        use std::os::unix::net::UnixListener;
        let socket = sift_core::config::socket_path_in(&support);
        let listener = UnixListener::bind(&socket).unwrap();
        std::thread::spawn(move || {
            let mut held = Vec::new();
            for stream in listener.incoming() {
                held.extend(stream);   // accepted, never answered
            }
        });
        let _ = fs::remove_file(&log);
        let args = ["config", "sync", "on", "--yes", "--json"];
        let (rc, out, _) = run(&args, Some(&app), &work);
        assert_eq!((rc, serde_json::from_str::<Value>(out.trim()).unwrap()["ok"].clone()), (0, true.into()), "{out}");
        assert_eq!(logged(), format!("{}\ncwd={}\n", args.join("\n"), work.display()));
        let _ = fs::remove_file(&socket);
    }

    // What only the forwarding can report, in sift's failure shape with command and code.
    let _ = fs::remove_file(&log);
    let (rc, out, err) = run(&["config", "status", "--json"], None, &work);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((rc, v["ok"].clone(), v["code"].clone(), v["command"].clone(), v["exit"].clone()),
               (1, false.into(), "app_missing".into(), "config status".into(), 1.into()), "{v}");
    assert!(v["error"].is_string() && err.starts_with("sift: "));
    let (rc, out, err) = run(&["update", "check"], None, &work);
    assert_eq!((rc, out.as_str()), (1, ""));
    assert!(err.contains("Sift.app"), "{err}");
    let (rc, out, _) = run(&["update", "hang", "--json"], Some(&app), &work);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((rc, v["code"].clone(), v["exit"].clone()), (4, "timeout".into(), 4.into()), "{v}");
    let (rc, out, _) = run(&["update", "killed", "--json"], Some(&app), &work);
    let v: Value = serde_json::from_str(out.trim()).unwrap();
    assert_eq!((rc, v["code"].clone()), (1, "app_failed".into()), "{v}");

    // `sift config` itself and `config set` are the CLI's own as before; a word that is no subcommand is still an error here.
    let _ = fs::remove_file(&log);
    let v: Value = serde_json::from_str(run(&["config", "--json"], Some(&app), &work).1.trim()).unwrap();
    assert_eq!((v["ok"].clone(), v["source"].clone()), (true.into(), "defaults".into()));
    assert_eq!(run(&["config", "bogus", "--json"], Some(&app), &work).0, 2);
    assert_eq!(run(&["config", "set", "--ignore-add", "~/Downloads", "--dry-run"], Some(&app), &work).0, 0);
    assert_eq!(run(&["config", "--json", "status"], Some(&app), &work).0, 2);
    assert_eq!(run(&["history", "clear"], Some(&app), &work).0, 2);
    assert!(!log.exists());
    // Nothing here wrote into the support dir.
    assert_eq!(fs::read_dir(&support).unwrap().count(), 0);
    let _ = fs::remove_dir_all(&support);
    let _ = fs::remove_dir_all(&work);
}
