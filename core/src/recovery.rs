//! Bounded background repair and one writer per support directory.
use anyhow::{Context, Result, bail};
use std::{fs::{File, OpenOptions}, os::unix::{fs::OpenOptionsExt, net::UnixStream},
    sync::OnceLock, time::{Duration, Instant}};
use crate::config::Config;

/// The walker fans out with rayon `par_bridge`, which runs on whichever pool it is
/// installed in. The global pool has one default-QoS thread per core, so lowering only
/// the calling thread left repairs on every core: on 2026-09-29 a repair of ~9.4M
/// entries ran at 308–446% CPU and 1.5 GB RSS, pushed the Mac past 95% CPU, and the
/// owner quit Sift from the load prompt (twice). Repairs use this small pool instead.
pub const REPAIR_THREADS: usize = 2;
/// Background QoS (pthread/qos.h): efficiency cores, throttled I/O, yields to the user.
const QOS_CLASS_BACKGROUND: u32 = 0x09;

pub fn repair_pool() -> Option<rayon::ThreadPool> {
    background_pool("sift-repair", REPAIR_THREADS)
}

fn background_pool(name: &'static str, threads: usize) -> Option<rayon::ThreadPool> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(threads)
        .thread_name(move |i| format!("{name}-{i}"))
        .start_handler(|_| unsafe { let _ = pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0); })
        .build()
        .ok()
}

/// The incremental walker is serial. Run it on the index thread at background
/// QoS, without a Rayon install/unpark/spin/park cycle for each small batch.
/// Queries restore their prior QoS; full walks and two-thread repairs stay parallel.
pub fn incremental<T>(work: impl FnOnce() -> T) -> T {
    let _priority = BackgroundPriority::enter();
    work()
}

/// A repair waits while the whole Mac is at least this busy…
pub const HOST_BUSY: f64 = 0.5;
/// …but not longer than this after the loss was first seen.
const MAX_DEFER: Duration = Duration::from_secs(30 * 60);

unsafe extern "C" {
    fn mach_host_self() -> u32;
    fn host_statistics(host: u32, flavor: i32, info: *mut i32, count: *mut u32) -> i32;
}
const HOST_CPU_LOAD_INFO: i32 = 3;
const CPU_STATE_IDLE: usize = 2;

/// Cumulative user/system/idle/nice ticks of all cores.
fn host_cpu_ticks() -> Option<[u32; 4]> {
    static HOST: OnceLock<u32> = OnceLock::new();
    let host = *HOST.get_or_init(|| unsafe { mach_host_self() });
    let (mut ticks, mut count) = ([0u32; 4], 4u32);
    let ok = unsafe { host_statistics(host, HOST_CPU_LOAD_INFO, ticks.as_mut_ptr().cast(), &mut count) } == 0;
    (ok && count == 4).then_some(ticks)
}

/// Busy share of the whole machine between two tick readings (counters may wrap).
pub fn busy_fraction(before: [u32; 4], after: [u32; 4]) -> Option<f64> {
    let delta: Vec<u64> = before.iter().zip(after).map(|(b, a)| a.wrapping_sub(*b) as u64).collect();
    let total: u64 = delta.iter().sum();
    (total > 0).then(|| 1.0 - delta[CPU_STATE_IDLE] as f64 / total as f64)
}

/// Whole-machine CPU use over the last housekeeping tick (one Mach call per tick).
#[derive(Default)]
pub struct HostLoad { last: Option<[u32; 4]> }

impl HostLoad {
    pub fn sample(&mut self) -> Option<f64> {
        let now = host_cpu_ticks()?;
        busy_fraction(self.last.replace(now)?, now)
    }
}

