//! File name → slab indices, keyed by the name's offset in [`NAME_POOL`].
//!
//! Most names occur once, so a single index is stored inline; only repeated
//! names allocate a path-ordered vector. On disk the index keeps its original
//! layout (a name-ordered map of name → indices), written and read in a
//! streaming way so neither direction materialises a second copy.

use crate::{FileNodes, NAME_POOL, SlabIndex};
use hashbrown::HashMap;
use rayon::prelude::*;
use search_cancel::CancellationToken;
use serde::{
    Deserialize, Deserializer, Serialize, Serializer,
    de::{MapAccess, Visitor},
    ser::SerializeMap,
};
use std::{fmt, time::Instant};
use thin_vec::ThinVec;
use tracing::info;

/// Slab indices sharing one name, ordered by full path.
#[derive(Debug, Clone)]
pub enum SortedSlabIndices {
    One(SlabIndex),
    Many(ThinVec<SlabIndex>),
}

impl SortedSlabIndices {
    pub fn new(index: SlabIndex) -> Self {
        Self::One(index)
    }

    pub fn as_slice(&self) -> &[SlabIndex] {
        match self {
            Self::One(index) => std::slice::from_ref(index),
            Self::Many(indices) => indices,
        }
    }

    pub fn len(&self) -> usize {
        self.as_slice().len()
    }

    pub fn is_empty(&self) -> bool {
        self.as_slice().is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &SlabIndex> {
        self.as_slice().iter()
    }

    fn to_many(&mut self) -> &mut ThinVec<SlabIndex> {
        if let Self::One(index) = *self {
            *self = Self::Many(ThinVec::from_iter([index]));
        }
        match self {
            Self::Many(indices) => indices,
            Self::One(_) => unreachable!(),
        }
    }

    fn from_vec(mut indices: ThinVec<SlabIndex>) -> Option<Self> {
        match indices.len() {
            0 => None,
            1 => Some(Self::One(indices[0])),
            _ => {
                indices.shrink_to_fit();
                Some(Self::Many(indices))
            }
        }
    }

    pub fn insert(&mut self, index: SlabIndex, slab: &FileNodes) {
        let Some(target_path) = slab.node_path(index) else {
            return;
        };
        let position = self.as_slice().binary_search_by(|existing| {
            slab.node_path(*existing)
                .expect("node in name index must resolve to a path")
                .cmp(&target_path)
        });
        if let Err(pos) = position {
            self.to_many().insert(pos, index);
        }
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn insert_ordered(&mut self, index: SlabIndex) {
        self.to_many().push(index);
    }

    /// Removes `index`; returns whether it was present. A set that becomes
    /// empty must be dropped by the caller.
    pub fn remove(&mut self, index: SlabIndex) -> bool {
        match self {
            Self::One(existing) => {
                if *existing == index {
                    *self = Self::Many(ThinVec::new());
                    true
                } else {
                    false
                }
            }
            Self::Many(indices) => {
                let Some(pos) = indices.iter().position(|&existing| existing == index) else {
                    return false;
                };
                indices.remove(pos);
                if indices.len() == 1 {
                    *self = Self::One(indices[0]);
                }
                true
            }
        }
    }
}

impl Serialize for SortedSlabIndices {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        // Same bytes as the former `#[serde(transparent)] ThinVec<SlabIndex>`.
        self.as_slice().serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for SortedSlabIndices {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let indices = ThinVec::<SlabIndex>::deserialize(deserializer)?;
        Ok(Self::from_vec(indices).unwrap_or(Self::Many(ThinVec::new())))
    }
}

#[derive(Clone, Default)]
pub struct NameIndex {
    // Separate the common inline case from allocated lists. A mixed enum
    // costs 16 bytes even for a single u32 index, plus padding beside the key.
    // Both maps keep the same pool-offset keys and on-disk representation.
    singles: HashMap<u32, SlabIndex>,
    shared: HashMap<u32, ThinVec<SlabIndex>>,
}

impl fmt::Debug for NameIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("NameIndex").field("len", &self.len()).finish()
    }
}

