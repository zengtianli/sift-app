//! Interned file names in one contiguous, append-only arena.
//!
//! Layout: `\0name\0name\0…`. Every name is stored once; the returned `&str`
//! points into the arena and never moves (the arena is a large lazily-committed
//! anonymous mapping), so callers can keep it as `&'static str`.
//!
//! Searching scans the raw bytes with SIMD `memmem` in parallel slices instead
//! of walking a tree of individually allocated strings. Names never contain
//! `\0`, so a match can never span two names; a prefix is `\0prefix`, a suffix
//! is `suffix\0`, and exact lookups go through the dedup hash table.
#![feature(str_from_raw_parts)]
use core::str;
use hashbrown::{DefaultHashBuilder, HashTable};
use memchr::memmem;
use memmap2::{MmapMut, MmapOptions};
use parking_lot::Mutex;
use rayon::prelude::*;
use regex::Regex;
use search_cancel::CancellationToken;
use std::{
    hash::BuildHasher,
    ops::Deref,
    sync::atomic::{AtomicUsize, Ordering},
};

/// Virtual size reserved for names. Only touched pages cost memory; u32
/// offsets cap it at 4 GiB (typical: ~75 MB for 2.3M unique names).
const ARENA_BYTES: usize = u32::MAX as usize;
/// Bytes scanned between cancellation checks.
const SCAN_BLOCK: usize = 1 << 20;

pub struct NamePool {
    /// Base of the arena; valid for `ARENA_BYTES`.
    base: *mut u8,
    _map: MmapMut,
    /// Bytes published to readers. Everything below is immutable.
    len: AtomicUsize,
    count: AtomicUsize,
    writer: Mutex<Writer>,
}

struct Writer {
    /// Start offsets of each unique name, keyed by the name's hash.
    table: HashTable<u32>,
    hasher: DefaultHashBuilder,
}

unsafe impl Send for NamePool {}
unsafe impl Sync for NamePool {}

impl std::fmt::Debug for NamePool {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("NamePool")
            .field("len", &self.len())
            .field("bytes", &self.len.load(Ordering::Relaxed))
            .finish()
    }
}

impl Default for NamePool {
    fn default() -> Self {
        Self::new()
    }
}

/// Builds the whole-arena prefilter for `pattern`, or `None` when the pattern
/// uses text-boundary assertions or flags that would not survive running over
/// `\0`-separated names. Builder flags are not part of `as_str()`, so the
/// prefilter is case-insensitive: a superset that the real regex then confirms.
fn whole_arena_regex(pattern: &Regex) -> Option<regex::bytes::Regex> {
    let src = pattern.as_str();
    if src.contains("\\A") || src.contains("\\z") || src.contains("(?-") || src.contains("(?s") {
        return None;
    }
    regex::bytes::RegexBuilder::new(src)
        .multi_line(true)
        .line_terminator(0)
        .case_insensitive(true)
        .build()
        .ok()
}

/// Matching names in byte order (the order the old `BTreeSet` produced).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Names<'pool>(Vec<&'pool str>);

impl<'pool> Names<'pool> {
    pub fn contains(&self, name: &str) -> bool {
        self.0.binary_search(&name).is_ok()
    }

    pub fn into_vec(self) -> Vec<&'pool str> {
        self.0
    }
}

