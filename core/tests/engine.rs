//! End-to-end check of the business layer shared by the app and the CLI:
//! index a temp tree, search, sort, pick up a live change, answer over the
//! socket, save, stop, and reopen offline.

use sift_core::{
    config::Config,
    engine::{Engine, EngineState, Row, SortKey},
    ipc::{self, Request},
    offline::Offline,
    service::Service,
};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

fn unique_dir(tag: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    // Canonical path: FSEvents reports /private/var/... for /var/... temp dirs.
    let base = fs::canonicalize(std::env::temp_dir()).unwrap();
    let dir = base.join(format!("sift-test-{tag}-{}-{nanos}", std::process::id()));
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

fn paths(engine: &Engine, query: &str) -> Vec<PathBuf> {
    let (outcome, _) = engine
        .search(None, Some(query.into()), true, false)
        .unwrap()
        .expect("non-interactive searches are never cancelled");
    engine
        .nodes(outcome.nodes.unwrap_or_default())
        .into_iter()
        .map(|n| Row::from(n).path)
        .collect()
}

#[test]
fn engine_search_sort_live_update_socket_and_snapshot() {
    let root = unique_dir("root");
    let support = unique_dir("support");
    fs::create_dir_all(root.join("docs/deep")).unwrap();
    fs::write(root.join("docs/README.md"), "x").unwrap();
    fs::write(root.join("docs/deep/notes.txt"), "hello").unwrap();
    fs::write(root.join("big.bin"), vec![0u8; 50_000]).unwrap();
    fs::write(root.join("small.bin"), vec![0u8; 10]).unwrap();
    fs::create_dir_all(root.join("skipped")).unwrap();
    fs::write(root.join("skipped/readme-hidden.md"), "x").unwrap();

    let config = Config {
        root: root.clone(),
        ignore_paths: vec![root.join("skipped")],
        include_paths: vec![],
        support_dir: support.clone(),
    }
    .normalized();
    config.save().unwrap();

    let engine = Engine::start(config.clone());
    wait_until("index ready", Duration::from_secs(30), || engine.status.state() == EngineState::Ready);

    // Case-insensitive name search; ignored folders stay out.
    assert_eq!(paths(&engine, "readme"), vec![root.join("docs/README.md")]);
    // Folder scope.
    let (scoped, _) = engine
        .search(Some("deep".into()), Some("notes".into()), false, false)
        .unwrap()
        .unwrap();
    assert_eq!(scoped.nodes.as_ref().map(Vec::len), Some(1));

    // Size sort, descending: big before small.
    let (bins, _) = engine.search(None, Some("*.bin".into()), false, false).unwrap().unwrap();
    let sorted = engine.sort(bins.nodes.unwrap(), SortKey::Size, true, false).unwrap();
    let rows: Vec<Row> = engine.nodes(sorted).into_iter().map(Row::from).collect();
    assert_eq!(rows[0].path, root.join("big.bin"));
    assert_eq!(rows[0].size, 50_000);
    assert_eq!(rows[1].path, root.join("small.bin"));

    // Live update through FSEvents.
    fs::write(root.join("docs/fresh-file.txt"), "new").unwrap();
    wait_until("FSEvents to add the new file", Duration::from_secs(20), || {
        paths(&engine, "fresh-file") == vec![root.join("docs/fresh-file.txt")]
    });
    fs::remove_file(root.join("docs/fresh-file.txt")).unwrap();
    wait_until("FSEvents to drop the removed file", Duration::from_secs(20), || {
        paths(&engine, "fresh-file").is_empty()
    });

    // CLI path: the same engine answers over the socket.
    let service = Service::new(engine.clone(), Box::new(|| {}));
    let server = ipc::Server::start(service).unwrap();
    let response = ipc::request(&config.socket_path(), &Request {
        op: "search".into(),
        query: Some("*.bin".into()),
        sort: Some("size".into()),
        desc: true,
        limit: Some(1),
        ..Default::default()
    })
    .unwrap()
    .expect("server is listening");
    assert_eq!(response["ok"], true);
    assert_eq!(response["total"], 2);
    assert_eq!(response["results"][0]["path"], root.join("big.bin").to_str().unwrap());
    let bad = ipc::request(&config.socket_path(), &Request { op: "nope".into(), ..Default::default() })
        .unwrap()
        .unwrap();
    assert_eq!(bad["ok"], false);
    drop(server);
    assert!(ipc::request(&config.socket_path(), &Request { op: "status".into(), ..Default::default() })
        .unwrap()
        .is_none());

    // A fresh walk is unsaved; shutdown writes it once.
    assert!(engine.status.dirty.load(std::sync::atomic::Ordering::Relaxed));
    engine.shutdown();
    assert!(config.db_path().exists());
    assert_eq!(engine.status.state(), EngineState::Stopped);

    // Offline reader sees the saved index.
    let mut offline = Offline::open(&config).unwrap();
    let hits = offline.search(None, Some("notes".into()), false).unwrap();
    let rows = offline.rows(&hits);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].path, root.join("docs/deep/notes.txt"));

    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&support);
    let _ = Path::new("");
}
