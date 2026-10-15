//! Engine thread: owns the `SearchCache`, applies FSEvents and serves requests.
//!
//! One thread owns the index; every caller (Swift UI through FFI, CLI through the
//! local socket) sends a command and waits for the reply. Searches carry a global
//! cancellation token, so a newer keystroke makes queued older searches return
//! immediately instead of running.

use crate::config::Config;
use crate::query::SearchOutcome;
use crate::recovery::{BackgroundPriority, HostLoad, RecoverySchedule, repair_pool, writer_lock};
use anyhow::{Context, Result};
use cardinal_sdk::{EventFlag, EventWatcher, FsEvent};
use crossbeam_channel::{Receiver, Sender, bounded, never, select, tick, unbounded};
use search_cache::{
    SearchCache, SearchOptions, SearchQuery, SearchResultNode, SlabIndex,
    SlabNodeMetadataCompact, WalkData,
};
use search_cancel::CancellationToken;
use std::{
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU8, AtomicU64, AtomicUsize, Ordering},
    },
    thread::JoinHandle,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tracing::{info, warn};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct RuntimePolicy {
    pub paused: bool,
    pub auto_repair: bool,
    pub auto_snapshot: bool,
}
impl Default for RuntimePolicy {
    fn default() -> Self { Self { paused: false, auto_repair: true, auto_snapshot: true } }
}

/// Set when the process is quitting; the walker and loaders poll it.
pub static QUIT: AtomicBool = AtomicBool::new(false);

/// FSEvents coalescing window. Cardinal uses 0.1s; a wider window batches bursts
/// (builds, git checkouts) into fewer wakeups while keeping results fresh.
const FSE_LATENCY_SECS: f64 = 0.5;
/// Housekeeping tick.
const TICK: Duration = Duration::from_secs(30);
/// Only flush a changed index after this long without searches…
const FLUSH_IDLE: Duration = Duration::from_secs(60);
/// …and at most this often. A stale snapshot is safe: on next launch FSEvents
/// replays everything since the snapshot's event id.
const FLUSH_MIN_INTERVAL: Duration = Duration::from_secs(60 * 60);
/// Metadata for sorting is fetched in chunks so a sort stays cancellable.
const SORT_CHUNK: usize = 8192;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EngineState {
    Starting = 0,
    Loading = 1,
    Scanning = 2,
    Updating = 3,
    Ready = 4,
    Stopped = 5,
    RebuildRequired = 6,
}

impl EngineState {
    pub fn from_u8(v: u8) -> Self {
        match v {
            1 => Self::Loading,
            2 => Self::Scanning,
            3 => Self::Updating,
            4 => Self::Ready,
            5 => Self::Stopped,
            6 => Self::RebuildRequired,
            _ => Self::Starting,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Starting => "starting",
            Self::Loading => "loading",
            Self::Scanning => "scanning",
            Self::Updating => "updating",
            Self::Ready => "ready",
            Self::Stopped => "stopped",
            Self::RebuildRequired => "rebuild_required",
        }
    }
}

#[derive(Default)]
pub struct Status {
    state: AtomicU8,
    pub files: AtomicUsize,
    pub events: AtomicUsize,
    pub rescans: AtomicU64,
    pub flushes: AtomicU64,
    /// Unix seconds of the last snapshot written by this process (0 = none).
    pub last_flush: AtomicU64,
    pub dirty: AtomicBool,
    /// Incremental history was lost. Never persist a later event watermark until rebuilt.
    pub rebuild_required: AtomicBool,
    /// Flag names only; never exposes filesystem paths in diagnostics.
    pub rebuild_reason: Mutex<String>,
    /// A background repair walk is running; searches keep using the last snapshot.
    pub repairing: AtomicBool,
    /// Completed full walks (first index, manual rescan, settings change, background repair).
    /// `rescans` counts only FSEvents rescan requests, so waiting for a rebuild watches this.
    pub walks: AtomicU64,
    /// Unix seconds when the last full walk finished (0 = none in this process).
    pub last_walk: AtomicU64,
    pub paused: AtomicBool,
    pub auto_repair: AtomicBool,
    pub auto_snapshot: AtomicBool,
    pub scan_stop: AtomicBool,
    pub index_revision: AtomicU64,
    pub configuration_error: Mutex<String>,
    pub runtime_error: Mutex<String>,
}

impl Status {
    pub fn state(&self) -> EngineState {
        EngineState::from_u8(self.state.load(Ordering::Relaxed))
    }

    fn set_state(&self, state: EngineState) {
        self.state.store(state as u8, Ordering::Relaxed);
    }

    fn record_walk(&self) {
        self.walks.fetch_add(1, Ordering::Relaxed);
        self.last_walk.store(unix_now(), Ordering::Relaxed);
    }
}

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SortKey {
    Name = 0,
    Path = 1,
    Size = 2,
    Modified = 3,
    Created = 4,
}

impl SortKey {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0 => Self::Name,
            1 => Self::Path,
            2 => Self::Size,
            3 => Self::Modified,
            4 => Self::Created,
            _ => return None,
        })
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "name" => Self::Name,
            "path" => Self::Path,
            "size" => Self::Size,
            "mtime" | "modified" => Self::Modified,
            "ctime" | "created" => Self::Created,
            _ => return None,
        })
    }
}

enum Cmd {
    Page {
        query: SearchQuery,
        options: SearchOptions,
        sort: Option<SortKey>,
        descending: bool,
        offset: usize,
        limit: usize,
        reply: Sender<Result<SearchPage>>,
    },
    Search {
        query: SearchQuery,
        options: SearchOptions,
        token: CancellationToken,
        /// The outcome and the time the search itself took (not time spent queued).
        reply: Sender<Result<(SearchOutcome, Duration, u64)>>,
    },
    Nodes {
        indices: Vec<SlabIndex>,
        revision: Option<u64>,
        reply: Sender<Vec<SearchResultNode>>,
    },
    Locate { indices: Vec<SlabIndex>, paths: Vec<PathBuf>, revision: u64, reply: Sender<Vec<usize>> },
    Sort {
        indices: Vec<SlabIndex>,
        revision: Option<u64>,
        key: SortKey,
        descending: bool,
        token: CancellationToken,
        reply: Sender<Option<Vec<SlabIndex>>>,
    },
    Rescan,
    Reconfigure(Config),
    PolicyChanged(bool),
    Flush {
        reply: Sender<Result<bool>>,
    },
    Shutdown {
        reply: Sender<()>,
    },
}