impl<'pool> Deref for Names<'pool> {
    type Target = [&'pool str];

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl<'pool> IntoIterator for Names<'pool> {
    type Item = &'pool str;
    type IntoIter = std::vec::IntoIter<&'pool str>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

impl NamePool {
    pub fn new() -> Self {
        let mut map = MmapOptions::new()
            .len(ARENA_BYTES)
            .map_anon()
            .expect("reserve name arena");
        map[0] = 0;
        Self {
            base: map.as_mut_ptr(),
            _map: map,
            len: AtomicUsize::new(1),
            count: AtomicUsize::new(0),
            writer: Mutex::new(Writer {
                table: HashTable::new(),
                hasher: DefaultHashBuilder::default(),
            }),
        }
    }

    /// Number of unique names.
    pub fn len(&self) -> usize {
        self.count.load(Ordering::Relaxed)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Bytes used by names and separators.
    pub fn bytes(&self) -> usize {
        self.len.load(Ordering::Acquire)
    }

    fn haystack(&self) -> &[u8] {
        let len = self.len.load(Ordering::Acquire);
        unsafe { std::slice::from_raw_parts(self.base, len) }
    }

    /// Name starting at `offset` (just after its leading `\0`).
    fn name_at(&self, offset: usize) -> &str {
        let hay = self.haystack();
        let end = memchr::memchr(0, &hay[offset..]).map_or(hay.len(), |e| offset + e);
        unsafe { str::from_raw_parts(self.base.add(offset), end - offset) }
    }

    /// Interns `name` and returns the pooled copy. The pointer is stable for the
    /// pool's lifetime.
    ///
    /// # Panic
    ///
    /// Panics if the name contains `\0` or the 4 GiB arena is exhausted.
    pub fn push<'c>(&'c self, name: &str) -> &'c str {
        assert!(!name.as_bytes().contains(&0), "name contains NUL");
        let mut writer = self.writer.lock();
        let Writer { table, hasher } = &mut *writer;
        let hash = hasher.hash_one(name);
        if let Some(&offset) = table.find(hash, |&o| self.name_at(o as usize) == name) {
            return self.name_at(offset as usize);
        }
        let start = self.len.load(Ordering::Relaxed);
        let end = start + name.len() + 1;
        assert!(end <= ARENA_BYTES, "name arena exhausted");
        unsafe {
            std::ptr::copy_nonoverlapping(name.as_ptr(), self.base.add(start), name.len());
            *self.base.add(start + name.len()) = 0;
        }
        self.len.store(end, Ordering::Release);
        self.count.fetch_add(1, Ordering::Relaxed);
        table.insert_unique(hash, start as u32, |&o| {
            hasher.hash_one(self.name_at(o as usize))
        });
        unsafe { str::from_raw_parts(self.base.add(start), name.len()) }
    }

    /// Arena offset of a string returned by this pool, i.e. a whole name whose
    /// bytes live in the arena. `None` for any other string (including slices
    /// of a pooled name).
    pub fn offset_of(&self, name: &str) -> Option<u32> {
        let base = self.base as usize;
        let start = (name.as_ptr() as usize).checked_sub(base)?;
        let hay = self.haystack();
        let end = start.checked_add(name.len())?;
        (start >= 1 && end < hay.len() && hay[start - 1] == 0 && hay[end] == 0)
            .then_some(start as u32)
    }

    /// The name stored at `offset` (as returned by [`Self::offset_of`] or
    /// [`Self::intern`]).
    pub fn name_at_offset(&self, offset: u32) -> &str {
        self.name_at(offset as usize)
    }

    /// Interns `name` and returns its stable arena offset.
    pub fn intern(&self, name: &str) -> u32 {
        let pooled = self.push(name);
        self.offset_of(pooled).expect("pushed names live in the arena")
    }

    /// Offset of `name`: pointer arithmetic for pooled strings, a hash lookup
    /// otherwise. `None` if the name was never interned.
    pub fn find_offset(&self, name: &str) -> Option<u32> {
        self.offset_of(name)
            .or_else(|| self.get(name).and_then(|pooled| self.offset_of(pooled)))
    }

    /// Returns the pooled copy of `name` if it was interned.
    pub fn get(&self, name: &str) -> Option<&str> {
        let writer = self.writer.lock();
        let hash = writer.hasher.hash_one(name);
        writer
            .table
            .find(hash, |&o| self.name_at(o as usize) == name)
            .map(|&o| self.name_at(o as usize))
    }

    /// Calls `f(offset, byte_len)` for every interned name, in arena order.
    pub fn for_each_name(&self, mut f: impl FnMut(u32, usize)) {
        let hay = self.haystack();
        let mut pos = 1;
        while pos < hay.len() {
            let end = memchr::memchr(0, &hay[pos..]).map_or(hay.len(), |e| pos + e);
            f(pos as u32, end - pos);
            pos = end + 1;
        }
    }

    /// Buckets in the dedup table.
    pub fn table_capacity(&self) -> usize {
        self.writer.lock().table.capacity()
    }

    /// Splits the published arena into slices `[b_i, b_{i+1}]` that start and
    /// end on `\0`, so every name lies wholly inside exactly one slice.
    fn slices(hay: &[u8]) -> Vec<(usize, usize)> {
        let parts = rayon::current_num_threads().max(1) * 4;
        let target = (hay.len() / parts).max(SCAN_BLOCK / 4);
        let mut out = Vec::new();
        let mut start = 0;
        while start + 1 < hay.len() {
            let mut end = (start + target).min(hay.len() - 1);
            if hay[end] != 0 {
                end = memchr::memchr(0, &hay[end..]).map_or(hay.len() - 1, |e| end + e);
            }
            out.push((start, end));
            start = end;
        }
        out
    }

    /// Scans for `needle` and reports each containing name once.
    fn scan(
        &self,
        needle: &[u8],
        token: CancellationToken,
    ) -> Option<Names<'_>> {
        let hay = self.haystack();
        let finder = memmem::Finder::new(needle);
        let parts: Option<Vec<Vec<&str>>> = Self::slices(hay)
            .into_par_iter()
            .map(|(start, end)| {
                let mut found = Vec::new();
                let slice = &hay[..=end];
                let mut pos = start;
                let mut next_check = start + SCAN_BLOCK;
                while pos < end {
                    if pos >= next_check {
                        token.is_cancelled()?;
                        next_check = pos + SCAN_BLOCK;
                    }
                    let Some(hit) = finder.find(&slice[pos..]) else { break };
                    let at = pos + hit;
                    // Leading `\0` of the containing name (a prefix needle starts on it).
                    let name_start = if needle.first() == Some(&0) {
                        at + 1
                    } else {
                        memchr::memrchr(0, &slice[..at]).map_or(0, |z| z + 1)
                    };
                    let name_end = memchr::memchr(0, &slice[name_start..])
                        .map_or(end, |z| name_start + z);
                    if name_start >= slice.len() || name_end < name_start {
                        break;
                    }
                    found.push(unsafe {
                        str::from_raw_parts(self.base.add(name_start), name_end - name_start)
                    });
                    pos = name_end.max(at + 1);
                }
                token.is_cancelled()?;
                Some(found)
            })
            .collect();
        Some(Self::sorted(parts?))
    }

    fn sorted(parts: Vec<Vec<&str>>) -> Names<'_> {
        let mut all: Vec<&str> = parts.into_iter().flatten().collect();
        all.par_sort_unstable();
        Names(all)
    }

