//! Query preprocessing shared by the app, the live CLI and the offline CLI.

use anyhow::Result;
use search_cache::{SearchCache, SearchOptions, SearchQuery, SlabIndex};
use search_cancel::CancellationToken;
use std::path::Path;

/// Product metadata stays outside the upstream cache and follows the exact result set.
pub struct SearchOutcome {
    pub nodes: Option<Vec<SlabIndex>>,
    pub highlights: Vec<String>,
    pub loosened: Option<String>,
}

impl From<search_cache::SearchOutcome> for SearchOutcome {
    fn from(outcome: search_cache::SearchOutcome) -> Self {
        Self { nodes: outcome.nodes, highlights: outcome.highlights, loosened: None }
    }
}

/// The one search entry point of the window, the live CLI and `--offline`.
///
/// The query is run exactly as written first, so everything that found something
/// keeps finding the same rows. Only when it finds nothing are the looser
/// readings of `loosened` tried, in order, and the first with results answers.
pub fn search(
    cache: &mut SearchCache,
    query: SearchQuery,
    options: SearchOptions,
    token: CancellationToken,
) -> Result<SearchOutcome> {
    let directory = query.directory_query.clone();
    let written = query.query.clone();
    let strict = SearchOutcome::from(cache.search_query_with_options(query, options, token)?);
    let found_nothing = |o: &SearchOutcome| o.nodes.as_ref().is_some_and(Vec::is_empty);
    if !found_nothing(&strict) {
        return Ok(strict);
    }
    for looser in written.as_deref().map(loosened).unwrap_or_default() {
        let query = SearchQuery { directory_query: directory.clone(), query: Some(looser.clone()) };
        match cache.search_query_with_options(query, options, token) {
            Ok(outcome) if outcome.nodes.as_ref().is_some_and(Vec::is_empty) => {}
            // Rows, or cancelled by a newer search. Highlight the words as typed: the
            // looser reading's `*word*` patterns would mark whole names.
            Ok(outcome) => return Ok(SearchOutcome {
                loosened: outcome.nodes.as_ref().map(|_| looser),
                nodes: outcome.nodes, highlights: strict.highlights,
            }),
            Err(_) => break,
        }
    }
    Ok(strict)
}

/// Looser readings of a query, closest to what was typed first.
///
/// Strictly, `reports/ html` asks for one name that ends in `reports` and
/// contains `html`, and `reports html` for one name with both words, so a
/// folder name next to a file name finds nothing. The readings here are:
///
/// 1. terms with a slash name folders anywhere above the file: `reports/ html`
///    → `*reports*/** html`, `a/b` → `*a*/**/*b*`;
/// 2. additionally, every plain word may match the name or a folder above it:
///    `reports html` → `(reports|*reports*/**) (html|*html*/**)`.
///
/// Filters (`ext:pdf`), `!x`, wildcards and anything quoted or grouped are
/// deliberate syntax and stay as written. Words shorter than `MIN_ASCII` /
/// `MIN_OTHER` characters stay too: `*a*/**` is most of the disk.
fn loosened(query: &str) -> Vec<String> {
    if query.contains(|c: char| "\"()<>|\\".contains(c)) {
        return vec![];
    }
    let terms: Vec<&str> = query.split_whitespace().collect();
    let folders: Vec<String> =
        terms.iter().map(|t| loosen_path(t).unwrap_or_else(|| (*t).to_owned())).collect();
    let mut readings = vec![];
    if folders.iter().zip(&terms).any(|(loose, term)| loose != term) {
        readings.push(folders.join(" "));
    }
    if terms.len() >= 2 {
        let words: Vec<String> = terms
            .iter()
            .zip(&folders)
            .map(|(t, loose)| {
                if !t.contains('/') && literal(t) && long_enough(t) {
                    format!("({t}|*{t}*/**)")
                } else {
                    loose.clone()
                }
            })
            .collect();
        if words != folders {
            readings.push(words.join(" "));
        }
    }
    readings
}

const MIN_ASCII: usize = 3;
const MIN_OTHER: usize = 2;

fn long_enough(word: &str) -> bool {
    word.chars().count() >= if word.is_ascii() { MIN_ASCII } else { MIN_OTHER }
}

/// A plain word or path: no filter, negation or wildcard.
fn literal(term: &str) -> bool {
    !term.starts_with('!') && !term.contains([':', '*', '?'])
}

fn loosen_path(term: &str) -> Option<String> {
    if !term.contains('/') || !literal(term) {
        return None;
    }
    let segments: Vec<&str> = term.split('/').filter(|s| !s.is_empty()).collect();
    if segments.is_empty() || !segments.iter().all(|s| long_enough(s)) {
        return None;
    }
    let chain = segments.iter().map(|s| format!("*{s}*")).collect::<Vec<_>>().join("/**/");
    Some(if term.ends_with('/') { format!("{chain}/**") } else { chain })
}