/// One bounded CLI page resolved under one index ownership interval. Large
/// exports retain the existing chunked/revision-checked path.
pub struct SearchPage {
    pub total: usize,
    pub offset: usize,
    pub took: Duration,
    pub loosened: Option<String>,
    pub rows: Vec<SearchResultNode>,
}

pub struct Engine {
    tx: Sender<Cmd>,
    pub status: Arc<Status>,
    /// The settings in effect. Whoever changes them (the `Service`) holds this lock
    /// while it saves and queues the change; the engine thread puts the previous
    /// settings back when that change's walk did not complete, so status never
    /// reports settings the index is not built with.
    settings: Arc<Mutex<Config>>,
    policy: Mutex<RuntimePolicy>,
    thread: Mutex<Option<JoinHandle<()>>>,
    _writer_lock: Option<std::fs::File>,
}

impl Engine {
    pub fn search_page(&self, directory: Option<String>, query: Option<String>,
        case_insensitive: bool, sort: Option<SortKey>, descending: bool,
        offset: usize, limit: usize) -> Result<SearchPage> {
        anyhow::ensure!(limit <= 4096, "atomic search pages are limited to 4096 rows");
        let (reply, rx) = bounded(1);
        self.send(Cmd::Page {
            query: SearchQuery {
                directory_query: directory.filter(|s| !s.trim().is_empty()),
                query: query.filter(|s| !s.trim().is_empty()).map(crate::query::normalize),
            }, options: SearchOptions { case_insensitive }, sort, descending, offset, limit, reply,
        })?;
        rx.recv()?
    }
    pub fn start(config: Config) -> Arc<Self> {
        Self::try_start(config).expect("cannot acquire Sift index ownership")
    }

