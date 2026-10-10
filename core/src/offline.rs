//! Reads the saved snapshot directly when no Sift app is running.
//! Results reflect the last snapshot, not live filesystem changes.

use crate::{
    config::Config,
    engine::{QUIT, Row, SortKey, sort_indices},
};
use anyhow::{Context, Result};
use search_cache::{SearchCache, SearchOptions, SearchQuery};
use search_cancel::CancellationToken;

pub struct Offline {
    cache: SearchCache,
}

impl Offline {
    pub fn open(config: &Config) -> Result<Self> {
        let cache = SearchCache::try_read_persistent_cache(
            &config.root,
            &config.db_path(),
            &config.ignore_paths,
            &config.include_paths,
            &QUIT,
        )
        .with_context(|| format!("no usable index at {}", config.db_path().display()))?;
        Ok(Self { cache })
    }

    pub fn total_files(&self) -> usize {
        self.cache.get_total_files()
    }

    pub fn search(
        &mut self,
        directory: Option<String>,
        query: Option<String>,
        case_insensitive: bool,
    ) -> Result<Vec<search_cache::SlabIndex>> {
        let outcome = self.cache.search_query_with_options(
            SearchQuery {
                directory_query: directory.filter(|s| !s.trim().is_empty()),
                query: query.filter(|s| !s.trim().is_empty()).map(crate::query::normalize),
            },
            SearchOptions { case_insensitive },
            CancellationToken::noop(),
        )?;
        Ok(outcome.nodes.unwrap_or_default())
    }

    /// Same ordering as the app and the live CLI (`engine::sort_indices`).
    pub fn sort(
        &mut self,
        indices: Vec<search_cache::SlabIndex>,
        key: SortKey,
        descending: bool,
    ) -> Vec<search_cache::SlabIndex> {
        sort_indices(&mut self.cache, indices, key, descending, CancellationToken::noop())
            .expect("a no-op token never cancels")
    }

    pub fn rows(&mut self, indices: &[search_cache::SlabIndex]) -> Vec<Row> {
        self.cache
            .expand_file_nodes(indices)
            .into_iter()
            .map(Row::from)
            .collect()
    }
}
