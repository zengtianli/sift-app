# Sift · 速寻

[简体中文](README.md)

A native macOS file-name search app with an AppKit interface and a Rust indexing engine based on [Cardinal](https://github.com/cardisoft/cardinal). The window and the `sift` CLI share the index, query syntax, sorting and configuration.

Search as you type, narrow searches to folders, match case, filter names, sizes and dates, and navigate with the keyboard. Results support Quick Look, revealing in Finder and moving to Trash. File-system events update the index incrementally. When events are lost, Sift keeps the usable index and shows the rebuild state.

## Installation

Requires an Apple Silicon Mac running macOS 14 or later. Download the ZIP or DMG from the [latest release](https://github.com/zengtianli/sift-app/releases/latest); the packages are Developer ID signed, notarized and stapled, with checksums in `SHA256SUMS.txt` on the same page.

Extract the ZIP (or open the DMG) and move `Sift.app` to Applications. To search protected directories, personally grant Sift access in System Settings → Privacy & Security → Full Disk Access.

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

With iCloud sync on, the settings file lives in your own iCloud Drive under `TianliApps/Settings/` (the folder name the author's apps share). The source here and the package in Releases are the same code, with the same version and build; it excludes the author's index, recent searches, actual file listings, screenshots and internal records.

**Check for updates…** reads `latest.json` from this repository's Releases (`AppUpdateFeedURL` in `Info.plist`), once a day by default from the first launch; turn it off in Settings. Automatic download and installation are off by default. A download is checked for its sha256, size, bundle identifier, version, signing team and notarization before it replaces the app. This is the app's only network access: network calls exist only in the shared update layer (`AppUpdateChecker` in `Sources/Shared/AppLifecycle.swift` reads the manifest, `AppUpgradeInstaller` in `Sources/Shared/AppLifecycleUI.swift` downloads the package); search, indexing and the `sift` command line never connect, and the command line links no networking library. This applies from 0.2.5; download 0.2.5 from Releases once by hand if you run 0.2.4 or earlier.

## License

Original Sift code is [MIT licensed](LICENSE). Cardinal's MIT license is retained at `third_party/cardinal/LICENSE`; see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for dependencies.
