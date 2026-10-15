//! `sift` — command-line access to the same index the Sift app keeps live.
//!
//! The window is for the human, this CLI is for scripts and agents: every
//! command talks to the running app over its local socket, so it goes through
//! the same engine, settings path and locks as the window. `search --offline`
//! reads the saved snapshot when the app is not running. Parsing is strict (an
//! unknown option is an error, `--help` never runs a command) and `config.json`
//! is only read by the commands that need it.
//!
//! The functions of the 配置与更新… window (`config status|export|import|sync`,
//! `update check|install`) belong to the app bundle: its preference domain, its version,
//! its release channel. They are answered by the shared command layer inside the app
//! executable (Sources/ProductLifecycle.swift); this CLI hands the words over and
//! brings stdout, stderr and the exit code back unchanged (`lifecycle`).
//!
//! `trash`, `hotkey …` and `login-item …` are things only the app process can do (its
//! permissions, its Carbon registration, its login item). They go over the socket as an
//! `app` request and are done by the functions the window's menu and Settings buttons
//! call (Sources/AppActions.swift).

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use sift_core::{
    config::{Config, ConfigEdit, socket_path_in},
    engine::{SortKey, rebuild_marker},
    ipc::{self, Hit, Request, SocketBlocked, TimedOut},
    offline::Offline,
    service::bundle_info,
};
use std::{
    path::PathBuf,
    process::ExitCode,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const NO_RESULTS: u8 = 1;
const ERROR: u8 = 2;
const NOT_RUNNING: u8 = 3;
const TIMEOUT: u8 = 4;
const BUNDLE_ID: &str = "cyou.tianli.sift";

/// The shared command layer's own help lines for `sift` (AppLifecycleCLI.helpRead and
/// helpWrite in Sources/Shared/AppLifecycleCLI.swift), verbatim. The app's lifecycle
/// self-test looks each of them up in `sift --help`.
macro_rules! lifecycle_reads {
    () => {
        "  config status              「使用 iCloud 记住配置」开关、开关下面那句同步状态、当前可迁移的配置项、App 是否在运行（只读）
  update check               检查更新：当前版本、此渠道最新版本、有没有新版、怎么升级（不改配置或安装；记录本机检查结果；私有渠道读 iCloud Drive 里的发行记录，公开渠道联网读发行记录）"
    };
}
macro_rules! lifecycle_writes {
    () => {
        "  config export -o <file>        导出配置：与窗口「导出配置…」同一份文件；不改设置，只写你指定的那个文件（--force 覆盖；-o - 输出到标准输出，不写文件）
  config import <file> --yes     导入配置：先备份原配置再覆盖，与窗口「导入配置…」相同
  config sync on|off --yes       拨动「使用 iCloud 记住配置」（--dry-run 只看会不会变；用 sift config status 回读）
  update install --yes           升级到新版：与窗口「升级到新版…」同一条路——验证发行包与签名、替换当前 App，运行中的先退出、换好再重开；配置保留，替换失败回滚（--dry-run 只看会做什么；用 sift update check 回读）
  update options [--yes]     查看或保存自动检查/下载/安装、间隔、渠道、跳过与延后选项（--dry-run 只预演）"
    };
}

const HELP: &str = concat!("\
sift — instant file-name search (CLI for Sift.app, same live index as its window)

USAGE:
  sift search <query...> [options]   Search file and folder names (alias: s)
  sift status [--json]               Index state, settings, permissions, app version
  sift config [--json]               Settings: index root, skipped and included folders
  sift config set <changes>          Change settings like Settings › Save & Re-index
  sift history [--json]              The window's recent searches (⌘Y), newest first
  sift history clear --yes           Clear them (the ⌘Y menu's Clear Recent Searches)
  sift trash <path...> --yes         Move to Trash (⌘⌫) for the files or folders you name
  sift hotkey [--json]               The global shortcut: stored, registered, in use or not
  sift hotkey set <combo|cardinal>   Set it (cardinal = ⇧⌘Space, the Settings preset button)
  sift hotkey clear                  Remove it (the Settings Clear button)
  sift login-item [on|off]           Open Sift at login: show it, turn it on or off
  sift rescan [--wait SECS]          Rebuild the index from disk (like ⇧⌘R)
  sift flush                         Save unsaved index changes now
  sift start [--wait SECS]           Start Sift in the background (no window, no focus)
  sift quit [--wait SECS] [--force]  Quit Sift the way ⌘Q does (saves the index)
  sift version [--json]              CLI and Sift.app version/build (also --version, -V)
  sift help <command>                Options of one command (or: sift <command> --help)

The 配置与更新… window as commands, each as `sift <line>` (text, or one JSON object with
--json; the same settings and release channel as the window; `sift help update`):
 read (update check records local check history):
", lifecycle_reads!(), "
 write:
", lifecycle_writes!(), "

READ COMMANDS (change nothing): search, status, config, history, hotkey, login-item,
  version, help, config status, index status, shortcuts list, saved list, file info.
  update check only records local check history. `sift status --json` is the read-back after
  any index or settings write and after login-item on|off; `sift hotkey --json` after
  hotkey set|clear; `sift config status --json` after config import / config sync;
  `sift update check --json` after update install.
WRITE COMMANDS: config set (settings; a real change re-indexes from scratch), rescan
  (rebuilds the index), flush (saves the index), start, quit, history clear, trash (moves
  the files you name to the Trash), hotkey set, hotkey clear, login-item on|off, config
  export (changes no setting, writes only the file you name), config import, config sync,
  update install (replaces Sift.app with the channel's newer release), update options,
  index pause|resume|cancel|set, shortcuts set|clear, saved add|remove, file rename,
  export (writes only the named destination or stdout).
No command opens a window, takes focus, asks for a permission or sends keys.

JSON: read commands print text, or one JSON object with --json. The index write commands
(config set, rescan, flush, start, quit), history clear, trash, hotkey set|clear and
login-item on|off always print one JSON line (--json is accepted).
  search      {ok, live, total, offset, search_ms, case_insensitive, rebuild_required,
               state, repairing, results:[{path, kind, size, mtime, ctime}], loosened?:actual_query}
              loosened is present only when a zero-result strict query found rows after expansion
  status      {ok, running, live, state, files, events, walks, rebuild_required, repairing,
               root, ignore_paths, include_paths, full_disk_access, login_item, app, pid,
               gui:{case_insensitive, show_folder_scope, hotkey}}; while Sift is not
               running: {ok:true, running:false, exit:3, snapshot, root, …, gui}
  config      {ok, root, ignore_paths, include_paths, support_dir, source}
  history     {ok, total, items:[query…]}        history clear  {ok, command, cleared}
  trash       {ok, command, count, trashed:[{path, trash_path}]}; when some could not be
               moved: the failure object plus trashed:[…], failed:[{path, error}]
  hotkey      {ok, command, running, hotkey:{stored, combo, display} | null, registered,
               in_use}; hotkey set and hotkey clear add changed. While Sift is not
               running, hotkey prints {ok:true, running:false, exit:3, hotkey (as stored),
               registered:null, in_use:null}
  login-item  {ok, command, running, login_item (enabled | not_registered |
               requires_approval | not_found), enabled}; on|off add action and changed.
               While Sift is not running: {ok:true, running:false, exit:3, login_item:null}
  version     {ok, cli, app:{version, build, identifier, path}}
  config set  {ok, changed, reindexing, saved, dry_run, config, walks_before}
  rescan      {ok, walks_before}        flush  {ok, written}
  start       {ok, started | already_running, pid, state}        quit  {ok, pid}
  config status  {ok, command, has_settings, sync_enabled, sync_status:{text, at, from
                  (app | record | derived), live}, keys:[…], app_running, problem}
  config export  {ok, command, path, bytes, keys:[…]}
  config import  {ok, command, imported, path, sync_enabled, app_running,
                  sync:{completed, status} (only while iCloud sync is on)}
  config sync    {ok, command, action, changed, sync_enabled, status, app_running,
                  check_with}; with --dry-run {…, dry_run, would_change, sync_enabled}
  update check   {ok, command, current:{version, build}, source:{kind, channel},
                  latest:{version, build, …}, update_available, state (update_available |
                  up_to_date | ahead_of_channel), message, upgrade:{in_app, button, how,
                  download_url, command}}
  update install {ok, command, installed, state (installed | up_to_date |
                  ahead_of_channel), message, current, latest, source, app_running}; once
                  installed also previous, backup (null), old_app_cleanup, relaunched;
                  with --dry-run {…, dry_run, would_install:{from, to}, installation,
                  will_quit_app, will_relaunch}
  failure     {\"ok\":false,\"error\":\"reason\",\"exit\":N} on stdout with --json (the reason is
               also on stderr); the process exits with N. The 配置与更新 commands, trash,
               hotkey and login-item add command and code: usage | confirmation_required
               (import, sync, update install, trash without --yes) | file_exists (export
               target exists, no --force) | not_found | import_rejected | export_failed |
               sync_incomplete | check_incomplete | no_settings | manual_install |
               needs_product_installer | upgrade_failed | app_busy | replace_failed |
               cleanup_failed | trash_failed | in_use (hotkey set: previous binding retained
               when the replacement is refused) | invalid_shortcut | login_item_failed |
               unavailable (a --headless Sift) | app_outdated (the running Sift is older
               than this sift) | failed | not_running | app_missing | app_failed | timeout
Whether Sift runs: key on the exit code (3) or `running`, not on `ok` (`status`
still reports the saved index with ok:true, running:false, exit:3).
Socket permission/sandbox denial instead returns {ok:false, code:socket_blocked,
exit:2, error:reason}, with no running field; start does not relaunch. Retry with
~/Dev/tools/dev/lib/tools/cc/guarded-bin/outside-guard -- sift <command>.

EXIT CODES:
  0  ok / results found (update install with nothing newer: 0, installed false)
  1  no results (search); for the 配置与更新 commands, trash, hotkey set and login-item:
     the operation did not complete (code says why: not_found, import_rejected,
     sync_incomplete, upgrade_failed, trash_failed, in_use, …)
  2  error: unknown command or option, bad value, invalid settings, refused action,
     a missing --yes or --force
  3  Sift.app is not running
  4  timed out (--wait, --timeout; a 配置与更新 command that did not end in 60 s,
     update install in 720 s)

WINDOW ONLY / 仅在窗口中 (a person at the window; no command on purpose):
  Open (⌘O, ↩, double-click), Show in Finder (⌘R, ⌘↩), Quick Look (Space): they put a
    file on screen for the person; `sift search` gives the paths
  Copy (⌘C, file objects on the clipboard) and dragging results into other apps
  Selecting rows (↑ ↓, click, multiple selection); commands take paths from `sift search`
  Find / Focus Search Field (⌘F, ⌘L, Tab) and the Edit menu's text editing in the fields
  Search Window (⌘0), Esc, Close Window, Minimize, Hide Sift / Hide Others / Show All,
    and showing or hiding the window with the global shortcut
  Resizing the window, column widths and order
  Settings… (⌘,) and 配置与更新… as windows (打开「配置与更新…」窗口); their values are
    `sift config`, `sift status`, `sift config status`
  Recording the global shortcut: a real key press (`sift hotkey set` takes a named
    combination instead; the stored one is `sift hotkey` and status gui.hotkey)
  Grant Full Disk Access… / Full Disk Access…: only a person can grant it in System
    Settings; `sift status` reports full_disk_access

SIFT_SUPPORT_DIR points the app and the CLI at another index/settings folder
(tests, side-by-side runs); the default is ~/Library/Application Support/cyou.tianli.sift.
SIFT_PREFS_DOMAIN points the CLI's read of the window's preferences (status gui,
history) at another defaults domain or plist path (tests).");

const PRODUCT_HELP: &str = "\
Sift 运行、快捷键和常用搜索（窗口与 CLI 共用业务）
  sift index [status|pause|resume|cancel] [--json]
  sift index set [--auto-repair on|off] [--auto-save on|off]
  sift shortcuts list [--json]
  sift shortcuts set <action> <combo> [--scope app|global]
  sift shortcuts clear <action|all|defaults>
  sift saved list [--json]
  sift saved add <name> <query> [--dir <folder>] [--case]
  sift saved remove <name>
  sift file info <path> [--json]
  sift file rename <path> <new-name> --yes
  sift export <query> [-o <file>] [--format json|csv|paths] [--force]
动作输出一行 JSON。index/shortcuts/saved/file 需要 App 在运行（退出 3）。
export 只读同一搜索引擎；默认 50 条，--limit 0 全部，可 --offline、--dir、--sort、--desc。
export -o 不覆盖已有文件，除非 --force；路径必须由用户显式指定。\n";

const TRASH_HELP: &str = "\
sift trash <path...> --yes [--timeout SECS]

Moves the named files or folders to the Trash, like File › Move to Trash (⌘⌫) on the
selected results: the running Sift does it with the same call (NSWorkspace recycle), so
Finder's Put Back restores them and Sift's own permissions apply (Full Disk Access).
The window asks in a dialog; the command asks for --yes. Paths come from `sift search`
(or anywhere); a relative path is resolved where the command was typed, and a symlink
is moved itself, not what it points to. An open search in the window is run again.

  --yes             Required. Without it nothing is moved (exit 2, confirmation_required)
  --timeout <SECS>  Give up waiting for Sift after SECS (default 120; exit 4)
  --json            Accepted; the output is always one JSON line

Refused before anything is moved (nothing is sent to Sift): a path that does not exist
(exit 1, not_found, with missing:[…]), the filesystem root and your home folder (exit 2).
Prints {\"ok\":true,\"command\":\"trash\",\"count\":N,\"trashed\":[{\"path\",\"trash_path\"}]}. When
the system could not move some of them, exit 1 with code trash_failed, the ones that did
move in trashed and the rest in failed:[{path, error}]. Read back with `sift search`
(the index follows within moments) or by looking at the path.

EXIT: 0 all moved, 1 not_found / trash_failed, 2 error or missing --yes, 3 app not
running (`sift start`), 4 timeout";

const HOTKEY_HELP: &str = "\
sift hotkey [--json]
sift hotkey set <combo|cardinal>
sift hotkey clear

The system-wide shortcut that shows or hides Sift from any app (Settings › Show/hide
Sift from any app). Off by default. The running Sift holds the registration, so all
three need it (exit 3 otherwise; `sift hotkey` then still prints the stored one).

`sift hotkey` prints what Settings shows: the stored combination, whether Sift has it
registered, and in_use, the window's orange note. If the replacement is occupied,
the previous stored combination and registration are retained.

`sift hotkey set <combo>` does what recording a combination in Settings does: registers
it before saving. <combo> is modifiers and a key joined by +, as `sift hotkey`
and status gui.hotkey print it: cmd+shift+space, option+ctrl+k, cmd+keycode96 (a key
without a name here, by its virtual key code). Modifiers: cmd, option, ctrl, shift, typed
in any order (they are printed in that one); at least one, and not shift alone. `cardinal`
is the Settings button Use ⇧⌘Space (as in Cardinal). The stored form
<keyCode>:<modifierFlags> is accepted too.
When the system refuses the replacement, the previous shortcut stays active and stored;
the command fails: exit 1, code in_use, with the same fields.

`sift hotkey clear` is the Clear button: the combination is unregistered and forgotten.

An open Settings window follows both. set and clear always print one JSON line:
{ok, command, running, hotkey:{stored, combo, display} | null, registered, in_use, changed}.
The shortcut travels with `sift config export` / import and the iCloud copy.

EXIT: 0 ok, 1 in_use (set), 2 error (invalid_shortcut; unavailable on a --headless Sift),
3 app not running, 4 timeout";

const LOGIN_ITEM_HELP: &str = "\
sift login-item [--json]
sift login-item on|off

Settings › Open Sift at login. The running Sift registers itself with macOS
(SMAppService), exactly as the checkbox does, so it needs the running app (exit 3
otherwise). Without on|off it prints the current state, which `sift status` also
reports as login_item: enabled | not_registered | requires_approval (macOS wants the
owner to allow it in System Settings › General › Login Items) | not_found.

on|off always print one JSON line: {ok, command, running, action, login_item, enabled,
changed}. Asking for the state it already has changes nothing (changed false) and
registers nothing. macOS may show its own \"login item added\" notice when it is turned on.
An open Settings window follows. This setting stays on this Mac (not exported or synced).

EXIT: 0 ok, 1 login_item_failed (macOS refused; the reason is in error), 2 error
(unavailable on a --headless Sift), 3 app not running, 4 timeout";

const SEARCH_HELP: &str = "\
sift search <query...> [options]        (alias: sift s)

Searches the running app's live index through the same engine as the window.
Without the app, --offline reads the saved snapshot instead; that loads the whole
index for every call (about 10–40 s and 0.5–0.7 GB for ~9M entries) and misses
changes made since the last save.

OPTIONS:
      --dir <query>     Only inside folders matching this query; the window uses one query field
  -i, --ignore-case     Case-insensitive (the window's default)
      --match-case      Case-sensitive (the CLI's default; the JSON echoes the mode)
  -n, --limit <N>       Max results (default 50, 0 = all)
      --offset <N>      Skip the first N results
      --sort <key>      name | path | size | mtime | ctime (window: ⌘1–⌘5). The window starts
                        size and dates descending; here add --desc
      --desc            Reverse order
      --json            One object: ok, live, total, offset, search_ms, case_insensitive,
                        rebuild_required, (live) state, repairing, (offline) snapshot,
                        results[{path, kind, size, mtime, ctime}], loosened?:actual_query
                        loosened reports the actual expanded query only when it found results
      --offline         Read the saved index (no running app needed)
      --timeout <SECS>  Give up after SECS (exit 4) instead of waiting while the index
                        loads or a full rebuild holds it
  --                    Everything after is query text (for a query starting with -)

Query syntax (Cardinal): words AND together, `a|b` OR, `!x` NOT, `ext:pdf`, `*.rs`,
`\"exact phrase\"`, `parent:/path`, `size:>1mb`, `dm:today`, `regex:…`. A pasted real
path with spaces or brackets is searched as one phrase.

Loose folder words: a query that finds nothing as written is tried again with folder
names allowed anywhere above the file. `docs/ report`, `docs report` and `docs/report`
then all find names containing `report` at any depth under a folder whose name contains
`docs`. A query that finds something as written is never widened; filters, `!x`,
wildcards, quotes and groups stay literal, and so do words under 3 letters (2 for CJK).

EXIT: 0 results, 1 no results, 2 error, 3 app not running (use --offline), 4 timeout";

const STATUS_HELP: &str = "\
sift status [--json]

Running app: index state (starting | loading | scanning | updating | ready |
rebuild_required | stopped), entries, file events, completed full walks
(walks, last_walk), rebuild/repair flags, snapshot writes, the live settings,
Full Disk Access as Sift itself sees it, the login item, the app version/build,
and the window's preferences (gui: match case default, legacy scope flag, global hotkey).
The legacy show_folder_scope flag is retained for configuration compatibility;
the window always has one query field.

App not running: the saved snapshot (path, bytes, mtime), the rebuild marker,
the settings in config.json and the window's preferences, with ok:true (the report
worked), running:false and exit:3 (also the exit code). Key on `running`.

EXIT: 0 running, 2 error (e.g. invalid config.json while the app is down), 3 not running";

const CONFIG_HELP: &str = "\
sift config [--json]
sift config set <changes> [--dry-run] [--wait SECS]
sift config status | export -o <file> | import <file> --yes | sync on|off --yes
                                   (the 配置与更新… window: `sift help update`)

`sift config` prints what Settings shows: the index root, skipped folders
(ignore_paths) and folders still indexed inside skipped ones (include_paths).

`sift config set` changes them through the running app, exactly like Settings ›
Save & Re-index. A real change re-indexes from scratch: every search, in the window
and here, waits until that walk finishes (minutes for a whole disk, with temporary
CPU and memory use). An edit that changes nothing only rewrites config.json
(changed: false, no re-index). Prints {ok, changed, reindexing, saved, dry_run,
config, walks_before}.

CHANGES (repeatable except --root; ~ allowed, relative paths are rejected):
  --root <PATH>            Index root (an existing folder)
  --ignore-add <PATH>      Skip a folder
  --ignore-remove <PATH>   Stop skipping a folder
  --include-add <PATH>     Still index a folder inside a skipped one
  --include-remove <PATH>  Remove such a folder
  --defaults               Start from the default settings
OPTIONS:
  --dry-run                Show the normalized result without saving (works without the app)
  --wait <SECS>            After a change, wait until the new index is ready (exit 4 on timeout)
  --json                   Accepted; the output is always one JSON line

Needs the running app (exit 3 otherwise): writing config.json behind its back would
leave the saved index unreadable for --offline until a rebuild.";

const RESCAN_HELP: &str = "\
sift rescan [--wait SECS]

Rebuilds the whole index from disk, like Search › Re-index Everything (⇧⌘R). Every
search waits until the walk finishes (minutes for ~9M entries, temporary CPU and
memory). Without --wait it returns at once with {\"ok\":true,\"walks_before\":N}; the
rebuild is done when `sift status --json` shows walks > N and state ready.

  --wait <SECS>   Wait for the rebuilt index to be ready (exit 4 on timeout)
  --json          Accepted; the output is always one JSON line

EXIT: 0 ok, 2 error, 3 app not running, 4 timeout";

const FLUSH_HELP: &str = "\
sift flush [--timeout SECS]

Saves unsaved index changes now (the app otherwise saves after a minute idle, at
most hourly, and on quit). Prints {\"ok\":true,\"written\":true|false}. Refused (exit 2)
while the index needs rebuilding, so the last good snapshot is kept.

  --timeout <SECS>  Give up after SECS (exit 4) if a rebuild holds the index
  --json            Accepted; the output is always one JSON line";

const START_HELP: &str = "\
sift start [--wait SECS] [--headless] [--app PATH] [--log PATH] [--dry-run]

Starts Sift in the background so live commands work:
  open -g -j <Sift.app> --args --background   (no window, never takes focus)
Does nothing when Sift already answers. Refuses when a Sift process runs without
answering, because relaunching it would bring its window forward, and when
config.json is invalid (the app would fall back to indexing the whole disk with
default settings; `sift status` shows the error). With SIFT_SUPPORT_DIR set,
starts a separate instance for that folder.

  --wait <SECS>   Wait until the index answers searches (state ready or
                  rebuild_required); exit 4 on timeout
  --headless      Run the app executable itself with --headless: no Dock icon, window,
                  global hotkey or preference writes (tests, private support dirs)
  --app <PATH>    Sift.app to start (default: the bundle this CLI ships in)
  --log <PATH>    With --headless: append the app's log here (default: discarded)
  --dry-run       Print what would run; start nothing
  --json          Accepted; the output is always one JSON line";

const QUIT_HELP: &str = "\
sift quit [--wait SECS] [--force]

Quits the running app the way ⌘Q does: it saves unsaved index changes and exits.
Live search stops until Sift runs again (`sift start`). Prints {\"ok\":true,\"pid\":N};
when nothing is running, {\"ok\":true,\"running\":false}.

While a full re-index runs (state scanning: `sift rescan`, a `config set` change, the
first index) quitting cancels it: nothing new is saved, the last snapshot is kept and
the next start begins with the index marked for rebuilding. So quit refuses (exit 2)
in that state unless --force is given (⌘Q in the window does not ask; it cancels
the walk the same way).

A running Sift older than this CLI (build 7 or earlier, no quit command) is sent
SIGTERM instead, which it also handles like ⌘Q; the output then has \"via\":\"SIGTERM\".

  --wait <SECS>   Wait until the process has exited (the final save can take up to 30 s);
                  exit 4 on timeout
  --force         Quit even while a full re-index runs (it is cancelled, see above)
  --json          Accepted; the output is always one JSON line";

const HISTORY_HELP: &str = "\
sift history [--json] [--limit N]
sift history clear --yes

The window's recent searches (Search › Recent Searches, ⌘Y, and ↑/↓ in the search
field), newest first. The window records a query when ↩ commits it or a result is
opened or revealed, keeps the newest 50 and shows 20 in its menu. Searches from this
CLI are never recorded. Reads the saved preference; works whether or not Sift runs.

  -n, --limit <N>   At most N entries (default and 0: all)
      --json        {ok, total, items:[query…]} (total counts all saved entries)

`sift history clear --yes` removes them all, like Clear Recent Searches at the end of
the ⌘Y menu (there is no undo; without --yes nothing is removed, exit 2). The saved
preference is cleared and a running Sift is told to drop the copy its window holds, so
its next search does not store the old list again. Works whether or not Sift runs.
Prints {\"ok\":true,\"command\":\"history clear\",\"cleared\":N} (N entries were saved);
read back with `sift history --json`.

EXIT: 0 ok (an empty history too), 2 error (clear without --yes: code
confirmation_required)";

const VERSION_HELP: &str = "\
sift version [--json]        (also: sift --version, sift -V)

Prints the CLI version and the version/build of the Sift.app it ships in.";

const LIFECYCLE_HELP: &str = concat!("\
sift config status [--json]
sift config export -o <file.json> [--force] [--json]
sift config import <file.json> --yes [--json]
sift config sync on|off --yes [--dry-run] [--json]
sift update check [--json]
sift update install --yes [--dry-run] [--json]
sift update options [--auto-check on|off] [--auto-download on|off] [--auto-install on|off]
  [--interval 1..720] [--channel <name>] [--skip <version/build|clear>] [--remind 0..720] [--yes|--dry-run] [--json]

The functions of the 配置与更新… window (Sift menu), on the same settings, the same
release channel and the same installer as the window. Sift.app's own executable does
the work (it opens no window and no index); a running Sift follows the change.
 read (update check records local check history):
", lifecycle_reads!(), "
 write:
", lifecycle_writes!(), "

What travels with an export, an import and the iCloud copy: the global shortcut, the
Match Case default, legacy scope flag (the window always has one query field),
action shortcuts, sort order, named searches,
update options, the index root, skipped/still-included folders and automatic repair/save.
Recent searches,
the window layout, Open Sift at login and Full Disk Access stay on this Mac.

`config import … --yes` and `config sync on --yes` can rewrite config.json (an import
does; the first iCloud sync takes over what another Mac saved). Like `config set` they
need the running app (exit 3 otherwise; `sift start`): it re-indexes with the new
settings, and a config.json changed behind its back would leave the saved index
unreadable for --offline until a rebuild. `config sync off`, `config status`,
`config export` and `update check` work whether or not Sift runs.

`update check` reads the release record of Sift's private channel in iCloud Drive
(the terminal may be asked once for access to iCloud Drive). Nothing is downloaded or
installed; `upgrade.command` and `upgrade.how` say how to upgrade.

`update install --yes` is the window's 升级到新版…: the same lookup, then the release
package and its signature are verified, a running Sift is asked to quit (it saves its
index), Sift.app is replaced, the old one goes to the Trash, and Sift is opened again if
it was running. Settings and the index are kept; a failed replacement is rolled back.
With nothing newer in the channel it does nothing (exit 0, installed false). --dry-run
only says what it would do. It can take minutes (exit 4 after 720 s). Where the window's
button is 下载新版… (this install location or channel cannot be replaced by a command)
it fails with manual_install and gives the package address.

`config status` also carries sync_status, the sentence under the window's switch: from
app (the running Sift shows it right now, live true), record (Sift is not running: what
the last sync left, at says when) or derived (no usable record: the window's initial
sentence for the switch).

Output: Chinese text like the window, or with --json one JSON object on one line:
  config status  {ok, command, has_settings, sync_enabled, sync_status:{text, at, from, live},
                 keys:[…], app_running, problem}
  config export  {ok, command, path, bytes, keys:[…]}
  config import  {ok, command, imported, path, sync_enabled, app_running, sync:{completed, status}}
  config sync    {ok, command, action, changed, sync_enabled, status, app_running, check_with}
                 --dry-run: {…, dry_run, would_change, sync_enabled}, nothing is changed
  update check   {ok, command, current, source, latest, update_available, state, message, upgrade}
  update install {ok, command, installed, state, message, current, latest, source, app_running};
                 installed: previous, backup (null), old_app_cleanup, relaunched;
                 --dry-run: dry_run, would_install:{from, to}, installation, will_quit_app, will_relaunch
  failure        {\"ok\":false,\"command\":…,\"code\":…,\"error\":\"reason\",\"exit\":N}; the reason
                 is also on stderr

EXIT and code:
  0  ok
  1  the operation did not complete: not_found (no such file) · import_rejected (the
     import was refused, the settings are kept) · export_failed · sync_incomplete (the
     switch is on, the first sync did not finish) · check_incomplete (no release record
     was read) · no_settings · manual_install (this channel or install location cannot be
     replaced by a command; the package address is given) · needs_product_installer ·
     upgrade_failed (download or verification failed, the current app is untouched) ·
     app_busy (the running Sift did not quit, nothing was replaced) · replace_failed (not
     replaced; the old app is kept or was put back) · cleanup_failed (the new version is
     verified, the old bundle could not be cleared away and is kept) · failed ·
     app_missing / app_failed (Sift.app's executable could not be run or was killed)
  2  usage (wrong arguments) · confirmation_required (import, sync, update install
     without --yes) · file_exists (the export target exists; add --force)
  3  not_running (config import, config sync on: start Sift first)
  4  timeout (no answer within 60 s, update install 720 s; read `sift config status` or
     `sift update check` before trying again)");

/// A failure with its own exit code (anything else exits 2).
#[derive(Debug)]
struct Exit {
    code: u8,
    message: String,
}

impl std::fmt::Display for Exit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Exit {}

fn fail(code: u8, message: impl Into<String>) -> anyhow::Error {
    Exit { code, message: message.into() }.into()
}

fn not_running(hint: &str) -> anyhow::Error {
    fail(NOT_RUNNING, format!("Sift.app is not running{hint}"))
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let as_json = args.iter().take_while(|a| *a != "--").any(|a| a == "--json")
        || args.first().is_some_and(|s| ["index","shortcuts","saved","file","export"].contains(&s.as_str()));
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            let code = match (e.downcast_ref::<Exit>(), e.downcast_ref::<TimedOut>()) {
                (Some(exit), _) => exit.code,
                (None, Some(_)) => TIMEOUT,
                _ => ERROR,
            };
            if as_json {
                let mut out = json!({"ok": false, "error": format!("{e:#}"), "exit": code});
                if e.downcast_ref::<SocketBlocked>().is_some() {
                    out["code"] = json!("socket_blocked");
                }
                if code == NOT_RUNNING {
                    out["running"] = json!(false);
                }
                println!("{out}");
            }
            eprintln!("sift: {e:#}");
            ExitCode::from(code)
        }
    }
}

fn run(args: &[String]) -> Result<u8> {
    let Some((cmd, rest)) = args.split_first() else {
        return show_help(None);
    };
    match cmd.as_str() {
        "-h" | "--help" => show_help(None),
        // `sift help config set` works unquoted, like `sift config set --help`.
        "help" => match rest {
            [] => show_help(None),
            words => show_help(Some(&words.join(" "))),
        },
        "-V" | "--version" | "version" => version(rest),
        "search" | "s" => search(rest),
        "status" => status(rest),
        "index" => index_control(rest),
        "shortcuts" | "saved" | "file" => product_action(cmd, rest),
        "export" => export_results(rest),
        "history" => match rest.first().map(String::as_str) {
            Some("clear") => history_clear(args),
            _ => history(rest),
        },
        "config" => match rest.first().map(String::as_str) {
            Some("set") => config_set(&rest[1..]),
            Some("status" | "export" | "import" | "sync") => lifecycle(args),
            _ => config(rest),
        },
        "update" => lifecycle(args),
        "trash" => trash(rest),
        "hotkey" => match rest.first().map(String::as_str) {
            Some("set") => hotkey_set(&rest[1..]),
            Some("clear") => hotkey_clear(&rest[1..]),
            _ => hotkey(rest),
        },
        "login-item" => login_item(rest),
        "rescan" => rescan(rest),
        "flush" => flush(rest),
        "start" => start(rest),
        "quit" => quit(rest),
        other => bail!("unknown command {other:?} (see `sift --help`)"),
    }
}

fn show_help(topic: Option<&str>) -> Result<u8> {
    if topic.is_none() { println!("{HELP}\n{PRODUCT_HELP}"); return Ok(0); }
    let text = match topic {
        None => HELP,
        Some("search" | "s") => SEARCH_HELP,
        Some("status") => STATUS_HELP,
        Some("index" | "shortcuts" | "saved" | "file" | "export") => PRODUCT_HELP,
        Some("config" | "config set") => CONFIG_HELP,
        Some("rescan") => RESCAN_HELP,
        Some("flush") => FLUSH_HELP,
        Some("start") => START_HELP,
        Some("quit") => QUIT_HELP,
        Some("history" | "history clear") => HISTORY_HELP,
        Some("version") => VERSION_HELP,
        Some("trash") => TRASH_HELP,
        Some("hotkey" | "hotkey set" | "hotkey clear") => HOTKEY_HELP,
        Some("login-item" | "login-item on" | "login-item off") => LOGIN_ITEM_HELP,
        Some("update" | "update check" | "update install" | "update options" | "config status" | "config export" | "config import" | "config sync") => LIFECYCLE_HELP,
        Some(other) => bail!("no help for {other:?} (see `sift --help`)"),
    };
    println!("{text}");
    Ok(0)
}

// ── argument parsing ────────────────────────────────────────────────────────

#[derive(Default)]
struct Parsed {
    /// Options in command-line order, so the last of two conflicting ones wins.
    opts: Vec<(String, Option<String>)>,
    words: Vec<String>,
}

impl Parsed {
    fn has(&self, name: &str) -> bool {
        self.opts.iter().any(|(n, _)| n == name)
    }

    fn value(&self, name: &str) -> Option<&str> {
        self.opts.iter().rev().find(|(n, _)| n == name).and_then(|(_, v)| v.as_deref())
    }

    fn values(&self, name: &str) -> Vec<PathBuf> {
        self.opts.iter().filter(|(n, _)| n == name).filter_map(|(_, v)| v.as_ref().map(PathBuf::from)).collect()
    }

    fn secs(&self, name: &str) -> Result<Option<Duration>> {
        self.value(name).map(|v| parse_secs(name, v)).transpose()
    }
}

fn parse_secs(name: &str, value: &str) -> Result<Duration> {
    let secs: f64 = value.parse().with_context(|| format!("{name} expects seconds, got {value:?}"))?;
    if !(secs.is_finite() && secs > 0.0) {
        bail!("{name} expects a positive number of seconds");
    }
    Ok(Duration::from_secs_f64(secs))
}

/// Strict parsing: `-h`/`--help` anywhere before `--` asks for help (`None`), an
/// unknown option is an error, `--name=value` works for options with a value, and
/// words are only accepted where the command takes them.
fn parse(cmd: &str, args: &[String], flags: &[&str], valued: &[&str], takes_words: bool) -> Result<Option<Parsed>> {
    let mut parsed = Parsed::default();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            let rest: Vec<String> = it.by_ref().cloned().collect();
            if !takes_words && !rest.is_empty() {
                bail!("`sift {cmd}` takes no arguments (see `sift {cmd} --help`)");
            }
            parsed.words.extend(rest);
            break;
        }
        if arg == "-h" || arg == "--help" {
            return Ok(None);
        }
        if arg.len() > 1 && arg.starts_with('-') {
            let (name, inline) = match arg.split_once('=') {
                Some((name, value)) if name.starts_with("--") => (name, Some(value.to_owned())),
                _ => (arg.as_str(), None),
            };
            if flags.contains(&name) {
                if inline.is_some() {
                    bail!("{name} takes no value");
                }
                parsed.opts.push((name.to_owned(), None));
            } else if valued.contains(&name) {
                let value = match inline {
                    Some(v) => v,
                    None => it.next().cloned().with_context(|| format!("{name} needs a value"))?,
                };
                parsed.opts.push((name.to_owned(), Some(value)));
            } else {
                let hint = if takes_words { "; put a query that starts with - after --" } else { "" };
                bail!("unknown option {arg:?} for `sift {cmd}` (see `sift {cmd} --help`{hint})");
            }
        } else if takes_words {
            parsed.words.push(arg.clone());
        } else {
            bail!("unexpected argument {arg:?} for `sift {cmd}` (see `sift {cmd} --help`)");
        }
    }
    Ok(Some(parsed))
}

// ── shared helpers ──────────────────────────────────────────────────────────

fn support_dir() -> PathBuf {
    Config::default_support_dir()
}

fn custom_support_dir() -> bool {
    std::env::var_os("SIFT_SUPPORT_DIR").is_some_and(|d| !d.is_empty())
}

/// One request to the running app; `None` when no app is listening.
fn live(op: &str, timeout: Option<Duration>) -> Result<Option<Value>> {
    live_request(&Request { op: op.into(), ..Default::default() }, timeout)
}

fn live_request(req: &Request, timeout: Option<Duration>) -> Result<Option<Value>> {
    ipc::request_within(&socket_path_in(&support_dir()), req, timeout)
}

fn ensure_ok(v: &Value) -> Result<()> {
    if v["ok"] != json!(true) {
        bail!("{}", v["error"].as_str().unwrap_or("Sift reported a failure"));
    }
    Ok(())
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn mtime_secs(meta: &std::fs::Metadata) -> u64 {
    meta.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs())
}

/// The saved index on disk (what `--offline` and the next launch read).
fn snapshot_info(config: &Config) -> Value {
    let path = config.db_path();
    match std::fs::metadata(&path) {
        Ok(meta) => json!({"path": path, "bytes": meta.len(), "mtime": mtime_secs(&meta)}),
        Err(_) => Value::Null,
    }
}

fn marker_state(config: &Config) -> (bool, String) {
    let marker = rebuild_marker(config);
    match std::fs::read_to_string(&marker) {
        Ok(text) => (true, text.trim().to_owned()),
        Err(_) => (marker.exists(), String::new()),
    }
}

fn ago(secs: u64) -> String {
    let d = unix_now().saturating_sub(secs);
    match d {
        0..60 => format!("{d} s ago"),
        60..3600 => format!("{} min ago", d / 60),
        3600..172_800 => format!("{:.1} h ago", d as f64 / 3600.0),
        _ => format!("{} days ago", d / 86_400),
    }
}

fn print_line(v: &Value) -> Result<()> {
    println!("{}", serde_json::to_string(v)?);
    Ok(())
}

/// Polls status until `done` holds; exit 4 on timeout. `absent_ok` keeps polling while
/// no app answers (it is still launching); otherwise a vanished app is exit 3 at once.
fn wait_status(limit: Duration, what: &str, absent_ok: bool, done: impl Fn(&Value) -> bool) -> Result<Value> {
    let started = Instant::now();
    loop {
        match live("status", Some(Duration::from_secs(10))) {
            Ok(Some(status)) if done(&status) => return Ok(status),
            Ok(Some(status)) if started.elapsed() >= limit => {
                return Err(fail(TIMEOUT, format!(
                    "{what} not reached within {:.1} s (state {})",
                    limit.as_secs_f64(),
                    status["state"].as_str().unwrap_or("?")
                )));
            }
            Ok(None) if !absent_ok => return Err(not_running(&format!(" (it stopped before {what})"))),
            Ok(None) if started.elapsed() >= limit => {
                return Err(fail(TIMEOUT, format!("{what} not reached within {:.1} s (Sift is not answering)", limit.as_secs_f64())));
            }
            Ok(_) => {}
            Err(e) if e.downcast_ref::<TimedOut>().is_some() && started.elapsed() < limit => {}
            Err(e) => return Err(e),
        }
        std::thread::sleep(Duration::from_millis(250));
    }
}

/// Waits for the full walk a rescan or settings change started (`walks` passes
/// `before`) and for the new index to be ready.
fn wait_rebuilt(before: &Value, limit: Duration) -> Result<Value> {
    let Some(before) = before.as_u64() else {
        bail!("the running Sift is older than this CLI (no walk counter); quit and reopen it to use --wait");
    };
    let started = Instant::now();
    let mut status = wait_status(limit, "rebuilt index ready", false, |s| {
        s["walks"].as_u64().is_some_and(|w| w > before) && s["state"] == "ready"
    })?;
    status["waited_s"] = json!((started.elapsed().as_secs_f64() * 10.0).round() / 10.0);
    Ok(status)
}

// ── search ──────────────────────────────────────────────────────────────────

fn search(args: &[String]) -> Result<u8> {
    let Some(p) = parse(
        "search",
        args,
        &["-i", "--ignore-case", "--match-case", "--desc", "--json", "--offline"],
        &["--dir", "-n", "--limit", "--offset", "--sort", "--timeout"],
        true,
    )?
    else {
        return show_help(Some("search"));
    };
    let mut req = Request { op: "search".into(), limit: Some(50), ..Default::default() };
    for (name, value) in &p.opts {
        let value = value.as_deref().unwrap_or_default();
        match name.as_str() {
            "--dir" => req.dir = Some(value.to_owned()),
            "-i" | "--ignore-case" => req.case_insensitive = true,
            "--match-case" => req.case_insensitive = false,
            "-n" | "--limit" => {
                let n: usize = value.parse().with_context(|| format!("{name} expects a number, got {value:?}"))?;
                req.limit = (n > 0).then_some(n);
            }
            "--offset" => req.offset = value.parse().with_context(|| format!("--offset expects a number, got {value:?}"))?,
            "--sort" => {
                SortKey::parse(value).with_context(|| format!("unknown sort key {value:?} (name, path, size, mtime, ctime)"))?;
                req.sort = Some(value.to_owned());
            }
            "--desc" => req.desc = true,
            _ => {}
        }
    }
    if !p.words.is_empty() {
        req.query = Some(p.words.join(" "));
    }
    if req.query.as_deref().is_none_or(|q| q.trim().is_empty()) && req.dir.as_deref().is_none_or(|d| d.trim().is_empty()) {
        bail!("search needs a query (see `sift search --help`)");
    }
    let as_json = p.has("--json");

    let response = if p.has("--offline") {
        offline_search(&req)?
    } else {
        match live_request(&req, p.secs("--timeout")?)? {
            Some(v) => v,
            None => return Err(not_running("; use --offline to read the saved index")),
        }
    };
    ensure_ok(&response)?;
    let total = response["total"].as_u64().unwrap_or(0);
    if as_json {
        print_line(&response)?;
    } else {
        for hit in response["results"].as_array().into_iter().flatten() {
            println!("{}", hit["path"].as_str().unwrap_or_default());
        }
        let shown = response["results"].as_array().map_or(0, Vec::len) as u64;
        if shown < total {
            eprintln!("… {shown} of {total} results (use --limit 0 for all)");
        }
        if response["rebuild_required"] == json!(true) {
            eprintln!("sift: note: the index is incomplete (lost file events; rebuild pending), so results may miss files");
        }
        if let Some(mtime) = response["snapshot"]["mtime"].as_u64() {
            eprintln!("sift: offline: saved index from {}", ago(mtime));
        }
    }
    Ok(if total == 0 { NO_RESULTS } else { 0 })
}

fn index_control(args: &[String]) -> Result<u8> {
    let Some(p) = parse("index", args, &["--json"], &["--auto-repair", "--auto-save"], true)? else { return show_help(Some("index")); };
    if p.words.len() > 1 { bail!("index expects one action"); }
    let action = p.words.first().map(String::as_str).unwrap_or("status");
    if !["status", "pause", "resume", "cancel", "set"].contains(&action) { bail!("unknown index action {action:?}"); }
    if action != "set" && !p.opts.iter().all(|(k,_)| k == "--json") { bail!("runtime options require index set"); }
    let mut body = json!({"action": action});
    for (flag, key) in [("--auto-repair", "auto_repair"), ("--auto-save", "auto_snapshot")] {
        if let Some(v) = p.value(flag) { body[key] = json!(match v { "on" => true, "off" => false, _ => bail!("{flag} expects on or off") }); }
    }
    let req = Request { op: "control".into(), action: Some(body), ..Default::default() };
    let v = live_request(&req, None)?.ok_or_else(|| not_running(""))?;
    ensure_ok(&v)?; print_line(&v)?; Ok(0)
}

fn product_action(verb: &str, args: &[String]) -> Result<u8> {
    let Some(p) = parse(verb, args, &["--json", "--yes", "--case"], &["--scope", "--dir"], true)? else { println!("{PRODUCT_HELP}"); return Ok(0); };
    let words: Vec<_> = p.words.iter().map(String::as_str).collect();
    let mut action = match (verb, words.as_slice()) {
        ("shortcuts", [] | ["list"]) => json!({"action":"shortcuts"}),
        ("shortcuts", ["set", id, _]) => json!({"action":"shortcut_set","id":id,"scope":p.value("--scope").unwrap_or("app")}),
        ("shortcuts", ["clear", id]) => json!({"action":"shortcut_clear","id":id}),
        ("saved", [] | ["list"]) => json!({"action":"saved"}),
        ("saved", ["add", name, query]) => json!({"action":"saved_add","name":name,"query":query,"dir":p.value("--dir").unwrap_or(""),"case_insensitive":!p.has("--case")}),
        ("saved", ["remove", name]) => json!({"action":"saved_remove","name":name}),
        ("file", ["info", path]) => json!({"action":"file_info","path":path}),
        ("file", ["rename", path, name]) if p.has("--yes") => json!({"action":"file_rename","path":path,"name":name,"confirmed":true}),
        _ => bail!("invalid {verb} arguments; see sift {verb} --help"),
    };
    if p.value("--scope").is_some() && action["action"] != "shortcut_set" { bail!("--scope is only for shortcuts set"); }
    if (p.value("--dir").is_some() || p.has("--case")) && action["action"] != "saved_add" { bail!("--dir/--case are only for saved add"); }
    if p.has("--yes") && action["action"] != "file_rename" { bail!("--yes is only for file rename"); }
    if action["action"] == "file_info" || action["action"] == "file_rename" {
        action["path"] = serde_json::to_value(typed_path(action["path"].as_str().unwrap_or(""))?)?;
    }
    if action["action"] == "shortcut_set" {
        let scope = action["scope"].as_str().unwrap_or("");
        if !["app","global"].contains(&scope) { bail!("scope expects app or global"); }
        let combo = prefs::parse_combo(words[2]).map_err(|e| fail(ERROR, e))?;
        action["stored"] = json!(combo);
    }
    match ask_app(verb, action, Duration::from_secs(20), true)? {
        AppReply::Done(v) => { print_line(&v)?; Ok(0) },
        AppReply::NotRunning => app_not_running(verb, p.has("--json")),
        AppReply::Failed(code) => Ok(code),
    }
}

fn export_results(args: &[String]) -> Result<u8> {
    let Some(p) = parse("export", args, &["--json", "--force", "--offline", "--desc", "-i"], &["-o", "--format", "--limit", "--dir", "--sort"], true)? else { return show_help(Some("export")); };
    let format = p.value("--format").unwrap_or("json");
    if !["json", "csv", "paths"].contains(&format) { bail!("format expects json, csv or paths"); }
    if p.words.is_empty() { bail!("export needs a query"); }
    let limit = p.value("--limit").unwrap_or("50").parse::<usize>().context("--limit expects a number")?;
    if let Some(sort) = p.value("--sort") { SortKey::parse(sort).context("invalid sort")?; }
    let req = Request { op: "search".into(), query: Some(p.words.join(" ")), dir: p.value("--dir").map(str::to_owned),
        limit: (limit != 0).then_some(limit), sort: p.value("--sort").map(str::to_owned), desc: p.has("--desc"), case_insensitive: p.has("-i"), ..Default::default() };
    let v = if p.has("--offline") { offline_search(&req)? } else { live_request(&req, None)?.ok_or_else(|| not_running(""))? };
    ensure_ok(&v)?;
    let rows = v["results"].as_array().context("missing results")?;
    let text = match format {
        "paths" => rows.iter().map(|r| format!("{}\n", r["path"].as_str().unwrap_or(""))).collect::<String>(),
        "csv" => {
            let mut out = String::from("path,kind,size,modified,created\r\n");
            for r in rows {
                let values = ["path","kind","size","mtime","ctime"].map(|k| {
                    let v = if let Some(s) = r[k].as_str() { s.to_owned() } else if r[k].is_null() { String::new() } else { r[k].to_string() };
                    format!("\"{}\"", v.replace('"', "\"\""))
                });
                out.push_str(&values.join(","));out.push_str("\r\n");
            }
            out
        },
        _ => serde_json::to_string_pretty(&v)? + "\n",
    };
    if let Some(path) = p.value("-o") {
        use std::io::Write;
        let destination = std::path::Path::new(path);
        let parent = destination.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(std::path::Path::new("."));
        let temporary = parent.join(format!(".sift-export-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos()));
        let result = (|| -> Result<()> {
            let mut file = std::fs::OpenOptions::new().write(true).create_new(true).open(&temporary)?;
            file.write_all(text.as_bytes())?;file.sync_all()?;drop(file);
            if p.has("--force") { std::fs::rename(&temporary,destination)?; }
            else { std::fs::hard_link(&temporary,destination).context("export destination exists or cannot be created; use --force only to replace it")?; }
            Ok(())
        })();
        let _ = std::fs::remove_file(&temporary);result?;
        print_line(&json!({"ok":true,"path":path,"format":format,"exported":rows.len(),"total":v["total"]}))?;
    } else { print!("{text}"); }
    Ok(0)
}

fn offline_search(req: &Request) -> Result<Value> {
    let config = Config::load(&support_dir())?;
    let mut index = Offline::open(&config)?;
    // Search and sort time only, like the live figure (loading the snapshot is not counted).
    let searched = Instant::now();
    let outcome = index.search_with_metadata(req.dir.clone(), req.query.clone(), req.case_insensitive)?;
    let mut indices = outcome.nodes.unwrap_or_default();
    if let Some(key) = req.sort.as_deref().and_then(SortKey::parse) {
        indices = index.sort(indices, key, req.desc);
    } else if req.desc {
        indices.reverse();
    }
    let search_ms = searched.elapsed().as_secs_f64() * 1000.0;
    let total = indices.len();
    let start = req.offset.min(total);
    let end = req.limit.map_or(total, |l| start.saturating_add(l).min(total));
    let hits: Vec<Hit> = index.rows(&indices[start..end]).into_iter().map(Hit::from).collect();
    let (rebuild_required, _) = marker_state(&config);
    let mut response = json!({
        "ok": true,
        "live": false,
        "total": total,
        "offset": start,
        "search_ms": (search_ms * 1000.0).round() / 1000.0,
        "case_insensitive": req.case_insensitive,
        "rebuild_required": rebuild_required,
        "snapshot": snapshot_info(&config),
        "results": hits,
    });
    if let Some(loosened) = outcome.loosened { response["loosened"] = json!(loosened); }
    Ok(response)
}

// ── status / config / version ───────────────────────────────────────────────

fn status(args: &[String]) -> Result<u8> {
    let Some(p) = parse("status", args, &["--json"], &[], false)? else {
        return show_help(Some("status"));
    };
    let as_json = p.has("--json");
    if let Some(mut v) = live("status", Some(Duration::from_secs(10)))? {
        ensure_ok(&v)?;
        v["running"] = json!(true);
        v["gui"] = prefs::gui();
        if as_json {
            print_line(&v)?;
        } else {
            let yes = |b: &Value| if b == &json!(true) { "yes" } else { "no" };
            println!("state: {}", v["state"].as_str().unwrap_or("?"));
            println!("files: {}", v["files"]);
            println!("fs events: {}", v["events"]);
            println!("unsaved changes: {}", v["unsaved_changes"]);
            println!("snapshot writes: {}", v["snapshot_writes"]);
            println!("full walks: {}", v["walks"]);
            let reason = v["rebuild_reason"].as_str().unwrap_or_default();
            println!("rebuild required: {}{}", yes(&v["rebuild_required"]), if reason.is_empty() { String::new() } else { format!(" ({})", reason.lines().last().unwrap_or(reason)) });
            println!("background repair running: {}", yes(&v["repairing"]));
            println!("root: {}", v["root"].as_str().unwrap_or("?"));
            println!("skipped folders: {}, included folders: {}", v["ignore_paths"].as_array().map_or(0, Vec::len), v["include_paths"].as_array().map_or(0, Vec::len));
            println!("full disk access: {}", yes(&v["full_disk_access"]));
            println!("login item: {}", v["login_item"].as_str().unwrap_or("unknown"));
            println!(
                "app: {} ({}), pid {}",
                v["app"]["version"].as_str().unwrap_or("?"),
                v["app"]["build"].as_str().unwrap_or("?"),
                v["pid"]
            );
        }
        return Ok(0);
    }
    // Not running: report what is on disk. An invalid config.json is an error (exit 2),
    // not "not running", so a broken setting is never mistaken for a stopped app.
    let config = Config::load(&support_dir())?;
    let (rebuild_required, reason) = marker_state(&config);
    let v = json!({
        "ok": true,
        "live": false,
        "running": false,
        // Same code as the process exit, like the {ok:false,…,exit} failure objects.
        "exit": NOT_RUNNING,
        "support_dir": config.support_dir,
        "root": config.root,
        "ignore_paths": config.ignore_paths,
        "include_paths": config.include_paths,
        "snapshot": snapshot_info(&config),
        "rebuild_required": rebuild_required,
        "rebuild_reason": reason,
        "gui": prefs::gui(),
    });
    if as_json {
        print_line(&v)?;
    } else {
        println!("Sift.app is not running");
        match v["snapshot"]["mtime"].as_u64() {
            Some(mtime) => println!("saved index: {} bytes, {}", v["snapshot"]["bytes"], ago(mtime)),
            None => println!("saved index: none"),
        }
        println!("rebuild required: {}", if rebuild_required { "yes" } else { "no" });
        println!("root: {}", config.root.display());
    }
    Ok(NOT_RUNNING)
}

fn config(args: &[String]) -> Result<u8> {
    let Some(p) = parse("config", args, &["--json"], &[], false)? else {
        return show_help(Some("config"));
    };
    let dir = support_dir();
    let config = Config::load(&dir)?;
    let v = json!({
        "ok": true,
        "root": config.root,
        "ignore_paths": config.ignore_paths,
        "include_paths": config.include_paths,
        "support_dir": config.support_dir,
        "source": if dir.join("config.json").exists() { "config.json" } else { "defaults" },
    });
    if p.has("--json") {
        print_line(&v)?;
    } else {
        println!("{}", serde_json::to_string_pretty(&v)?);
    }
    Ok(0)
}

fn config_set(args: &[String]) -> Result<u8> {
    let Some(p) = parse(
        "config set",
        args,
        &["--defaults", "--dry-run", "--json"],
        &["--root", "--ignore-add", "--ignore-remove", "--include-add", "--include-remove", "--wait"],
        false,
    )?
    else {
        return show_help(Some("config"));
    };
    let edit = ConfigEdit {
        defaults: p.has("--defaults"),
        root: p.value("--root").map(PathBuf::from),
        ignore_add: p.values("--ignore-add"),
        ignore_remove: p.values("--ignore-remove"),
        include_add: p.values("--include-add"),
        include_remove: p.values("--include-remove"),
    };
    if edit.is_empty() {
        bail!("config set needs a change (see `sift config set --help`)");
    }
    let dry_run = p.has("--dry-run");
    let wait = p.secs("--wait")?;
    let req = Request { op: "configure".into(), edit: Some(edit.clone()), dry_run, ..Default::default() };
    let Some(mut v) = live_request(&req, Some(Duration::from_secs(30)))? else {
        if !dry_run {
            return Err(not_running(
                "; start it first (`sift start`): settings change through the app so the index is rebuilt with them",
            ));
        }
        let current = Config::load(&support_dir())?;
        let next = edit.apply(&current)?;
        print_line(&json!({
            "ok": true, "live": false, "dry_run": true, "changed": next != current,
            "reindexing": false, "saved": false, "config": next,
        }))?;
        return Ok(0);
    };
    ensure_ok(&v)?;
    if v["reindexing"] == json!(true) {
        eprintln!("sift: settings saved; re-indexing from scratch (searches wait until the walk finishes)");
        if let Some(limit) = wait {
            let status = wait_rebuilt(&v["walks_before"], limit)?;
            v["state"] = status["state"].clone();
            v["files"] = status["files"].clone();
            v["waited_s"] = status["waited_s"].clone();
        }
    }
    print_line(&v)?;
    Ok(0)
}

/// The window's recent searches as it saved them (read-only; the CLI never records any).
fn history(args: &[String]) -> Result<u8> {
    let Some(p) = parse("history", args, &["--json"], &["-n", "--limit"], false)? else {
        return show_help(Some("history"));
    };
    let limit = ["-n", "--limit"]
        .iter()
        .filter_map(|name| p.opts.iter().rposition(|(n, _)| n == name).map(|at| (at, *name)))
        .max()
        .map(|(at, name)| {
            let value = p.opts[at].1.as_deref().unwrap_or_default();
            value.parse::<usize>().with_context(|| format!("{name} expects a number, got {value:?}"))
        })
        .transpose()?;
    let all = prefs::recent_searches();
    // 0 means all, as for `search --limit`.
    let items = &all[..limit.filter(|&l| l > 0).map_or(all.len(), |l| l.min(all.len()))];
    if p.has("--json") {
        print_line(&json!({"ok": true, "total": all.len(), "items": items}))?;
    } else {
        for query in items {
            println!("{query}");
        }
    }
    Ok(0)
}

/// `sift history clear --yes`: the ⌘Y menu's Clear Recent Searches. `words` starts at
/// `history`, for the failure object.
fn history_clear(words: &[String]) -> Result<u8> {
    let Some(p) = parse("history clear", &words[2..], &["--yes", "--json"], &[], false)? else {
        return show_help(Some("history"));
    };
    if !p.has("--yes") {
        return lifecycle_failure(
            words,
            ERROR,
            "confirmation_required",
            "this removes every saved recent search of the window and cannot be undone: add --yes to confirm",
        );
    }
    let cleared = prefs::recent_searches().len();
    if !prefs::clear_recent_searches() {
        return lifecycle_failure(words, 1, "failed", "the preference could not be saved; the recent searches are unchanged");
    }
    print_line(&json!({"ok": true, "command": "history clear", "cleared": cleared}))?;
    Ok(0)
}

fn version(args: &[String]) -> Result<u8> {
    let Some(p) = parse("version", args, &["--json"], &[], false)? else {
        return show_help(Some("version"));
    };
    let app = std::env::current_exe().ok().and_then(|exe| bundle_info(&exe));
    if p.has("--json") {
        print_line(&json!({"ok": true, "cli": env!("CARGO_PKG_VERSION"), "app": app}))?;
    } else {
        match app {
            Some(app) => println!(
                "sift {} (Sift.app {}, build {})",
                env!("CARGO_PKG_VERSION"),
                app.version.as_deref().unwrap_or("?"),
                app.build.as_deref().unwrap_or("?")
            ),
            None => println!("sift {}", env!("CARGO_PKG_VERSION")),
        }
    }
    Ok(0)
}

// ── actions: rescan / flush / start / quit ─────────────────────────────────

fn rescan(args: &[String]) -> Result<u8> {
    let Some(p) = parse("rescan", args, &["--json"], &["--wait"], false)? else {
        return show_help(Some("rescan"));
    };
    let wait = p.secs("--wait")?;
    let Some(mut v) = live("rescan", Some(Duration::from_secs(30)))? else {
        return Err(not_running(""));
    };
    ensure_ok(&v)?;
    eprintln!("sift: re-indexing from scratch (searches wait until the walk finishes)");
    if let Some(limit) = wait {
        let status = wait_rebuilt(&v["walks_before"], limit)?;
        for key in ["walks", "state", "files", "rebuild_required", "waited_s"] {
            v[key] = status[key].clone();
        }
    }
    print_line(&v)?;
    Ok(0)
}

fn flush(args: &[String]) -> Result<u8> {
    let Some(p) = parse("flush", args, &["--json"], &["--timeout"], false)? else {
        return show_help(Some("flush"));
    };
    let Some(v) = live("flush", p.secs("--timeout")?)? else {
        return Err(not_running(""));
    };
    ensure_ok(&v)?;
    print_line(&v)?;
    Ok(0)
}

fn quit(args: &[String]) -> Result<u8> {
    let Some(p) = parse("quit", args, &["--force", "--json"], &["--wait"], false)? else {
        return show_help(Some("quit"));
    };
    let wait = p.secs("--wait")?;
    let force = p.has("--force");
    let req = Request { op: "quit".into(), force, ..Default::default() };
    let Some(mut v) = live_request(&req, Some(Duration::from_secs(10)))? else {
        print_line(&json!({"ok": true, "running": false}))?;
        return Ok(0);
    };
    if v["ok"] != json!(true) && v["error"].as_str().is_some_and(|e| e.starts_with("unknown op")) {
        // A Sift from before `quit` existed (build 7 or earlier): it maps SIGTERM to ⌘Q.
        match quit_older_app(force)? {
            Some(old) => v = old,
            None => {
                print_line(&json!({"ok": true, "running": false}))?;
                return Ok(0);
            }
        }
    }
    ensure_ok(&v)?;
    if let (Some(limit), Some(pid)) = (wait, v["pid"].as_i64()) {
        let started = Instant::now();
        while process_alive(pid as i32) {
            if started.elapsed() >= limit {
                return Err(fail(TIMEOUT, format!("Sift (pid {pid}) still running after {:.1} s", limit.as_secs_f64())));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        v["exited"] = json!(true);
        v["waited_s"] = json!((started.elapsed().as_secs_f64() * 10.0).round() / 10.0);
    }
    print_line(&v)?;
    Ok(0)
}

/// SIGTERM to the pid a pre-`quit` Sift reports in its status, with the same
/// refusal as the new app while a full re-index runs. `None` if it stopped meanwhile.
fn quit_older_app(force: bool) -> Result<Option<Value>> {
    let Some(status) = live("status", Some(Duration::from_secs(10)))? else {
        return Ok(None);
    };
    let pid = status["pid"].as_i64().filter(|&p| p > 1).context("the running Sift did not report its pid")?;
    if status["state"] == "scanning" && !force {
        bail!(
            "a full re-index is running ({} entries so far); quitting now cancels it, keeps the last \
             saved snapshot and marks the index for rebuilding at the next start. Wait for it \
             (`sift status`, state ready) or pass --force",
            status["files"]
        );
    }
    if unsafe { kill(pid as i32, SIGTERM) } != 0 {
        bail!("cannot signal Sift (pid {pid}): {}", std::io::Error::last_os_error());
    }
    Ok(Some(json!({"ok": true, "pid": pid, "via": "SIGTERM"})))
}

const SIGTERM: i32 = 15;
unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}

fn process_alive(pid: i32) -> bool {
    // Signal 0 only checks existence; EPERM would still mean "exists".
    let delivered = unsafe { kill(pid, 0) } == 0;
    delivered || std::io::Error::last_os_error().raw_os_error() == Some(1)
}

fn start(args: &[String]) -> Result<u8> {
    let Some(p) = parse("start", args, &["--headless", "--dry-run", "--json"], &["--wait", "--app", "--log"], false)? else {
        return show_help(Some("start"));
    };
    let wait = p.secs("--wait")?;
    let headless = p.has("--headless");
    if let Some(status) = live("status", Some(Duration::from_secs(10)))? {
        print_line(&json!({
            "ok": true, "already_running": true, "pid": status["pid"], "state": status["state"],
        }))?;
        return Ok(0);
    }
    // With an invalid config.json the app falls back to the defaults (index root /)
    // and starts a whole-disk walk; `sift status` reports the same error (exit 2).
    Config::load(&support_dir()).context("not starting Sift: fix or remove config.json first")?;
    if !custom_support_dir() && sift_process_running() {
        bail!(
            "a Sift process is running but not answering on its socket; not relaunching it \
             (LaunchServices would bring its window forward). Check `pgrep -lx Sift`."
        );
    }
    let bundle = match p.value("--app") {
        Some(path) => PathBuf::from(path),
        None => std::env::current_exe()
            .ok()
            .and_then(|exe| bundle_info(&exe))
            .map(|info| info.path)
            .context("this sift is not inside Sift.app; pass --app /path/to/Sift.app")?,
    };
    let info = bundle_info(&bundle.join("Contents/MacOS/Sift"))
        .with_context(|| format!("{} is not a Sift.app bundle", bundle.display()))?;
    if info.identifier.as_deref() != Some(BUNDLE_ID) {
        bail!("{} is not Sift.app (bundle id {:?})", bundle.display(), info.identifier);
    }
    let command: Vec<String> = if headless {
        vec![bundle.join("Contents/MacOS/Sift").to_string_lossy().into_owned(), "--headless".into()]
    } else {
        let mut cmd: Vec<String> = ["/usr/bin/open", "-g", "-j"].map(String::from).into();
        if custom_support_dir() {
            // A private support dir is a separate instance; -n keeps LaunchServices from
            // reopening (and showing) an already running one.
            cmd.extend(["-n".into(), "--env".into(), format!("SIFT_SUPPORT_DIR={}", support_dir().display())]);
        }
        cmd.extend([bundle.to_string_lossy().into_owned(), "--args".into(), "--background".into()]);
        cmd
    };
    if p.has("--dry-run") {
        print_line(&json!({"ok": true, "dry_run": true, "would_run": command}))?;
        return Ok(0);
    }
    let mut out = json!({"ok": true, "started": true, "command": command});
    if headless {
        use std::{os::unix::process::CommandExt, process::Stdio};
        let (stdout, stderr) = match p.value("--log") {
            Some(path) => {
                let file = std::fs::OpenOptions::new().create(true).append(true).open(path)
                    .with_context(|| format!("open {path}"))?;
                (Stdio::from(file.try_clone()?), Stdio::from(file))
            }
            None => (Stdio::null(), Stdio::null()),
        };
        // Its own process group: it outlives this command and the terminal.
        let child = std::process::Command::new(&command[0])
            .args(&command[1..])
            .stdin(Stdio::null())
            .stdout(stdout)
            .stderr(stderr)
            .process_group(0)
            .spawn()
            .with_context(|| format!("start {}", command[0]))?;
        out["pid"] = json!(child.id());
    } else {
        let status = std::process::Command::new(&command[0])
            .args(&command[1..])
            .status()
            .context("run /usr/bin/open")?;
        if !status.success() {
            bail!("`open` failed ({status})");
        }
    }
    if let Some(limit) = wait {
        let status = wait_status(limit, "searchable index", true, |s| {
            matches!(s["state"].as_str(), Some("ready" | "rebuild_required"))
        })?;
        out["pid"] = status["pid"].clone();
        out["state"] = status["state"].clone();
        out["files"] = status["files"].clone();
    }
    print_line(&out)?;
    Ok(0)
}

/// Any process named exactly `Sift` (the resident app, a snapshot run, a test instance).
fn sift_process_running() -> bool {
    std::process::Command::new("/usr/bin/pgrep")
        .args(["-xq", "Sift"])
        .status()
        .is_ok_and(|s| s.success())
}

// ── the 配置与更新… window: config status|export|import|sync, update check ────

/// The shared layer waits at most 30 s for one sync pass or one release lookup; an
/// import while sync is on does a write and a pass. SIFT_APP_TIMEOUT shortens it (tests).
const LIFECYCLE_SECONDS: f64 = 60.0;
/// `update install`: the shared layer allows 330 s for download and verification, 45 s
/// for the running Sift to quit (Lifecycle.product) and 330 s for the replacement.
const INSTALL_SECONDS: f64 = 720.0;

/// The words of a command without its options (`-o` takes a value).
fn positionals(words: &[String]) -> Vec<&str> {
    let mut out = Vec::new();
    let mut it = words.iter();
    while let Some(word) = it.next() {
        if word == "-o" || word == "--output" {
            it.next();
        } else if !word.starts_with('-') {
            out.push(word.as_str());
        }
    }
    out
}

/// The app executable that carries the shared command layer: the one of the bundle
/// this CLI ships in. Only a CLI outside any bundle (a source build, the tests) reads
/// SIFT_APP, the path of a built Sift.app.
fn lifecycle_app() -> Option<PathBuf> {
    let bundle = std::env::current_exe()
        .ok()
        .and_then(|exe| bundle_info(&exe))
        .map(|info| info.path)
        .or_else(|| std::env::var_os("SIFT_APP").filter(|p| !p.is_empty()).map(PathBuf::from))?;
    let exe = bundle.join("Contents/MacOS/Sift");
    exe.is_file().then_some(exe)
}

/// The forwarding itself failed (or was refused here): `sift`'s failure object with the
/// same `command` and `code` fields the app adds to these commands' failures.
fn lifecycle_failure(words: &[String], exit: u8, code: &str, message: &str) -> Result<u8> {
    if words.iter().any(|w| w == "--json") {
        let command = positionals(words).into_iter().take(2).collect::<Vec<_>>().join(" ");
        let mut out = json!({"ok": false, "command": command, "code": code, "error": message, "exit": exit});
        if exit == NOT_RUNNING {
            out["running"] = json!(false);
        }
        println!("{out}");
    }
    eprintln!("sift: {message}");
    Ok(exit)
}

/// `sift config status|export|import|sync …` and `sift update check|install`. `words` starts at the
/// verb and goes to the app executable unchanged; its stdout, stderr and exit code come
/// back unchanged. Nothing is parsed or re-implemented here, and a running Sift is not
/// touched by the forwarding: it follows the change on its own.
fn lifecycle(words: &[String]) -> Result<u8> {
    if words.iter().take_while(|w| *w != "--").any(|w| w == "-h" || w == "--help") {
        return show_help(Some("update"));
    }
    let has = |flag: &str| words.iter().any(|w| w == flag);
    let named = positionals(words);
    // The two that can rewrite config.json (an import does; the first iCloud sync takes
    // over what another Mac saved): like `config set`, only through the running app,
    // which re-indexes with the new settings. Without --yes or with --dry-run the app
    // executable answers without writing, so those go through.
    let rewrites = named.first() == Some(&"config")
        && has("--yes")
        && !has("--dry-run")
        && (named.get(1) == Some(&"import") || (named.get(1) == Some(&"sync") && named.get(2) == Some(&"on")));
    let answering = !rewrites
        || match live("status", Some(Duration::from_secs(10))) {
            Ok(reply) => reply.is_some(),
            // It took the connection and is busy (index loading, a full walk): it is running.
            Err(e) if e.downcast_ref::<TimedOut>().is_some() => true,
            Err(e) => return Err(e),
        };
    if !answering {
        return lifecycle_failure(
            words,
            NOT_RUNNING,
            "not_running",
            "Sift.app is not running; start it first (`sift start`): this can rewrite config.json, and only the \
             running app re-indexes with new settings (a config.json changed behind its back leaves the saved \
             index unreadable for --offline until a rebuild)",
        );
    }
    let Some(app) = lifecycle_app() else {
        return lifecycle_failure(
            words,
            1,
            "app_missing",
            "Sift.app's executable was not found: these commands are answered by the app this sift ships in \
             (run the sift inside an installed Sift.app)",
        );
    };
    let limit = std::env::var("SIFT_APP_TIMEOUT")
        .ok()
        .and_then(|v| v.parse::<f64>().ok())
        .filter(|s| s.is_finite() && *s > 0.0)
        .unwrap_or(if named.first() == Some(&"update") && named.get(1) == Some(&"install") { INSTALL_SECONDS } else { LIFECYCLE_SECONDS });
    let readback = if named.first() == Some(&"update") { "sift update check" } else { "sift config status" };
    use std::{io::Read, process::Stdio};
    let mut child = match std::process::Command::new(&app)
        .args(words)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(e) => return lifecycle_failure(words, 1, "app_missing", &format!("cannot run {}: {e}", app.display())),
    };
    // Both pipes are drained while waiting, so a long answer never blocks the app.
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut bytes = Vec::new();
            if let Some(mut pipe) = pipe {
                let _ = pipe.read_to_end(&mut bytes);
            }
            bytes
        })
    };
    let stdout = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let stderr = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let started = Instant::now();
    let status = loop {
        match child.try_wait().context("wait for Sift.app's executable")? {
            Some(status) => break Some(status),
            None if started.elapsed().as_secs_f64() >= limit => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    };
    // Timed out: whatever it had written so far is dropped, and the pipes are not waited for.
    let Some(status) = status else {
        return lifecycle_failure(
            words,
            TIMEOUT,
            "timeout",
            &format!("no answer within {limit:.0} s, stopped; read `{readback}` before trying again"),
        );
    };
    let (stdout, stderr) = (stdout.join().unwrap_or_default(), stderr.join().unwrap_or_default());
    let Some(code) = status.code() else {
        return lifecycle_failure(
            words,
            1,
            "app_failed",
            &format!("Sift.app's executable was killed before it answered; read `{readback}` before trying again"),
        );
    };
    use std::io::Write;
    std::io::stdout().write_all(&stdout)?;
    std::io::stdout().flush()?;
    std::io::stderr().write_all(&stderr)?;
    Ok(code.clamp(0, 255) as u8)
}

// ── the app's own actions: trash, hotkey, login-item ────────────────────────

/// A failure of one of these commands in `sift`'s shape, with the `command` and `code`
/// the 配置与更新 commands also carry and whatever state the app reported (`extra`).
fn action_failure(command: &str, as_json: bool, exit: u8, code: &str, message: &str, extra: Value) -> Result<u8> {
    if as_json {
        let mut out = if extra.is_object() { extra } else { json!({}) };
        out["ok"] = json!(false);
        out["command"] = json!(command);
        out["code"] = json!(code);
        out["error"] = json!(message);
        out["exit"] = json!(exit);
        if exit == NOT_RUNNING {
            out["running"] = json!(false);
        }
        println!("{out}");
    }
    eprintln!("sift: {message}");
    Ok(exit)
}

/// What the app answered, or why there is no answer to work with.
enum AppReply {
    Done(Value),
    NotRunning,
    /// Already reported; exit with this code.
    Failed(u8),
}

/// One request to the running app's own code (Sources/AppActions.swift): the functions
/// the window's menu and Settings buttons call, in the app process.
fn ask_app(command: &str, action: Value, timeout: Duration, as_json: bool) -> Result<AppReply> {
    let req = Request { op: "app".into(), action: Some(action), ..Default::default() };
    let reply = match live_request(&req, Some(timeout)) {
        Ok(Some(reply)) => reply,
        Ok(None) => return Ok(AppReply::NotRunning),
        Err(e) if e.downcast_ref::<TimedOut>().is_some() => {
            return action_failure(command, as_json, TIMEOUT, "timeout", &format!("{e:#}"), json!({})).map(AppReply::Failed);
        }
        Err(e) => return Err(e),
    };
    if reply["ok"] == json!(true) {
        return Ok(AppReply::Done(reply));
    }
    let message = reply["error"].as_str().unwrap_or("Sift reported a failure").to_owned();
    if message.starts_with("unknown op") {
        return action_failure(
            command,
            as_json,
            1,
            "app_outdated",
            "the running Sift is older than this sift command (it has no trash, hotkey or login-item commands): \
             quit and reopen it (`sift quit --wait 60`, `sift start`)",
            json!({}),
        )
        .map(AppReply::Failed);
    }
    let code = reply["code"].as_str().unwrap_or("failed").to_owned();
    let exit = match code.as_str() {
        "invalid_shortcut" | "unavailable" | "confirmation_required" | "usage" => ERROR,
        _ => 1,
    };
    action_failure(command, as_json, exit, &code, &message, reply).map(AppReply::Failed)
}

fn app_not_running(command: &str, as_json: bool) -> Result<u8> {
    action_failure(
        command,
        as_json,
        NOT_RUNNING,
        "not_running",
        "Sift.app is not running; start it first (`sift start`): the app itself does this, as its window does",
        json!({}),
    )
}

/// An absolute path where the command was typed, `.` and `..` folded by name only: a
/// symlink is never resolved, so the link itself is what gets moved.
fn typed_path(word: &str) -> Result<PathBuf> {
    use std::path::Component;
    let path = std::path::absolute(word).with_context(|| format!("cannot use the path {word:?}"))?;
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    Ok(out)
}

/// `sift trash <path...> --yes`: the window's Move to Trash (⌘⌫) on named paths.
fn trash(args: &[String]) -> Result<u8> {
    let Some(p) = parse("trash", args, &["--yes", "--json"], &["--timeout"], true)? else {
        return show_help(Some("trash"));
    };
    let as_json = p.has("--json");
    let timeout = p.secs("--timeout")?.unwrap_or(Duration::from_secs(120));
    if p.words.is_empty() {
        bail!("trash needs at least one path (see `sift trash --help`)");
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mut paths: Vec<PathBuf> = Vec::new();
    for word in &p.words {
        if word.is_empty() {
            bail!("trash got an empty path");
        }
        let path = typed_path(word)?;
        if path.parent().is_none() || Some(&path) == home.as_ref() {
            bail!("refusing to move {} to the Trash", path.display());
        }
        if !paths.contains(&path) {
            paths.push(path);
        }
    }
    // Only "it is not there" is decided here: a folder this process may not look into
    // (privacy protection) is left to Sift, which has its own access.
    let missing: Vec<&PathBuf> = paths
        .iter()
        .filter(|path| matches!(std::fs::symlink_metadata(path), Err(e) if e.kind() == std::io::ErrorKind::NotFound))
        .collect();
    if !missing.is_empty() {
        let message = format!(
            "nothing was moved: {} not exist: {}",
            if missing.len() == 1 { "this path does" } else { "these paths do" },
            missing.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join(", ")
        );
        return action_failure("trash", as_json, 1, "not_found", &message, json!({"missing": missing, "trashed": []}));
    }
    if !p.has("--yes") {
        let message = format!(
            "this moves {} to the Trash (Finder's Put Back restores {}): add --yes to confirm",
            if paths.len() == 1 { "1 item".to_owned() } else { format!("{} items", paths.len()) },
            if paths.len() == 1 { "it" } else { "them" }
        );
        return action_failure("trash", as_json, ERROR, "confirmation_required", &message, json!({"paths": paths}));
    }
    let reply = match ask_app("trash", json!({"action": "trash", "paths": paths, "confirmed": true}), timeout, as_json)? {
        AppReply::Done(reply) => reply,
        AppReply::NotRunning => return app_not_running("trash", as_json),
        AppReply::Failed(code) => return Ok(code),
    };
    let trashed = reply["trashed"].clone();
    print_line(&json!({"ok": true, "command": "trash", "count": trashed.as_array().map_or(0, Vec::len), "trashed": trashed}))?;
    Ok(0)
}

/// The app's hotkey answer as the commands print it: the stored combination also in the
/// spelling `status` uses (gui.hotkey) and as Settings shows it.
fn hotkey_fields(command: &str, reply: &Value) -> Value {
    let hotkey = match reply["stored"].as_str() {
        Some(stored) => {
            let mut hotkey = prefs::hotkey(stored);
            hotkey["display"] = reply["display"].clone();
            hotkey
        }
        None => Value::Null,
    };
    let mut out = json!({
        "ok": true, "command": command, "running": true, "hotkey": hotkey,
        "registered": reply["registered"], "in_use": reply["in_use"],
    });
    if !reply["changed"].is_null() {
        out["changed"] = reply["changed"].clone();
    }
    out
}

/// `sift hotkey`: what Settings shows of the global shortcut.
fn hotkey(args: &[String]) -> Result<u8> {
    let Some(p) = parse("hotkey", args, &["--json"], &[], false)? else {
        return show_help(Some("hotkey"));
    };
    let as_json = p.has("--json");
    let v = match ask_app("hotkey", json!({"action": "hotkey"}), Duration::from_secs(20), as_json)? {
        AppReply::Done(reply) => hotkey_fields("hotkey", &reply),
        AppReply::Failed(code) => return Ok(code),
        // Like `status`: the report worked, the registration is only known to a running Sift.
        AppReply::NotRunning => json!({
            "ok": true, "command": "hotkey", "running": false, "exit": NOT_RUNNING,
            "hotkey": prefs::gui()["hotkey"], "registered": Value::Null, "in_use": Value::Null,
        }),
    };
    let running = v["running"] == json!(true);
    if as_json {
        print_line(&v)?;
    } else {
        match v["hotkey"]["combo"].as_str() {
            Some(combo) => println!("shortcut: {}{combo}", v["hotkey"]["display"].as_str().map(|d| format!("{d}  ")).unwrap_or_default()),
            None => println!("shortcut: not set"),
        }
        if running {
            let yes = |b: &Value| if b == &json!(true) { "yes" } else { "no" };
            println!("registered: {}", yes(&v["registered"]));
            println!("in use by another app: {}", yes(&v["in_use"]));
        } else {
            println!("Sift.app is not running (whether it is registered is only known while it runs)");
        }
    }
    Ok(if running { 0 } else { NOT_RUNNING })
}

/// `sift hotkey set <combo|cardinal>`: recording a combination in Settings, or its preset button.
fn hotkey_set(args: &[String]) -> Result<u8> {
    let Some(p) = parse("hotkey set", args, &["--json"], &[], true)? else {
        return show_help(Some("hotkey"));
    };
    let as_json = p.has("--json");
    let [word] = p.words.as_slice() else {
        bail!("hotkey set takes one combination, e.g. cmd+shift+space, or cardinal (see `sift hotkey --help`)");
    };
    let action = if word.eq_ignore_ascii_case("cardinal") {
        // The preset is the Settings button's own constant, in the app.
        json!({"action": "hotkey_set", "preset": "cardinal"})
    } else {
        json!({"action": "hotkey_set", "stored": prefs::parse_combo(word).map_err(|e| fail(ERROR, e))?})
    };
    let reply = match ask_app("hotkey set", action, Duration::from_secs(20), as_json)? {
        AppReply::Done(reply) => reply,
        AppReply::NotRunning => return app_not_running("hotkey set", as_json),
        AppReply::Failed(code) => return Ok(code),
    };
    let mut v = hotkey_fields("hotkey set", &reply);
    if v["in_use"] == json!(true) {
        // As in the window: the combination stays stored and its orange note is shown.
        v.as_object_mut().map(|o| o.remove("ok"));
        return action_failure(
            "hotkey set",
            as_json,
            1,
            "in_use",
            "the system refused the new combination; the previous shortcut was kept; set another one or sift hotkey clear",
            v,
        );
    }
    print_line(&v)?;
    Ok(0)
}

/// `sift hotkey clear`: the Settings Clear button.
fn hotkey_clear(args: &[String]) -> Result<u8> {
    let Some(p) = parse("hotkey clear", args, &["--json"], &[], false)? else {
        return show_help(Some("hotkey"));
    };
    let as_json = p.has("--json");
    match ask_app("hotkey clear", json!({"action": "hotkey_clear"}), Duration::from_secs(20), as_json)? {
        AppReply::Done(reply) => {
            print_line(&hotkey_fields("hotkey clear", &reply))?;
            Ok(0)
        }
        AppReply::NotRunning => app_not_running("hotkey clear", as_json),
        AppReply::Failed(code) => Ok(code),
    }
}

/// `sift login-item [on|off]`: Settings › Open Sift at login.
fn login_item(args: &[String]) -> Result<u8> {
    let Some(p) = parse("login-item", args, &["--json"], &[], true)? else {
        return show_help(Some("login-item"));
    };
    let as_json = p.has("--json");
    let wanted = match p.words.as_slice() {
        [] => None,
        [word] if word == "on" => Some(true),
        [word] if word == "off" => Some(false),
        _ => bail!("login-item takes on or off, or nothing to show the state (see `sift login-item --help`)"),
    };
    let Some(on) = wanted else {
        let v = match ask_app("login-item", json!({"action": "login_item"}), Duration::from_secs(20), as_json)? {
            AppReply::Done(reply) => json!({
                "ok": true, "command": "login-item", "running": true,
                "login_item": reply["login_item"], "enabled": reply["enabled"],
            }),
            AppReply::Failed(code) => return Ok(code),
            // Like `status`: only a running Sift can ask macOS about its own login item.
            AppReply::NotRunning => json!({
                "ok": true, "command": "login-item", "running": false, "exit": NOT_RUNNING, "login_item": Value::Null,
            }),
        };
        let running = v["running"] == json!(true);
        if as_json {
            print_line(&v)?;
        } else if running {
            println!("login item: {}", v["login_item"].as_str().unwrap_or("unknown"));
        } else {
            println!("Sift.app is not running (only a running Sift can read its login item)");
        }
        return Ok(if running { 0 } else { NOT_RUNNING });
    };
    match ask_app("login-item", json!({"action": "login_item_set", "on": on}), Duration::from_secs(30), as_json)? {
        AppReply::Done(reply) => {
            print_line(&json!({
                "ok": true, "command": "login-item", "running": true, "action": if on { "on" } else { "off" },
                "login_item": reply["login_item"], "enabled": reply["enabled"], "changed": reply["changed"],
            }))?;
            Ok(0)
        }
        AppReply::NotRunning => app_not_running("login-item", as_json),
        AppReply::Failed(code) => Ok(code),
    }
}

// ── the window's preferences ────────────────────────────────────────────────

/// The app is not sandboxed, so its UserDefaults domain is readable here through
/// CFPreferences (cfprefsd), without asking the app. Only the keys the window shows,
/// read-only except for `history clear`, which removes the saved recent searches.
mod prefs {
    use serde_json::{Value, json};
    use std::ffi::c_void;

    type CFTypeRef = *const c_void;
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(alloc: CFTypeRef, bytes: *const u8, len: isize, encoding: u32, external: u8) -> CFTypeRef;
        fn CFPreferencesCopyAppValue(key: CFTypeRef, app: CFTypeRef) -> CFTypeRef;
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFBooleanGetValue(b: CFTypeRef) -> u8;
        fn CFNumberGetTypeID() -> usize;
        fn CFNumberGetValue(n: CFTypeRef, kind: isize, out: *mut c_void) -> u8;
        fn CFStringGetTypeID() -> usize;
        fn CFStringGetCString(s: CFTypeRef, buf: *mut u8, size: isize, encoding: u32) -> u8;
        fn CFStringGetLength(s: CFTypeRef) -> isize;
        fn CFStringGetMaximumSizeForEncoding(len: isize, encoding: u32) -> isize;
        fn CFArrayGetTypeID() -> usize;
        fn CFArrayGetCount(a: CFTypeRef) -> isize;
        fn CFArrayGetValueAtIndex(a: CFTypeRef, index: isize) -> CFTypeRef;
        fn CFRelease(cf: CFTypeRef);
        fn CFPreferencesSetAppValue(key: CFTypeRef, value: CFTypeRef, app: CFTypeRef);
        fn CFPreferencesAppSynchronize(app: CFTypeRef) -> u8;
        fn CFNotificationCenterGetDistributedCenter() -> CFTypeRef;
        fn CFNotificationCenterPostNotification(center: CFTypeRef, name: CFTypeRef, object: CFTypeRef, info: CFTypeRef, now: u8);
    }
    const UTF8: u32 = 0x0800_0100;
    const SINT64: isize = 4;

    fn cfstr(s: &str) -> CFTypeRef {
        unsafe { CFStringCreateWithBytes(std::ptr::null(), s.as_ptr(), s.len() as isize, UTF8, 0) }
    }

    enum Pref {
        Bool(bool),
        Text(String),
        List(Vec<String>),
    }

    /// The app's defaults domain, or SIFT_PREFS_DOMAIN (another domain or an absolute
    /// plist path without `.plist`) so tests never read the user's preferences.
    fn domain() -> String {
        std::env::var("SIFT_PREFS_DOMAIN").ok().filter(|d| !d.is_empty()).unwrap_or_else(|| super::BUNDLE_ID.to_owned())
    }

    /// A CFString of any length as UTF-8.
    unsafe fn text(s: CFTypeRef) -> Option<String> {
        unsafe {
            let size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), UTF8) + 1;
            let mut buf = vec![0u8; size.max(1) as usize];
            (CFStringGetCString(s, buf.as_mut_ptr(), buf.len() as isize, UTF8) != 0).then(|| {
                let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
                String::from_utf8_lossy(&buf[..end]).into_owned()
            })
        }
    }

    fn read(key: &str) -> Option<Pref> {
        unsafe {
            let (k, app) = (cfstr(key), cfstr(&domain()));
            let value = CFPreferencesCopyAppValue(k, app);
            CFRelease(k);
            CFRelease(app);
            if value.is_null() {
                return None;
            }
            let id = CFGetTypeID(value);
            let out = if id == CFBooleanGetTypeID() {
                Some(Pref::Bool(CFBooleanGetValue(value) != 0))
            } else if id == CFNumberGetTypeID() {
                let mut n: i64 = 0;
                (CFNumberGetValue(value, SINT64, (&mut n as *mut i64).cast()) != 0).then_some(Pref::Bool(n != 0))
            } else if id == CFStringGetTypeID() {
                text(value).map(Pref::Text)
            } else if id == CFArrayGetTypeID() {
                let mut items = Vec::new();
                for i in 0..CFArrayGetCount(value) {
                    let item = CFArrayGetValueAtIndex(value, i);
                    if !item.is_null() && CFGetTypeID(item) == CFStringGetTypeID() {
                        items.extend(text(item));
                    }
                }
                Some(Pref::List(items))
            } else {
                None
            };
            CFRelease(value);
            out
        }
    }

    fn flag(key: &str, default: bool) -> bool {
        match read(key) {
            Some(Pref::Bool(b)) => b,
            _ => default,
        }
    }

    /// `"<keyCode>:<NSEvent.ModifierFlags rawValue>"` as the Settings recorder stores it.
    pub fn hotkey(stored: &str) -> Value {
        let mut parts = stored.split(':');
        let (Some(Ok(code)), Some(Ok(mods))) = (parts.next().map(str::parse::<u32>), parts.next().map(str::parse::<u64>)) else {
            return json!({"stored": stored});
        };
        let mut combo: Vec<String> = [(1 << 20, "cmd"), (1 << 19, "option"), (1 << 18, "ctrl"), (1 << 17, "shift")]
            .iter()
            .filter(|(bit, _)| mods & bit != 0)
            .map(|(_, name)| name.to_string())
            .collect();
        combo.push(key_name(code));
        json!({"stored": stored, "combo": combo.join("+")})
    }

    /// `cmd+shift+space` (the spelling `hotkey` above prints) or the stored form itself,
    /// as the stored form. Whether the combination is one Sift accepts (a modifier other
    /// than shift alone) is the app's rule, checked there.
    pub fn parse_combo(text: &str) -> Result<String, String> {
        let text = text.trim();
        if let Some((code, mods)) = text.split_once(':') {
            return match (code.parse::<u32>(), mods.parse::<u64>()) {
                (Ok(code), Ok(mods)) => Ok(format!("{code}:{mods}")),
                _ => Err(format!("{text:?} is not a stored shortcut (<keyCode>:<modifierFlags>)")),
            };
        }
        let mut parts: Vec<&str> = text.split('+').map(str::trim).collect();
        let key = parts.pop().filter(|k| !k.is_empty()).ok_or_else(|| format!("{text:?} names no key (e.g. cmd+shift+space)"))?;
        let mut mods: u64 = 0;
        for part in parts {
            mods |= match part.to_ascii_lowercase().as_str() {
                "cmd" | "command" => 1 << 20,
                "option" | "opt" | "alt" => 1 << 19,
                "ctrl" | "control" => 1 << 18,
                "shift" => 1 << 17,
                _ => return Err(format!("unknown modifier {part:?} in {text:?} (cmd, option, ctrl, shift)")),
            };
        }
        let lower = key.to_ascii_lowercase();
        let code = match lower.strip_prefix("keycode") {
            Some(number) => number.parse::<u32>().map_err(|_| format!("{key:?} is not a key code (keycode<N>)"))?,
            None => KEYS
                .iter()
                .find(|(_, name)| *name == lower)
                .map(|(code, _)| *code)
                .ok_or_else(|| format!("unknown key {key:?} in {text:?} (a letter, a digit, space, return, tab, … or keycode<N>)"))?,
        };
        Ok(format!("{code}:{mods}"))
    }

    /// ANSI key codes (Carbon kVK_*) for the keys a shortcut normally uses.
    const KEYS: &[(u32, &str)] = &[
        (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"), (9, "v"),
        (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"), (18, "1"), (19, "2"),
        (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"),
        (29, "0"), (30, "]"), (31, "o"), (32, "u"), (33, "["), (34, "i"), (35, "p"), (36, "return"), (37, "l"),
        (38, "j"), (39, "'"), (40, "k"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "n"), (46, "m"),
        (47, "."), (48, "tab"), (49, "space"), (50, "`"), (51, "delete"), (53, "escape"),
        (76,"enter"),(117,"forward-delete"),(123,"left"),(124,"right"),(125,"down"),(126,"up"),
        (115,"home"),(119,"end"),(116,"page-up"),(121,"page-down"),
        (122,"f1"),(120,"f2"),(99,"f3"),(118,"f4"),(96,"f5"),(97,"f6"),(98,"f7"),(100,"f8"),(101,"f9"),(109,"f10"),
        (103,"f11"),(111,"f12"),(105,"f13"),(107,"f14"),(113,"f15"),(106,"f16"),(64,"f17"),(79,"f18"),(80,"f19"),(90,"f20"),
    ];

    fn key_name(code: u32) -> String {
        KEYS.iter().find(|(c, _)| *c == code).map_or_else(|| format!("keycode{code}"), |(_, n)| n.to_string())
    }

    /// `recentSearches` as the window saved it: newest first, de-duplicated, at most 50.
    pub fn recent_searches() -> Vec<String> {
        match read("recentSearches") {
            Some(Pref::List(items)) => items,
            _ => Vec::new(),
        }
    }

    /// Removes `recentSearches` from the same domain and tells a running window of that
    /// domain to drop the copy it holds (AppDelegate observes this name with its own
    /// bundle identifier), or its next recorded search would store the old list again.
    /// The only preference this CLI writes. False when the removal could not be saved.
    pub fn clear_recent_searches() -> bool {
        let domain = domain();
        unsafe {
            let (key, app) = (cfstr("recentSearches"), cfstr(&domain));
            CFPreferencesSetAppValue(key, std::ptr::null(), app);
            let saved = CFPreferencesAppSynchronize(app) != 0;
            let name = cfstr(&format!("cyou.tianli.sift.recent-searches-cleared.{domain}"));
            if saved {
                CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), name, std::ptr::null(), std::ptr::null(), 1);
            }
            CFRelease(name);
            CFRelease(key);
            CFRelease(app);
            saved
        }
    }

    /// The window's own preferences; searches from the CLI never record history.
    pub fn gui() -> Value {
        json!({
            // Unset means the window's default: case-insensitive.
            "case_insensitive": flag("caseInsensitive", true),
            "show_folder_scope": flag("showFolderScope", false),
            "hotkey": match read("hotkey") { Some(Pref::Text(s)) => hotkey(&s), _ => Value::Null },
        })
    }
}