    pub fn try_start(config: Config) -> Result<Arc<Self>> {
        let lock = writer_lock(&config)?;
        let (tx, rx) = unbounded();
        let status = Arc::new(Status::default());
        let policy = match std::fs::read(config.support_dir.join("runtime.json")) {
            Ok(bytes) => match serde_json::from_slice::<RuntimePolicy>(&bytes) {
                Ok(policy) => policy,
                Err(error) => {
                    *status.runtime_error.lock().unwrap() = format!("索引运行选项损坏，已暂停；请在设置中确认运行选项：{error}");
                    RuntimePolicy { paused:true, auto_repair:false, auto_snapshot:false }
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => RuntimePolicy::default(),
            Err(error) => {
                *status.runtime_error.lock().unwrap() = format!("无法读取索引运行选项，已暂停：{error}");
                RuntimePolicy { paused:true, auto_repair:false, auto_snapshot:false }
            }
        };
        status.paused.store(policy.paused, Ordering::Relaxed);
        status.auto_repair.store(policy.auto_repair, Ordering::Relaxed);
        status.auto_snapshot.store(policy.auto_snapshot, Ordering::Relaxed);
        let thread_status = status.clone();
        let settings = Arc::new(Mutex::new(config.clone()));
        let thread_settings = settings.clone();
        let thread = std::thread::Builder::new()
            .name("sift-engine".into())
            .spawn(move || run(config, rx, thread_status, thread_settings))
            .expect("spawn engine thread");
        Ok(Arc::new(Self {
            tx,
            status,
            settings,
            policy: Mutex::new(policy),
            thread: Mutex::new(Some(thread)),
            _writer_lock: lock,
        }))
    }

    /// Returns `Ok(None)` when a newer search superseded this one.
    /// `interactive` searches (the UI) cancel older interactive ones; CLI
    /// searches never cancel or get cancelled.
    pub fn search(
        &self,
        directory: Option<String>,
        query: Option<String>,
        case_insensitive: bool,
        interactive: bool,
    ) -> Result<Option<(SearchOutcome, Duration)>> {
        Ok(self.search_versioned(directory, query, case_insensitive, interactive)?.map(|(o,t,_)| (o,t)))
    }

    pub fn search_versioned(
        &self, directory: Option<String>, query: Option<String>, case_insensitive: bool, interactive: bool,
    ) -> Result<Option<(SearchOutcome, Duration, u64)>> {
        let token = token(interactive);
        let (reply, rx) = bounded(1);
        self.send(Cmd::Search {
            query: SearchQuery {
                directory_query: directory.filter(|s| !s.trim().is_empty()),
                query: query.filter(|s| !s.trim().is_empty()).map(crate::query::normalize),
            },
            options: SearchOptions { case_insensitive },
            token,
            reply,
        })?;
        let (outcome, took, revision) = rx.recv()??;
        Ok(outcome.nodes.is_some().then_some((outcome, took, revision)))
    }

    pub fn nodes(&self, indices: Vec<SlabIndex>) -> Vec<SearchResultNode> {
        self.nodes_at(indices, None)
    }

    pub fn nodes_at(&self, indices: Vec<SlabIndex>, revision: Option<u64>) -> Vec<SearchResultNode> {
        if indices.is_empty() {
            return Vec::new();
        }
        let (reply, rx) = bounded(1);
        if self.send(Cmd::Nodes { indices, revision, reply }).is_err() {
            return Vec::new();
        }
        rx.recv().unwrap_or_default()
    }
    pub fn locate(&self, indices: Vec<SlabIndex>, paths: Vec<PathBuf>, revision: u64) -> Vec<usize> {
        let (reply, rx) = bounded(1);
        if self.send(Cmd::Locate { indices, paths, revision, reply }).is_err() { return vec![]; }
        rx.recv().unwrap_or_default()
    }

    /// Sorts under the current search token: a newer search cancels it (`None`).
    pub fn sort(
        &self,
        indices: Vec<SlabIndex>,
        key: SortKey,
        descending: bool,
        interactive: bool,
    ) -> Option<Vec<SlabIndex>> {
        self.sort_at(indices, key, descending, interactive, None)
    }

    pub fn sort_at(&self, indices: Vec<SlabIndex>, key: SortKey, descending: bool, interactive: bool, revision: Option<u64>) -> Option<Vec<SlabIndex>> {
        let token = token(interactive);
        let (reply, rx) = bounded(1);
        self.send(Cmd::Sort {
            indices,
            revision,
            key,
            descending,
            token,
            reply,
        })
        .ok()?;
        rx.recv().ok().flatten()
    }

    pub fn rescan(&self) {
        self.status.scan_stop.store(false, Ordering::Relaxed);
        let _ = self.send(Cmd::Rescan);
    }

    pub fn policy(&self) -> RuntimePolicy { self.policy.lock().unwrap().clone() }

    pub fn set_policy(&self, policy: RuntimePolicy) -> Result<()> {
        self.edit_policy(|p| *p = policy)
    }

    pub fn edit_policy(&self, edit: impl FnOnce(&mut RuntimePolicy)) -> Result<()> {
        let mut saved = self.policy.lock().unwrap();
        let mut policy = saved.clone();edit(&mut policy);
        let directory = self.settings.lock().unwrap().support_dir.clone();
        std::fs::create_dir_all(&directory)?;
        let temporary = directory.join("runtime.json.tmp");
        std::fs::write(&temporary, serde_json::to_vec_pretty(&policy)?)?;
        std::fs::rename(temporary, directory.join("runtime.json"))?;
        self.status.runtime_error.lock().unwrap().clear();
        // Resume only on the index thread, after its paused watcher is replaced:
        // otherwise a new batch could advance the watermark past changes skipped while paused.
        if policy.paused { self.status.paused.store(true, Ordering::Relaxed); }
        self.status.auto_repair.store(policy.auto_repair, Ordering::Relaxed);
        self.status.auto_snapshot.store(policy.auto_snapshot, Ordering::Relaxed);
        if policy.paused { self.status.scan_stop.store(true, Ordering::Relaxed); }
        let paused = policy.paused;*saved = policy;
        self.send(Cmd::PolicyChanged(paused))
    }

    pub fn cancel_scan(&self) {
        self.status.scan_stop.store(true, Ordering::Relaxed);
        let _ = self.send(Cmd::PolicyChanged(self.policy().paused));
    }

    /// The settings in effect (see the field). Hold the lock across a check-and-change.
    pub fn settings(&self) -> &Mutex<Config> {
        &self.settings
    }

    /// Queues a settings change. Callers set `settings()` to `config` under its lock
    /// first (the `Service` does), so a failed walk can restore the previous ones.
    pub fn reconfigure(&self, config: Config) {
        let _ = self.send(Cmd::Reconfigure(config));
    }

    /// Writes the snapshot now if the index changed. Returns whether it wrote.
    pub fn flush(&self) -> Result<bool> {
        let (reply, rx) = bounded(1);
        self.send(Cmd::Flush { reply })?;
        rx.recv()?
    }

    /// Flushes a changed index and stops the engine thread.
    pub fn shutdown(&self) {
        QUIT.store(true, Ordering::Relaxed);
        let (reply, rx) = bounded(1);
        if self.send(Cmd::Shutdown { reply }).is_ok() {
            let _ = rx.recv_timeout(Duration::from_secs(30));
        }
        if let Some(handle) = self.thread.lock().unwrap().take() {
            let _ = handle.join();
        }
    }

    fn send(&self, cmd: Cmd) -> Result<()> {
        self.tx
            .send(cmd)
            .map_err(|_| anyhow::anyhow!("engine stopped"))
    }
}

fn token(interactive: bool) -> CancellationToken {
    if interactive {
        CancellationToken::new_search()
    } else {
        CancellationToken::noop()
    }
}

struct Loop {
    config: Config,
    /// `Engine::settings`, restored here when a reconfigure walk does not complete.
    settings: Arc<Mutex<Config>>,
    cache: SearchCache,
    watcher: EventWatcher,
    status: Arc<Status>,
    history_done: bool,
    last_activity: Instant,
    last_flush: Option<Instant>,
    recovery: RecoverySchedule,
    pending_rebuild_commit: bool,
    repair: Option<Repair>,
    host: HostLoad,
}

/// A repair walk on its own thread and the small background pool, so the loop keeps
/// answering searches from the last snapshot (a throttled walk of the whole disk takes
/// minutes). Dropping it cancels the walk.
struct Repair {
    done: Receiver<Option<SearchCache>>,
    cancel: Arc<AtomicBool>,
}

impl Repair {
    fn start(config: Config) -> Self {
        let (tx, done) = bounded(1);
        let cancel = Arc::new(AtomicBool::new(false));
        let stop = cancel.clone();
        let spawned = std::thread::Builder::new().name("sift-repair".into()).spawn(move || {
            let _priority = BackgroundPriority::enter();
            // Never falls back to the all-core global pool; a failed start is retried later.
            let cache = repair_pool().and_then(|pool| pool.install(|| walk_counting(&config, None, &stop)));
            let _ = tx.send(cache.filter(|_| !stop.load(Ordering::Relaxed)));
        });
        if let Err(e) = spawned {
            warn!("cannot start background repair: {e}");
        }
        Self { done, cancel }
    }
}

impl Drop for Repair {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::Relaxed);
    }
}

