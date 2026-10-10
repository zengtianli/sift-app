//! The Settings window's Save path end to end: the C ABI the Swift app calls
//! (`sift_engine_start`, `sift_config_update`) on a private support dir, checked
//! through the `sift` binary. Its own test binary, because the engine's quit flag is
//! process-wide and another test's shutdown would cancel these walks.

use serde_json::Value;
use sift_core::{config::Config, ffi};
use std::{
    ffi::CString,
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let base = fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir = base.join(format!("sift-ffi-{tag}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn sift(support: &Path, args: &[&str]) -> (i32, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_sift"))
        .args(args)
        .env("SIFT_SUPPORT_DIR", support)
        .output()
        .expect("run sift");
    (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned())
}

fn status(support: &Path) -> Option<Value> {
    let (rc, out) = sift(support, &["status", "--json"]);
    (rc == 0).then(|| serde_json::from_str(out.trim()).unwrap())
}

fn wait_status(support: &Path, what: &str, f: impl Fn(&Value) -> bool) -> Value {
    let started = Instant::now();
    loop {
        if let Some(v) = status(support).filter(|v| f(v)) {
            return v;
        }
        assert!(started.elapsed() < Duration::from_secs(30), "timed out waiting for {what}: {:?}", status(support));
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn ignores(v: &Value, path: &Path) -> bool {
    v["ignore_paths"].as_array().unwrap().iter().any(|p| p.as_str() == path.to_str())
}

#[test]
fn settings_save_through_the_c_abi_is_live_for_the_cli() {
    let root = unique_dir("root");
    let support = unique_dir("support");
    fs::create_dir_all(root.join("skipme")).unwrap();
    for dir in ["a", "b", "c"] {
        fs::create_dir_all(root.join(dir)).unwrap();
        fs::write(root.join(dir).join(format!("target-{dir}.md")), "x").unwrap();
    }
    fs::write(root.join("skipme/hidden-target.md"), "x").unwrap();
    Config { root: root.clone(), ignore_paths: vec![], include_paths: vec![], support_dir: support.clone() }
        .normalized()
        .save()
        .unwrap();

    let dir = CString::new(support.to_str().unwrap()).unwrap();
    let engine = unsafe { ffi::sift_engine_start(dir.as_ptr()) };
    assert!(!engine.is_null());
    let before = wait_status(&support, "index ready", |v| v["state"] == "ready");
    let walks = before["walks"].as_u64().unwrap();
    assert_eq!(sift(&support, &["search", "hidden-target"]).0, 0);

    // Settings › Save & Re-index: the JSON the window sends.
    let skip = root.join("skipme");
    let json = serde_json::json!({"root": root, "ignore_paths": [skip], "include_paths": []}).to_string();
    let json = CString::new(json).unwrap();
    let mut error = std::ptr::null_mut();
    assert!(unsafe { ffi::sift_config_update(engine, json.as_ptr(), &mut error) });
    // `sift status` shows the saved settings at once and the re-index completes.
    assert!(ignores(&status(&support).expect("running"), &skip));
    let after = wait_status(&support, "re-index after Save", |v| {
        v["walks"].as_u64().unwrap() > walks && v["state"] == "ready"
    });
    assert!(ignores(&after, &skip));
    assert!(Config::load(&support).unwrap().ignore_paths.contains(&skip));
    assert_eq!(sift(&support, &["search", "hidden-target"]).0, 1);

    // Concurrent edits from several agents all land: each is applied to the live
    // settings inside the same lock as the save (no lost update).
    let handles: Vec<_> = ["a", "b", "c"]
        .into_iter()
        .map(|d| {
            let (support, path) = (support.clone(), root.join(d));
            std::thread::spawn(move || sift(&support, &["config", "set", "--ignore-add", path.to_str().unwrap()]))
        })
        .collect();
    for h in handles {
        let (rc, out) = h.join().unwrap();
        assert_eq!(rc, 0, "{out}");
    }
    let saved = Config::load(&support).unwrap();
    let live = wait_status(&support, "all edits indexed", |v| v["state"] == "ready");
    for d in ["a", "b", "c"] {
        assert!(saved.ignore_paths.contains(&root.join(d)), "config.json lost {d}: {saved:?}");
        assert!(ignores(&live, &root.join(d)), "status lost {d}: {live}");
    }
    assert!(ignores(&live, &skip));

    // The window reads back what it saved.
    let text = unsafe { ffi::sift_config_json(engine) };
    let shown: Value = serde_json::from_str(unsafe { std::ffi::CStr::from_ptr(text) }.to_str().unwrap()).unwrap();
    unsafe { ffi::sift_string_free(text) };
    for path in [skip.clone(), root.join("a"), root.join("b"), root.join("c")] {
        assert!(ignores(&shown, &path), "window shows {shown}");
    }

    unsafe { ffi::sift_engine_shutdown(engine) };
    assert_eq!(sift(&support, &["status"]).0, 3);
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&support);
}
