//! Interactive name search over a finished scan: a substring or `*`/`?`
//! wildcard query, matched case-insensitively against the flat name arrays in
//! parallel, keeping the `limit` largest matches.
use crate::ranking::TopK;
use crate::Tree;

const SCAN_CHUNK: usize = 1 << 15;

impl Tree {
    /// Search all nodes (1..len) for `query`, returning total matches and
    /// up to `limit` matching node indices sorted largest allocated size first.
    /// Ties break by path, matching `ranking::top_by_alloc`, so the returned
    /// set never depends on how rayon splits the scan.
    pub fn search(&self, query: &str, limit: usize) -> (u64, Vec<u32>) {
        let Some(matcher) = QueryMatcher::new(query) else {
            return (0, Vec::new());
        };
        if self.len() <= 1 {
            return (0, Vec::new());
        }

        use rayon::prelude::*;

        let (total, top) = (0..(self.len() - 1).div_ceil(SCAN_CHUNK))
            .into_par_iter()
            .map(|chunk| {
                let start = 1 + chunk * SCAN_CHUNK;
                let mut count = 0u64;
                let mut top = TopK::new(self, limit);
                for idx in start..(start + SCAN_CHUNK).min(self.len()) {
                    if matcher.matches(self.name_bytes(idx)) {
                        count += 1;
                        top.push(idx);
                    }
                }
                (count, top)
            })
            .reduce(
                || (0u64, TopK::new(self, limit)),
                |(count_a, top_a), (count_b, top_b)| (count_a + count_b, top_a.merge(top_b)),
            );

        (
            total,
            top.into_sorted().into_iter().map(|i| i as u32).collect(),
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AsciiToken {
    Star,
    Question,
    Byte(u8),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PatternToken {
    Star,
    Question,
    Char(char),
}

#[derive(Clone, Debug)]
pub enum QueryMatcher {
    SubstringAscii {
        ascii_bytes: Vec<u8>,
        unicode_chars: Vec<char>,
    },
    SubstringUnicode(Vec<char>),
    WildcardAscii {
        ascii_tokens: Vec<AsciiToken>,
        unicode_tokens: Vec<PatternToken>,
    },
    WildcardUnicode(Vec<PatternToken>),
}

fn lowercase_chars(q: &str) -> Vec<char> {
    q.chars().flat_map(|c| c.to_lowercase()).collect()
}

fn unicode_tokens(q: &str) -> Vec<PatternToken> {
    let mut tokens = Vec::new();
    for c in q.chars() {
        match c {
            '*' => {
                if !matches!(tokens.last(), Some(PatternToken::Star)) {
                    tokens.push(PatternToken::Star);
                }
            }
            '?' => tokens.push(PatternToken::Question),
            _ => tokens.extend(c.to_lowercase().map(PatternToken::Char)),
        }
    }
    tokens
}

fn ascii_tokens(q: &str) -> Vec<AsciiToken> {
    let mut tokens = Vec::new();
    for b in q.bytes() {
        match b {
            b'*' => {
                if !matches!(tokens.last(), Some(AsciiToken::Star)) {
                    tokens.push(AsciiToken::Star);
                }
            }
            b'?' => tokens.push(AsciiToken::Question),
            _ => tokens.push(AsciiToken::Byte(b.to_ascii_lowercase())),
        }
    }
    tokens
}

impl QueryMatcher {
    pub fn new(query: &str) -> Option<Self> {
        let q = query.trim();
        if q.is_empty() {
            return None;
        }
        let has_wildcards = q.contains('*') || q.contains('?');
        let is_ascii = q.is_ascii();

        if !has_wildcards {
            let lowered = lowercase_chars(q);
            return Some(if lowered.iter().all(char::is_ascii) {
                Self::SubstringAscii {
                    ascii_bytes: lowered.iter().map(|&c| c as u8).collect(),
                    unicode_chars: lowered,
                }
            } else {
                Self::SubstringUnicode(lowered)
            });
        }
        Some(if is_ascii {
            Self::WildcardAscii {
                ascii_tokens: ascii_tokens(q),
                unicode_tokens: unicode_tokens(q),
            }
        } else {
            Self::WildcardUnicode(unicode_tokens(q))
        })
    }

    #[inline]
    pub fn matches(&self, name_bytes: &[u8]) -> bool {
        let is_ascii = name_bytes.is_ascii();
        let text = || std::str::from_utf8(name_bytes).ok();
        match self {
            Self::SubstringAscii {
                ascii_bytes,
                unicode_chars,
            } => {
                if is_ascii {
                    ascii_contains(name_bytes, ascii_bytes)
                } else {
                    text().is_some_and(|s| unicode_contains(s, unicode_chars))
                }
            }
            Self::SubstringUnicode(unicode_chars) => {
                !is_ascii && text().is_some_and(|s| unicode_contains(s, unicode_chars))
            }
            Self::WildcardAscii {
                ascii_tokens,
                unicode_tokens,
            } => {
                if is_ascii {
                    wildcard_match(ascii_tokens, name_bytes)
                } else {
                    text().is_some_and(|s| {
                        with_lowercase(s, |lower| wildcard_match(unicode_tokens, lower))
                    })
                }
            }
            Self::WildcardUnicode(unicode_tokens) => text()
                .is_some_and(|s| with_lowercase(s, |lower| wildcard_match(unicode_tokens, lower))),
        }
    }
}

#[inline]
fn ascii_contains(text: &[u8], pat: &[u8]) -> bool {
    if pat.is_empty() {
        return true;
    }
    if text.len() < pat.len() {
        return false;
    }
    let first = pat[0];
    let end = text.len() - pat.len();
    for i in 0..=end {
        if text[i].to_ascii_lowercase() == first {
            let window = &text[i..i + pat.len()];
            if window
                .iter()
                .zip(pat.iter())
                .all(|(&b, &p)| b.to_ascii_lowercase() == p)
            {
                return true;
            }
        }
    }
    false
}

const STACK_CHARS: usize = 256;

#[inline]
fn with_lowercase<R>(text: &str, f: impl FnOnce(&[char]) -> R) -> R {
    let mut stack_buf = ['\0'; STACK_CHARS];
    let heap_buf;
    let lower: &[char] = match lowercase_into(text, &mut stack_buf) {
        Some(len) => &stack_buf[..len],
        None => {
            heap_buf = lowercase_chars(text);
            &heap_buf
        }
    };
    f(lower)
}

#[inline]
fn lowercase_into(text: &str, buf: &mut [char; STACK_CHARS]) -> Option<usize> {
    if text.len() > STACK_CHARS {
        return None;
    }
    let mut len = 0;
    let mut overflow = false;
    for c in text.chars() {
        for lc in c.to_lowercase() {
            if len < STACK_CHARS {
                buf[len] = lc;
                len += 1;
            } else {
                overflow = true;
            }
        }
    }
    (!overflow).then_some(len)
}

fn unicode_contains(text: &str, pat: &[char]) -> bool {
    if pat.is_empty() {
        return true;
    }
    with_lowercase(text, |lower| {
        lower.len() >= pat.len() && lower.windows(pat.len()).any(|w| w == pat)
    })
}

trait WildToken: Copy + PartialEq {
    type Elem: Copy;
    const STAR: Self;
    fn is_question(self) -> bool;
    fn accepts(self, elem: Self::Elem) -> bool;
}

impl WildToken for AsciiToken {
    type Elem = u8;
    const STAR: Self = Self::Star;
    #[inline]
    fn is_question(self) -> bool {
        self == Self::Question
    }
    #[inline]
    fn accepts(self, elem: u8) -> bool {
        matches!(self, Self::Byte(b) if elem.to_ascii_lowercase() == b)
    }
}

impl WildToken for PatternToken {
    type Elem = char;
    const STAR: Self = Self::Star;
    #[inline]
    fn is_question(self) -> bool {
        self == Self::Question
    }
    #[inline]
    fn accepts(self, elem: char) -> bool {
        matches!(self, Self::Char(c) if elem == c)
    }
}

#[inline]
fn wildcard_match<T: WildToken>(pattern: &[T], text: &[T::Elem]) -> bool {
    let mut p_idx = 0;
    let mut t_idx = 0;
    let mut star_p = None;
    let mut star_t = 0;

    while t_idx < text.len() {
        if p_idx < pattern.len() {
            let token = pattern[p_idx];
            if token == T::STAR {
                star_p = Some(p_idx);
                p_idx += 1;
                star_t = t_idx;
                continue;
            }
            if token.is_question() || token.accepts(text[t_idx]) {
                p_idx += 1;
                t_idx += 1;
                continue;
            }
        }

        if let Some(sp) = star_p {
            p_idx = sp + 1;
            star_t += 1;
            t_idx = star_t;
        } else {
            return false;
        }
    }

    while p_idx < pattern.len() && pattern[p_idx] == T::STAR {
        p_idx += 1;
    }

    p_idx == pattern.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ranking::top_by_alloc;
    use std::cmp::Reverse;

    fn tied_fixture(dirs: usize, files: usize) -> Tree {
        let mut t = Tree::with_root("/fixture");
        for d in 0..dirs {
            t.push(&format!("d{:03}", dirs - d), 0, 0, 0, true);
        }
        for d in 0..dirs {
            for f in 0..files {
                t.push(
                    &format!("m{:05}", files - f),
                    d as u32 + 1,
                    4096,
                    4096,
                    false,
                );
            }
        }
        t.link_children();
        t
    }

    fn full_sort_top(t: &Tree, matcher: &QueryMatcher, limit: usize) -> (u64, Vec<u32>) {
        let mut hits: Vec<usize> = (1..t.len())
            .filter(|&i| matcher.matches(t.name_bytes(i)))
            .collect();
        let total = hits.len() as u64;
        hits.sort_unstable_by_key(|&i| (Reverse(t.alloc[i]), t.path(i), Reverse(i)));
        hits.truncate(limit);
        (total, hits.into_iter().map(|i| i as u32).collect())
    }

    #[test]
    fn search_cutoff_ties_are_the_path_ordered_top_k_on_every_run() {
        let t = tied_fixture(80, 1500);
        let matcher = QueryMatcher::new("m0").unwrap();
        for limit in [1, 10, 25, 1000] {
            let expected = full_sort_top(&t, &matcher, limit);
            assert_eq!(expected.0, 120_000);
            let by_ranking: Vec<u32> = top_by_alloc(
                &t,
                (1..t.len()).filter(|&i| matcher.matches(t.name_bytes(i))),
                limit,
            )
            .into_iter()
            .map(|i| i as u32)
            .collect();
            assert_eq!(by_ranking, expected.1);
            for run in 0..20 {
                assert_eq!(t.search("m0", limit), expected, "limit {limit}, run {run}");
            }
        }
    }

    #[test]
    fn search_cutoff_keeps_larger_matches_ahead_of_the_tied_ones() {
        let mut t = tied_fixture(80, 1500);
        let big = t.push("m00000_big", 0, 9000, 9000, false) as usize;
        let mid = t.push("m00000_mid", 40, 8000, 8000, false) as usize;
        t.link_children();
        let matcher = QueryMatcher::new("m0").unwrap();
        let expected = full_sort_top(&t, &matcher, 10);
        assert_eq!(expected.1[..2], [big as u32, mid as u32]);
        for _ in 0..20 {
            assert_eq!(t.search("m0", 10), expected);
        }
    }

    #[test]
    fn search_covers_every_node_at_scan_chunk_boundaries() {
        for nodes in [
            1,
            2,
            SCAN_CHUNK - 1,
            SCAN_CHUNK,
            SCAN_CHUNK + 1,
            2 * SCAN_CHUNK,
            2 * SCAN_CHUNK + 1,
        ] {
            let mut t = Tree::with_root("/fixture");
            for i in 0..nodes {
                t.push(&format!("m{i:06}"), 0, 1, 1 + (i % 7) as u64, false);
            }
            t.link_children();
            let matcher = QueryMatcher::new("m").unwrap();
            assert_eq!(t.search("m", 5), full_sort_top(&t, &matcher, 5), "{nodes} nodes");
            assert_eq!(t.search("m", 5).0, nodes as u64, "{nodes} nodes");
            assert_eq!(t.search("m000000", 5).0, 1);
            assert_eq!(t.search(&format!("m{:06}", nodes - 1), 5).1, vec![nodes as u32]);
        }
    }

    #[test]
    fn search_matches_by_lowercased_form_on_both_sides() {
        let mut t = Tree::with_root("/fixture");
        t.push("kilo.txt", 0, 10, 10, false);
        t.push("\u{212A}elvin.txt", 0, 20, 20, false);
        t.push("plain.txt", 0, 30, 30, false);
        t.push("\u{e5}.txt", 0, 40, 40, false);
        t.push("\u{212B}ngstrom.txt", 0, 50, 50, false);
        t.push("KILO.BIN", 0, 60, 60, false);
        t.link_children();

        for q in ["\u{212A}", "k", "K"] {
            assert_eq!(t.search(q, 10), (3, vec![6, 2, 1]), "{q:?}");
        }
        assert_eq!(t.search("\u{212A}ilo", 10), (2, vec![6, 1]));
        assert_eq!(t.search("kilo", 10), (2, vec![6, 1]));
        assert_eq!(t.search("\u{212A}elvin", 10), (1, vec![2]));
        assert_eq!(t.search("kelvin", 10), (1, vec![2]));
        assert_eq!(t.search("\u{212A}*.txt", 10), (2, vec![2, 1]));
        assert_eq!(t.search("k*.txt", 10), (2, vec![2, 1]));
        assert_eq!(t.search("?ilo*", 10), (2, vec![6, 1]));
        assert_eq!(t.search("\u{212A}ILO*", 10), (2, vec![6, 1]));
        for q in ["\u{212B}", "\u{e5}", "\u{c5}"] {
            assert_eq!(t.search(q, 10), (2, vec![5, 4]), "{q:?}");
        }
        assert_eq!(t.search("\u{212B}*.txt", 10), (2, vec![5, 4]));
        assert_eq!(t.search("*\u{e5}*", 10), (2, vec![5, 4]));
        assert_eq!(t.search("\u{e5}lo", 10), (0, vec![]));
    }

    #[test]
    fn search_with_a_zero_limit_still_counts_every_match() {
        let t = tied_fixture(4, 50);
        assert_eq!(t.search("m0", 0), (200, Vec::new()));
    }

    #[test]
    fn search_finds_unicode_names_past_the_stack_buffer() {
        let at_limit = "é".repeat(128) + "_Target.bin";
        let past_limit = "É".repeat(129) + "_Target.bin";
        let far_past = "é".repeat(400) + "_Target.bin";
        let expanding = "İ".repeat(128);
        let mut t = Tree::with_root("/fixture");
        t.push(&at_limit, 0, 10, 10, false);
        t.push(&past_limit, 0, 20, 20, false);
        t.push(&far_past, 0, 30, 30, false);
        t.push(&expanding, 0, 40, 40, false);
        t.push("plain_target.bin", 0, 50, 50, false);
        t.link_children();

        assert_eq!(t.search("ÉÉÉ_TARGET", 10), (3, vec![3, 2, 1]));
        assert_eq!(t.search("*_TARGET.BIN", 10), (4, vec![5, 3, 2, 1]));
        assert_eq!(t.search("?_target.bin", 10), (0, vec![]));
        assert_eq!(t.search("é*_target.bin", 10), (3, vec![3, 2, 1]));
        assert_eq!(t.search("é*é_target.bin", 10), (3, vec![3, 2, 1]));
        assert_eq!(t.search("*ééé", 10), (0, vec![]));
        assert_eq!(t.search(&format!("{}*", "é".repeat(400)), 10), (1, vec![3]));
        assert_eq!(t.search(&format!("{}*", "é".repeat(401)), 10), (0, vec![]));
        let dotted_i = "i\u{307}";
        assert_eq!(t.search(&dotted_i.repeat(3), 10), (1, vec![4]));
        assert_eq!(t.search(&format!("{}*", dotted_i.repeat(128)), 10), (1, vec![4]));
        assert_eq!(t.search(&format!("{}*", dotted_i.repeat(129)), 10), (0, vec![]));
    }

    #[test]
    fn search_matcher_and_ranking() {
        let mut t = Tree::with_root("/fixture");
        t.push("photo1.png", 0, 100, 100, false);
        t.push("PHOTO2.PNG", 0, 300, 300, false);
        t.push("documents", 0, 5000, 5000, true);
        t.push("my_photo.jpg", 0, 200, 200, false);
        t.push("münchen_report.pdf", 0, 400, 400, false);
        t.push("東京_notes.txt", 0, 50, 50, false);
        t.link_children();

        let (total, matches) = t.search("photo", 10);
        assert_eq!(total, 3);
        assert_eq!(matches, vec![2, 4, 1]);

        let (total, matches) = t.search("*.png", 10);
        assert_eq!(total, 2);
        assert_eq!(matches, vec![2, 1]);

        let (total, matches) = t.search("photo?.png", 10);
        assert_eq!(total, 2);
        assert_eq!(matches, vec![2, 1]);

        let (total, matches) = t.search("MÜNCHEN*", 10);
        assert_eq!(total, 1);
        assert_eq!(matches, vec![5]);

        let (total, matches) = t.search("*京*", 10);
        assert_eq!(total, 1);
        assert_eq!(matches, vec![6]);

        let (total, matches) = t.search("photo", 1);
        assert_eq!(total, 3);
        assert_eq!(matches, vec![2]);

        let (total, matches) = t.search("", 10);
        assert_eq!(total, 0);
        assert!(matches.is_empty());
        let (total, matches) = t.search("   ", 10);
        assert_eq!(total, 0);
        assert!(matches.is_empty());
    }
}
