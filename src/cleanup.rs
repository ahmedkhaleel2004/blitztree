//! The Clean Up panel's folder recognition, shared with the JSON CLI and the
//! C bridge. This module is the single owner of recognition; callers only
//! format its output. These are name/structure heuristics, not authorization
//! to delete anything: the Swift guards and verifiers (`Kind::verify`) decide.
use crate::Tree;
use std::ffi::CStr;
use std::path::{Component, Path, PathBuf};

pub const MIN_BYTES: u64 = 50_000_000;

/// `s` must end in one NUL; ids are stored that way so the C bridge can hand
/// out `'static` C strings without allocating.
fn trim_nul(s: &'static str) -> &'static str {
    &s[..s.len() - 1]
}

fn c_str(s: &'static str) -> &'static CStr {
    CStr::from_bytes_with_nul(s.as_bytes()).expect("ids are NUL-terminated without interior NUL")
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Group {
    /// Rebuilt or re-downloaded without user data loss.
    Safe = 0,
    /// Recreatable at a cost, or holding history the user may want.
    Review = 1,
}

impl Group {
    pub fn id(self) -> &'static str {
        match self {
            Self::Safe => "safe",
            Self::Review => "review",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Build,
    Packages,
    Apps,
    DevTools,
    Models,
    Agents,
    Worktrees,
}

impl Section {
    pub const ALL: &'static [Section] = &[
        Self::Build,
        Self::Packages,
        Self::Apps,
        Self::DevTools,
        Self::Models,
        Self::Agents,
        Self::Worktrees,
    ];

    fn id_nul(self) -> &'static str {
        match self {
            Self::Build => "build\0",
            Self::Packages => "packages\0",
            Self::Apps => "apps\0",
            Self::DevTools => "devtools\0",
            Self::Models => "models\0",
            Self::Agents => "agents\0",
            Self::Worktrees => "worktrees\0",
        }
    }

    pub fn id(self) -> &'static str {
        trim_nul(self.id_nul())
    }

    pub fn c_id(self) -> &'static CStr {
        c_str(self.id_nul())
    }
}

const CACHEDIR_TAG: &str = "cachedir_tag\0";
const GIT_WORKTREE: &str = "git_worktree\0";
const RECENT_ACTIVITY: &str = "recent_activity\0";
const AGENT_SESSION: &str = "agent_session\0";

macro_rules! kinds {
    ($($kind:ident => $id:literal, $group:ident, $section:ident, $verify:expr, $description:literal;)*) => {
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum Kind { $($kind),* }

        impl Kind {
            pub const ALL: &'static [Kind] = &[$(Self::$kind),*];

            fn id_nul(self) -> &'static str {
                match self { $(Self::$kind => concat!($id, "\0")),* }
            }

            /// English panel label; Swift localizes by `id()` and falls back to this.
            pub fn description(self) -> &'static str {
                match self { $(Self::$kind => $description),* }
            }

            pub fn group(self) -> Group {
                match self { $(Self::$kind => Group::$group),* }
            }

            pub fn section(self) -> Section {
                match self { $(Self::$kind => Section::$section),* }
            }

            fn verify_nul(self) -> Option<&'static str> {
                match self { $(Self::$kind => $verify),* }
            }
        }
    };
}

kinds! {
    // The original nine; ids and labels unchanged.
    NodeModules => "node_modules", Safe, Build, None, "npm packages, reinstallable";
    PythonEnvironment => "python_environment", Safe, Build, None, "Python environment, reinstallable";
    RustBuild => "rust_build", Safe, Build, None, "Rust build output";
    NextBuild => "next_build", Safe, Build, None, "Next.js build output";
    XcodeDerivedData => "xcode_derived_data", Safe, DevTools, None, "Xcode build data";
    DeviceSupport => "device_support", Safe, DevTools, None, "Device symbols, re-downloaded when needed";
    AppCaches => "app_caches", Safe, Apps, None, "App caches, rebuilt automatically";
    ToolCaches => "tool_caches", Safe, Packages, None, "Caches, rebuilt or re-downloaded when needed";
    BunCache => "bun_cache", Safe, Packages, None, "Bun package cache, re-downloaded when needed";
    // Project build output, gated on the project's manifest.
    SwiftBuild => "swift_build", Safe, Build, None, "Swift package build output";
    GradleBuild => "gradle_build", Safe, Build, None, "Gradle build output";
    DartBuild => "dart_build", Safe, Build, None, "Dart and Flutter tool output";
    JsBuildCache => "js_build_cache", Safe, Build, None, "JavaScript build cache";
    CocoaPods => "cocoapods", Safe, Build, None, "CocoaPods dependencies, reinstallable";
    PythonTestEnvironments => "python_test_environments", Safe, Build, None, "tox/nox test environments, recreated by the next run";
    ZigBuild => "zig_build", Safe, Build, None, "Zig build output and cache";
    ElixirBuild => "elixir_build", Safe, Build, None, "Elixir build output and dependencies";
    HaskellBuild => "haskell_build", Safe, Build, None, "Haskell build output";
    // Package-manager caches.
    CargoCache => "cargo_cache", Safe, Packages, None, "Cargo download cache, re-downloaded when needed";
    GradleCache => "gradle_cache", Safe, Packages, None, "Gradle caches and distributions, re-downloaded when needed";
    MavenRepository => "maven_repository", Review, Packages, None, "Maven local repository; locally installed artifacts are not re-downloadable";
    TaggedCache => "tagged_cache", Safe, Packages, Some(CACHEDIR_TAG), "Folder marked as a cache (CACHEDIR.TAG)";
    // Developer tools.
    XcodeArchives => "xcode_archives", Review, DevTools, None, "Xcode archives, needed to symbolicate shipped builds";
    XcodePreviews => "xcode_previews", Safe, DevTools, None, "Xcode preview simulators, recreated when needed";
    XcodeTestDevices => "xcode_test_devices", Safe, DevTools, None, "XCTest device clones, recreated by test runs";
    RustToolchain => "rust_toolchain", Review, DevTools, None, "Rust toolchain, reinstallable with rustup";
    // Models.
    MlModel => "ml_model", Review, Models, None, "Downloaded ML model, re-downloaded on next use";
    OllamaModels => "ollama_models", Review, Models, None, "Ollama models, re-pulled on next use";
    // Coding agents.
    AgentTranscripts => "agent_transcripts", Review, Agents, Some(RECENT_ACTIVITY), "Claude Code session history for one project";
    AgentCheckpoints => "agent_checkpoints", Review, Agents, Some(RECENT_ACTIVITY), "Claude Code file checkpoints (rewind history)";
    AgentLogs => "agent_logs", Safe, Agents, None, "Claude Code debug logs";
    CodexSessions => "codex_sessions", Review, Agents, Some(RECENT_ACTIVITY), "Codex session history";
    // A CACHEDIR.TAG folder in a Claude Code session's temp scratchpad.
    AgentScratch => "agent_scratch", Safe, Agents, Some(AGENT_SESSION), "Build output in a Claude Code scratchpad";
    // Emitted and descended (I3): its own build output is listed separately.
    GitWorktree => "git_worktree", Review, Worktrees, Some(GIT_WORKTREE), "Linked Git worktree";
}

impl Kind {
    /// Stable id, also the CLI's `category`.
    pub fn id(self) -> &'static str {
        trim_nul(self.id_nul())
    }

    pub fn c_id(self) -> &'static CStr {
        c_str(self.id_nul())
    }

    /// A container kind: emitted AND descended, so candidates may nest inside it.
    pub fn descends(self) -> bool {
        matches!(self, Self::GitWorktree)
    }

    /// The check Swift must pass before acting: "cachedir_tag" (the CLI and
    /// this module match the tag by name only), "git_worktree",
    /// "recent_activity" or "agent_session" (the tag, and the Claude Code
    /// session owning the scratchpad is not running). `None` when the rule
    /// needs no extra check.
    pub fn verify(self) -> Option<&'static str> {
        self.verify_nul().map(trim_nul)
    }

    /// `verify()` as a C string, "" when there is none.
    pub fn c_verify(self) -> &'static CStr {
        c_str(self.verify_nul().unwrap_or("\0"))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub node: u32,
    pub kind: Kind,
}

/// The user's home directory, the only anchor home rules (`~/.cache`,
/// `~/Library/Caches`, `~/.cargo`, ...) compare against. A whole-disk scan is
/// rooted at /System/Volumes/Data, where /Users/x appears as
/// /System/Volumes/Data/Users/x, so both spellings are kept. Without a home,
/// home rules never match.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Anchors {
    /// Each spelling's normal components, e.g. ["Users", "x"].
    homes: Vec<Vec<String>>,
}

const DATA_VOLUME: [&str; 3] = ["System", "Volumes", "Data"];

impl Anchors {
    /// `home` must be absolute, UTF-8, free of `..` and not `/`; anything else
    /// yields no anchors (fail closed: no home rule matches).
    pub fn new(home: Option<&Path>) -> Self {
        let mut anchors = Self::default();
        if let Some(home) = home {
            anchors.add(home);
        }
        anchors
    }

    /// `$HOME`, plus its symlink-resolved spelling when that differs.
    pub fn from_env() -> Self {
        let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
        let mut anchors = Self::new(home.as_deref());
        if let Some(real) = home
            .filter(|h| h.is_absolute())
            .and_then(|h| std::fs::canonicalize(h).ok())
        {
            anchors.add(&real);
        }
        anchors
    }

    fn add(&mut self, home: &Path) {
        if !home.is_absolute() {
            return;
        }
        let mut parts = Vec::new();
        for component in home.components() {
            match component {
                Component::RootDir | Component::CurDir => {}
                Component::Normal(part) => match part.to_str() {
                    Some(part) => parts.push(part.to_owned()),
                    None => return,
                },
                Component::ParentDir | Component::Prefix(_) => return,
            }
        }
        if parts.is_empty() {
            return;
        }
        let alias: Vec<String> = if parts.len() > DATA_VOLUME.len() && parts[..3] == DATA_VOLUME {
            parts[3..].to_vec()
        } else {
            DATA_VOLUME
                .iter()
                .map(|s| s.to_string())
                .chain(parts.iter().cloned())
                .collect()
        };
        for spelling in [parts, alias] {
            if !self.homes.contains(&spelling) {
                self.homes.push(spelling);
            }
        }
    }
}

/// Path components of node `i` from itself upward: tree names until the root,
/// then the root's own path components (node 0's name is its full path).
/// Every ancestor-name rule reads names through this, so a rule still matches
/// when the ancestor it inspects is the scan root (e.g. a scan rooted at
/// .../Xcode still recognizes DerivedData).
fn upward(t: &Tree, i: usize) -> impl Iterator<Item = &str> {
    let mut n = i;
    std::iter::from_fn(move || {
        (n != 0).then(|| {
            let name = t.name(n);
            n = t.parents[n] as usize;
            name
        })
    })
    .chain(
        t.name(0)
            .rsplit('/')
            .filter(|part| !part.is_empty() && *part != "."),
    )
}

/// Name of the `k`-th ancestor (0 = the node itself), "" above `/`.
fn up(t: &Tree, i: usize, k: usize) -> &str {
    upward(t, i).nth(k).unwrap_or("")
}

impl Anchors {
    /// Whether the `skip`-th ancestor of `i` is exactly `home/<rel>`.
    fn at(&self, t: &Tree, i: usize, skip: usize, rel: &[&str]) -> bool {
        self.homes.iter().any(|home| {
            let mut path = upward(t, i).skip(skip);
            rel.iter().rev().all(|part| path.next() == Some(*part))
                && home
                    .iter()
                    .rev()
                    .all(|part| path.next() == Some(part.as_str()))
                && path.next().is_none()
        })
    }