    pub fn search_substr<'search, 'pool: 'search>(
        &'pool self,
        substr: &'search str,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        if substr.is_empty() {
            return self.filter(|_| true, cancellation_token);
        }
        self.scan(substr.as_bytes(), cancellation_token)
    }

    pub fn search_suffix<'search, 'pool: 'search>(
        &'pool self,
        suffix: &'search str,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        let mut needle = suffix.as_bytes().to_vec();
        needle.push(0);
        self.scan(&needle, cancellation_token)
    }

    pub fn search_prefix<'search, 'pool: 'search>(
        &'pool self,
        prefix: &'search str,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        if prefix.is_empty() {
            return self.filter(|_| true, cancellation_token);
        }
        let mut needle = Vec::with_capacity(prefix.len() + 1);
        needle.push(0);
        needle.extend_from_slice(prefix.as_bytes());
        self.scan(&needle, cancellation_token)
    }

    pub fn search_exact<'search, 'pool: 'search>(
        &'pool self,
        exact: &'search str,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        cancellation_token.is_cancelled()?;
        Some(Names(self.get(exact).into_iter().collect()))
    }

    pub fn search_regex<'search, 'pool: 'search>(
        &'pool self,
        pattern: &Regex,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        match whole_arena_regex(pattern) {
            Some(prefilter) => self.scan_regex(&prefilter, pattern, cancellation_token),
            None => self.filter(|name| pattern.is_match(name), cancellation_token),
        }
    }

    /// Runs one regex over each slice (with `^`/`$` anchored at `\0`) to find
    /// candidate names, then confirms each with the original per-name regex, so
    /// results equal `filter(pattern.is_match)`. After a candidate the search
    /// restarts at that name's end.
    fn scan_regex(
        &self,
        prefilter: &regex::bytes::Regex,
        pattern: &Regex,
        token: CancellationToken,
    ) -> Option<Names<'_>> {
        let hay = self.haystack();
        let parts: Option<Vec<Vec<&str>>> = Self::slices(hay)
            .into_par_iter()
            .map(|(start, end)| {
                let mut found = Vec::new();
                let slice = &hay[..=end];
                let mut pos = start + 1;
                let mut next_check = pos + SCAN_BLOCK;
                while pos <= end {
                    if pos >= next_check {
                        token.is_cancelled()?;
                        next_check = pos + SCAN_BLOCK;
                    }
                    // Earliest match end (forward scan only). A name that matches on
                    // its own ends its match inside itself, before any match that
                    // crosses a separator could end, so no matching name is skipped.
                    let Some(e) = prefilter.shortest_match_at(slice, pos) else { break };
                    // Name holding the last matched byte; an empty match at a name
                    // start belongs to that name.
                    let at = if e > pos && slice[e - 1] != 0 { e - 1 } else { e };
                    let name_start = memchr::memrchr(0, &slice[..at]).map_or(0, |z| z + 1);
                    let name_end = memchr::memchr(0, &slice[name_start..])
                        .map_or(end, |z| name_start + z);
                    if name_start > end {
                        break;
                    }
                    let name = unsafe {
                        str::from_raw_parts(self.base.add(name_start), name_end - name_start)
                    };
                    if pattern.is_match(name) {
                        found.push(name);
                    }
                    pos = name_end + 1;
                }
                token.is_cancelled()?;
                Some(found)
            })
            .collect();
        Some(Self::sorted(parts?))
    }

    /// Every name for which `keep` returns true, in byte order (parallel).
    pub fn search_by<'pool>(
        &'pool self,
        keep: impl Fn(&str) -> bool + Sync,
        cancellation_token: CancellationToken,
    ) -> Option<Names<'pool>> {
        self.filter(keep, cancellation_token)
    }

    /// Tests every name with `keep`, in parallel.
    fn filter(
        &self,
        keep: impl Fn(&str) -> bool + Sync,
        token: CancellationToken,
    ) -> Option<Names<'_>> {
        let hay = self.haystack();
        let parts: Option<Vec<Vec<&str>>> = Self::slices(hay)
            .into_par_iter()
            .map(|(start, end)| {
                let mut found = Vec::new();
                let mut pos = start + 1;
                let mut next_check = pos + SCAN_BLOCK;
                while pos <= end {
                    if pos >= next_check {
                        token.is_cancelled()?;
                        next_check = pos + SCAN_BLOCK;
                    }
                    let stop = memchr::memchr(0, &hay[pos..=end]).map_or(end, |z| pos + z);
                    let name = unsafe { str::from_raw_parts(self.base.add(pos), stop - pos) };
                    if keep(name) {
                        found.push(name);
                    }
                    pos = stop + 1;
                }
                token.is_cancelled()?;
                Some(found)
            })
            .collect();
        Some(Self::sorted(parts?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn guard<T>(value: Option<T>) -> T {
        value.expect("noop cancellation should not trigger")
    }

    fn substr<'pool>(pool: &'pool NamePool, needle: &str) -> Names<'pool> {
        guard(pool.search_substr(needle, CancellationToken::noop()))
    }

    fn suffix_search<'pool>(pool: &'pool NamePool, needle: &str) -> Names<'pool> {
        guard(pool.search_suffix(needle, CancellationToken::noop()))
    }

    fn prefix_search<'pool>(pool: &'pool NamePool, needle: &str) -> Names<'pool> {
        guard(pool.search_prefix(needle, CancellationToken::noop()))
    }

    fn exact_search<'pool>(pool: &'pool NamePool, needle: &str) -> Names<'pool> {
        guard(pool.search_exact(needle, CancellationToken::noop()))
    }

    fn regex_search<'pool>(pool: &'pool NamePool, pattern: &Regex) -> Names<'pool> {
        guard(pool.search_regex(pattern, CancellationToken::noop()))
    }

    #[test]
    fn test_search_substr_cancelled_returns_none() {
        let pool = NamePool::new();
        pool.push("alpha");
        pool.push("beta");

        let token = CancellationToken::new_search();
        // Move global active version forward so the token becomes cancelled.
        let _ = CancellationToken::new_search();

        assert!(pool.search_substr("a", token).is_none());
    }

    #[test]
    fn test_search_regex_partial_results_cancelled() {
        let pool = NamePool::new();
        for idx in 0..5 {
            pool.push(&format!("item{idx}"));
        }
        let token = CancellationToken::new_search();
        let _ = CancellationToken::new_search();
        let regex = Regex::new("item\\d").unwrap();

        assert!(pool.search_regex(&regex, token).is_none());
    }

    #[test]
    fn test_new() {
        let pool = NamePool::new();
        assert_eq!(pool.len(), 0);
    }

    #[test]
    fn test_push_basic() {
        let pool = NamePool::new();
        let s = pool.push("hello");
        assert_eq!(s, "hello");
    }

    #[test]
    fn test_push_multiple() {
        let pool = NamePool::new();
        let s1 = pool.push("foo");
        let s2 = pool.push("bar");
        let s3 = pool.push("baz");
        assert_eq!(s1, "foo");
        assert_eq!(s2, "bar");
        assert_eq!(s3, "baz");
    }

    #[test]
    fn test_push_empty_string() {
        let pool = NamePool::new();
        let s = pool.push("");
        assert_eq!(s, "");
    }

    #[test]
    fn test_push_unicode() {
        let pool = NamePool::new();
        let s = pool.push("こんにちは");
        assert_eq!(s, "こんにちは");
    }

    #[test]
    fn test_push_deduplication() {
        let pool = NamePool::new();
        let s1 = pool.push("hello");
        let s2 = pool.push("hello");
        assert_eq!(s1, s2);
        assert_eq!(s1, "hello");
    }

    #[test]
    fn test_search_substr() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hello world");
        pool.push("hello world hello");

        let result = substr(&pool, "hello");
        assert_eq!(result.len(), 3);
        assert!(result.contains("hello"));
        assert!(result.contains("hello world"));
        assert!(result.contains("hello world hello"));
    }

    #[test]
    fn test_search_substr_2() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hello world");

        let result = substr(&pool, "world");
        assert_eq!(result.len(), 2);
        assert!(result.contains("world"));
        assert!(result.contains("hello world"));
    }

    #[test]
    fn test_search_suffix() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hello world");

        let suffix = "world";
        let result = suffix_search(&pool, suffix);
        assert_eq!(result.len(), 2);
        assert!(result.contains("world"));
        assert!(result.contains("hello world"));
    }

    #[test]
    fn test_search_prefix() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hello world");

        let prefix = "hello";
        let result = prefix_search(&pool, prefix);
        assert_eq!(result.len(), 2);
        assert!(result.contains("hello"));
        assert!(result.contains("hello world"));
    }

    #[test]
    fn test_search_exact() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hello world");

        let exact = "hello";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("hello"));

        let exact = "world";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("world"));
    }

    #[test]
    fn test_search_regex_basic() {
        use regex::Regex;

        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("helloworld");

        let regex = Regex::new("hell.*").unwrap();
        let result = regex_search(&pool, &regex);
        assert_eq!(result.len(), 2);
        assert!(result.contains("hello"));
        assert!(result.contains("helloworld"));
    }

    #[test]
    fn test_search_regex_case_insensitive() {
        use regex::RegexBuilder;

        let pool = NamePool::new();
        pool.push("Alpha");
        pool.push("beta");

        let regex = RegexBuilder::new("alpha")
            .case_insensitive(true)
            .build()
            .unwrap();
        let result = regex_search(&pool, &regex);
        assert_eq!(result.len(), 1);
        assert!(result.contains("Alpha"));
    }

    #[test]
    fn test_search_nonexistent() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");

        let result = substr(&pool, "nonexistent");
        assert!(result.is_empty());

        let result = substr(&pool, "nonexistent");
        assert!(result.is_empty());
    }

    #[test]
    fn test_search_partial_match() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");
        pool.push("hell");

        let result = substr(&pool, "hell");
        assert_eq!(result.len(), 2);
        assert!(result.contains("hello"));
        assert!(result.contains("hell"));
    }

    #[test]
    fn test_search_exact_unicode() {
        let pool = NamePool::new();
        pool.push("こんにちは");
        pool.push("世界");
        pool.push("こんにちは世界");

        let exact = "こんにちは";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("こんにちは"));

        let exact = "世界";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("世界"));

        let exact = "こんにちは世界";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("こんにちは世界"));
    }

    #[test]
    fn test_search_exact_no_overlap() {
        let pool = NamePool::new();
        pool.push("test");
        pool.push("testtest");
        pool.push("testtesttest");

        let exact = "test";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("test"));

        let exact = "testtest";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("testtest"));

        let exact = "testtesttest";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("testtesttest"));
    }

    #[test]
    fn test_search_exact_with_embedded_nulls() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");

        let exact = "\0\0hello\0";
        let result = exact_search(&pool, exact);
        assert!(result.is_empty());

        let exact = "\0hello\0\0";
        let result = exact_search(&pool, exact);
        assert!(result.is_empty());
    }

    #[test]
    fn test_search_exact_boundary_cases() {
        let pool = NamePool::new();
        pool.push("");
        pool.push("a");
        pool.push("ab");

        let exact = "";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains(""));

        let exact = "a";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("a"));

        let exact = "ab";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("ab"));
    }

    #[test]
    fn test_search_exact_similar_strings() {
        let pool = NamePool::new();
        pool.push("test");
        pool.push("testing");
        pool.push("tester");
        pool.push("test123");

        let exact = "test";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("test"));

        let exact = "testing";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("testing"));

        let exact = "tester";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("tester"));

        let exact = "test123";
        let result = exact_search(&pool, exact);
        assert_eq!(result.len(), 1);
        assert!(result.contains("test123"));
    }

    #[test]
    fn test_search_unicode() {
        let pool = NamePool::new();
        pool.push("こんにちは");
        pool.push("世界");
        pool.push("こんにちは世界");

        let result = substr(&pool, "世界");
        assert_eq!(result.len(), 2);
        assert!(result.contains("世界"));
        assert!(result.contains("こんにちは世界"));
    }

    #[test]
    fn test_search_prefix_nonexistent() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");

        let prefix = "nonexistent";
        let result = prefix_search(&pool, prefix);
        assert!(result.is_empty());
    }

    #[test]
    fn test_search_exact_nonexistent() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("world");

        let exact = "nonexistent";
        let result = exact_search(&pool, exact);
        assert!(result.is_empty());
    }

    #[test]
    fn test_dedup_behavior_comparison() {
        let pool = NamePool::new();
        pool.push("hello");
        pool.push("hello world");
        pool.push("hello world hello");

        let substr_result: Vec<_> = substr(&pool, "hello").into_iter().collect();
        assert_eq!(substr_result.len(), 3);

        let exact_result: Vec<_> = exact_search(&pool, "hello").into_iter().collect();
        assert_eq!(exact_result.len(), 1);
        assert_eq!(exact_result[0], "hello");

        let mut unique_results = substr_result.clone();
        unique_results.sort();
        unique_results.dedup();
        assert_eq!(substr_result.len(), unique_results.len());
    }

    #[test]
    fn test_search_exact_performance_assumption() {
        let pool = NamePool::new();
        pool.push("abc");
        pool.push("abcabc");

        let exact = "abc";
        let result: Vec<_> = exact_search(&pool, exact).into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "abc");

        let exact = "abcabc";
        let result: Vec<_> = exact_search(&pool, exact).into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "abcabc");

        let exact = "ab";
        let result: Vec<_> = exact_search(&pool, exact).into_iter().collect();
        assert_eq!(result.len(), 0);
    }

    #[test]
    fn test_boundary_single_char() {
        let pool = NamePool::new();
        pool.push("a");
        let result: Vec<_> = substr(&pool, "a").into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "a");

        let result: Vec<_> = substr(&pool, "a").into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "a");

        pool.push("abc");
        let result: Vec<_> = substr(&pool, "a").into_iter().collect();
        assert_eq!(result.len(), 2);

        let result: Vec<_> = substr(&pool, "b").into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "abc");

        let result: Vec<_> = substr(&pool, "c").into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], "abc");
    }

    #[test]
    fn test_boundary_very_long_strings() {
        let pool = NamePool::new();
        let long_string = "a".repeat(500);
        let medium_string = "b".repeat(250);

        pool.push(&long_string);
        pool.push(&medium_string);

        let result: Vec<_> = substr(&pool, "a").into_iter().collect();
        assert_eq!(result.len(), 1);

        let result: Vec<_> = substr(&pool, "b").into_iter().collect();
        assert_eq!(result.len(), 1);

        let middle_substr = "a".repeat(100);
        let result: Vec<_> = substr(&pool, &middle_substr).into_iter().collect();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_boundary_special_characters() {
        let pool = NamePool::new();
        pool.push("hello\nworld");
        pool.push("tab\there");
        pool.push("quote\"here");
        pool.push("backslash\\here");
        pool.push("unicode🚀test");

        let result: Vec<_> = substr(&pool, "hello\nworld").into_iter().collect();
        assert_eq!(result.len(), 1);

        let result: Vec<_> = substr(&pool, "tab\there").into_iter().collect();
        assert_eq!(result.len(), 1);

        let result: Vec<_> = substr(&pool, "quote\"here").into_iter().collect();
        assert_eq!(result.len(), 1);

        let result: Vec<_> = substr(&pool, "backslash\\here").into_iter().collect();
        assert_eq!(result.len(), 1);

        let result: Vec<_> = substr(&pool, "unicode🚀test").into_iter().collect();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_boundary_overlapping_patterns() {
        let pool = NamePool::new();
        pool.push("aaa");
        pool.push("aaaa");
        pool.push("aaaaa");

        let result: Vec<_> = substr(&pool, "aa").into_iter().collect();
        assert_eq!(result.len(), 3);

        let mut unique_results = result.clone();
        unique_results.sort();
        unique_results.dedup();
        assert_eq!(result.len(), unique_results.len());
    }

    #[test]
    fn test_corner_many_duplicates() {
        let pool = NamePool::new();
        // Push the same string many times
        for _ in 0..100 {
            pool.push("duplicate");
        }
        assert_eq!(pool.len(), 1); // Should only store one unique string

        let result = exact_search(&pool, "duplicate");
        assert_eq!(result.len(), 1);
        assert!(result.contains("duplicate"));
    }

    #[test]
    fn test_corner_capacity_overflow() {
        let pool = NamePool::new();
        // Fill with small strings first
        for i in 0..50 {
            pool.push(&format!("str{i}"));
        }

        // Try to add a very long string that might not fit
        let long_str = "x".repeat(800);
        pool.push(&long_str); // This should succeed as it goes to a new cache line

        let result: Vec<_> = substr(&pool, &long_str).into_iter().collect();
        assert_eq!(result.len(), 1);
        assert_eq!(result[0], long_str);
    }

    #[test]
    fn test_corner_exact_boundary_strings() {
        let pool = NamePool::new();
        // Test strings that are exactly at various boundaries
        pool.push(""); // Empty
        pool.push("x"); // Single char
        pool.push("xy"); // Two chars
        pool.push("xyz"); // Three chars

        let result = exact_search(&pool, "");
        assert_eq!(result.len(), 1);
        assert!(result.contains(""));

        let result = exact_search(&pool, "x");
        assert_eq!(result.len(), 1);
        assert!(result.contains("x"));

        let result = exact_search(&pool, "xy");
        assert_eq!(result.len(), 1);
        assert!(result.contains("xy"));

        let result = exact_search(&pool, "xyz");
        assert_eq!(result.len(), 1);
        assert!(result.contains("xyz"));
    }

    #[test]
    fn test_corner_search_longer_than_strings() {
        let pool = NamePool::new();
        pool.push("hi");
        pool.push("hello");

        // Search for pattern longer than any string
        let result = substr(&pool, "helloworld");
        assert!(result.is_empty());

        let result = substr(&pool, "helloworld");
        assert!(result.is_empty());
    }

    #[test]
    fn test_corner_multiple_cache_lines() {
        let pool = NamePool::new();
        // Fill first cache line
        for i in 0..100 {
            pool.push(&format!("line1_{i}"));
        }

        // Add to second cache line
        for i in 0..100 {
            pool.push(&format!("line2_{i}"));
        }

        // Search should work across all cache lines
        let result = substr(&pool, "line1_");
        assert_eq!(result.len(), 100);

        let result = substr(&pool, "line2_");
        assert_eq!(result.len(), 100);

        // Total unique strings
        assert_eq!(pool.len(), 200);
    }

    #[test]
    fn test_corner_prefix_suffix_relationships() {
        let pool = NamePool::new();
        pool.push("a");
        pool.push("ab");
        pool.push("abc");
        pool.push("abcd");

        // Test prefix searches
        let result = prefix_search(&pool, "a");
        assert_eq!(result.len(), 4); // All strings start with "a"

        let result = prefix_search(&pool, "ab");
        assert_eq!(result.len(), 3); // "ab", "abc", "abcd"

        let result = prefix_search(&pool, "abc");
        assert_eq!(result.len(), 2); // "abc", "abcd"

        let result = prefix_search(&pool, "abcd");
        assert_eq!(result.len(), 1); // "abcd"

        // Test suffix searches
        let result = suffix_search(&pool, "d");
        assert_eq!(result.len(), 1); // "abcd"

        let result = suffix_search(&pool, "cd");
        assert_eq!(result.len(), 1); // "abcd"

        let result = suffix_search(&pool, "bcd");
        assert_eq!(result.len(), 1); // "abcd"
    }

    #[test]
    fn test_offsets_round_trip() {
        let pool = NamePool::new();
        let a = pool.intern("alpha");
        let e = pool.intern("");
        let b = pool.intern("beta");
        assert_eq!(pool.intern("alpha"), a);
        assert_eq!(pool.name_at_offset(a), "alpha");
        assert_eq!(pool.name_at_offset(e), "");
        assert_eq!(pool.name_at_offset(b), "beta");
        let pooled = pool.push("beta");
        assert_eq!(pool.offset_of(pooled), Some(b));
        assert_eq!(pool.offset_of(&pooled[1..]), None, "a slice of a name is not a name");
        assert_eq!(pool.offset_of("beta"), None, "a foreign string has no offset");
        assert_eq!(pool.find_offset("beta"), Some(b));
        assert_eq!(pool.find_offset("gamma"), None);
    }

    #[test]
    fn test_regex_never_matches_across_names() {
        let pool = NamePool::new();
        for name in ["foo", "zbar", "foobar", "xbar", "Foo.TXT", "a.txt"] {
            pool.push(name);
        }
        let cross = Regex::new("foo[^x]*bar").unwrap();
        assert_eq!(regex_search(&pool, &cross).into_vec(), vec!["foobar"]);
        let anchored = regex::RegexBuilder::new("^(?:foo)$").build().unwrap();
        assert_eq!(regex_search(&pool, &anchored).into_vec(), vec!["foo"]);
        let suffix_ci = regex::RegexBuilder::new("(?:\\.txt)$")
            .case_insensitive(true)
            .build()
            .unwrap();
        assert_eq!(regex_search(&pool, &suffix_ci).into_vec(), vec!["Foo.TXT", "a.txt"]);
        let suffix_cs = Regex::new("(?:\\.txt)$").unwrap();
        assert_eq!(regex_search(&pool, &suffix_cs).into_vec(), vec!["a.txt"]);
        let empty = Regex::new("z*").unwrap();
        assert_eq!(regex_search(&pool, &empty).len(), 6);
        let text_anchor = Regex::new("\\Afoo").unwrap();
        assert_eq!(regex_search(&pool, &text_anchor).into_vec(), vec!["foo", "foobar"]);
    }

    #[test]
    #[should_panic(expected = "name contains NUL")]
    fn test_nul_names_are_rejected() {
        // File names can never contain NUL; the arena uses it as the separator.
        NamePool::new().push("null\0byte");
    }

    #[test]
    fn test_corner_control_characters() {
        let pool = NamePool::new();
        pool.push("line1\nline2");
        pool.push("tab\there");
        pool.push("bell\x07sound");

        let result = substr(&pool, "line1\nline2");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "tab\there");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "bell\x07sound");
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_corner_unicode_edge_cases() {
        let pool = NamePool::new();
        pool.push("café");
        pool.push("naïve");
        pool.push("Москва"); // Cyrillic
        pool.push("東京"); // Japanese
        pool.push("🚀🌟"); // Emojis
        pool.push("e\u{0301}"); // Combining character

        let result = substr(&pool, "café");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "naïve");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "Москва");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "東京");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "🚀🌟");
        assert_eq!(result.len(), 1);

        let result = substr(&pool, "e\u{0301}");
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn test_corner_search_result_deduplication() {
        let pool = NamePool::new();
        pool.push("abab");
        pool.push("ababa");

        // "ab" appears in both strings, but should only be returned once per string
        let result: Vec<_> = substr(&pool, "ab").into_iter().collect();
        assert_eq!(result.len(), 2); // Two strings contain "ab"
        assert!(result.contains(&"abab"));
        assert!(result.contains(&"ababa"));
    }

    #[test]
    fn test_corner_exact_vs_substring() {
        let pool = NamePool::new();
        pool.push("test");
        pool.push("testing");
        pool.push("atestb");

        // Exact search for "test"
        let exact_result = exact_search(&pool, "test");
        assert_eq!(exact_result.len(), 1);
        assert!(exact_result.contains("test"));

        // Substring search for "test"
        let substr_result = substr(&pool, "test");
        assert_eq!(substr_result.len(), 3); // "test", "testing", "atestb"
        assert!(substr_result.contains("test"));
        assert!(substr_result.contains("testing"));
        assert!(substr_result.contains("atestb"));
    }

    #[test]
    fn test_corner_zero_width_strings() {
        let pool = NamePool::new();
        pool.push("");
        pool.push("a");
        pool.push("");

        // Should only have one empty string due to deduplication
        assert_eq!(pool.len(), 2);

        let result = exact_search(&pool, "");
        assert_eq!(result.len(), 1);
        assert!(result.contains(""));
    }

    #[test]
    fn test_corner_large_number_of_small_strings() {
        let pool = NamePool::new();
        // Add many small strings
        for i in 0..1000 {
            pool.push(&i.to_string());
        }

        assert_eq!(pool.len(), 1000);

        // Search for a specific number
        let result = exact_search(&pool, "42");
        assert_eq!(result.len(), 1);
        assert!(result.contains("42"));

        // Search for a pattern that appears in many strings
        let result = substr(&pool, "1");
        assert_eq!(result.len(), 271);
    }
}
