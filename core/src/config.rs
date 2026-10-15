//! Shared settings: GUI and CLI read the same `config.json` in the support dir.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
};

/// FSEvents reports `/System/Volumes/Data/...` twins of every user path; always skip them.
pub const SYSTEM_IGNORE_PATH: &str = "/System/Volumes/Data";

/// Low-value, high-churn locations skipped by default (same list Cardinal ships).
pub const DEFAULT_IGNORE_PATHS: &[&str] = &[
    "/Volumes",
    "~/Library/CloudStorage",
    "~/Library/Biome",
    "~/Library/Caches",
    "~/Library/Logs",
    "~/Library/Metadata",
    "/Library/Caches",
    "/System/Library/Caches",
    "/private/var",
    "/private/tmp",
];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    pub root: PathBuf,
    pub ignore_paths: Vec<PathBuf>,
    #[serde(default)]
    pub include_paths: Vec<PathBuf>,
    /// Where `config.json`, `index.db` and `sift.sock` live. Not persisted.
    #[serde(skip)]
    pub support_dir: PathBuf,
}

impl Config {
    /// `$SIFT_SUPPORT_DIR` when set (tests, side-by-side runs), else the app's folder.
    pub fn default_support_dir() -> PathBuf {
        match std::env::var_os("SIFT_SUPPORT_DIR") {
            Some(dir) if !dir.is_empty() => PathBuf::from(dir),
            // `$HOME` itself, not `home()`: in the sandboxed app this is the container, where its files belong.
            _ => home_from(None, std::env::var_os("HOME")).join("Library/Application Support/cyou.tianli.sift"),
        }
    }

    pub fn default_in(support_dir: &Path) -> Self {
        Self {
            root: default_root(std::env::var_os("SIFT_DEFAULT_ROOT")),
            ignore_paths: DEFAULT_IGNORE_PATHS.iter().map(PathBuf::from).collect(),
            include_paths: Vec::new(),
            support_dir: support_dir.to_path_buf(),
        }
        .normalized()
    }

    /// Reads `config.json`, falling back to defaults when it is missing.
    pub fn load(support_dir: &Path) -> Result<Self> {
        let path = support_dir.join("config.json");
        match fs::read(&path) {
            Ok(bytes) => {
                let mut config: Config = serde_json::from_slice(&bytes)
                    .with_context(|| format!("invalid {}", path.display()))?;
                config.support_dir = support_dir.to_path_buf();
                config.validated()
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(Self::default_in(support_dir))
            }
            Err(e) => Err(e).with_context(|| format!("read {}", path.display())),
        }
    }

    pub fn save(&self) -> Result<()> {
        fs::create_dir_all(&self.support_dir)?;
        let path = self.support_dir.join("config.json");
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::rename(&tmp, &path)?;
        // Keep only an independently valid configuration for a damaged-file startup.
        // A backup failure does not turn an already committed save into a failed transaction.
        if self.clone().validated().is_ok() {
            let backup = self.support_dir.join("config-last-good.json");
            let temporary = backup.with_extension("json.tmp");
            if fs::write(&temporary, serde_json::to_vec_pretty(self)?).is_ok() {
                let _ = fs::rename(temporary, backup);
            }
        }
        Ok(())
    }

    /// Validate before normalization: never silently broaden a malformed root or drop a line.
    pub fn validated(self) -> Result<Self> {
        for path in std::iter::once(&self.root).chain(&self.ignore_paths).chain(&self.include_paths) {
            if expand(path).is_none() {
                bail!("路径 {} 必须是绝对路径或 ~/ 开头；原配置未修改", path.display());
            }
        }
        let normalized = self.normalized();
        if !normalized.root.is_dir() {
            bail!("索引根目录 {} 不存在或不是文件夹；原配置未修改", normalized.root.display());
        }
        fs::read_dir(&normalized.root).with_context(|| format!("无法读取索引根目录 {}", normalized.root.display()))?;
        Ok(normalized)
    }

    /// On a bad primary file restore its last valid scope, or an empty private scope.
    /// The damaged file stays untouched for diagnosis and an explicit Settings save.
    pub fn recover(support_dir: &Path) -> Self {
        if let Ok(bytes) = fs::read(support_dir.join("config-last-good.json")) {
            if let Ok(mut config) = serde_json::from_slice::<Self>(&bytes) {
                config.support_dir = support_dir.to_path_buf();
                if let Ok(config) = config.validated() { return config; }
            }
        }
        let empty = support_dir.join("configuration-needs-repair");
        let _ = fs::create_dir_all(&empty);
        Self { root: empty, ignore_paths: vec![], include_paths: vec![], support_dir: support_dir.to_path_buf() }.normalized()
    }