/// Present while the index is known to be incomplete (survives restarts).
pub fn rebuild_marker(config: &Config) -> PathBuf {
    config.support_dir.join("rebuild-required")
}

fn requires_rebuild(event: &FsEvent, root: &std::path::Path) -> bool {
    event.flag.intersects(EventFlag::UserDropped | EventFlag::KernelDropped | EventFlag::EventIdsWrapped)
        || event.should_rescan(root)
}

fn run(config: Config, rx: Receiver<Cmd>, status: Arc<Status>, settings: Arc<Mutex<Config>>) {
    status.rebuild_required.store(rebuild_marker(&config).exists(), Ordering::Relaxed);
    *status.rebuild_reason.lock().unwrap() = std::fs::read_to_string(rebuild_marker(&config)).unwrap_or_default();
    let cache = load_or_walk(&config, &status);
    let mut state = Loop {
        watcher: EventWatcher::noop(),
        cache,
        config,
        settings,
        status,
        history_done: false,
        last_activity: Instant::now(),
        last_flush: None,
        recovery: RecoverySchedule::default(),
        pending_rebuild_commit: false,
        repair: None,
        host: HostLoad::default(),
    };
    state.start_watcher();
    let ticker = tick(TICK);

    loop {
        let repair_done = state.repair.as_ref().map_or_else(never, |r| r.done.clone());
        select! {
            recv(rx) -> cmd => {
                let Ok(cmd) = cmd else { break };
                if let Some(reply) = state.handle(cmd) {
                    state.flush_if_dirty(true);
                    state.status.set_state(EngineState::Stopped);
                    let _ = reply.send(());
                    return;
                }
            }
            recv(state.watcher) -> events => {
                if let Ok(events) = events {
                    state.apply_events(events);
                }
            }
            recv(repair_done) -> cache => state.finish_repair(cache.ok().flatten()),
            recv(ticker) -> _ => {
                state.maybe_recover();
                state.maybe_idle_flush();
            },
        }
    }
    state.flush_if_dirty(true);
    state.status.set_state(EngineState::Stopped);
}

fn load_or_walk(config: &Config, status: &Status) -> SearchCache {
    status.set_state(EngineState::Loading);
    let started = Instant::now();
    match SearchCache::try_read_persistent_cache(
        &config.root,
        &config.db_path(),
        &config.ignore_paths,
        &config.include_paths,
        &QUIT,
    ) {
        Ok(cache) => {
            info!(
                "loaded snapshot: {} nodes in {:?}",
                cache.get_total_files(),
                started.elapsed()
            );
            status.files.store(cache.get_total_files(), Ordering::Relaxed);
            cache
        }
        Err(e) => {
            info!("no usable snapshot ({e:#}); walking {:?}", config.root);
            let cache = if status.paused.load(Ordering::Relaxed) { None } else { walk(config, status) }.unwrap_or_else(|| {
                SearchCache::noop(
                    config.root.clone(),
                    config.ignore_paths.clone(),
                    config.include_paths.clone(),
                    &QUIT,
                )
            });
            // A fresh walk has never been saved.
            status.dirty.store(!cache.is_noop(), Ordering::Relaxed);
            cache
        }
    }
}

fn walk(config: &Config, status: &Status) -> Option<SearchCache> {
    status.set_state(EngineState::Scanning);
    let cache = walk_counting(config, Some(&status.files), &status.scan_stop);
    if cache.is_some() {
        status.record_walk();
    }
    cache
}

/// Walks the index root on the current rayon pool. `progress` receives live counts;
/// `stop` (like QUIT) ends the walk early.
fn walk_counting(config: &Config, progress: Option<&AtomicUsize>, stop: &AtomicBool) -> Option<SearchCache> {
    let started = Instant::now();
    let walk_data = WalkData::new(
        &config.root,
        &config.ignore_paths,
        &config.include_paths,
        false,
        || QUIT.load(Ordering::Relaxed) || stop.load(Ordering::Relaxed),
    );
    let done = AtomicBool::new(false);
    let cache = std::thread::scope(|s| {
        if let Some(files) = progress {
            s.spawn(|| {
                while !done.load(Ordering::Relaxed) {
                    let n = walk_data.num_files.load(Ordering::Relaxed)
                        + walk_data.num_dirs.load(Ordering::Relaxed);
                    files.store(n, Ordering::Relaxed);
                    std::thread::sleep(Duration::from_millis(200));
                }
            });
        }
        let cache = SearchCache::walk_fs_with_walk_data(&walk_data, &QUIT);
        done.store(true, Ordering::Relaxed);
        cache
    });
    if let Some(cache) = &cache {
        if let Some(files) = progress {
            files.store(cache.get_total_files(), Ordering::Relaxed);
        }
        info!(
            "walked {} nodes in {:?}",
            cache.get_total_files(),
            started.elapsed()
        );
    }
    let cache = cache.filter(|_| !stop.load(Ordering::Relaxed) && !QUIT.load(Ordering::Relaxed));
    // The parallel walk's temporary Node tree has now been dropped, on success
    // or cancellation. Each worker must drain its own remote-free queue before
    // purging the unused pages; collecting only the index thread misses them.
    rayon::broadcast(|_| crate::alloc::collect_unused());
    crate::alloc::collect_unused();
    cache
}

impl Loop {
    fn require_rebuild(&self) {
        let was_required = self.status.rebuild_required.swap(true, Ordering::Relaxed);
        self.status.set_state(EngineState::RebuildRequired);
        if !was_required && std::env::var_os("SIFT_READONLY").is_none() {
            if let Err(e) = std::fs::write(rebuild_marker(&self.config),
                format!("FSEvents history requires rebuilding. Background repair is scheduled after query inactivity; sift rescan repairs immediately. The last snapshot is preserved.\n{}\n",
                    self.status.rebuild_reason.lock().unwrap())) {
                warn!("cannot persist rebuild marker: {e}");
            }
        }
    }