impl NameIndex {
    pub fn len(&self) -> usize {
        self.singles.len() + self.shared.len()
    }

    pub fn is_empty(&self) -> bool {
        self.singles.is_empty() && self.shared.is_empty()
    }

    /// Entries in name order (the order the index is searched and saved in).
    fn sorted_entries(&self) -> Vec<(&'static str, &[SlabIndex])> {
        let mut entries = Vec::with_capacity(self.len());
        entries.extend(self.singles.iter().map(|(&offset, index)|
            (NAME_POOL.name_at_offset(offset), std::slice::from_ref(index))));
        entries.extend(self.shared.iter().map(|(&offset, indices)|
            (NAME_POOL.name_at_offset(offset), indices.as_slice())));
        entries.par_sort_unstable_by(|a, b| a.0.cmp(b.0));
        entries
    }

    pub fn all_indices(&self, cancellation_token: CancellationToken) -> Option<Vec<SlabIndex>> {
        cancellation_token.is_cancelled()?;
        let entries = self.sorted_entries();
        let mut out = Vec::with_capacity(entries.len());
        for (i, (_, indices)) in entries.into_iter().enumerate() {
            cancellation_token.is_cancelled_sparse(i)?;
            out.extend_from_slice(indices);
        }
        Some(out)
    }

    pub fn get(&self, name: &str) -> Option<&[SlabIndex]> {
        let offset = NAME_POOL.find_offset(name)?;
        self.singles.get(&offset).map(std::slice::from_ref)
            .or_else(|| self.shared.get(&offset).map(|v| v.as_slice()))
    }

    fn put(&mut self, offset: u32, indices: SortedSlabIndices) {
        match indices {
            SortedSlabIndices::One(index) => { self.singles.insert(offset, index); }
            SortedSlabIndices::Many(indices) if !indices.is_empty() => {
                self.shared.insert(offset, indices);
            }
            _ => {}
        }
    }

    fn take(&mut self, offset: u32) -> Option<SortedSlabIndices> {
        self.singles.remove(&offset).map(SortedSlabIndices::One)
            .or_else(|| self.shared.remove(&offset).map(SortedSlabIndices::Many))
    }

    /// # Safety
    ///
    /// The index must be inserted with it's full path ordered.
    pub unsafe fn add_index_ordered(&mut self, name: &str, index: SlabIndex) {
        let offset = NAME_POOL.intern(name);
        if let Some(indices) = self.shared.get_mut(&offset) {
            indices.push(index);
        } else if let Some(first) = self.singles.remove(&offset) {
            self.shared.insert(offset, ThinVec::from_iter([first, index]));
        } else {
            self.singles.insert(offset, index);
        }
    }

    pub fn add_index(&mut self, name: &str, index: SlabIndex, slab: &FileNodes) {
        let offset = NAME_POOL.intern(name);
        if let Some(mut indices) = self.take(offset) {
            indices.insert(index, slab);
            self.put(offset, indices);
        } else {
            self.singles.insert(offset, index);
        }
    }

    pub fn remove_index(&mut self, name: &str, index: SlabIndex) -> bool {
        let Some(offset) = NAME_POOL.find_offset(name) else {
            return false;
        };
        let Some(mut indices) = self.take(offset) else {
            return false;
        };
        let removed = indices.remove(index);
        self.put(offset, indices);
        removed
    }

    pub fn remove(&mut self, name: &str) -> Option<SortedSlabIndices> {
        let offset = NAME_POOL.find_offset(name)?;
        self.take(offset)
    }

    /// Whether a live node uses the name at this pool offset.
    pub fn contains_offset(&self, offset: u32) -> bool {
        self.singles.contains_key(&offset) || self.shared.contains_key(&offset)
    }