    pub fn db_path(&self) -> PathBuf {
        self.support_dir.join("index.db")
    }

    pub fn socket_path(&self) -> PathBuf {
        socket_path_in(&self.support_dir)
    }

    /// Expands `~`, drops relative entries and always ignores the Data volume twin.
    pub fn normalized(mut self) -> Self {
        self.root = expand(&self.root).unwrap_or_else(|| PathBuf::from("/"));
        let clean = |paths: Vec<PathBuf>| -> Vec<PathBuf> {
            let mut out: Vec<PathBuf> = Vec::new();
            for p in paths.iter().filter_map(|p| expand(p)) {
                if !out.contains(&p) {
                    out.push(p);
                }
            }
            out
        };
        self.ignore_paths = clean(self.ignore_paths);
        if !self
            .ignore_paths
            .iter()
            .any(|p| p == Path::new(SYSTEM_IGNORE_PATH))
        {
            self.ignore_paths.push(PathBuf::from(SYSTEM_IGNORE_PATH));
        }
        self.include_paths = clean(self.include_paths);
        self
    }
}

/// Unix socket paths are limited to 104 bytes on macOS; long support dirs
/// fall back to a per-user temp path derived from the dir. Depends only on the
/// support dir, so live CLI commands never need to parse `config.json`.
pub fn socket_path_in(support_dir: &Path) -> PathBuf {
    let preferred = support_dir.join("sift.sock");
    if preferred.as_os_str().len() < 100 {
        return preferred;
    }
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in support_dir.as_os_str().as_encoded_bytes() {
        hash = (hash ^ *b as u64).wrapping_mul(0x100000001b3);
    }
    std::env::temp_dir().join(format!("sift-{hash:016x}.sock"))
}

/// A change to the settings, as `sift config set` expresses it. Applied by the
/// running app to its live settings (under the same lock the Settings window's
/// Save uses), or computed locally for `--dry-run` when the app is not running.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConfigEdit {
    /// Start from the default settings instead of the current ones.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub defaults: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ignore_add: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ignore_remove: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub include_add: Vec<PathBuf>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub include_remove: Vec<PathBuf>,
}

impl ConfigEdit {
    pub fn is_empty(&self) -> bool {
        *self == Self::default()
    }

    /// The settings after this edit, normalized exactly as the Settings window's
    /// Save normalizes them. Unlike the window (which silently drops relative
    /// lines), an edit naming a relative path or a root that is not a folder is
    /// rejected, because it would otherwise re-index the wrong tree.
    pub fn apply(&self, base: &Config) -> Result<Config> {
        let all = self.root.iter().chain(&self.ignore_add).chain(&self.ignore_remove)
            .chain(&self.include_add).chain(&self.include_remove);
        for path in all {
            if expand(path).is_none() {
                bail!("{:?} is not an absolute path (use /… or ~/…)", path.display().to_string());
            }
        }
        let mut next = if self.defaults { Config::default_in(&base.support_dir) } else { base.clone() };
        if let Some(root) = &self.root {
            let root = expand(root).expect("checked above");
            if !root.is_dir() {
                bail!("index root {} is not a folder", root.display());
            }
            next.root = root;
        }
        let edit = |list: &mut Vec<PathBuf>, remove: &[PathBuf], add: &[PathBuf]| {
            let gone: Vec<PathBuf> = remove.iter().filter_map(|p| expand(p)).collect();
            list.retain(|p| expand(p).is_none_or(|p| !gone.contains(&p)));
            list.extend(add.iter().cloned());
        };
        edit(&mut next.ignore_paths, &self.ignore_remove, &self.ignore_add);
        edit(&mut next.include_paths, &self.include_remove, &self.include_add);
        Ok(next.normalized())
    }
}

/// The user's home folder, for `~` in settings and pasted paths. `$HOME` everywhere
/// except in the sandboxed (Mac App Store) app: there `$HOME` is the app's container,
/// so the app names the real home in `SIFT_USER_HOME` before it starts the engine
/// (Sources/StoreAccess.swift). Otherwise `~/Library/Caches` on the ignore list would
/// name a folder inside the container and the real one would be indexed.
pub(crate) fn home() -> PathBuf {
    home_from(std::env::var_os("SIFT_USER_HOME"), std::env::var_os("HOME"))
}

