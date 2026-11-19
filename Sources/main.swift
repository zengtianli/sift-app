import AppKit

// `sift config status|export|import|sync …` and `sift update check`: the `sift` CLI (core/src/bin/sift.rs) starts this
// executable with the words after `sift`, and the shared command layer answers on the window's own configuration
// and update source (Lifecycle). It returns here, before any NSApplication exists: no window, no Dock icon, no
// engine, no index. A Sift that is already running is not touched; it follows through AppLifecycleCLI.follow.
let launchWords = Array(CommandLine.arguments.dropFirst())
#if APP_STORE
// The Mac App Store build has no `sift` CLI and no updater of its own (the App Store updates it); its settings
// travel through Settings › Export / Import and the iCloud switch. The command words are refused, not taken for
// a launch of the window.
if let verb = launchWords.first, ["config", "update"].contains(verb) {
    FileHandle.standardError.write(Data("sift: `\(verb)` is not part of the Mac App Store build of Sift\n".utf8))
    exit(2)
}
#else
if AppLifecycleCLI.handles(launchWords.first) { exit(Lifecycle.run(launchWords)) }
// `Sift feed <latest.json>`: the release's latest.json read by this build's own parser (update_feed.py make runs it
// before a release, shared AppUpdateFeed.swift). Offline; nothing is downloaded or installed.
if AppUpdateFeed.handles(launchWords.first) {
    exit(AppUpdateFeed.run(launchWords, bundleID: Lifecycle.hostBundle.bundleIdentifier ?? Lifecycle.productID, bundle: Lifecycle.hostBundle))
}
// Before anything reads the environment: the lifecycle self-test runs on its own fixture, folders and preferences.
if Prefs.lifecycleSelfTest { LifecycleSelfTest.prepareEnvironment(arguments: launchWords) }
#endif

// The menu bar icon is on unless turned off in Settings: its drop-down (⌃⌥S) holds Quit for the menu-bar-resident app.
UserDefaults.standard.register(defaults: ["menuBar": true])
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Prefs.readOnly || Prefs.headless || Prefs.lifecycleSelfTest ? .prohibited : .regular)

// Quit cleanly on SIGTERM (kill, logout scripts) so unsaved index changes are written.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler { NSApp.terminate(nil) }
termSource.resume()

app.run()