pub fn writer_lock(config: &Config) -> Result<Option<File>> {
    if std::env::var_os("SIFT_READONLY").is_some() { return Ok(None); }
    // Also reject older running builds that predate the file lock.
    if UnixStream::connect(config.socket_path()).is_ok() {
        bail!("another Sift instance already owns this index");
    }
    std::fs::create_dir_all(&config.support_dir)?;
    let lock = OpenOptions::new().read(true).write(true).create(true).truncate(false)
        .mode(0o600).open(config.support_dir.join("writer.lock"))?;
    lock.try_lock().context("another Sift instance owns the index writer lock")?;
    Ok(Some(lock))
}

#[derive(Default)]
pub struct RecoverySchedule {
    first_pending: Option<Instant>,
    last_attempt: Option<Instant>,
    attempts: u32,
}

impl RecoverySchedule {
    /// `host_busy` is the machine's CPU share over the last tick (`None` = unknown).
    pub fn due(&mut self, now: Instant, pending: bool, idle: Duration, host_busy: Option<f64>) -> bool {
        if !pending {
            self.first_pending = None;
            // A sustained healthy period resets the retry sequence.
            if self.last_attempt.is_some_and(|t| now.duration_since(t) >= Duration::from_secs(3600)) {
                self.attempts = 0;
            }
            return false;
        }
        let waited = now.duration_since(*self.first_pending.get_or_insert(now));
        idle >= Duration::from_secs(60)
            && waited >= Duration::from_secs(30)
            && (host_busy.is_none_or(|busy| busy < HOST_BUSY) || waited >= MAX_DEFER)
            && self.last_attempt.is_none_or(|t| now.duration_since(t) >= Self::delay(self.attempts))
    }

    pub fn attempted(&mut self, now: Instant) {
        self.last_attempt = Some(now);
        self.first_pending = None;
        self.attempts = self.attempts.saturating_add(1);
    }

    fn delay(attempts: u32) -> Duration {
        Duration::from_secs(match attempts { 0 => 0, 1 => 300, 2 => 600, 3 => 1200, _ => 3600 })
    }
}