    /// Whether `i` is strictly inside the home.
    fn inside(&self, t: &Tree, i: usize) -> bool {
        let depth = upward(t, i).count();
        self.homes
            .iter()
            .any(|home| depth > home.len() && self.at(t, i, depth - home.len(), &[]))
    }

    /// Sorted tree nodes that are never listed because the Swift guard always
    /// refuses them (I1): the home and its ancestors, `home/<NEVER_LISTED>`,
    /// and the home's direct children not starting with "." (a dotfiles
    /// `.git` file or a stray CACHEDIR.TAG must not list ~/Library or the
    /// home). Computed once per `find` by walking down from the root.
    fn never_listed(&self, t: &Tree) -> Vec<usize> {
        let mut root: Vec<&str> = upward(t, 0).collect();
        root.reverse();
        // The node at an absolute path, when that path is in the tree.
        let locate = |target: &[&str]| -> Option<usize> {
            if target.len() < root.len() || target[..root.len()] != root[..] {
                return None;
            }
            let mut at = 0usize;
            for part in &target[root.len()..] {
                at = *t.kids(at).iter().find(|&&k| t.name(k as usize) == *part)? as usize;
            }
            Some(at)
        };
        let mut never = Vec::new();
        for home in &self.homes {
            let home: Vec<&str> = home.iter().map(String::as_str).collect();
            never.extend((0..=home.len()).filter_map(|depth| locate(&home[..depth])));
            if let Some(h) = locate(&home) {
                never.extend(
                    t.kids(h)
                        .iter()
                        .map(|&k| k as usize)
                        .filter(|&k| !t.name(k).starts_with('.')),
                );
            }
            for rel in NEVER_LISTED {
                let target: Vec<&str> = home.iter().copied().chain(rel.iter().copied()).collect();
                never.extend(locate(&target));
            }
        }
        never.sort_unstable();
        never.dedup();
        never
    }
}

/// Home-relative folders the Swift guard always refuses as too broad
/// (CleanupSafety.broadRelative). Containers among them are still descended.
const NEVER_LISTED: &[&[&str]] = &[
    &["Library"],
    &["Library", "Caches"],
    &["Library", "Application Support"],
    &["Library", "Containers"],
    &["Library", "Group Containers"],
    &["Library", "Developer"],
    &["Library", "Preferences"],
    &[".config"],
    &[".cache"],
    &["Library", "Developer", "CoreSimulator"],
    &["Library", "Developer", "CoreSimulator", "Devices"],
    &[".local"],
    &[".local", "share"],
    &["Downloads"],
];

/// A directory whose children are classified by its own rules. Every
/// container except `Plain` is restricted: children its rules do not name
/// are skipped without descent ("nothing else in ~/.cargo").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Container {
    Plain,
    DotCache,
    LibraryCaches,
    HuggingFace,
    HfHub,
    Cargo,
    Maven,
    Ollama,
    Rustup,
    RustupToolchains,
    Claude,
    ClaudeProjects,
    Codex,
    CodexSessions,
    CodexWorktrees,
    /// `~/.codex/worktrees/<id>`: the linked worktree is `<id>/<repo>`.
    CodexWorktreeId,
    GradleHome,
}

/// Home-relative containers. The walk reaches nested ones through their
/// parent container; this table seeds a scan rooted at any of them.
const HOME_CONTAINERS: &[(&[&str], Container)] = &[
    (&[".cache"], Container::DotCache),
    (&[".cache", "huggingface"], Container::HuggingFace),
    (&[".cache", "huggingface", "hub"], Container::HfHub),
    (&["Library", "Caches"], Container::LibraryCaches),
    (&[".cargo"], Container::Cargo),
    (&[".m2"], Container::Maven),
    (&[".ollama"], Container::Ollama),
    (&[".rustup"], Container::Rustup),
    (&[".rustup", "toolchains"], Container::RustupToolchains),
    (&[".claude"], Container::Claude),
    (&[".claude", "projects"], Container::ClaudeProjects),
    (&[".codex"], Container::Codex),
    (&[".codex", "sessions"], Container::CodexSessions),
    (&[".codex", "worktrees"], Container::CodexWorktrees),
    (&[".gradle"], Container::GradleHome),
];

const GRADLE_CONFIG: &[&str] = &[
    "gradle.properties",
    "init.d",
    "init.gradle",
    "init.gradle.kts",
];
/// Documented as recreated by Gradle; `native` and `.tmp` deliberately excluded.
const GRADLE_CACHES: &[&str] = &[
    "caches",
    "wrapper",
    "daemon",
    "jdks",
    "workers",
    "kotlin-profile",
    "build-scan-data",
];
const ELECTRON_CACHES: &[&str] = &[
    "Cache",
    "Code Cache",
    "GPUCache",
    "CachedData",
    "CachedExtensionVSIXs",
    "DawnGraphiteCache",
    "DawnWebGPUCache",
    "ShaderCache",
];

enum Outcome {
    /// A candidate; descended too when `kind.descends()`.
    Emit(Kind),
    /// A container: not emitted, children classified by its rules.
    Descend(Container),
    /// Neither emitted nor descended.
    Skip,
    /// No rule: an ordinary folder, descended.
    Pass,
}

/// Name-only marker checks, as the panel has always done: any entry type.
fn contains(t: &Tree, directory: usize, names: &[&str]) -> bool {
    any_kid(t, directory, |name| names.contains(&name))
}

/// Whether any entry of `directory` satisfies `wanted` (e.g. a `*.cabal` file).
fn any_kid(t: &Tree, directory: usize, wanted: impl Fn(&str) -> bool) -> bool {
    t.kids(directory)
        .iter()
        .any(|&i| wanted(t.name(i as usize)))
}

#[derive(Default)]
struct Markers {
    /// Any `.git` entry: this directory is (part of) a repository.
    git: bool,
    /// `.git` is not a directory: a linked worktree, a submodule, or a
    /// repository created with `--separate-git-dir`.
    git_file: bool,
    /// A non-directory `CACHEDIR.TAG` (contents are verified in Swift).
    cachedir_tag: bool,
}

/// What a folder's `.git` file says about it. Only a linked worktree is a
/// `git_worktree` candidate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum GitFile {
    /// Names `<common dir>/worktrees/<name>`, an admin directory whose
    /// `commondir` leads to that common dir and whose `gitdir` names this file.
    Worktree,
    /// Names `<parent>/.git/modules/<name>`.
    Submodule,
    /// A `--separate-git-dir` repository, a copy of a worktree, or a file that
    /// is missing, a link, a pipe, unreadable, larger than `GIT_FILE_MAX`, not
    /// UTF-8, not exactly one `gitdir: <path>` line, or naming an admin
    /// directory that does not check out. Never a candidate: whatever the file
    /// claims is unproven.
    Other,
}

/// Git's own `.git` files are one short line; anything longer is not one.
const GIT_FILE_MAX: usize = 4096;

/// Exactly one line: an optional single trailing newline, no other control
/// bytes, valid UTF-8 (as Swift's `GitWorktree.singleLine`).
fn single_line(bytes: &[u8]) -> Option<&str> {
    let bytes = bytes.strip_suffix(b"\n").unwrap_or(bytes);
    if bytes.iter().any(|&b| b < 0x20 || b == 0x7f) {
        return None;
    }
    std::str::from_utf8(bytes).ok()
}

/// `reference` (absolute, or relative to `base`) with `.` and `..` folded away
/// lexically; `None` when `..` climbs above the root.
fn resolve(base: &Path, reference: &str) -> Option<PathBuf> {
    let reference = Path::new(reference);
    let joined = if reference.is_absolute() {
        reference.to_path_buf()
    } else {
        base.join(reference)
    };
    let mut dir = PathBuf::new();
    for component in joined.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if !dir.pop() {
                    return None;
                }
            }
            other => dir.push(other.as_os_str()),
        }
    }
    Some(dir)
}

/// The directory a `.git` file's bytes name (relative paths resolve against
/// `folder`, lexically) and what that directory's path says it is. Names only:
/// the caller checks the directory.
fn parse_git_file(content: &[u8], folder: &Path) -> Option<(GitFile, PathBuf)> {
    if content.len() > GIT_FILE_MAX {
        return None;
    }
    let target = single_line(content)?.strip_prefix("gitdir: ")?;
    if target.is_empty() {
        return None;
    }
    let dir = resolve(folder, target)?;
    let names: Vec<_> = dir
        .components()
        .filter_map(|c| match c {
            Component::Normal(name) => Some(name),
            _ => None,
        })
        .collect();
    let kind = if names.len() >= 2 && names[names.len() - 2] == "worktrees" {
        GitFile::Worktree
    } else if names
        .windows(2)
        .any(|pair| pair[0] == ".git" && pair[1] == "modules")
    {
        GitFile::Submodule
    } else {
        GitFile::Other
    };
    Some((kind, dir))
}