fn home_from(user_home: Option<OsString>, home: Option<OsString>) -> PathBuf {
    user_home
        .filter(|h| Path::new(h).is_absolute())
        .or(home)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

/// The index root of the default settings: the whole disk, unless the app names
/// another folder in `SIFT_DEFAULT_ROOT`. The sandboxed app does (the folder the user
/// granted, or an empty one while nothing is granted): it cannot read `/` on its own,
/// and a first start without `config.json` must not walk what it was never given.
fn default_root(named: Option<OsString>) -> PathBuf {
    named
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from("/"))
}

fn expand(path: &Path) -> Option<PathBuf> {
    let s = path.to_str()?.trim();
    if s.contains('\0') { return None; }
    let expanded = if s == "~" {
        home()
    } else if let Some(rest) = s.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(s)
    };
    expanded.is_absolute().then_some(expanded)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_and_appends_system_ignore() {
        let c = Config {
            root: PathBuf::from("/"),
            ignore_paths: vec!["~/x".into(), "rel".into(), "/Volumes".into(), "/Volumes".into()],
            include_paths: vec![],
            support_dir: PathBuf::new(),
        }
        .normalized();
        assert_eq!(
            c.ignore_paths,
            vec![home().join("x"), PathBuf::from("/Volumes"), PathBuf::from(SYSTEM_IGNORE_PATH)]
        );
    }

    #[test]
    fn sandboxed_app_names_the_real_home_and_its_default_root() {
        let container = Some(OsString::from("/Users/me/Library/Containers/cyou.tianli.sift/Data"));
        // Outside the sandbox nothing is named: `$HOME` and the whole disk, as before.
        assert_eq!(home_from(None, Some("/Users/me".into())), PathBuf::from("/Users/me"));
        assert_eq!(default_root(None), PathBuf::from("/"));
        // In the sandbox `$HOME` is the container; the named home wins.
        assert_eq!(home_from(Some("/Users/me".into()), container.clone()), PathBuf::from("/Users/me"));
        assert_eq!(default_root(Some("/Users/me/Documents".into())), PathBuf::from("/Users/me/Documents"));
        // A value that is not an absolute path is not taken.
        assert_eq!(home_from(Some("".into()), container.clone()), PathBuf::from(container.unwrap()));
        assert_eq!(default_root(Some("relative".into())), PathBuf::from("/"));
        assert_eq!(home_from(None, None), PathBuf::from("/"));
    }

    #[test]
    fn edit_adds_removes_and_rejects_relative_paths() {
        let base = Config::default_in(Path::new("/tmp/sift-edit-test"));
        let add = ConfigEdit { ignore_add: vec!["~/Downloads".into(), "/Volumes".into()], ..Default::default() };
        let next = add.apply(&base).unwrap();
        // Already-present entries are not duplicated; the new one is appended before the Data-volume twin.
        assert_eq!(next.ignore_paths.len(), base.ignore_paths.len() + 1);
        assert!(next.ignore_paths.contains(&home().join("Downloads")));
        // Applying the same edit again changes nothing (idempotent).
        assert_eq!(add.apply(&next).unwrap(), next);

        let remove = ConfigEdit { ignore_remove: vec!["~/Library/Caches".into(), "/nowhere".into()], ..Default::default() };
        let fewer = remove.apply(&base).unwrap();
        assert!(!fewer.ignore_paths.contains(&home().join("Library/Caches")));
        assert_eq!(fewer.ignore_paths.len(), base.ignore_paths.len() - 1);
        // The Data-volume twin cannot be removed.
        let twin = ConfigEdit { ignore_remove: vec![SYSTEM_IGNORE_PATH.into()], ..Default::default() };
        assert!(twin.apply(&base).unwrap().ignore_paths.contains(&PathBuf::from(SYSTEM_IGNORE_PATH)));

        assert!(ConfigEdit { ignore_add: vec!["relative/dir".into()], ..Default::default() }.apply(&base).is_err());
        assert!(ConfigEdit { root: Some("/definitely/not/here".into()), ..Default::default() }.apply(&base).is_err());
        let reset = ConfigEdit { defaults: true, ..Default::default() }.apply(&fewer).unwrap();
        assert_eq!(reset, base);
        assert!(ConfigEdit::default().is_empty() && !add.is_empty());
    }
}
