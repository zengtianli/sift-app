// AppUpdateFeed.swift —— 交得出去 · HTTPS 自动更新（共享原版，本人 2026-11-18；vendor-lifecycle.py --feed 下发，只在这里改）。
//
// 每款只登记一个更新地址：Info.plist 的 AppUpdateFeedURL = https://<站点>/<目录>/latest.json（build.sh 写进 Info.plist）。
//   · 登记了：设置里的「检查更新」、命令行 update check|install、自动检查都读这个 HTTPS 地址，别人的 Mac 不要 iCloud、不要账号就能更新；
//   · 没登记：仍走产品原来的更新源（多半是本人的 iCloud 私有渠道），什么都不变。
// latest.json 与安装包由 ../update_feed.py make 生成、publish 上传（本人说发才传）；字段与解析规则就是 AppLifecycle.swift 的
// AppUpdateChecker.manifest（download_url 相对 latest.json；装前核 sha256、大小、包名、版本、签名团队与公证）。
//
// 接法（3 处）：
//   static let updateSource: AppUpdateSource = AppUpdateFeed.source(fallback: .privateCloud(channel: "private"))
//   启动时：AppUpdateFeed.seedDailyCheck(bundleID: …)                      // 第一次打开默认每天查一次，改过就不动
//   命令行：if AppUpdateFeed.handles(verb) { return AppUpdateFeed.run(args, bundleID: …) }   // <命令> feed <latest.json>
//   离屏自检：checks.merge(AppUpdateFeed.selfTest(bundleID: …)) { $1 }
import Foundation

enum AppUpdateFeed {
    static let infoKey = "AppUpdateFeedURL"

    /// 登记的更新地址；没登记或不是合格的 HTTPS JSON 地址时为 nil。
    static func registeredURL(bundle: Bundle = .main) -> URL? {
        (bundle.object(forInfoDictionaryKey: infoKey) as? String).flatMap(validFeed)
    }

    /// 合格的更新地址：https、有主机、不带账号密码、不带查询和片段、以 .json 结尾。
    static func validFeed(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.pathExtension.lowercased() == "json" else { return nil }
        return url
    }

    /// 产品的更新源：登记了 HTTPS 地址就读它，没登记就是 fallback（原来的渠道）。
    static func source(fallback: AppUpdateSource, bundle: Bundle = .main) -> AppUpdateSource {
        registeredURL(bundle: bundle).map { .manifest($0) } ?? fallback
    }

    /// 第一次打开时默认每天自动检查一次（共享默认是关）；本人或对方在设置里改过就不再动。只对登记了 HTTPS 源的 App 生效。
    static func seedDailyCheck(bundleID: String, bundle: Bundle = .main) {
        guard registeredURL(bundle: bundle) != nil,
              AppUpdatePreferences.defaults(bundleID).object(forKey: "appUpdateOptions") == nil else { return }
        var options = AppUpdateOptions(); options.automaticCheck = true; options.intervalHours = 24
        try? AppUpdatePreferences.save(options, bundleID)
    }

    // MARK: 命令行 `<命令> feed <latest.json>`：发布前用 App 自己的解析读一遍（update_feed.py make 会调它复核）

    static func handles(_ verb: String?) -> Bool { verb == "feed" }