/// A small regular file and what it held, read as Swift's
/// `GitWorktree.readMarker` does: `lstat` first (a link, a pipe, a device, an
/// empty or oversized file, or a dataless cloud placeholder, which opening would
/// download, is refused unopened); then `open` without following a link and
/// without blocking, accepted only when the opened file is the one `lstat` saw
/// (so a swap in between cannot make us wait on a pipe or read another file);
/// then at most `GIT_FILE_MAX` bytes. Its metadata is returned for identity checks.
fn read_marker(path: &Path) -> Option<(Vec<u8>, std::fs::Metadata)> {
    use std::io::Read;
    use std::os::macos::fs::MetadataExt as _;
    use std::os::unix::fs::{MetadataExt as _, OpenOptionsExt as _};
    let seen = std::fs::symlink_metadata(path).ok()?;
    if !seen.file_type().is_file()
        || seen.st_flags() & crate::SF_DATALESS != 0
        || seen.len() == 0
        || seen.len() > GIT_FILE_MAX as u64
    {
        return None;
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let opened = file.metadata().ok()?;
    if !opened.file_type().is_file() || opened.dev() != seen.dev() || opened.ino() != seen.ino() {
        return None;
    }
    let mut content = Vec::new();
    file.take(GIT_FILE_MAX as u64 + 1)
        .read_to_end(&mut content)
        .ok()?;
    (!content.is_empty() && content.len() <= GIT_FILE_MAX).then_some((content, opened))
}

fn same_file(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;
    a.dev() == b.dev() && a.ino() == b.ino()
}

/// Whether `admin` is a linked worktree's administrative directory for the
/// folder whose `.git` file is `git` (Swift's `GitWorktree.layout`, structural
/// part): `commondir` names a directory whose `worktrees` is `admin`'s parent,
/// and `gitdir` names back this very `.git` file.
fn is_linked_admin(admin: &Path, git: &std::fs::Metadata) -> bool {
    let line_of = |name: &str| {
        let (raw, _) = read_marker(&admin.join(name))?;
        single_line(&raw)
            .filter(|line| !line.is_empty())
            .and_then(|line| resolve(admin, line))
    };
    let Some(common) = line_of("commondir") else {
        return false;
    };
    let linked = || {
        let admin_dir = std::fs::metadata(admin).ok().filter(|m| m.is_dir())?;
        std::fs::metadata(&common).ok().filter(|m| m.is_dir())?;
        let listed = std::fs::metadata(admin.parent()?).ok()?;
        let worktrees = std::fs::metadata(common.join("worktrees")).ok()?;
        let back = std::fs::symlink_metadata(line_of("gitdir")?).ok()?;
        (same_file(&listed, &worktrees) && same_file(&back, git)).then_some(admin_dir)
    };
    linked().is_some()
}

/// Read `folder/.git` and say what it is (see `GitFile`). Every failure,
/// including a file that changes underneath us, is `Other`.
fn probe_git_file(folder: &Path) -> GitFile {
    let Some((content, git)) = read_marker(&folder.join(".git")) else {
        return GitFile::Other;
    };
    match parse_git_file(&content, folder) {
        Some((GitFile::Worktree, admin)) if !is_linked_admin(&admin, &git) => GitFile::Other,
        Some((kind, _)) => kind,
        None => GitFile::Other,
    }
}

fn markers(t: &Tree, directory: usize) -> Markers {
    let mut m = Markers::default();
    for &kid in t.kids(directory) {
        let kid = kid as usize;
        match t.name(kid) {
            ".git" => {
                m.git = true;
                m.git_file |= !t.is_dir(kid);
            }
            "CACHEDIR.TAG" => m.cachedir_tag |= !t.is_dir(kid),
            _ => {}
        }
    }
    m
}

fn is_year(name: &str) -> bool {
    name.len() == 4 && name.bytes().all(|b| b.is_ascii_digit())
}

/// Whether a `~/.claude/projects/<project>` folder holds nothing but session
/// transcripts: `*.jsonl` files and session-id folders. Claude Code keeps its
/// persistent memory (`memory/`) in the same folder, and any other entry is
/// unknown, so only a folder that is all transcripts is a candidate. Candidates
/// are directories, so the transcripts can only be offered with their folder.
fn only_transcripts(t: &Tree, project: usize) -> bool {
    // A session folder is trusted only for the entries Claude Code puts there.
    let session = |folder: usize| {
        t.kids(folder).iter().all(|&kid| {
            let kid = kid as usize;
            let name = t.name(kid);
            match t.is_dir(kid) {
                true => matches!(name, "subagents" | "tool-results" | "workflows"),
                false => {
                    matches!(name, "custom-title.json" | ".DS_Store") || name.ends_with(".jsonl")
                }
            }
        })
    };
    t.kids(project).iter().all(|&kid| {
        let kid = kid as usize;
        let name = t.name(kid);
        match t.is_dir(kid) {
            true => is_uuid(name) && session(kid),
            false => name == ".DS_Store" || name.ends_with(".jsonl"),
        }
    })
}

/// Whether a file named `token` or `stored_tokens` (Hugging Face's login)
/// lies anywhere under `directory`.
fn holds_token(t: &Tree, directory: usize) -> bool {
    let mut pending = vec![directory];
    while let Some(d) = pending.pop() {
        for &kid in t.kids(d) {
            let kid = kid as usize;
            if t.is_dir(kid) {
                pending.push(kid);
            } else if matches!(t.name(kid), "token" | "stored_tokens") {
                return true;
            }
        }
    }
    false
}

/// Rules for a child `i` of a container, or `None` for a plain parent.
/// `git` says what a folder's `.git` file is (see `GitFile`).
fn container_rule(
    t: &Tree,
    i: usize,
    ctx: Container,
    git: &dyn Fn(usize) -> GitFile,
) -> Option<Outcome> {
    use Container as C;
    use Outcome::{Descend, Emit, Skip};
    let name = t.name(i);
    let linked_worktree = || markers(t, i).git_file && git(i) == GitFile::Worktree;
    Some(match ctx {
        C::Plain => return None,
        C::DotCache => match name {
            "huggingface" => Descend(C::HuggingFace),
            ".cache" => Descend(C::DotCache),
            "torch" => Emit(Kind::MlModel),
            _ => Emit(Kind::ToolCaches),
        },
        C::LibraryCaches => {
            // macOS-managed caches; the Swift guard refuses them too.
            if name.len() >= 10 && name.as_bytes()[..10].eq_ignore_ascii_case(b"com.apple.") {
                Skip
            } else if name == ".cache" {
                Descend(C::DotCache)
            } else {
                Emit(Kind::AppCaches)
            }
        }
        // Only the hub: `token`, `stored_tokens` and config live beside it.
        C::HuggingFace if name == "hub" => Descend(C::HfHub),
        C::HfHub
            if ["models--", "datasets--", "spaces--"]
                .iter()
                .any(|p| name.starts_with(p)) =>
        {
            Emit(Kind::MlModel)
        }
        C::Cargo if name == "registry" || name == "git" => Emit(Kind::CargoCache),
        C::Maven if name == "repository" => Emit(Kind::MavenRepository),
        C::Ollama if name == "models" => Emit(Kind::OllamaModels),
        C::Rustup if name == "toolchains" => Descend(C::RustupToolchains),
        C::Rustup if name == "downloads" || name == "tmp" => Emit(Kind::ToolCaches),
        C::RustupToolchains => Emit(Kind::RustToolchain),
        C::Claude => match name {
            "projects" => Descend(C::ClaudeProjects),
            "file-history" => Emit(Kind::AgentCheckpoints),
            "debug" => Emit(Kind::AgentLogs),
            _ => Skip,
        },
        C::ClaudeProjects if only_transcripts(t, i) => Emit(Kind::AgentTranscripts),
        C::Codex => match name {
            "sessions" => Descend(C::CodexSessions),
            "archived_sessions" => Emit(Kind::CodexSessions),
            "worktrees" => Descend(C::CodexWorktrees),
            _ => Skip,
        },
        C::CodexSessions if is_year(name) => Emit(Kind::CodexSessions),
        // Codex puts a worktree at `<id>` or at `<id>/<repo>`. A folder with no
        // linked worktree in either place is not a Codex worktree whatever it
        // holds (the dev machine's holds release artifacts), and a `.git`
        // directory is a full clone: neither is ever offered.
        C::CodexWorktrees if linked_worktree() => Emit(Kind::GitWorktree),
        C::CodexWorktrees if !markers(t, i).git => Descend(C::CodexWorktreeId),
        C::CodexWorktreeId if linked_worktree() => Emit(Kind::GitWorktree),
        C::GradleHome if GRADLE_CACHES.contains(&name) => Emit(Kind::GradleCache),
        _ => Skip,
    })
}

/// Rules for a directory `i` whose parent is a plain folder.
fn plain_rule(t: &Tree, i: usize, anchors: &Anchors, git: &dyn Fn(usize) -> GitFile) -> Outcome {
    use Container as C;
    use Outcome::{Descend, Emit, Skip};
    let parent = t.parents[i] as usize;
    let parent_name = || up(t, i, 1);
    let sibling = |names: &[&str]| contains(t, parent, names);
    let home_child = |container| {
        if anchors.at(t, i, 0, &[t.name(i)]) {
            Some(Descend(container))
        } else {
            None
        }
    };
    // Marker lookups happen only for the named artifact, not every sibling.
    let named = match t.name(i) {
        // Wherever it is, never whole: `huggingface/token` and the like live in
        // it, and a home that is not $HOME's spelling is indistinguishable.
        ".cache" => Some(Descend(C::DotCache)),
        "Caches" if parent_name() == "Library" => {
            Some(if anchors.at(t, i, 0, &["Library", "Caches"]) {
                Descend(C::LibraryCaches)
            } else if anchors.inside(t, parent) {
                // Containers/<app>/Data/Library/Caches and the like.
                Emit(Kind::AppCaches)
            } else {
                // System /Library/Caches, other users' and other volumes' caches.
                Skip
            })
        }
        "Caches" if parent_name() == "CoreSimulator" => Some(Emit(Kind::AppCaches)),
        ".cargo" => home_child(C::Cargo),
        ".m2" => home_child(C::Maven),
        ".ollama" => home_child(C::Ollama),
        ".rustup" => home_child(C::Rustup),
        ".claude" => home_child(C::Claude),
        ".codex" => home_child(C::Codex),
        ".gradle" => Some(if contains(t, i, GRADLE_CONFIG) {
            Descend(C::GradleHome)
        } else {
            home_child(C::GradleHome).unwrap_or(Emit(Kind::ToolCaches))
        }),
        // A node_modules without package.json is a global prefix (installed CLIs).
        "node_modules" => Some(if sibling(&["package.json"]) {
            Emit(Kind::NodeModules)
        } else {
            Skip
        }),
        ".venv" => Some(Emit(Kind::PythonEnvironment)),
        "venv" if contains(t, i, &["pyvenv.cfg"]) => Some(Emit(Kind::PythonEnvironment)),
        "target" if sibling(&["Cargo.toml"]) => Some(Emit(Kind::RustBuild)),
        ".next" if sibling(&["package.json"]) => Some(Emit(Kind::NextBuild)),
        "DerivedData" if parent_name() == "Xcode" => Some(Emit(Kind::XcodeDerivedData)),
        "Archives" if parent_name() == "Xcode" => Some(Emit(Kind::XcodeArchives)),
        "Previews" if parent_name() == "UserData" && up(t, i, 2) == "Xcode" => {
            Some(Emit(Kind::XcodePreviews))
        }
        "XCTestDevices" if parent_name() == "Developer" => Some(Emit(Kind::XcodeTestDevices)),
        "iOS DeviceSupport" | "macOS DeviceSupport" | "watchOS DeviceSupport" => {
            Some(Emit(Kind::DeviceSupport))
        }
        ".npm" => Some(Emit(Kind::ToolCaches)),
        "cache" if parent_name() == "install" && up(t, i, 2) == ".bun" => {
            Some(Emit(Kind::BunCache))
        }
        ".build" if sibling(&["Package.swift"]) => Some(Emit(Kind::SwiftBuild)),
        "build"
            if sibling(&[
                "build.gradle",
                "build.gradle.kts",
                "settings.gradle",
                "settings.gradle.kts",
            ]) =>
        {
            Some(Emit(Kind::GradleBuild))
        }
        ".dart_tool" if sibling(&["pubspec.yaml"]) => Some(Emit(Kind::DartBuild)),
        ".turbo" | ".parcel-cache" | ".nuxt" | ".svelte-kit" | ".expo" | ".angular"
            if sibling(&["package.json"]) =>
        {
            Some(Emit(Kind::JsBuildCache))
        }
        "Pods" if sibling(&["Podfile"]) => Some(Emit(Kind::CocoaPods)),
        ".tox" | ".nox" if sibling(&["tox.ini", "noxfile.py", "pyproject.toml", "setup.cfg"]) => {
            Some(Emit(Kind::PythonTestEnvironments))
        }
        ".zig-cache" | "zig-cache" | "zig-out" if sibling(&["build.zig"]) => {
            Some(Emit(Kind::ZigBuild))
        }
        "_build" | "deps" if sibling(&["mix.exs"]) => Some(Emit(Kind::ElixirBuild)),
        ".stack-work" | "dist-newstyle"
            if any_kid(t, parent, |n| {
                matches!(n, "stack.yaml" | "cabal.project") || n.ends_with(".cabal")
            }) =>
        {
            Some(Emit(Kind::HaskellBuild))
        }
        name if ELECTRON_CACHES.contains(&name)
            && up(t, i, 2) == "Application Support"
            && anchors.at(t, i, 2, &["Library", "Application Support"]) =>
        {
            Some(Emit(Kind::AppCaches))
        }
        _ => None,
    };
    if let Some(outcome) = named {
        return outcome;
    }
    // Structure rules, after every named rule.
    let m = markers(t, i);
    // The `.git` file's own content decides, not where the folder sits: a
    // submodule or a --separate-git-dir repository is not a linked worktree.
    if m.git_file && git(i) == GitFile::Worktree {
        Emit(Kind::GitWorktree)
    } else if m.cachedir_tag {
        Emit(if in_claude_scratchpad(t, i) {
            Kind::AgentScratch
        } else {
            Kind::TaggedCache
        })
    } else {
        Outcome::Pass
    }
}

/// Whether `i` lies inside a Claude Code session's temp scratchpad:
/// `/private/tmp/claude-<uid>/<project>/<session uuid>/scratchpad/...`, also
/// spelled under /System/Volumes/Data. Name shape only; Swift parses the same
/// shape (CleanupPathSafety.claudeScratch) and checks the session is over.
fn in_claude_scratchpad(t: &Tree, i: usize) -> bool {
    let names: Vec<&str> = upward(t, i).collect();
    (1..names.len()).any(|k| {
        let above = &names[k..];
        let rest = |n: usize| above.get(n).copied();
        above[0] == "scratchpad"
            && rest(1).is_some_and(is_uuid)
            && rest(2).is_some_and(|p| !p.is_empty())
            && rest(3)
                .and_then(|c| c.strip_prefix("claude-"))
                .is_some_and(|uid| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit()))
            && rest(4) == Some("tmp")
            && rest(5) == Some("private")
            && (above.len() == 6 || above[6..] == ["Data", "Volumes", "System"])
    })
}