    fn set_active_state(&self, state: EngineState) {
        self.status.set_state(if self.status.rebuild_required.load(Ordering::Relaxed) {
            EngineState::RebuildRequired
        } else { state });
    }

    fn start_watcher(&mut self) {
        self.history_done = false;
        if self.status.paused.load(Ordering::Relaxed) {
            self.watcher = EventWatcher::noop();
            self.set_active_state(EngineState::Ready);
            return;
        }
        if self.cache.is_noop() {
            self.watcher = EventWatcher::noop();
            self.set_active_state(EngineState::Ready);
            return;
        }
        self.set_active_state(EngineState::Updating);
        self.watcher = EventWatcher::spawn(
            self.config.root.to_string_lossy().into_owned(),
            self.cache.last_event_id(),
            FSE_LATENCY_SECS,
            self.cache.ignore_paths(),
            self.cache.include_paths(),
        )
        .1;
    }

    /// Returns the shutdown reply channel when asked to stop.
    fn handle(&mut self, cmd: Cmd) -> Option<Sender<()>> {
        match cmd {
            Cmd::Page { query, options, sort, descending, offset, limit, reply } => {
                self.last_activity = Instant::now();
                let started = Instant::now();
                let result = crate::query::search(&mut self.cache, query, options, token(false)).and_then(|outcome| {
                    let took = started.elapsed();
                    let mut indices = outcome.nodes.context("search was superseded")?;
                    if let Some(key) = sort {
                        indices = self.sort(indices, key, descending, token(false)).context("sorting was superseded")?;
                    } else if descending { indices.reverse(); }
                    let total = indices.len();
                    let offset = offset.min(total);
                    let end = offset.saturating_add(limit).min(total);
                    let rows = self.cache.expand_file_nodes(&indices[offset..end]);
                    Ok(SearchPage { total, offset, took, loosened: outcome.loosened, rows })
                });
                let _ = reply.send(result);
            }
            Cmd::Search {
                query,
                options,
                token,
                reply,
            } => {
                self.last_activity = Instant::now();
                let started = Instant::now();
                let outcome = crate::query::search(&mut self.cache, query, options, token);
                let revision = self.status.index_revision.load(Ordering::Relaxed);
                let _ = reply.send(outcome.map(|o| (o, started.elapsed(), revision)));
            }
            Cmd::Nodes { indices, revision, reply } => {
                let current = self.status.index_revision.load(Ordering::Relaxed);
                let rows = if revision.is_none_or(|r| r == current) { self.cache.expand_file_nodes(&indices) } else { vec![] };
                let _ = reply.send(rows);
            }
            Cmd::Locate { indices, paths, revision, reply } => {
                if self.status.index_revision.load(Ordering::Relaxed) != revision { let _ = reply.send(vec![]); return None; }
                let names: std::collections::HashSet<_> = paths.iter().filter_map(|p| p.file_name().and_then(|n| n.to_str())).collect();
                let wanted: std::collections::HashSet<_> = paths.iter().collect();
                let found = indices.iter().enumerate().filter_map(|(position,index)| {
                    if !self.cache.node_name(*index).is_some_and(|n| names.contains(n)) { return None; }
                    self.cache.node_path(*index).filter(|p| wanted.contains(p)).map(|_| position)
                }).collect();
                let _ = reply.send(found);
            }
            Cmd::Sort {
                indices,
                revision,
                key,
                descending,
                token,
                reply,
            } => {
                self.last_activity = Instant::now();
                let current = self.status.index_revision.load(Ordering::Relaxed);
                let sorted = if revision.is_none_or(|r| r == current) { self.sort(indices, key, descending, token) } else { None };
                let _ = reply.send(sorted);
            }
            Cmd::Rescan => { self.rescan(); }
            Cmd::PolicyChanged(paused) => {
                let was_paused = self.status.paused.load(Ordering::Relaxed);
                let canceled = self.status.scan_stop.load(Ordering::Relaxed);
                if self.status.scan_stop.load(Ordering::Relaxed) { self.cancel_repair(); }
                if !self.status.auto_repair.load(Ordering::Relaxed) { self.cancel_repair(); }
                if paused {
                    self.watcher = EventWatcher::noop();
                    self.set_active_state(EngineState::Ready);
                } else {
                    self.status.paused.store(false, Ordering::Relaxed);
                    self.status.scan_stop.store(false, Ordering::Relaxed);
                    if self.cache.is_noop() && self.status.configuration_error.lock().unwrap().is_empty() { self.rescan(); }
                    else if was_paused || canceled { self.start_watcher(); }
                }
            }
            Cmd::Reconfigure(config) => {
                if config != self.config {
                    self.watcher = EventWatcher::noop();
                    let previous = std::mem::replace(&mut self.config, config);
                    if !self.rescan() {
                        let failed = std::mem::replace(&mut self.config, previous);
                        // Report what the index is built with again, unless a newer
                        // change is already queued behind this one.
                        let mut settings = self.settings.lock().unwrap();
                        if *settings == failed {
                            *settings = self.config.clone();
                            if let Err(e) = self.config.save() {
                                *self.status.configuration_error.lock().unwrap() = format!("扫描未完成，原范围已恢复，但配置回滚写入失败：{e:#}");
                            }
                        }
                        drop(settings);
                        self.start_watcher();
                    }
                }
            }
            Cmd::Flush { reply } => {
                let _ = reply.send(self.flush_now_if_dirty());
            }
            Cmd::Shutdown { reply } => return Some(reply),
        }
        None
    }