/// Temporarily lower the indexing thread; unspecified QoS restores to default.
pub struct BackgroundPriority { prior: u32, relative: i32, changed: bool }
unsafe extern "C" {
    fn pthread_self() -> usize;
    fn pthread_get_qos_class_np(thread: usize, class: *mut u32, relative: *mut i32) -> i32;
    fn pthread_set_qos_class_self_np(class: u32, relative: i32) -> i32;
}
impl BackgroundPriority {
    pub fn enter() -> Self {
        let mut value = Self { prior: 0, relative: 0, changed: false };
        // QOS_CLASS_BACKGROUND from the macOS SDK's pthread/qos.h.
        unsafe {
            if pthread_get_qos_class_np(pthread_self(), &mut value.prior, &mut value.relative) == 0 {
                if value.prior == 0 { value.prior = 0x15; value.relative = 0; }
                value.changed = pthread_set_qos_class_self_np(0x09, 0) == 0;
            }
        }
        value
    }
}
impl Drop for BackgroundPriority {
    fn drop(&mut self) {
        if self.changed { unsafe { pthread_set_qos_class_self_np(self.prior, self.relative); } }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn recovery_waits_for_idle_and_backs_off_without_losing_pending_work() {
        let t = Instant::now();
        let mut schedule = RecoverySchedule::default();
        assert!(!schedule.due(t, true, Duration::from_secs(90), None));
        assert!(!schedule.due(t + Duration::from_secs(30), true, Duration::from_secs(59), None));
        assert!(schedule.due(t + Duration::from_secs(60), true, Duration::from_secs(60), None));
        schedule.attempted(t + Duration::from_secs(60));
        assert!(!schedule.due(t + Duration::from_secs(120), true, Duration::from_secs(120), None));
        assert!(!schedule.due(t + Duration::from_secs(359), true, Duration::from_secs(359), None));
        assert!(schedule.due(t + Duration::from_secs(360), true, Duration::from_secs(360), None));
        schedule.attempted(t + Duration::from_secs(360));
        assert!(!schedule.due(t + Duration::from_secs(400), true, Duration::from_secs(400), None));
        assert!(!schedule.due(t + Duration::from_secs(959), true, Duration::from_secs(959), None));
        assert!(schedule.due(t + Duration::from_secs(960), true, Duration::from_secs(960), None));
        assert!(!schedule.due(t + Duration::from_secs(961), false, Duration::from_secs(961), None));
    }

    #[test]
    fn recovery_waits_while_the_mac_is_busy_but_not_forever() {
        let t = Instant::now();
        let idle = Duration::from_secs(600);
        let mut schedule = RecoverySchedule::default();
        assert!(!schedule.due(t, true, idle, Some(0.1)));
        // The 2026-09-29 incidents started with the host at 70-99% CPU.
        assert!(!schedule.due(t + Duration::from_secs(60), true, idle, Some(0.77)));
        assert!(!schedule.due(t + Duration::from_secs(90), true, idle, Some(HOST_BUSY)));
        assert!(schedule.due(t + Duration::from_secs(120), true, idle, Some(0.3)));
        assert!(!schedule.due(t + Duration::from_secs(29 * 60), true, idle, Some(0.99)));
        assert!(schedule.due(t + Duration::from_secs(30 * 60), true, idle, Some(0.99)));
    }

    #[test]
    fn host_busy_share_comes_from_idle_ticks() {
        assert_eq!(busy_fraction([100, 50, 850, 0], [200, 100, 900, 0]), Some(0.75));
        assert_eq!(busy_fraction([u32::MAX, 0, u32::MAX - 9, 0], [9, 0, 0, 0]), Some(0.5));
        assert_eq!(busy_fraction([1, 2, 3, 4], [1, 2, 3, 4]), None);
        let mut host = HostLoad::default();
        assert_eq!(host.sample(), None);
        std::thread::sleep(Duration::from_millis(50));
        assert!(host.sample().is_none_or(|busy| (0.0..=1.0).contains(&busy)));
    }

    #[test]
    fn repair_work_stays_on_two_background_threads() {
        use rayon::iter::{ParallelBridge, ParallelIterator};
        let pool = repair_pool().unwrap();
        // The walker's own fan-out pattern (`par_bridge`), installed in the repair pool.
        let seen: Vec<(Option<usize>, u32)> = pool.install(|| (0..256).par_bridge().map(|_| {
            let (mut class, mut relative) = (0u32, 0i32);
            unsafe { pthread_get_qos_class_np(pthread_self(), &mut class, &mut relative) };
            (rayon::current_thread_index(), class)
        }).collect());
        assert_eq!(pool.current_num_threads(), REPAIR_THREADS);
        assert!(seen.iter().all(|(index, class)|
            index.is_some_and(|i| i < REPAIR_THREADS) && *class == QOS_CLASS_BACKGROUND), "{seen:?}");
    }

    #[test]
    fn incremental_walk_keeps_results_and_does_not_wake_search_workers() {
        let global_threads = rayon::current_num_threads();
        let caller = std::thread::current().id();
        let mut seen = incremental(|| (0..256).map(|value| {
            let (mut class, mut relative) = (0u32, 0i32);
            unsafe { pthread_get_qos_class_np(pthread_self(), &mut class, &mut relative) };
            (value, std::thread::current().id(), class)
        }).collect::<Vec<_>>());
        seen.sort_by_key(|row| row.0);
        assert_eq!(seen.iter().map(|row| row.0).collect::<Vec<_>>(), (0..256).collect::<Vec<_>>());
        assert!(seen.iter().all(|row| row.1 == caller && row.2 == QOS_CLASS_BACKGROUND));
        assert_eq!(rayon::current_num_threads(), global_threads);
    }
    #[test]
    fn only_one_writer_can_hold_a_support_directory() {
        let dir = std::env::temp_dir().join(format!("sift-lock-{}", std::process::id()));
        let config = Config::default_in(&dir);
        let lock = writer_lock(&config).unwrap();
        assert!(writer_lock(&config).is_err());
        drop(lock);
        assert!(writer_lock(&config).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
