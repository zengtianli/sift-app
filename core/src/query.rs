//! Query preprocessing shared by the app, the live CLI and the offline CLI.

use std::path::Path;

/// A pasted path such as `/Users/me/Library/Application Support/x (1).txt`
/// would otherwise be parsed as several AND-ed words, a group and a NOT and
/// find nothing. When the whole query names a path that exists on disk and
/// contains characters the query syntax gives meaning to, it is searched as
/// one quoted phrase instead (with `~` expanded, which quotes would keep
/// literal). Anything else is returned unchanged.
pub fn normalize(query: String) -> String {
    normalize_with(query, std::env::var_os("HOME").as_deref().map(Path::new), |p| {
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
    use super::normalize_with;
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
}