    fn apply_events(&mut self, events: Vec<FsEvent>) {
        if self.status.paused.load(Ordering::Relaxed) { return; }
        self.status
            .events
            .fetch_add(events.len(), Ordering::Relaxed);
        if events.iter().any(|e| e.flag == EventFlag::HistoryDone) {
            self.history_done = true;
            self.set_active_state(EngineState::Ready);
        }
        if events.iter().any(|e| e.flag != EventFlag::HistoryDone) {
            self.status.dirty.store(true, Ordering::Relaxed);
        }
        // A root/history-loss event cannot be repaired cheaply. Keep applying the
        // other paths, but retain the last known snapshot and expose the gap.
        let (rebuild, incremental): (Vec<_>, Vec<_>) = events.into_iter()
            .partition(|e| requires_rebuild(e, &self.config.root));
        if !rebuild.is_empty() {
            self.pending_rebuild_commit = false;
            *self.status.rebuild_reason.lock().unwrap() = rebuild.iter().map(|e|
                format!("flags={:?}; at_root={}; ancestor_of_root={}", e.flag,
                    e.path == self.config.root, self.config.root.starts_with(&e.path)))
                .collect::<Vec<_>>().join(" | ");
            let _ = self.cache.handle_fs_events(rebuild);
            self.require_rebuild();
        }
        let cache = &mut self.cache;
        if crate::recovery::incremental(|| cache.handle_fs_events(incremental)).is_err() {
            self.pending_rebuild_commit = false;
            self.require_rebuild();
        }
        // A completed disk walk is not enough: catch up from its starting event
        // ID, and only commit after HistoryDone without any new history loss.
        if self.pending_rebuild_commit && self.history_done {
            self.commit_rebuilt_cache();
        }
        self.status
            .files
            .store(self.cache.get_total_files(), Ordering::Relaxed);
        self.status
            .rescans
            .store(self.cache.rescan_count(), Ordering::Relaxed);
        self.status.index_revision.fetch_add(1, Ordering::Relaxed);
    }

    fn rescan(&mut self) -> bool {
        if self.status.paused.load(Ordering::Relaxed) { return false; }
        self.cancel_repair();
        self.recovery.attempted(Instant::now());
        self.pending_rebuild_commit = false;
        self.watcher = EventWatcher::noop();
        if let Some(cache) = walk(&self.config, &self.status) {
            self.accept_rebuilt_cache(cache);
            self.start_watcher();
            true
        } else {
            self.status.files.store(self.cache.get_total_files(), Ordering::Relaxed);
            self.require_rebuild();
            if !QUIT.load(Ordering::Relaxed) { self.start_watcher(); }
            false
        }
    }

    fn accept_rebuilt_cache(&mut self, cache: SearchCache) {
        self.cache = cache;
        // The previous index has just been dropped. Its freed small blocks must
        // not remain charged to the resident app until the next full walk.
        crate::alloc::collect_unused();
        self.status.dirty.store(true, Ordering::Relaxed);
        self.pending_rebuild_commit = self.status.rebuild_required.load(Ordering::Relaxed);
        self.history_done = false;
        self.status.index_revision.fetch_add(1, Ordering::Relaxed);
    }

    fn commit_rebuilt_cache(&mut self) {
        // Clear a durable warning only after its replacement snapshot is durable.
        if self.status.rebuild_required.load(Ordering::Relaxed)
            && std::env::var_os("SIFT_READONLY").is_none()
            && !QUIT.load(Ordering::Relaxed) {
            let repaired = self.cache.flush_snapshot_to_file(&self.config.db_path())
                .and_then(|_| match std::fs::remove_file(rebuild_marker(&self.config)) {
                    Ok(()) => Ok(()),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
                    Err(e) => Err(e.into()),
                });
            match repaired {
                Ok(()) => {
                        self.status.rebuild_required.store(false, Ordering::Relaxed);
                        self.status.rebuild_reason.lock().unwrap().clear();
                    self.record_flush();
                    self.pending_rebuild_commit = false;
                    self.status.set_state(EngineState::Ready);
                }
                Err(e) => {
                    self.pending_rebuild_commit = false;
                    warn!("rebuilt index could not be committed; recovery will retry: {e:#}");
                }
            }
        }
    }

    fn maybe_recover(&mut self) {
        let host_busy = self.host.sample();
        if QUIT.load(Ordering::Relaxed) || std::env::var_os("SIFT_READONLY").is_some()
            || self.status.paused.load(Ordering::Relaxed) || !self.status.auto_repair.load(Ordering::Relaxed)
            || self.pending_rebuild_commit || self.repair.is_some() { return; }
        if self.recovery.due(Instant::now(), self.status.rebuild_required.load(Ordering::Relaxed),
                             self.last_activity.elapsed(), host_busy) {
            info!("repairing lost filesystem history on background threads");
            self.recovery.attempted(Instant::now());
            self.status.repairing.store(true, Ordering::Relaxed);
            self.repair = Some(Repair::start(self.config.clone()));
        }
    }

    /// Swaps in a finished repair, then catches up from the event ID its walk started
    /// at; the marker clears only after HistoryDone without new loss (see apply_events).
    fn finish_repair(&mut self, cache: Option<SearchCache>) {
        self.cancel_repair();
        let Some(cache) = cache.filter(|_| !QUIT.load(Ordering::Relaxed)) else {
            if !QUIT.load(Ordering::Relaxed) {
                warn!("background repair did not finish; it will be retried");
            }
            return;
        };
        self.watcher = EventWatcher::noop();
        self.accept_rebuilt_cache(cache);
        self.status.record_walk();
        self.start_watcher();
    }

    fn cancel_repair(&mut self) {
        self.repair = None;
        self.status.repairing.store(false, Ordering::Relaxed);
    }

    fn maybe_idle_flush(&mut self) {
        if !self.status.auto_snapshot.load(Ordering::Relaxed) { return; }
        if self.last_activity.elapsed() < FLUSH_IDLE {
            return;
        }
        if self
            .last_flush
            .is_some_and(|at| at.elapsed() < FLUSH_MIN_INTERVAL)
        {
            return;
        }
        self.flush_if_dirty(false);
    }

    fn flush_if_dirty(&mut self, final_flush: bool) {
        match self.flush_now_if_dirty() {
            Ok(true) => info!("snapshot written (final={final_flush})"),
            Ok(false) => {}
            Err(e) => warn!("snapshot write failed: {e:#}"),
        }
    }

