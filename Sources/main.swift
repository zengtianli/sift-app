import AppKit

// `sift config status|export|import|sync …` and `sift update check`: the `sift` CLI (core/src/bin/sift.rs) starts this
// executable with the words after `sift`, and the shared command layer answers on the window's own configuration
// and update source (Lifecycle). It returns here, before any NSApplication exists: no window, no Dock icon, no
// engine, no index. A Sift that is already running is not touched; it follows through AppLifecycleCLI.follow.
let launchWords = Array(CommandLine.arguments.dropFirst())
if AppLifecycleCLI.handles(launchWords.first) { exit(Lifecycle.run(launchWords)) }
// Before anything reads the environment: the lifecycle self-test runs on its own fixture, folders and preferences.
if Prefs.lifecycleSelfTest { LifecycleSelfTest.prepareEnvironment(arguments: launchWords) }

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
