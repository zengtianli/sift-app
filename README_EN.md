# Sift · 速寻

[简体中文](README.md)

A native macOS file-name search app with an AppKit interface and a Rust indexing engine based on [Cardinal](https://github.com/cardisoft/cardinal). The window and the `sift` CLI share the index, query syntax, sorting and configuration.

Search as you type, narrow searches to folders, match case, filter names, sizes and dates, and navigate with the keyboard. Results support Quick Look, revealing in Finder and moving to Trash. File-system events update the index incrementally. When events are lost, Sift keeps the usable index and shows the rebuild state.

## Installation

Requires an Apple Silicon Mac running macOS 14 or later. [Download the distribution ZIP](https://github.com/zengtianli/sift-app/releases/download/v0.2.4/Sift-0.2.4-arm64.zip); the public package is Developer ID signed, notarized and stapled. New packages and checksums are listed in [Releases](https://github.com/zengtianli/sift-app/releases).

Extract the ZIP and move `Sift.app` to Applications. To search protected directories, personally grant Sift access in System Settings → Privacy & Security → Full Disk Access.

The CLI is included in the app. You can create a symlink yourself:

```sh
mkdir -p "$HOME/.local/bin"
ln -s /Applications/Sift.app/Contents/Resources/bin/sift "$HOME/.local/bin/sift"
sift --help
sift search readme --limit 20 --json
```

## Building from source

Install Xcode Command Line Tools and [rustup](https://rustup.rs/), then run from the repository root:

```sh
git clone https://github.com/zengtianli/sift-app.git
cd sift-app
bash build.sh
cd core
cargo test --locked -j 12
```

The Rust toolchain is pinned in `core/rust-toolchain.toml`. The required Cardinal fork sources are included; no author-specific local directories are needed. The output is `build/Sift.app`. The default ad-hoc signature is for local development. Distributors can set `CODESIGN_IDENTITY` to their own Developer ID identity and must notarize and staple the app before public distribution.

## Data and updates

The file-name index and index settings remain in the local application support directory. Recent searches remain in local preferences. File contents are not indexed. Global shortcuts are opt-in and unset by default. Portable settings support import/export and optional iCloud synchronization.

This public snapshot uses a separate `Sift` cloud-directory namespace. It excludes the author's update directories, index, recent searches, actual file listings, screenshots and internal records. It retains the local iCloud update mechanism; a public GitHub automatic update channel has not been connected yet. Get new versions from Releases.

## License

Original Sift code is [MIT licensed](LICENSE). Cardinal's MIT license is retained at `third_party/cardinal/LICENSE`; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for dependencies.