    fn flush_now_if_dirty(&mut self) -> Result<bool> {
        anyhow::ensure!(!self.status.rebuild_required.load(Ordering::Relaxed),
            "index needs rebuilding; last snapshot preserved (run sift rescan)");
        // Verification runs (`SIFT_READONLY=1`) never write the index.
        if std::env::var_os("SIFT_READONLY").is_some() {
            return Ok(false);
        }
        if !self.status.dirty.load(Ordering::Relaxed) || self.cache.is_noop() {
            return Ok(false);
        }
        let started = Instant::now();
        self.cache.flush_snapshot_to_file(&self.config.db_path())?;
        self.record_flush();
        info!("snapshot flush took {:?}", started.elapsed());
        Ok(true)
    }

    fn record_flush(&mut self) {
        self.status.dirty.store(false, Ordering::Relaxed);
        self.status.flushes.fetch_add(1, Ordering::Relaxed);
        self.status.last_flush.store(unix_now(), Ordering::Relaxed);
        self.last_flush = Some(Instant::now());
    }

    fn sort(
        &mut self,
        indices: Vec<SlabIndex>,
        key: SortKey,
        descending: bool,
        token: CancellationToken,
    ) -> Option<Vec<SlabIndex>> {
        sort_indices(&mut self.cache, indices, key, descending, token)
    }
}

/// The one result ordering: the app (FFI), the live CLI (socket) and the offline
/// CLI (saved snapshot) all sort through here. Names compare ASCII-case-insensitively
/// first, then by bytes; size and dates fill in metadata the walk skipped. `None`
/// when a newer search cancelled it.
pub fn sort_indices(
    cache: &mut SearchCache,
    mut indices: Vec<SlabIndex>,
    key: SortKey,
    descending: bool,
    token: CancellationToken,
) -> Option<Vec<SlabIndex>> {
    token.is_cancelled()?;
    match key {
        SortKey::Name => {
            let cache = &*cache;
            indices.sort_by(|a, b| {
                let (na, nb) = (
                    cache.node_name(*a).unwrap_or(""),
                    cache.node_name(*b).unwrap_or(""),
                );
                cmp_ignore_ascii_case(na, nb).then_with(|| na.cmp(nb))
            });
        }
        SortKey::Path => {
            // Large path sorts materialise one temporary PathBuf per result.
            // Declared before keyed so cancellation also drops all paths first.
            let _collect = if indices.len() >= 8192 { Some(crate::alloc::CollectOnDrop) } else { None };
            let mut keyed = Vec::with_capacity(indices.len());
            for (i, index) in indices.iter().enumerate() {
                token.is_cancelled_sparse(i)?;
                keyed.push((cache.node_path(*index).unwrap_or_default(), *index));
            }
            token.is_cancelled()?;
            keyed.sort_unstable_by(|a, b| a.0.cmp(&b.0));
            indices = keyed.into_iter().map(|(_, index)| index).collect();
        }
        SortKey::Size | SortKey::Modified | SortKey::Created => {
            // Fill in metadata the walk skipped, chunk by chunk.
            for chunk in indices.chunks(SORT_CHUNK) {
                token.is_cancelled()?;
                let missing: Vec<_> = chunk
                    .iter()
                    .copied()
                    .filter(|i| cache.node_metadata(*i).is_some_and(|m| m.is_none()))
                    .collect();
                if !missing.is_empty() {
                    cache.expand_file_nodes(&missing);
                }
            }
            token.is_cancelled()?;
            let cache = &*cache;
            let value = |i: SlabIndex| -> i64 {
                numeric(cache.node_metadata(i).unwrap_or_else(SlabNodeMetadataCompact::none), key)
            };
            indices.sort_by_cached_key(|i| value(*i));
        }
    }
    if descending {
        indices.reverse();
    }
    token.is_cancelled()?;
    Some(indices)
}

fn numeric(meta: SlabNodeMetadataCompact, key: SortKey) -> i64 {
    let Some(m) = meta.as_ref() else {
        return i64::MIN;
    };
    match key {
        SortKey::Size => m.size(),
        SortKey::Modified => m.mtime().map_or(i64::MIN, |v| v.get() as i64),
        SortKey::Created => m.ctime().map_or(i64::MIN, |v| v.get() as i64),
        SortKey::Name | SortKey::Path => 0,
    }
}

fn cmp_ignore_ascii_case(a: &str, b: &str) -> std::cmp::Ordering {
    a.bytes()
        .map(|c| c.to_ascii_lowercase())
        .cmp(b.bytes().map(|c| c.to_ascii_lowercase()))
}

pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Plain row data shared by the FFI and socket layers.
pub struct Row {
    pub path: PathBuf,
    pub kind: u8,
    pub size: i64,
    pub mtime: u32,
    pub ctime: u32,
    /// 0 = metadata known, 1 = not fetched, 2 = inaccessible.
    pub state: u8,
}

impl From<SearchResultNode> for Row {
    fn from(node: SearchResultNode) -> Self {
        let meta = node.metadata;
        let state = if meta.is_some() {
            0
        } else if meta.is_unaccessible() {
            2
        } else {
            1
        };
        let (size, mtime, ctime) = meta.as_ref().map_or((-1, 0, 0), |m| {
            (
                m.size(),
                m.mtime().map_or(0, |v| v.get()),
                m.ctime().map_or(0, |v| v.get()),
            )
        });
        Row {
            path: node.path,
            kind: meta.file_type_hint() as u8,
            size,
            mtime,
            ctime,
            state,
        }
    }
}

#[cfg(test)]
mod rebuild_tests {
    use super::*;