/// A lowercase or uppercase 8-4-4-4-12 hex id.
fn is_uuid(name: &str) -> bool {
    name.len() == 36
        && name.bytes().enumerate().all(|(k, b)| {
            if matches!(k, 8 | 13 | 18 | 23) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}

/// The scan root's own container, from its absolute path.
fn root_container(t: &Tree, anchors: &Anchors) -> Container {
    HOME_CONTAINERS
        .iter()
        .find(|(rel, _)| anchors.at(t, 0, 0, rel))
        .map(|&(_, container)| container)
        .unwrap_or(
            if up(t, 0, 0) == ".gradle" && contains(t, 0, GRADLE_CONFIG) {
                Container::GradleHome
            } else {
                Container::Plain
            },
        )
}

/// Panel semantics: visit descendants (not the scan root), skip `.Trash` and
/// anything below `min_bytes` (with its subtree), and never descend into a
/// candidate except a container kind (`Kind::descends`, I3). O(n) over the
/// visited directories plus O(depth) path checks for name-matched ones.
/// Size ties use paths so parallel scan scheduling cannot reorder the report.
///
/// The one rule that reads the disk: a folder with a `.git` file is a
/// `git_worktree` only when that file names a linked worktree's admin
/// directory (`probe_git_file`); nothing else is read.
pub fn find(t: &Tree, min_bytes: u64, anchors: &Anchors) -> Vec<Candidate> {
    find_with(t, min_bytes, anchors, &|i| probe_git_file(&t.path(i)))
}

/// `find`, with `git` answering what the `.git` file of node `i` is.
pub(crate) fn find_with(
    t: &Tree,
    min_bytes: u64,
    anchors: &Anchors,
    git: &dyn Fn(usize) -> GitFile,
) -> Vec<Candidate> {
    let mut found = Vec::new();
    if t.is_empty() {
        return found;
    }
    let never = anchors.never_listed(t);
    // (directory, its container)
    let mut stack = vec![(0usize, root_container(t, anchors))];
    while let Some((i, ctx)) = stack.pop() {
        for &child in t.kids(i) {
            let c = child as usize;
            // Skip this subtree, not later siblings (the final sort decides order).
            if t.alloc[c] < min_bytes || !t.is_dir(c) || t.name(c) == ".Trash" {
                continue;
            }
            let outcome = match container_rule(t, c, ctx, git)
                .unwrap_or_else(|| plain_rule(t, c, anchors, git))
            {
                Outcome::Emit(kind) if never.binary_search(&c).is_ok() => {
                    if matches!(
                        kind,
                        Kind::GitWorktree | Kind::TaggedCache | Kind::AgentScratch
                    ) {
                        // A user folder that merely carries a marker: look inside.
                        Outcome::Pass
                    } else {
                        Outcome::Skip
                    }
                }
                // A Gradle user home anywhere (GRADLE_USER_HOME=~/.cache/gradle)
                // holds credentials in gradle.properties: never emit it whole.
                Outcome::Emit(kind) if !kind.descends() && contains(t, c, GRADLE_CONFIG) => {
                    Outcome::Descend(Container::GradleHome)
                }
                // Likewise a Hugging Face home under any name (HF_HOME=~/.cache/hf)
                // or any tool cache with a login token anywhere in it: only
                // `hub` entries are offered, never the folder.
                Outcome::Emit(Kind::ToolCaches) if holds_token(t, c) => {
                    Outcome::Descend(Container::HuggingFace)
                }
                outcome => outcome,
            };
            match outcome {
                Outcome::Emit(kind) => {
                    found.push(Candidate { node: child, kind });
                    if kind.descends() {
                        stack.push((c, Container::Plain));
                    }
                }
                Outcome::Descend(container) => stack.push((c, container)),
                Outcome::Skip => {}
                Outcome::Pass => {
                    if ctx == Container::Plain {
                        stack.push((c, Container::Plain));
                    }
                }
            }
        }
    }
    found.sort_by(|a, b| {
        t.alloc[b.node as usize]
            .cmp(&t.alloc[a.node as usize])
            .then_with(|| t.compare_paths(a.node as usize, b.node as usize))
    });
    found
}

/// For each candidate, the index (into `found`) of its nearest enclosing
/// candidate, if any. Only container kinds enclose others (I3); totals must
/// sum candidates with `None` here, never all of them.
pub fn enclosing(t: &Tree, found: &[Candidate]) -> Vec<Option<usize>> {
    let index: std::collections::HashMap<u32, usize> =
        found.iter().enumerate().map(|(k, c)| (c.node, k)).collect();
    found
        .iter()
        .map(|c| {
            let mut n = c.node as usize;
            while n != 0 {
                n = t.parents[n] as usize;
                if let Some(&k) = index.get(&(n as u32)) {
                    return Some(k);
                }
            }
            None
        })
        .collect()
}

#[cfg(test)]
#[path = "cleanup_stress_tests.rs"]
mod stress_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::NO_PARENT;

    /// Sizes are set per node as given (not aggregated). Siblings must be
    /// added consecutively, as a scan appends them; `link` then lists them.
    fn add(scan: &mut Tree, parent: u32, name: &str, is_dir: bool, bytes: u64) -> u32 {
        if parent == NO_PARENT {
            *scan = Tree::with_root(name);
            scan.alloc[0] = bytes;
            scan.logical[0] = bytes;
            return 0;
        }
        assert!(
            scan.parents.last() == Some(&parent) || !scan.parents.contains(&parent),
            "siblings are contiguous"
        );
        scan.push(name, parent, bytes, bytes, is_dir)
    }

    fn link(mut scan: Tree) -> Tree {
        scan.link_children();
        scan
    }

    /// Build a tree from root-relative paths. `a/b/` is an empty directory,
    /// `a/b` a file of MIN_BYTES (so every non-empty directory passes the
    /// threshold); directory sizes are subtree sums. Siblings are appended in
    /// the order `order` gives (identity when it returns the input).
    pub(super) fn build_with(
        root: &str,
        paths: &[&str],
        order: &mut dyn FnMut(Vec<usize>) -> Vec<usize>,
    ) -> Tree {
        struct N {
            name: String,
            dir: bool,
            size: u64,
            kids: std::collections::BTreeMap<String, usize>,
        }
        let mut nodes = vec![N {
            name: root.into(),
            dir: true,
            size: 0,
            kids: Default::default(),
        }];
        for path in paths {
            let (path, dir_leaf) = match path.strip_suffix('/') {
                Some(p) => (p, true),
                None => (*path, false),
            };
            let parts: Vec<&str> = path.split('/').collect();
            let mut at = 0;
            for (k, part) in parts.iter().enumerate() {
                let leaf = k + 1 == parts.len();
                let dir = !leaf || dir_leaf;
                at = match nodes[at].kids.get(*part) {
                    Some(&next) => {
                        nodes[next].dir |= dir;
                        next
                    }
                    None => {
                        nodes.push(N {
                            name: part.to_string(),
                            dir,
                            size: 0,
                            kids: Default::default(),
                        });
                        let next = nodes.len() - 1;
                        nodes[at].kids.insert(part.to_string(), next);
                        next
                    }
                };
            }
        }
        fn total(nodes: &mut Vec<N>, i: usize) -> u64 {
            let kids: Vec<usize> = nodes[i].kids.values().copied().collect();
            let sum: u64 = if nodes[i].dir {
                kids.into_iter().map(|k| total(nodes, k)).sum()
            } else {
                MIN_BYTES
            };
            nodes[i].size = sum;
            sum
        }
        total(&mut nodes, 0);
        let mut t = Tree::with_root(root);
        (t.alloc[0], t.logical[0]) = (nodes[0].size, nodes[0].size);
        let mut queue = std::collections::VecDeque::from([(0usize, 0u32)]);
        while let Some((at, index)) = queue.pop_front() {
            let kids = order(nodes[at].kids.values().copied().collect());
            for k in kids {
                let n = &nodes[k];
                let pushed = t.push(&n.name, index, n.size, n.size, n.dir);
                queue.push_back((k, pushed));
            }
        }
        t.link_children();
        t
    }

    pub(super) fn build(root: &str, paths: &[&str]) -> Tree {
        build_with(root, paths, &mut |v| v)
    }

    /// Root-relative path of a node.
    pub(super) fn rel(t: &Tree, i: u32) -> String {
        let mut parts = Vec::new();
        let mut i = i as usize;
        while i != 0 {
            parts.push(t.name(i));
            i = t.parents[i] as usize;
        }
        parts.reverse();
        parts.join("/")
    }

    /// Candidates as sorted (relative path, kind id) pairs. Every `.git` file in
    /// these synthetic trees is taken to name a linked worktree; the rules that
    /// read `.git` files are tested against real files (`Scratch`) and the
    /// classifier directly.
    fn found(t: &Tree, home: Option<&str>) -> Vec<(String, &'static str)> {
        let mut v: Vec<_> = find_with(t, MIN_BYTES, &Anchors::new(home.map(Path::new)), &|_| {
            GitFile::Worktree
        })
        .iter()
        .map(|c| (rel(t, c.node), c.kind.id()))
        .collect();
        v.sort();
        v
    }

    fn expect(rows: &[(&str, &'static str)]) -> Vec<(String, &'static str)> {
        let mut v: Vec<_> = rows.iter().map(|(p, k)| (p.to_string(), *k)).collect();
        v.sort();
        v
    }

    #[test]
    fn node_modules_requires_a_sibling_package_json() {
        let t = build(
            "/w",
            &[
                "global/lib/node_modules/npm/x",
                "app/package.json",
                "app/node_modules/x",
            ],
        );
        assert_eq!(
            found(&t, None),
            expect(&[("app/node_modules", "node_modules")])
        );
    }

    #[test]
    fn global_node_modules_prefixes_are_never_candidates() {
        // Installed CLIs live in <prefix>/lib/node_modules with no package.json
        // beside them (Homebrew, system, nvm). Nothing under them is reached
        // either: the folder is skipped, not descended.
        let t = build(
            "/",
            &[
                "opt/homebrew/lib/node_modules/npm/x",
                "opt/homebrew/lib/node_modules/npm/node_modules/y",
                "usr/local/lib/node_modules/typescript/x",
                "Users/u/.nvm/versions/node/v20.1.0/lib/node_modules/codex/x",
                "Users/u/.nvm/versions/node/v20.1.0/lib/node_modules/codex/package.json",
                "Users/u/app/package.json",
                "Users/u/app/node_modules/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[("Users/u/app/node_modules", "node_modules")])
        );
    }

    #[test]
    fn claude_project_folders_are_emitted_only_when_they_hold_nothing_but_transcripts() {
        const A: &str = "0b7e9a52-6c1d-4f3e-8a47-5d2c9e1f0a63";
        const B: &str = "f1c4d8a7-2b39-4e60-9d15-7a8b3c6e2f04";
        let paths = [
            // Only transcripts and session folders: the whole project.
            format!(".claude/projects/clean/{A}.jsonl"),
            format!(".claude/projects/clean/{B}.jsonl"),
            format!(".claude/projects/clean/{A}/subagents/agent-1.jsonl"),
            format!(".claude/projects/clean/{B}/custom-title.json"),
            format!(".claude/projects/clean/{B}/tool-results/r"),
            format!(".claude/projects/clean/{B}/workflows/w"),
            format!(".claude/projects/clean/{B}/{A}.jsonl"),
            ".claude/projects/clean/.DS_Store".to_string(),
            format!(".claude/projects/clean/{A}/.DS_Store"),
            // A session folder is trusted only for the names Claude Code gives it.
            format!(".claude/projects/uuid-memory/{A}.jsonl"),
            format!(".claude/projects/uuid-memory/{A}/memory/MEMORY.md"),
            format!(".claude/projects/uuid-notes/{A}/notes.md"),
            // Claude Code's persistent memory sits beside the transcripts.
            format!(".claude/projects/with-memory/{A}.jsonl"),
            ".claude/projects/with-memory/memory/MEMORY.md".to_string(),
            // Any other folder or file is unknown: fail closed.
            format!(".claude/projects/unknown-dir/{A}.jsonl"),
            ".claude/projects/unknown-dir/notes/a.md".to_string(),
            format!(".claude/projects/unknown-file/{A}.jsonl"),
            ".claude/projects/unknown-file/MEMORY.md".to_string(),
            format!(".claude/projects/superseded/{A}.jsonl"),
            format!(".claude/projects/superseded/{A}.superseded-1790899128948/x"),
        ];
        let paths: Vec<&str> = paths.iter().map(String::as_str).collect();
        let t = build("/Users/u", &paths);
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".claude/projects/clean", "agent_transcripts")])
        );
        // Also when the scan is rooted at ~/.claude/projects.
        let rooted: Vec<String> = paths
            .iter()
            .map(|p| p.trim_start_matches(".claude/projects/").to_string())
            .collect();
        let rooted: Vec<&str> = rooted.iter().map(String::as_str).collect();
        let t = build("/Users/u/.claude/projects", &rooted);
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[("clean", "agent_transcripts")])
        );
    }

    #[test]
    fn a_cache_folder_is_a_container_wherever_it_is() {
        // Another user's home, or a home spelled differently from $HOME: the
        // whole .cache is never a candidate, and neither is anything that
        // holds credentials. Its other children are.
        let paths = [
            "Users/other/.cache/huggingface/token",
            "Users/other/.cache/huggingface/stored_tokens",
            "Users/other/.cache/huggingface/hub/models--a/x",
            "Users/other/.cache/pip/x",
            "Users/other/.cache/gradle/gradle.properties",
            "Users/other/.cache/gradle/caches/x",
            "Users/u/proj/.cache/huggingface/token",
            "Users/u/proj/.cache/hit/x",
            // HF_HOME=~/.cache/hf: a Hugging Face home under another name.
            "Users/other/.cache/hf/token",
            "Users/other/.cache/hf/hub/models--b/x",
            // The same without a hub, or with only datasets, xet or nothing else.
            "Users/other/.cache/hf2/token",
            "Users/other/.cache/hf2/datasets/d/x",
            "Users/other/.cache/hf3/stored_tokens",
            "Users/other/.cache/hf3/xet/x",
            // A credential file anywhere below a tool cache keeps it from being offered whole.
            "Users/other/.cache/deep/a/b/token",
            "Users/other/.cache/deep/a/b/blob",
        ];
        let t = build("/", &paths);
        let expected = expect(&[
            ("Users/other/.cache/gradle/caches", "gradle_cache"),
            ("Users/other/.cache/hf/hub/models--b", "ml_model"),
            ("Users/other/.cache/huggingface/hub/models--a", "ml_model"),
            ("Users/other/.cache/pip", "tool_caches"),
            ("Users/u/proj/.cache/hit", "tool_caches"),
        ]);
        assert_eq!(found(&t, None), expected);
        assert_eq!(found(&t, Some("/Users/u")), expected);
    }

    #[test]
    #[allow(clippy::type_complexity)]
    fn build_tool_folders_need_their_project_files() {
        let cases: &[(&[&str], &[(&str, &str)])] = &[
            (&["p/.tox/x"], &[]),
            (&["p/.nox/x"], &[]),
            (
                &["p/.tox/x", "p/tox.ini"],
                &[("p/.tox", "python_test_environments")],
            ),
            (
                &["p/.nox/x", "p/noxfile.py"],
                &[("p/.nox", "python_test_environments")],
            ),
            (
                &["p/.tox/x", "p/pyproject.toml"],
                &[("p/.tox", "python_test_environments")],
            ),
            (
                &["p/.tox/x", "p/setup.cfg"],
                &[("p/.tox", "python_test_environments")],
            ),
            (&["p/.stack-work/x"], &[]),
            (&["p/dist-newstyle/x"], &[]),
            (
                &["p/.stack-work/x", "p/stack.yaml"],
                &[("p/.stack-work", "haskell_build")],
            ),
            (
                &["p/dist-newstyle/x", "p/cabal.project"],
                &[("p/dist-newstyle", "haskell_build")],
            ),
            (
                &["p/dist-newstyle/x", "p/app.cabal"],
                &[("p/dist-newstyle", "haskell_build")],
            ),
            (&["p/dist-newstyle/x", "p/app.cabal.bak"], &[]),
        ];
        for (paths, expected) in cases {
            assert_eq!(
                found(&build("/root", paths), None),
                expect(expected),
                "{paths:?}"
            );
        }
    }

    #[test]
    fn home_cache_roots_are_containers_and_their_children_are_candidates() {
        let t = build(
            "/Users/u",
            &[
                ".cache/pip/x",
                "Library/Caches/com.example.app/x",
                "Library/Caches/com.apple.Safari/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[
                (".cache/pip", "tool_caches"),
                ("Library/Caches/com.example.app", "app_caches")
            ])
        );
    }

    #[test]
    fn gradle_home_with_config_is_never_a_candidate_but_its_caches_are() {
        let t = build(
            "/Users/u",
            &[
                ".gradle/gradle.properties",
                ".gradle/caches/x",
                ".gradle/init.d/x",
                ".gradle/wrapper/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[
                (".gradle/caches", "gradle_cache"),
                (".gradle/wrapper", "gradle_cache")
            ])
        );
    }

    #[test]
    fn cargo_home_is_never_a_candidate_but_registry_and_git_are() {
        let t = build(
            "/Users/u",
            &[
                ".cargo/registry/x",
                ".cargo/git/x",
                ".cargo/bin/x",
                ".cargo/credentials.toml",
                ".cargo/env",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[
                (".cargo/git", "cargo_cache"),
                (".cargo/registry", "cargo_cache")
            ])
        );
    }

    #[test]
    fn cachedir_tag_marks_a_tagged_cache() {
        let t = build("/w", &["tool/state/CACHEDIR.TAG", "tool/state/blob"]);
        assert_eq!(found(&t, None), expect(&[("tool/state", "tagged_cache")]));
    }

    #[test]
    fn tagged_caches_in_a_claude_scratchpad_are_agent_scratch() {
        const SESSION: &str = "ce907f81-c909-44a2-bcf7-70370fa492b7";
        let tagged = |base: &str| [format!("{base}/CACHEDIR.TAG"), format!("{base}/blob")];
        let scratch = format!("private/tmp/claude-501/-Users-u-p/{SESSION}/scratchpad");
        let paths: Vec<String> = [
            tagged(&format!("{scratch}/devmap-target")),
            tagged(&format!("{scratch}/p2/target")),
            // Not a scratchpad: the session's own folder and its tasks.
            tagged(&format!(
                "private/tmp/claude-501/-Users-u-p/{SESSION}/tasks/t"
            )),
            // Not a session id, not a claude-<uid> folder, not under /private/tmp.
            tagged("private/tmp/claude-501/-Users-u-p/not-a-session/scratchpad/t"),
            tagged(&format!(
                "private/tmp/claude-x/-Users-u-p/{SESSION}/scratchpad/t"
            )),
            tagged(&format!(
                "private/var/claude-501/-Users-u-p/{SESSION}/scratchpad/t"
            )),
        ]
        .concat();
        let paths: Vec<&str> = paths.iter().map(String::as_str).collect();
        let base = format!("private/tmp/claude-501/-Users-u-p/{SESSION}");
        let plain = [
            format!("{base}/tasks/t"),
            "private/tmp/claude-501/-Users-u-p/not-a-session/scratchpad/t".into(),
            format!("private/tmp/claude-x/-Users-u-p/{SESSION}/scratchpad/t"),
            format!("private/var/claude-501/-Users-u-p/{SESSION}/scratchpad/t"),
        ];
        let mut want = vec![
            (format!("{scratch}/devmap-target"), "agent_scratch"),
            (format!("{scratch}/p2/target"), "agent_scratch"),
        ];
        want.extend(plain.into_iter().map(|p| (p, "tagged_cache")));
        want.sort();
        assert_eq!(found(&build("/", &paths), None), want);

        // The whole-disk spelling, and a scan rooted at the scratchpad itself.
        let data: Vec<String> = paths
            .iter()
            .map(|p| format!("System/Volumes/Data/{p}"))
            .collect();
        let data: Vec<&str> = data.iter().map(String::as_str).collect();
        let kinds: Vec<_> = found(&build("/", &data), None)
            .into_iter()
            .map(|(_, k)| k)
            .collect();
        assert_eq!(kinds.iter().filter(|k| **k == "agent_scratch").count(), 2);
        let rooted = build(
            &format!("/{scratch}"),
            &["devmap-target/CACHEDIR.TAG", "devmap-target/blob"],
        );
        assert_eq!(
            found(&rooted, None),
            expect(&[("devmap-target", "agent_scratch")])
        );
    }

    #[test]
    fn git_worktrees_are_emitted_and_descended_and_only_when_the_git_file_says_so() {
        let paths = [
            "repo/.git/HEAD",
            "repo/src/x",
            "repo/sub/.git",
            "repo/sub/x",
            "repo/.claude/worktrees/feature/.git",
            "repo/.claude/worktrees/feature/package.json",
            "repo/.claude/worktrees/feature/node_modules/x",
            "loose/.git",
            "loose/x",
        ];
        let t = build("/w", &paths);
        // The `.git` file decides per folder, wherever the folder sits: a
        // `.git` directory is a repository, not a worktree.
        let by_name = |i: usize| match t.name(i) {
            "feature" | "loose" => GitFile::Worktree,
            "sub" => GitFile::Submodule,
            _ => GitFile::Other,
        };
        let mut got: Vec<_> = find_with(&t, MIN_BYTES, &Anchors::default(), &by_name)
            .iter()
            .map(|c| (rel(&t, c.node), c.kind.id()))
            .collect();
        got.sort();
        assert_eq!(
            got,
            expect(&[
                ("loose", "git_worktree"),
                ("repo/.claude/worktrees/feature", "git_worktree"),
                (
                    "repo/.claude/worktrees/feature/node_modules",
                    "node_modules"
                ),
            ])
        );
    }

    #[test]
    fn git_files_are_classified_from_their_content_alone() {
        let folder = Path::new("/Users/u/Code/repo/vendor/sub");
        let check = |content: &[u8]| {
            parse_git_file(content, folder).map(|(kind, dir)| (kind, dir.display().to_string()))
        };
        let worktree = |dir: &str| Some((GitFile::Worktree, dir.to_string()));
        // Absolute and relative links to a linked worktree's admin directory.
        assert_eq!(
            check(b"gitdir: /r/.git/worktrees/x\n"),
            worktree("/r/.git/worktrees/x")
        );
        assert_eq!(
            check(b"gitdir: /r/.git/worktrees/x"),
            worktree("/r/.git/worktrees/x")
        );
        assert_eq!(
            check(b"gitdir: ../../.git/worktrees/x\n"),
            worktree("/Users/u/Code/repo/.git/worktrees/x")
        );
        assert_eq!(
            check(b"gitdir: /r/./a/../.git/worktrees/x\n"),
            worktree("/r/.git/worktrees/x")
        );
        // A worktree of a submodule is still a linked worktree.
        assert_eq!(
            check(b"gitdir: /r/.git/modules/m/worktrees/x\n"),
            worktree("/r/.git/modules/m/worktrees/x")
        );
        // Submodules, by relative or absolute path.
        let submodule = |dir: &str| Some((GitFile::Submodule, dir.to_string()));
        assert_eq!(
            check(b"gitdir: ../../.git/modules/sub\n"),
            submodule("/Users/u/Code/repo/.git/modules/sub")
        );
        assert_eq!(
            check(b"gitdir: /r/.git/modules/a/modules/b\n"),
            submodule("/r/.git/modules/a/modules/b")
        );
        // --separate-git-dir: neither, even under a folder that is named worktrees.
        let other = |dir: &str| Some((GitFile::Other, dir.to_string()));
        assert_eq!(check(b"gitdir: /r/proj.git\n"), other("/r/proj.git"));
        assert_eq!(
            check(b"gitdir: /r/modules/proj\n"),
            other("/r/modules/proj")
        );
        assert_eq!(
            check(b"gitdir: /r/.git/worktrees\n"),
            other("/r/.git/worktrees")
        );
        assert_eq!(check(b"gitdir: /worktrees\n"), other("/worktrees"));
        // Not a git file at all: nothing is claimed.
        let mut long = b"gitdir: /r/.git/worktrees/".to_vec();
        long.resize(GIT_FILE_MAX + 1, b'x');
        let mut limit = b"gitdir: /r/.git/worktrees/".to_vec();
        limit.resize(GIT_FILE_MAX, b'x');
        assert!(check(&limit).is_some() && check(&long).is_none());
        for bad in [
            &b""[..],
            b"\n",
            b"gitdir:",
            b"gitdir: ",
            b"gitdir: \n",
            b"gitdir:/r/.git/worktrees/x\n",
            b"GITDIR: /r/.git/worktrees/x\n",
            b" gitdir: /r/.git/worktrees/x\n",
            b"gitdir: /r/.git/worktrees/x\ngitdir: /r/.git/worktrees/y\n",
            b"gitdir: /r/.git/worktrees/x\n\n",
            b"gitdir: /r/.git/worktrees/x\0\n",
            b"gitdir: /r/.git/worktrees/x\r\n",
            b"gitdir: /r/.git/worktrees/x\x7f\n",
            b"gitdir: /r/.git/worktrees/\xff\n",
            b"\xef\xbb\xbfgitdir: /r/.git/worktrees/x\n",
            b"gitdir: ../../../../../../../../../../.git/worktrees/x\n",
            b"gitdir: /..\n",
            b"ref: refs/heads/main\n",
        ] {
            assert_eq!(check(bad), None, "{:?}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn global_node_modules_prefixes_are_never_candidates_on_disk() {
        let s = Scratch::new("global");
        s.file("opt/homebrew/lib/node_modules/npm/index.js", b"x");
        s.file(
            "home/.nvm/versions/node/v20.1.0/lib/node_modules/codex/index.js",
            b"x",
        );
        s.file("home/proj/package.json", b"{}");
        s.file("home/proj/node_modules/dep/index.js", b"x");
        assert_eq!(
            s.found("", None),
            expect(&[("home/proj/node_modules", "node_modules")])
        );
    }

    /// A real directory tree for the rules that read `.git` files. Removed on drop.
    pub(super) struct Scratch(pub(super) std::path::PathBuf);

    impl Scratch {
        pub(super) fn new(tag: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("bz-cleanup-{}-{tag}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            std::fs::create_dir_all(&root).unwrap();
            Self(root)
        }

        pub(super) fn path(&self, rel: &str) -> std::path::PathBuf {
            self.0.join(rel)
        }

        pub(super) fn dir(&self, rel: &str) {
            std::fs::create_dir_all(self.path(rel)).unwrap();
        }

        pub(super) fn file(&self, rel: &str, contents: &[u8]) {
            self.dir(Path::new(rel).parent().and_then(Path::to_str).unwrap_or(""));
            std::fs::write(self.path(rel), contents).unwrap();
        }

        /// The admin directory a linked worktree's `.git` file names.
        pub(super) fn admin(&self, repo: &str, name: &str) -> std::path::PathBuf {
            self.file(
                &format!("{repo}/.git/worktrees/{name}/commondir"),
                b"../..\n",
            );
            self.file(
                &format!("{repo}/.git/worktrees/{name}/HEAD"),
                b"ref: refs/heads/x\n",
            );
            self.path(&format!("{repo}/.git/worktrees/{name}"))
        }

        /// A folder whose `.git` file names `target`.
        /// When `target` is an existing worktree admin directory, its `gitdir`
        /// is pointed back at this folder's `.git`, as `git worktree add` does.
        pub(super) fn gitdir_file(&self, folder: &str, target: &str) {
            self.file(
                &format!("{folder}/.git"),
                format!("gitdir: {target}\n").as_bytes(),
            );
            self.file(&format!("{folder}/payload"), b"x");
            let admin = self.path(folder).join(target);
            if admin.join("commondir").is_file() {
                std::fs::write(
                    admin.join("gitdir"),
                    format!("{}\n", self.path(folder).join(".git").display()),
                )
                .unwrap();
            }
        }

        /// Candidates of a scan of `root` (relative to the scratch dir) as
        /// (path relative to the scratch dir, kind id).
        pub(super) fn found(&self, root: &str, home: Option<&str>) -> Vec<(String, &'static str)> {
            let base = self.path(root);
            let tree = crate::scan(&base, &crate::Progress::default());
            let anchors = Anchors::new(home.map(|h| self.path(h)).as_deref());
            let mut v: Vec<_> = find(&tree, 0, &anchors)
                .iter()
                .map(|c| {
                    let full = tree.path(c.node as usize);
                    let rel = full
                        .strip_prefix(&self.0)
                        .unwrap()
                        .to_str()
                        .unwrap()
                        .to_string();
                    (rel, c.kind.id())
                })
                .collect();
            v.sort();
            v
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn a_submodule_or_separate_git_dir_repo_is_not_a_linked_worktree() {
        let s = Scratch::new("submodule");
        // main/.git is the parent repository; vendor/sub is its submodule.
        s.file("main/.git/modules/sub/HEAD", b"ref: refs/heads/main\n");
        s.file("main/src/x", b"x");
        s.gitdir_file("main/vendor/sub", "../../.git/modules/sub");
        // An absolute gitdir does the same.
        s.file("main/.git/modules/abs/HEAD", b"ref: refs/heads/main\n");
        s.gitdir_file(
            "main/vendor/abs",
            &s.path("main/.git/modules/abs").display().to_string(),
        );
        // A repository created with --separate-git-dir, even one whose git
        // directory sits under a folder named `worktrees`.
        s.file("elsewhere/proj.git/HEAD", b"ref: refs/heads/main\n");
        s.gitdir_file(
            "loose/proj",
            &s.path("elsewhere/proj.git").display().to_string(),
        );
        s.file("worktrees/proj2.git/HEAD", b"ref: refs/heads/main\n");
        s.gitdir_file(
            "loose/proj2",
            &s.path("worktrees/proj2.git").display().to_string(),
        );
        // A real linked worktree.
        let admin = s.admin("main", "feature");
        s.gitdir_file("main/feature-wt", &admin.display().to_string());

        // Scanned from below the parent repo: the submodule is not a worktree.
        assert_eq!(s.found("main/vendor", None), expect(&[]));
        // Scanned from above, nothing but the linked worktree is.
        assert_eq!(
            s.found("", None),
            expect(&[("main/feature-wt", "git_worktree")])
        );
    }

    #[test]
    fn a_copied_worktree_or_a_garbage_admin_dir_is_not_a_linked_worktree() {
        let s = Scratch::new("backlink");
        let admin = s.admin("main", "w");
        s.gitdir_file("orig", &admin.display().to_string());
        // `cp -R orig copy`: the same .git file, but the admin dir's `gitdir`
        // still names orig/.git.
        s.file(
            "copy/.git",
            format!("gitdir: {}\n", admin.display()).as_bytes(),
        );
        s.file("copy/payload", b"x");
        // A commondir that names nothing, one that names the admin dir itself
        // (not the folder that holds `worktrees`), and one that is a link.
        s.file("fake/worktrees/w/commondir", b"garbage\n");
        s.file(
            "fake/worktrees/w/gitdir",
            format!("{}\n", s.path("fakewt/.git").display()).as_bytes(),
        );
        s.gitdir_file("fakewt", &s.path("fake/worktrees/w").display().to_string());
        s.file("self/worktrees/w/commondir", b".\n");
        s.gitdir_file("selfwt", &s.path("self/worktrees/w").display().to_string());
        s.file("link/worktrees/w/real", b"../..\n");
        std::os::unix::fs::symlink("real", s.path("link/worktrees/w/commondir")).unwrap();
        s.gitdir_file("linkwt", &s.path("link/worktrees/w").display().to_string());
        // A missing, empty or multi-line back link.
        for (name, back) in [
            ("noback", None),
            ("emptyback", Some("")),
            ("twoback", Some("a\nb\n")),
        ] {
            let admin = s.admin("main", name);
            s.gitdir_file(name, &admin.display().to_string());
            let file = admin.join("gitdir");
            match back {
                None => std::fs::remove_file(file).unwrap(),
                Some(text) => std::fs::write(file, text).unwrap(),
            }
        }
        assert_eq!(s.found("", None), expect(&[("orig", "git_worktree")]));
    }

    #[test]
    fn codex_worktrees_are_found_one_or_two_levels_down() {
        let s = Scratch::new("codex");
        // Codex's layout: ~/.codex/worktrees/<id>/<repo> is the linked worktree.
        let admin = s.admin("code/app", "w1");
        s.gitdir_file(".codex/worktrees/a1b2/app", &admin.display().to_string());
        s.file(".codex/worktrees/a1b2/app/node_modules/x", b"x");
        s.file(".codex/worktrees/a1b2/app/package.json", b"{}");
        // The older shape, with the worktree at the first level.
        let admin = s.admin("code/lib", "w2");
        s.gitdir_file(".codex/worktrees/c3d4", &admin.display().to_string());
        // Real install on the dev machine: user artifacts, no .git anywhere.
        s.file(
            ".codex/worktrees/git-client-release/artifacts/GitPulse.zip",
            b"zip",
        );
        s.file(".codex/worktrees/git-client-release/evidence/a.json", b"{}");
        // A full clone is a repository, never a leftover.
        s.file(".codex/worktrees/e5f6/.git/HEAD", b"ref: refs/heads/main\n");
        s.file(".codex/worktrees/e5f6/work", b"x");
        s.file(
            ".codex/worktrees/g7h8/repo/.git/HEAD",
            b"ref: refs/heads/main\n",
        );
        s.file(".codex/worktrees/g7h8/repo/work", b"x");
        // A submodule's .git file is not a linked worktree either.
        s.file("code/app/.git/modules/m/HEAD", b"ref: refs/heads/main\n");
        s.gitdir_file(
            ".codex/worktrees/i9j0/m",
            "../../../../code/app/.git/modules/m",
        );

        let want = expect(&[
            (".codex/worktrees/a1b2/app", "git_worktree"),
            (".codex/worktrees/a1b2/app/node_modules", "node_modules"),
            (".codex/worktrees/c3d4", "git_worktree"),
        ]);
        assert_eq!(s.found("", Some("")), want);
        // The same folders carry the git_worktree verifier.
        assert_eq!(Kind::GitWorktree.verify(), Some("git_worktree"));
    }

    #[test]
    fn home_rules_follow_the_data_volume_alias_and_roots_inside_home() {
        let paths = [
            "Users/u/.cache/pip/x",
            "Users/u/.cargo/registry/x",
            "Users/u/.cargo/bin/x",
        ];
        let expected = expect(&[
            ("Users/u/.cache/pip", "tool_caches"),
            ("Users/u/.cargo/registry", "cargo_cache"),
        ]);
        let t = build("/System/Volumes/Data", &paths);
        assert_eq!(found(&t, Some("/Users/u")), expected);
        let t = build("/", &paths);
        assert_eq!(found(&t, Some("/Users/u")), expected);
        // A scan rooted inside the home anchors by the root's own path.
        let t = build("/Users/u/.cache", &["pip/x", "uv/x"]);
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[("pip", "tool_caches"), ("uv", "tool_caches")])
        );
        let t = build("/Users/u/Library/", &["Caches/com.example/x"]);
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[("Caches/com.example", "app_caches")])
        );
        // Outside the home, home rules never match, but a .cache is a container wherever it is.
        let t = build("/Volumes/X", &[".cache/pip/x", ".cargo/registry/x"]);
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[(".cache/pip", "tool_caches")])
        );
    }

    /// The complete rule set. Every row of the old nine-rule table whose
    /// behavior is unchanged is kept; changed rows say what changed. Each row
    /// is an independent tree: (root, home, entries, expected candidates).
    #[test]
    #[allow(clippy::type_complexity)]
    fn recognizes_the_cleanup_category_rules_and_no_others() {
        const H: Option<&str> = Some("/Users/u");
        #[rustfmt::skip]
        let cases: &[(&str, Option<&str>, &[&str], &[(&str, &str)])] = &[
            // Unchanged rows of the original table.
            ("/root", None, &[".venv/x"], &[(".venv", "python_environment")]),
            ("/root", None, &["p/venv/pyvenv.cfg"], &[("p/venv", "python_environment")]),
            ("/root", None, &["p/venv/x"], &[]),
            ("/root", None, &["p/target/x", "p/Cargo.toml"], &[("p/target", "rust_build")]),
            ("/root", None, &["p/target/x"], &[]),
            ("/root", None, &["p/.next/x", "p/package.json"], &[("p/.next", "next_build")]),
            ("/root", None, &["p/.next/x"], &[]),
            ("/root", None, &["Xcode/DerivedData/x"], &[("Xcode/DerivedData", "xcode_derived_data")]),
            ("/root", None, &["other/DerivedData/x"], &[]),
            ("/root", None, &["a/iOS DeviceSupport/x"], &[("a/iOS DeviceSupport", "device_support")]),
            ("/root", None, &["a/macOS DeviceSupport/x"], &[("a/macOS DeviceSupport", "device_support")]),
            ("/root", None, &["a/watchOS DeviceSupport/x"], &[("a/watchOS DeviceSupport", "device_support")]),
            ("/root", None, &["CoreSimulator/Caches/x"], &[("CoreSimulator/Caches", "app_caches")]),
            ("/root", None, &["other/Caches/x"], &[]),
            ("/root", None, &["a/.cache/x"], &[]),
            ("/root", None, &["a/.cache/pip/x"], &[("a/.cache/pip", "tool_caches")]),
            ("/root", None, &["a/.npm/x"], &[("a/.npm", "tool_caches")]),
            ("/root", None, &["a/.gradle/x"], &[("a/.gradle", "tool_caches")]),
            ("/root", None, &[".bun/install/cache/x"], &[(".bun/install/cache", "bun_cache")]),
            ("/root", None, &["other/install/cache/x"], &[]),
            ("/root", None, &[".bun/other/cache/x"], &[]),
            ("/Users/u", H, &["Downloads/x"], &[]),
            // Changed: node_modules needs package.json (global npm prefixes are installed CLIs).
            ("/root", None, &["p/node_modules/x", "p/package.json"], &[("p/node_modules", "node_modules")]),
            ("/root", None, &["lib/node_modules/npm/package.json", "lib/node_modules/npm/node_modules/x"], &[]),
            // Changed: Library/Caches is a container at home, whole when deeper in
            // the home, skipped elsewhere (system /Library/Caches, other users).
            ("/Users/u", H, &["Library/Caches/a/x", "Library/Caches/com.apple.b/x"], &[("Library/Caches/a", "app_caches")]),
            ("/Users/u", H, &["Library/Containers/c/Data/Library/Caches/x"], &[("Library/Containers/c/Data/Library/Caches", "app_caches")]),
            ("/", H, &["Library/Caches/x", "Users/v/Library/Caches/x"], &[]),
            ("/root", None, &["a/Library/Caches/x"], &[]),
            // Changed: ~/.cache is a container; elsewhere .cache stays whole.
            ("/Users/u", H, &[".cache/pip/x", ".cache/torch/x", ".cache/huggingface/token",
                ".cache/huggingface/xet/x", ".cache/huggingface/hub/models--a/x",
                ".cache/huggingface/hub/datasets--b/x", ".cache/huggingface/hub/spaces--c/x",
                ".cache/huggingface/hub/.locks/x"],
                &[(".cache/pip", "tool_caches"), (".cache/torch", "ml_model"),
                  (".cache/huggingface/hub/models--a", "ml_model"),
                  (".cache/huggingface/hub/datasets--b", "ml_model"),
                  (".cache/huggingface/hub/spaces--c", "ml_model")]),
            // Changed: a Gradle user home (config inside, or at home) is a container.
            ("/Users/u", H, &[".gradle/caches/x", ".gradle/wrapper/x", ".gradle/daemon/x", ".gradle/jdks/x",
                ".gradle/native/x", ".gradle/.tmp/x", ".gradle/init.d/x", ".gradle/workers/x"],
                &[(".gradle/caches", "gradle_cache"), (".gradle/wrapper", "gradle_cache"),
                  (".gradle/daemon", "gradle_cache"), (".gradle/jdks", "gradle_cache"),
                  (".gradle/workers", "gradle_cache")]),
            ("/root", None, &["g/.gradle/gradle.properties", "g/.gradle/caches/x"], &[("g/.gradle/caches", "gradle_cache")]),
            ("/Users/u", H, &[".cache/gradle/gradle.properties", ".cache/gradle/caches/x", ".cache/pip/x"],
                &[(".cache/gradle/caches", "gradle_cache"), (".cache/pip", "tool_caches")]),
            // New home rules.
            ("/Users/u", H, &[".cargo/registry/x", ".cargo/git/x", ".cargo/bin/x", ".cargo/config.toml", ".cargo/env/x"],
                &[(".cargo/git", "cargo_cache"), (".cargo/registry", "cargo_cache")]),
            ("/root", None, &["p/.cargo/registry/x"], &[]),
            ("/Users/u", H, &[".m2/repository/x", ".m2/settings.xml", ".m2/wrapper/x"], &[(".m2/repository", "maven_repository")]),
            ("/Users/u", H, &[".ollama/models/x", ".ollama/id_ed25519"], &[(".ollama/models", "ollama_models")]),
            ("/Users/u", H, &[".rustup/toolchains/stable/x", ".rustup/downloads/x", ".rustup/tmp/x", ".rustup/update-hashes/x"],
                &[(".rustup/downloads", "tool_caches"), (".rustup/tmp", "tool_caches"),
                  (".rustup/toolchains/stable", "rust_toolchain")]),
            ("/Users/u", H, &[".claude/projects/p1/s.jsonl", ".claude/file-history/x", ".claude/debug/x",
                ".claude/settings.json", ".claude/local/package.json", ".claude/local/node_modules/x"],
                &[(".claude/debug", "agent_logs"), (".claude/file-history", "agent_checkpoints"),
                  (".claude/projects/p1", "agent_transcripts")]),
            ("/Users/u", H, &[".codex/sessions/2025/x", ".codex/sessions/misc/x", ".codex/archived_sessions/x",
                ".codex/worktrees/a/.git", ".codex/worktrees/a/package.json", ".codex/worktrees/a/node_modules/x",
                ".codex/worktrees/b/x", ".codex/auth.json", ".codex/config.toml"],
                &[(".codex/archived_sessions", "codex_sessions"), (".codex/sessions/2025", "codex_sessions"),
                  (".codex/worktrees/a", "git_worktree"), (".codex/worktrees/a/node_modules", "node_modules")]),
            // Codex's own layout: the worktree is <id>/<repo>.
            ("/Users/u", H, &[".codex/worktrees/c/app/.git", ".codex/worktrees/c/app/package.json",
                ".codex/worktrees/c/app/node_modules/x", ".codex/worktrees/c/notes/x", ".codex/worktrees/d/x/y"],
                &[(".codex/worktrees/c/app", "git_worktree"), (".codex/worktrees/c/app/node_modules", "node_modules")]),
            // A full clone is never a leftover or a worktree.
            ("/Users/u", H, &[".codex/worktrees/e/.git/HEAD", ".codex/worktrees/e/x", ".codex/worktrees/f/r/.git/HEAD"], &[]),
            ("/Users/u", H, &["Library/Application Support/Code/Cache/x", "Library/Application Support/Code/User/x",
                "Library/Application Support/Slack/GPUCache/x"],
                &[("Library/Application Support/Code/Cache", "app_caches"),
                  ("Library/Application Support/Slack/GPUCache", "app_caches")]),
            ("/root", None, &["Application Support/Code/Cache/x"], &[]),
            // Xcode.
            ("/root", None, &["Xcode/Archives/x", "Xcode/UserData/Previews/x", "Developer/XCTestDevices/x"],
                &[("Developer/XCTestDevices", "xcode_test_devices"), ("Xcode/Archives", "xcode_archives"),
                  ("Xcode/UserData/Previews", "xcode_previews")]),
            // Changed: marker-gated project build output (was not recognized).
            ("/root", None, &["s/.build/x", "s/Package.swift"], &[("s/.build", "swift_build")]),
            ("/root", None, &["s/.build/x"], &[]),
            ("/root", None, &["g/build/x", "g/build.gradle.kts"], &[("g/build", "gradle_build")]),
            ("/root", None, &["g/build/x"], &[]),
            ("/root", None, &["d/.dart_tool/x", "d/pubspec.yaml"], &[("d/.dart_tool", "dart_build")]),
            ("/root", None, &["j/.turbo/x", "j/.angular/x", "j/package.json"], &[("j/.angular", "js_build_cache"), ("j/.turbo", "js_build_cache")]),
            ("/root", None, &["j/.turbo/x"], &[]),
            ("/root", None, &["i/Pods/x", "i/Podfile"], &[("i/Pods", "cocoapods")]),
            ("/root", None, &["py/.tox/x", "py/.nox/x", "py/tox.ini"], &[("py/.nox", "python_test_environments"), ("py/.tox", "python_test_environments")]),
            ("/root", None, &["py/.tox/x", "py/.nox/x"], &[]),
            ("/root", None, &["z/zig-out/x", "z/.zig-cache/x", "z/build.zig"], &[("z/.zig-cache", "zig_build"), ("z/zig-out", "zig_build")]),
            ("/root", None, &["e/_build/x", "e/deps/x", "e/mix.exs"], &[("e/_build", "elixir_build"), ("e/deps", "elixir_build")]),
            ("/root", None, &["e/deps/x"], &[]),
            ("/root", None, &["h/.stack-work/x", "h/dist-newstyle/x", "h/stack.yaml"], &[("h/.stack-work", "haskell_build"), ("h/dist-newstyle", "haskell_build")]),
            ("/root", None, &["h/.stack-work/x", "h/dist-newstyle/x"], &[]),
            // Structure rules come after every named rule.
            ("/root", None, &["r/target/CACHEDIR.TAG", "r/target/x", "r/Cargo.toml"], &[("r/target", "rust_build")]),
            ("/root", None, &["c/CACHEDIR.TAG/x"], &[]),
            ("/root", None, &["w/.git/x"], &[]),
            ("/root", None, &["Downloads/x"], &[]),
        ];
        for (root, home, paths, expected) in cases {
            assert_eq!(
                found(&build(root, paths), *home),
                expect(expected),
                "{root} {paths:?}"
            );
        }
    }

    /// Every ancestor-name rule must match when that ancestor is the scan
    /// root, whose node name is a full path.
    #[test]
    #[allow(clippy::type_complexity)]
    fn ancestor_name_rules_match_when_the_ancestor_is_the_scan_root() {
        const H: Option<&str> = Some("/Users/u");
        #[rustfmt::skip]
        let cases: &[(&str, Option<&str>, &[&str], &[(&str, &str)])] = &[
            ("/Users/u/Library/Developer/Xcode", None, &["DerivedData/x", "Archives/x"],
                &[("Archives", "xcode_archives"), ("DerivedData", "xcode_derived_data")]),
            ("/Users/u/Library/Developer/Xcode/UserData", None, &["Previews/x"], &[("Previews", "xcode_previews")]),
            ("/Users/u/Library/Developer", None, &["XCTestDevices/x", "CoreSimulator/Caches/x"],
                &[("CoreSimulator/Caches", "app_caches"), ("XCTestDevices", "xcode_test_devices")]),
            ("/Users/u/Library/Developer/CoreSimulator", None, &["Caches/x"], &[("Caches", "app_caches")]),
            ("/x/.bun", None, &["install/cache/x"], &[("install/cache", "bun_cache")]),
            ("/x/.bun/install", None, &["cache/x"], &[("cache", "bun_cache")]),
            ("/Users/u/Library", H, &["Caches/a/x"], &[("Caches/a", "app_caches")]),
            ("/Users/u/Library/Caches", H, &["a/x", "com.apple.b/x"], &[("a", "app_caches")]),
            ("/Users/u/Library/Containers/c/Data/Library", H, &["Caches/x"], &[("Caches", "app_caches")]),
            ("/Library", H, &["Caches/x"], &[]),
            ("/Users/u/Library/Application Support", H, &["Code/Cache/x"], &[("Code/Cache", "app_caches")]),
            ("/Users/u/Library/Application Support/Code", H, &["Cache/x"], &[("Cache", "app_caches")]),
            ("/repo/.claude/worktrees", None, &["a/.git", "a/x"], &[("a", "git_worktree")]),
            ("/root/p", None, &["node_modules/x", "package.json"], &[("node_modules", "node_modules")]),
            ("/Users/u/.gradle", H, &["caches/x", "native/x"], &[("caches", "gradle_cache")]),
            ("/elsewhere/.gradle", None, &["caches/x", "gradle.properties"], &[("caches", "gradle_cache")]),
            ("/Users/u/.cargo", H, &["registry/x", "bin/x"], &[("registry", "cargo_cache")]),
            ("/Users/u/.claude/projects", H, &["p/s.jsonl"], &[("p", "agent_transcripts")]),
            ("/Users/u/.codex/sessions", H, &["2024/x", "misc/x"], &[("2024", "codex_sessions")]),
            ("/Users/u/.codex/worktrees", H, &["a/.git", "a/x", "b/x", "c/r/.git", "c/r/x"], &[("a", "git_worktree"), ("c/r", "git_worktree")]),
            ("/Users/u/.cache/huggingface", H, &["hub/models--a/x", "token", "xet/x"], &[("hub/models--a", "ml_model")]),
            ("/Users/u/.cache/huggingface/hub", H, &["models--a/x", ".locks/x"], &[("models--a", "ml_model")]),
            ("/Users/u/.rustup/toolchains", H, &["stable/x"], &[("stable", "rust_toolchain")]),
            ("/System/Volumes/Data/Users/u", H, &[".cache/pip/x"], &[(".cache/pip", "tool_caches")]),
            ("/Users/u/", H, &[".cache/pip/x"], &[(".cache/pip", "tool_caches")]),
        ];
        for (root, home, paths, expected) in cases {
            assert_eq!(
                found(&build(root, paths), *home),
                expect(expected),
                "{root} {paths:?}"
            );
        }
    }

    /// The root-seeding table and the walk must agree for every container.
    #[test]
    fn every_home_container_is_the_same_as_a_root_and_inside_the_walk() {
        for (rel, _) in HOME_CONTAINERS {
            let prefix = rel.join("/");
            let children = [
                "models--m/x",
                "registry/x",
                "caches/x",
                "projects/x",
                "2025/x",
                "a/x",
                "hub/x",
                "toolchains/x",
            ];
            let nested: Vec<String> = children.iter().map(|c| format!("{prefix}/{c}")).collect();
            let nested: Vec<&str> = nested.iter().map(String::as_str).collect();
            let from_home = found(&build("/Users/u", &nested), Some("/Users/u"));
            let from_root = found(
                &build(&format!("/Users/u/{prefix}"), &children),
                Some("/Users/u"),
            );
            let rebased: Vec<_> = from_root
                .into_iter()
                .map(|(p, k)| (format!("{prefix}/{p}"), k))
                .collect();
            assert_eq!(from_home, rebased, "{prefix}");
        }
    }

    #[test]
    fn the_home_and_its_ancestors_are_never_candidates() {
        // A dotfiles `.git` file or a stray CACHEDIR.TAG must not make the home one.
        let t = build(
            "/",
            &[
                "Users/CACHEDIR.TAG",
                "Users/u/.git",
                "Users/u/p/package.json",
                "Users/u/p/node_modules/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[("Users/u/p/node_modules", "node_modules")])
        );
        // Without a home anchor the same tree reports the tagged folder (review in Swift).
        assert_eq!(found(&t, None), expect(&[("Users", "tagged_cache")]));
        // Nor folders the Swift guard always refuses: broad home folders and the
        // home's direct non-dot children. Marked ones are still looked into.
        let t = build(
            "/Users/u",
            &[
                "Library/CACHEDIR.TAG",
                "Library/Developer/.git",
                "Library/Developer/x",
                "Downloads/CACHEDIR.TAG",
                "Downloads/x",
                "wt/.git",
                "wt/package.json",
                "wt/node_modules/x",
                "node_modules/x",
                "package.json",
                "Pods/x",
                "Podfile",
                ".hidden/CACHEDIR.TAG",
                ".hidden/x",
            ],
        );
        assert_eq!(
            found(&t, Some("/Users/u")),
            expect(&[
                (".hidden", "tagged_cache"),
                ("wt/node_modules", "node_modules")
            ])
        );
    }

    #[test]
    fn anchors_reject_unusable_homes_and_add_the_data_volume_spelling() {
        for bad in ["relative", "/", "/Users/../etc", ""] {
            assert_eq!(
                Anchors::new(Some(Path::new(bad))),
                Anchors::default(),
                "{bad}"
            );
        }
        assert_eq!(Anchors::new(None), Anchors::default());
        let a = Anchors::new(Some(Path::new("/Users/u/")));
        let b = Anchors::new(Some(Path::new("/System/Volumes/Data/Users/u")));
        assert_eq!(a.homes.len(), 2);
        assert_eq!(a.homes[0], b.homes[1]);
        assert_eq!(a.homes[1], b.homes[0]);
    }

    #[test]
    fn kind_metadata_is_complete_and_consistent() {
        let mut ids = std::collections::HashSet::new();
        for &kind in Kind::ALL {
            assert!(ids.insert(kind.id()), "duplicate id {}", kind.id());
            assert_eq!(kind.c_id().to_str().unwrap(), kind.id());
            assert!(!kind.id().is_empty() && !kind.description().is_empty());
            assert_eq!(kind.descends(), kind == Kind::GitWorktree);
            assert!(matches!(
                kind.verify(),
                None | Some("cachedir_tag" | "git_worktree" | "recent_activity" | "agent_session")
            ));
            assert_eq!(
                kind.c_verify().to_str().unwrap(),
                kind.verify().unwrap_or("")
            );
            assert!(Section::ALL.contains(&kind.section()));
        }
        assert_eq!(Kind::ALL.len(), 34);
        for (kind, id) in [
            (Kind::NodeModules, "node_modules"),
            (Kind::PythonEnvironment, "python_environment"),
            (Kind::RustBuild, "rust_build"),
            (Kind::NextBuild, "next_build"),
            (Kind::XcodeDerivedData, "xcode_derived_data"),
            (Kind::DeviceSupport, "device_support"),
            (Kind::AppCaches, "app_caches"),
            (Kind::ToolCaches, "tool_caches"),
            (Kind::BunCache, "bun_cache"),
        ] {
            assert_eq!(kind.id(), id, "existing ids are stable");
        }
        let sections: Vec<_> = Section::ALL.iter().map(|s| s.id()).collect();
        assert_eq!(
            sections,
            [
                "build",
                "packages",
                "apps",
                "devtools",
                "models",
                "agents",
                "worktrees"
            ]
        );
        assert_eq!(Section::Build.c_id().to_str().unwrap(), "build");
        assert_eq!((Group::Safe.id(), Group::Review.id()), ("safe", "review"));
        assert_eq!((Group::Safe as u8, Group::Review as u8), (0, 1));
        for review in [
            Kind::MavenRepository,
            Kind::MlModel,
            Kind::GitWorktree,
            Kind::AgentTranscripts,
        ] {
            assert_eq!(review.group(), Group::Review);
        }
    }

    #[test]
    fn enclosing_reports_only_container_parents() {
        let t = build(
            "/w",
            &[
                "wt/.git",
                "wt/package.json",
                "wt/node_modules/x",
                "p/package.json",
                "p/node_modules/x",
            ],
        );
        let f = find_with(&t, MIN_BYTES, &Anchors::default(), &|_| GitFile::Worktree);
        let enc = enclosing(&t, &f);
        for (k, c) in f.iter().enumerate() {
            match rel(&t, c.node).as_str() {
                "wt/node_modules" => assert_eq!(enc[k].map(|e| f[e].kind), Some(Kind::GitWorktree)),
                _ => assert_eq!(enc[k], None),
            }
        }
        assert_eq!(f.len(), 3);
    }

    #[test]
    fn preserves_panel_traversal_threshold_and_partial_candidates() {
        let mut scan = Tree::default();
        add(
            &mut scan,
            NO_PARENT,
            "/root/node_modules",
            true,
            MIN_BYTES * 10,
        );
        let trash = add(&mut scan, 0, ".Trash", true, MIN_BYTES * 2);
        add(&mut scan, 0, ".cache", false, MIN_BYTES * 2);
        let matched = add(&mut scan, 0, "node_modules", true, MIN_BYTES);
        let small = add(&mut scan, 0, ".gradle", true, MIN_BYTES - 1);
        add(&mut scan, 0, "package.json", false, 0);
        add(&mut scan, trash, "node_modules", true, MIN_BYTES * 2);
        add(&mut scan, matched, ".venv", true, MIN_BYTES);
        // Deliberately inconsistent size catches descent under a small match.
        add(&mut scan, small, ".venv", true, MIN_BYTES);
        let mut scan = link(scan);
        scan.complete[matched as usize] = false;
        assert_eq!(
            find(&scan, MIN_BYTES, &Anchors::default()),
            vec![Candidate {
                node: matched,
                kind: Kind::NodeModules
            }]
        );
    }

    #[test]
    fn size_ties_are_lexical_independent_of_discovery_order() {
        for names in [["z", "a"], ["a", "z"]] {
            let mut scan = Tree::default();
            add(&mut scan, NO_PARENT, "/root", true, 0);
            let first = add(&mut scan, 0, names[0], true, MIN_BYTES);
            let second = add(&mut scan, 0, names[1], true, MIN_BYTES);
            let large = add(&mut scan, 0, ".npm", true, MIN_BYTES * 2);
            let first_cache = add(&mut scan, first, ".venv", true, MIN_BYTES);
            let second_cache = add(&mut scan, second, ".venv", true, MIN_BYTES);
            let scan = link(scan);
            let expected = if names[0] == "a" {
                vec![large, first_cache, second_cache]
            } else {
                vec![large, second_cache, first_cache]
            };
            assert_eq!(
                find(&scan, MIN_BYTES, &Anchors::default())
                    .iter()
                    .map(|c| c.node)
                    .collect::<Vec<_>>(),
                expected
            );
        }
    }
}