    /// Hash map buckets, and for names shared by several nodes: how many
    /// lists, their total length and their total capacity.
    pub fn shape(&self) -> (usize, usize, usize, usize) {
        let (mut lists, mut len, mut cap) = (0, 0, 0);
        for v in self.shared.values() {
                if v.capacity() > 0 {
                    lists += 1;
                    len += v.len();
                    cap += v.capacity();
                }
        }
        (self.singles.capacity() + self.shared.capacity(), lists, len, cap)
    }

    /// Releases spare capacity after bulk construction.
    pub fn shrink_to_fit(&mut self) {
        self.singles.shrink_to_fit();
        self.shared.shrink_to_fit();
    }
}

/// Written as a name-ordered map `name → [index]`, byte-identical to the
/// former `BTreeMap<Box<str>, SortedSlabIndices>` encoding.
impl Serialize for NameIndex {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let entries = self.sorted_entries();
        let mut map = serializer.serialize_map(Some(entries.len()))?;
        for (name, indices) in entries {
            map.serialize_entry(name, indices)?;
        }
        map.end()
    }
}

/// Streams entries straight into the pool and map: no intermediate tree.
impl<'de> Deserialize<'de> for NameIndex {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct IndexVisitor;

        impl<'de> Visitor<'de> for IndexVisitor {
            type Value = NameIndex;

            fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
                f.write_str("a map of file name to slab indices")
            }

            fn visit_map<A: MapAccess<'de>>(self, mut access: A) -> Result<NameIndex, A::Error> {
                let started = Instant::now();
                // Reserve both common cases while still streaming the snapshot.
                // This is only an allocation hint; either map grows as needed.
                // Real full-disk indexes have roughly three unique-only names
                // for each repeated name. Shrinking below removes any excess.
                let hint = access.size_hint().unwrap_or(0);
                let mut index = NameIndex {
                    singles: HashMap::with_capacity(hint.saturating_mul(3) / 4),
                    shared: HashMap::with_capacity(hint / 4),
                };
                while let Some(name) = access.next_key::<std::borrow::Cow<'de, str>>()? {
                    let indices: SortedSlabIndices = access.next_value()?;
                    if indices.is_empty() {
                        continue;
                    }
                    index.put(NAME_POOL.intern(&name), indices);
                }
                info!(
                    "Name index load time: {:?}, names: {}, pool: {}",
                    started.elapsed(),
                    index.len(),
                    NAME_POOL.len(),
                );
                index.shrink_to_fit();
                Ok(index)
            }
        }

        deserializer.deserialize_map(IndexVisitor)
    }
}

#[cfg(test)]
mod split_index_tests {
    use super::*;

    #[test]
    fn transitions_and_snapshot_encoding_preserve_sorted_indices() {
        let mut index = NameIndex::default();
        let first = SlabIndex::new(1);
        let second = SlabIndex::new(2);
        unsafe {
            index.add_index_ordered("split-index-fixture", first);
            index.add_index_ordered("split-index-fixture", second);
        }
        assert_eq!(index.len(), 1);
        assert_eq!(index.get("split-index-fixture"), Some([first, second].as_slice()));
        let encoded = postcard::to_stdvec(&index).unwrap();
        let original_format = std::collections::BTreeMap::from([
            ("split-index-fixture", vec![first, second]),
        ]);
        assert_eq!(encoded, postcard::to_stdvec(&original_format).unwrap());
        let mut restored: NameIndex = postcard::from_bytes(&encoded).unwrap();
        assert!(restored.remove_index("split-index-fixture", second));
        assert_eq!(restored.get("split-index-fixture"), Some([first].as_slice()));
        assert_eq!(restored.len(), 1);
        assert!(restored.remove_index("split-index-fixture", first));
        assert!(restored.is_empty());
        assert!(restored.get("split-index-fixture").is_none());
        assert!(!restored.remove_index("split-index-fixture", first));
    }
}