    @discardableResult
    static func run(_ arguments: [String], bundleID: String, bundle: Bundle = .main, out: (String) -> Void = { print($0) }) -> Int32 {
        let words = Array((arguments.first == "feed" ? arguments.dropFirst() : arguments[...]).filter { $0 != "--json" })
        guard words.count == 1 else { out(json(["ok": false, "error": "feed 需要一个 latest.json 路径"])); return 2 }
        guard let feed = registeredURL(bundle: bundle) else {
            out(json(["ok": false, "error": "这个 App 没有登记 HTTPS 更新地址（Info.plist \(infoKey)）"])); return 1
        }
        do {
            let path = (words[0] as NSString).expandingTildeInPath
            let release = try read(Data(contentsOf: URL(fileURLWithPath: path)), feed: feed, bundleID: bundleID)
            let current = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                           bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0")
            var result: [String: Any] = ["ok": true, "feed": feed.absoluteString, "version": release.version, "build": release.build,
                                         "download_url": release.downloadURL?.absoluteString ?? "", "sha256": release.sha256 ?? "",
                                         "newer_than_this_app": release.isNewer(than: current.0, build: current.1)]
            if let size = release.size { result["size_bytes"] = size }
            if let url = release.releaseURL { result["release_url"] = url.absoluteString }
            if let notes = release.notes { result["notes"] = notes }
            if let date = release.publishedAt { result["published_at"] = date }
            out(json(result)); return 0
        } catch { out(json(["ok": false, "error": error.localizedDescription])); return 1 }
    }

    /// 和线上自动更新同一段解析，再加两条安装器的要求：有下载地址和 sha256，安装包是 .dmg 或 .zip。
    static func read(_ data: Data, feed: URL, bundleID: String) throws -> AppRelease {
        let release = try AppUpdateChecker.manifest(data, at: feed, bundleID: bundleID)
        guard let download = release.downloadURL, release.sha256 != nil else {
            throw AppUpdateError("缺下载地址或 sha256：App 不会安装没有校验值的包")
        }
        guard ["dmg", "zip"].contains(download.pathExtension.lowercased()) else { throw AppUpdateError("安装包须是 .dmg 或 .zip") }
        guard release.bundleID == bundleID else { throw AppUpdateError("发行记录要写明 bundle_id（\(bundleID)）") }
        return release
    }

    // MARK: 离屏自检（在隔离偏好域里跑：APP_LIFECYCLE_SUPPORT_DIR）

    static func selfTest(bundleID: String, bundle: Bundle = .main) -> [String: Bool] {
        guard let feed = registeredURL(bundle: bundle) else { return ["update.feed_registered": false] }
        var checks: [String: Bool] = ["update.feed_registered": true]
        if case .manifest(let url) = source(fallback: .privateCloud(channel: "private"), bundle: bundle) {
            checks["update.source_is_feed"] = url == feed
        } else { checks["update.source_is_feed"] = false }
        let hash = String(repeating: "a", count: 64)
        let sample = Data("""
        {"version":"9.9.1","build":"99901","bundle_id":"\(bundleID)","download_url":"App-9.9.1-99901.dmg","sha256":"\(hash)",\
        "size_bytes":123,"release_url":"https://\(feed.host ?? "example.com")/","notes":"x","published_at":"2026-11-18T12:00:00+08:00"}
        """.utf8)
        let release = try? read(sample, feed: feed, bundleID: bundleID)
        checks["update.manifest_parse"] = release?.downloadURL?.absoluteString
            == feed.deletingLastPathComponent().appendingPathComponent("App-9.9.1-99901.dmg").absoluteString
            && release?.size == 123 && release?.isNewer(than: "9.9.0", build: "1") == true
        let other = Data(#"{"version":"9.9.1","build":"1","bundle_id":"cyou.tianli.another-app","download_url":"x.dmg","sha256":"\#(hash)"}"#.utf8)
        checks["update.manifest_rejects_other_app"] = (try? read(other, feed: feed, bundleID: bundleID)) == nil
        let unsigned = Data(#"{"version":"9.9.1","build":"1","bundle_id":"\#(bundleID)","download_url":"x.dmg"}"#.utf8)
        checks["update.manifest_requires_sha256"] = (try? read(unsigned, feed: feed, bundleID: bundleID)) == nil
        if AppUpdatePreferences.isolatedDomain() != nil {
            seedDailyCheck(bundleID: bundleID, bundle: bundle)
            let options = AppUpdatePreferences.options(bundleID)
            checks["update.auto_check_default"] = options.automaticCheck && options.intervalHours == 24
        }
        return checks
    }

    private static func json(_ value: Any) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8), as: UTF8.self)
    }
}