/// A pasted path such as `/Users/me/Library/Application Support/x (1).txt`
/// would otherwise be parsed as several AND-ed words, a group and a NOT and
/// find nothing. When the whole query names a path that exists on disk and
/// contains characters the query syntax gives meaning to, it is searched as
/// one quoted phrase instead (with `~` expanded, which quotes would keep
/// literal). Anything else is returned unchanged.
pub fn normalize(query: String) -> String {
    // The user's real home, also in the sandboxed app (config::home).
    normalize_with(query, Some(crate::config::home().as_path()), |p| {
        Path::new(p).symlink_metadata().is_ok()
    })
}

fn normalize_with(query: String, home: Option<&Path>, exists: impl Fn(&str) -> bool) -> String {
    let trimmed = query.trim();
    if trimmed.contains('"') || !trimmed.contains(|c: char| c.is_whitespace() || "()!|<>".contains(c)) {
        return query;
    }
    let expanded = match trimmed.strip_prefix("~/") {
        Some(rest) => match home {
            Some(home) => format!("{}/{rest}", home.display()),
            None => return query,
        },
        None if trimmed.starts_with('/') => trimmed.to_owned(),
        None => return query,
    };
    let bare = match expanded.trim_end_matches('/') {
        "" => "/",
        s => s,
    };
    if exists(bare) {
        format!("\"{bare}\"")
    } else {
        query
    }
}

#[cfg(test)]
mod tests {
    use super::{loosened, normalize_with};
    use std::path::Path;

    fn n(q: &str) -> String {
        let existing = [
            "/Users/me/Library/Application Support/App 7",
            "/Users/me/voices/!v/Alex",
            "/Users/me/a (1).txt",
            "/Users/me/plain",
        ];
        normalize_with(q.to_owned(), Some(Path::new("/Users/me")), |p| existing.contains(&p))
    }

    #[test]
    fn quotes_existing_paths_with_syntax_characters() {
        assert_eq!(
            n("/Users/me/Library/Application Support/App 7"),
            "\"/Users/me/Library/Application Support/App 7\""
        );
        assert_eq!(n("  /Users/me/voices/!v/Alex\n"), "\"/Users/me/voices/!v/Alex\"");
        assert_eq!(n("/Users/me/a (1).txt"), "\"/Users/me/a (1).txt\"");
        assert_eq!(
            n("~/Library/Application Support/App 7/"),
            "\"/Users/me/Library/Application Support/App 7\""
        );
    }

    #[test]
    fn leaves_other_queries_alone() {
        // Already works unquoted.
        assert_eq!(n("/Users/me/plain"), "/Users/me/plain");
        // Deliberate syntax, not an existing path.
        assert_eq!(n("/Apps readme"), "/Apps readme");
        assert_eq!(n("/Users/me/voices !Alex"), "/Users/me/voices !Alex");
        assert_eq!(n("report (draft)"), "report (draft)");
        // User quoted it already.
        assert_eq!(n("\"/Users/me/a (1).txt\""), "\"/Users/me/a (1).txt\"");
    }

    #[test]
    fn folder_terms_are_loosened_first_then_plain_words() {
        assert_eq!(
            loosened("shaoxing-绍兴/ html"),
            ["*shaoxing-绍兴*/** html", "*shaoxing-绍兴*/** (html|*html*/**)"]
        );
        assert_eq!(loosened("/docs/ .html"), ["*docs*/** .html", "*docs*/** (.html|*.html*/**)"]);
        assert_eq!(loosened("eco-flow/绍兴/ ext:html"), ["*eco-flow*/**/*绍兴*/** ext:html"]);
        assert_eq!(loosened("docs/readme"), ["*docs*/**/*readme*"]);
        assert_eq!(loosened("绍兴 ext:html"), ["(绍兴|*绍兴*/**) ext:html"]);
        assert_eq!(loosened("docs readme"), ["(docs|*docs*/**) (readme|*readme*/**)"]);
    }

    #[test]
    fn deliberate_syntax_and_short_words_stay_as_written() {
        // One word that is in no name is in no folder name either.
        assert!(loosened("readme").is_empty());
        // Quoted, grouped, OR-ed.
        assert!(loosened("\"my docs\"/ html").is_empty());
        assert!(loosened("docs/ (a|b)").is_empty());
        assert!(loosened("docs/|src/ html").is_empty());
        // Filters, negation and wildcards.
        assert!(loosened("ext:html !draft").is_empty());
        assert_eq!(loosened("docs/*.html !draft readme"), ["docs/*.html !draft (readme|*readme*/**)"]);
        // Too short to be worth a walk of most of the disk.
        assert!(loosened("a/ ab").is_empty());
        assert_eq!(loosened("ab/ html 绍"), ["ab/ (html|*html*/**) 绍"]);
        assert_eq!(loosened("绍兴/ ab"), ["*绍兴*/** ab"]);
    }
}
