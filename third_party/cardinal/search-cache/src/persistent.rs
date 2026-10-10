use crate::{NameIndex, SlabIndex, SlabNode, ThinSlab};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File},
    io::{BufReader, BufWriter},
    path::{Path, PathBuf},
    thread::available_parallelism,
    time::Instant,
};
use tracing::info;
use typed_num::Num;

const LSF_VERSION: i64 = 6;

#[derive(Serialize, Deserialize)]
pub struct PersistentStorage {
    pub version: Num<LSF_VERSION>,
    /// The last event id of the cache.
    pub last_event_id: u64,
    /// Root file path of the cache
    pub path: PathBuf,
    /// Ignore paths
    pub ignore_paths: Vec<PathBuf>,
    /// Paths to include even when they fall under an ignored directory.
    pub include_paths: Vec<PathBuf>,
    /// Root index of the slab
    pub slab_root: SlabIndex,
    pub slab: ThinSlab<SlabNode>,
    pub name_index: NameIndex,
    /// The number of rescans emitted before this snapshot.
    pub rescan_count: u64,
}

pub fn read_cache_from_file(path: &Path) -> Result<PersistentStorage> {
    let cache_decode_time = Instant::now();
    let mut bytes = vec![0u8; 4 * 1024];
    let input = File::open(path).context("Failed to open cache file")?;
    let input = zstd::Decoder::new(input).context("Failed to create zstd decoder")?;
    let mut input = BufReader::new(input);
    let storage: PersistentStorage = postcard::from_io((&mut input, &mut bytes))
        .context("Failed to decode cache, maybe the cache is corrupted")?
        .0;
    info!("Cache decode time: {:?}", cache_decode_time.elapsed());
    Ok(storage)
}

/// Borrowed twin of [`PersistentStorage`] with the same field order, so a
/// snapshot can be written without moving or cloning the live index.
#[derive(Serialize)]
pub struct PersistentStorageRef<'a> {
    pub version: Num<LSF_VERSION>,
    pub last_event_id: u64,
    pub path: &'a Path,
    pub ignore_paths: &'a [PathBuf],
    pub include_paths: &'a [PathBuf],
    pub slab_root: SlabIndex,
    pub slab: &'a ThinSlab<SlabNode>,
    pub name_index: &'a NameIndex,
    pub rescan_count: u64,
}

/// Level 1 compresses the 9M-node snapshot about 6x faster than level 6 for a
/// file about 14% larger (193 vs 169 MB). Snapshots are written in the
/// background, so CPU matters more than disk; any level reads back the same.
const SNAPSHOT_ZSTD_LEVEL: i32 = 1;

pub fn write_cache_to_file<T: Serialize>(path: &Path, storage: &T) -> Result<()> {
    let cache_encode_time = Instant::now();
    let _ = fs::create_dir_all(path.parent().unwrap());
    let tmp_path = &path.with_extension(".sctmp");
    {
        let output = File::create(tmp_path).context("Failed to create cache file")?;
        let mut output = zstd::Encoder::new(output, SNAPSHOT_ZSTD_LEVEL).context("Failed to create zstd encoder")?;
        output
            // Each zstd worker holds its own window and job buffers; four keep a
            // snapshot write quick without a large transient memory spike.
            .multithread(available_parallelism().map(|x| x.get().min(4) as u32).unwrap_or(4))
            .context("Failed to create parallel zstd encoder")?;
        let mut output = BufWriter::new(output);
        postcard::to_io(storage, &mut output).context("Failed to encode cache")?;
        // Dropping BufWriter/auto_finish discards write/finalization errors.
        // Finish and sync before replacing the last usable snapshot.
        let output = output.into_inner().map_err(|e| e.into_error())
            .context("Failed to flush encoded cache")?;
        let output = output.finish().context("Failed to finish compressed cache")?;
        output.sync_all().context("Failed to sync cache file")?;
    }
    fs::rename(tmp_path, path).context("Failed to rename cache file")?;
    File::open(path.parent().unwrap())?.sync_all().context("Failed to sync cache directory")?;
    info!("Cache encode time: {:?}", cache_encode_time.elapsed());
    info!(
        "Cache size: {} MB",
        fs::symlink_metadata(path)
            .context("Failed to get cache file metadata")?
            .len() as f32
            / 1024.
            / 1024.
    );
    Ok(())
}

#[cfg(test)]
mod durable_tests {
    use super::*;
    struct Broken;
    impl Serialize for Broken {
        fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
            Err(serde::ser::Error::custom("injected encode failure"))
        }
    }
    #[test]
    fn failed_snapshot_keeps_last_file() {
        let dir = std::env::temp_dir().join(format!("sift-snapshot-failure-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("index.db");
        fs::write(&path, b"last valid snapshot").unwrap();
        assert!(write_cache_to_file(&path, &Broken).is_err());
        assert_eq!(fs::read(&path).unwrap(), b"last valid snapshot");
        fs::remove_dir_all(dir).unwrap();
    }
}