    #[test]
    fn dropped_batch_keeps_other_changes_and_preserves_replay_snapshot() {
        let dir = std::env::temp_dir().join(format!("sift-rebuild-test-{}", std::process::id()));
        let root = dir.join("files");
        std::fs::create_dir_all(&root).unwrap();
        let config = Config { root: root.clone(), ignore_paths: vec![], include_paths: vec![], support_dir: dir.clone() };
        let mut cache = SearchCache::walk_fs(&root);
        cache.flush_snapshot_to_file(&config.db_path()).unwrap();
        let original = std::fs::read(config.db_path()).unwrap();
        let status = Arc::new(Status::default());
        let settings = Arc::new(Mutex::new(config.clone()));
        let mut state = Loop { config, settings, cache, watcher: EventWatcher::noop(), status: status.clone(),
            history_done: false, last_activity: Instant::now(), last_flush: None,
            recovery: RecoverySchedule::default(), pending_rebuild_commit: false,
            repair: None, host: HostLoad::default() };
        let added = root.join("added.txt");
        std::fs::write(&added, "new").unwrap();
        state.apply_events(vec![
            FsEvent { path: root.clone(), flag: EventFlag::RootChanged, id: 100 },
            FsEvent { path: added.clone(), flag: EventFlag::ItemCreated | EventFlag::ItemIsFile, id: 101 },
            FsEvent { path: root.clone(), flag: EventFlag::HistoryDone, id: 102 },
        ]);
        assert!(state.cache.node_index_for_path(&added).is_some());
        assert!(status.rebuild_required.load(Ordering::Relaxed));
        assert_eq!(status.state(), EngineState::RebuildRequired);
        assert!(rebuild_marker(&state.config).exists());
        state.apply_events(vec![FsEvent { path: root.clone(), flag: EventFlag::HistoryDone, id: 103 }]);
        assert_eq!(status.state(), EngineState::RebuildRequired);
        assert!(state.flush_now_if_dirty().is_err());
        assert_eq!(original, std::fs::read(state.config.db_path()).unwrap());

        // Repair uses only this tiny fixture, never the user's index or watcher.
        state.accept_rebuilt_cache(SearchCache::walk_fs(&root));
        assert!(status.rebuild_required.load(Ordering::Relaxed));
        assert_eq!(original, std::fs::read(state.config.db_path()).unwrap());
        // A new drop during catch-up invalidates that completed walk, even if
        // HistoryDone occurs in the same batch. The old snapshot must survive.
        state.apply_events(vec![
            FsEvent { path: root.clone(), flag: EventFlag::UserDropped, id: 104 },
            FsEvent { path: root.clone(), flag: EventFlag::HistoryDone, id: 105 },
        ]);
        assert!(status.rebuild_required.load(Ordering::Relaxed));
        assert!(!state.pending_rebuild_commit);
        assert_eq!(original, std::fs::read(state.config.db_path()).unwrap());
        state.accept_rebuilt_cache(SearchCache::walk_fs(&root));
        state.apply_events(vec![FsEvent { path: root.clone(), flag: EventFlag::HistoryDone, id: 106 }]);
        assert!(!status.rebuild_required.load(Ordering::Relaxed));
        assert!(!rebuild_marker(&state.config).exists());
        let reloaded = SearchCache::try_read_persistent_cache(&root, &state.config.db_path(), &vec![], &vec![], &QUIT).unwrap();
        assert!(reloaded.node_index_for_path(&added).is_some());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn background_repair_walks_off_the_loop_and_commits_after_catch_up() {
        let dir = std::env::temp_dir().join(format!("sift-repair-test-{}", std::process::id()));
        let root = dir.join("files");
        std::fs::create_dir_all(root.join("sub")).unwrap();
        std::fs::write(root.join("sub/kept.txt"), "x").unwrap();
        let config = Config { root: root.clone(), ignore_paths: vec![], include_paths: vec![], support_dir: dir.clone() };
        let status = Arc::new(Status::default());
        let mut state = Loop { config: config.clone(), settings: Arc::new(Mutex::new(config.clone())),
            cache: SearchCache::walk_fs(&root), watcher: EventWatcher::noop(),
            status: status.clone(), history_done: false, last_activity: Instant::now(), last_flush: None,
            recovery: RecoverySchedule::default(), pending_rebuild_commit: false,
            repair: None, host: HostLoad::default() };
        state.apply_events(vec![FsEvent { path: root.clone(), flag: EventFlag::UserDropped, id: 1 }]);
        assert!(status.rebuild_required.load(Ordering::Relaxed));
        // Only a fresh walk knows a file created after the loss.
        let late = root.join("sub/late.txt");
        std::fs::write(&late, "y").unwrap();
        assert!(state.cache.node_index_for_path(&late).is_none());

        state.repair = Some(Repair::start(config));
        let cache = state.repair.as_ref().unwrap().done.recv_timeout(Duration::from_secs(30)).unwrap();
        assert!(cache.as_ref().is_some_and(|c| c.node_index_for_path(&late).is_some()));
        // Until the swap the loop still answers from the old snapshot.
        assert!(state.cache.node_index_for_path(&root.join("sub/kept.txt")).is_some());
        state.finish_repair(cache);
        assert!(state.repair.is_none() && !status.repairing.load(Ordering::Relaxed));
        assert!(state.pending_rebuild_commit && rebuild_marker(&state.config).exists());
        state.apply_events(vec![FsEvent { path: root.clone(), flag: EventFlag::HistoryDone, id: 2 }]);
        assert!(!status.rebuild_required.load(Ordering::Relaxed));
        assert!(!rebuild_marker(&state.config).exists());
        assert!(state.cache.node_index_for_path(&late).is_some());
        drop(state);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn event_loss_cannot_be_mistaken_for_history_completion() {
        for flag in [EventFlag::UserDropped, EventFlag::KernelDropped, EventFlag::EventIdsWrapped] {
            assert!(requires_rebuild(&FsEvent { path: "/somewhere".into(), flag, id: 1 }, std::path::Path::new("/")));
        }
    }
}
