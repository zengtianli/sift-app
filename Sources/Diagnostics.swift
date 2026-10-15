import AppKit

enum SiftDiagnostics {
    static func summary(_ d: [String:Any]) -> String {
        let count = (d["files"] as? NSNumber)?.stringValue ?? "0"
        let error = d["configuration_error"] as? String ?? ""
        if !error.isEmpty { return "配置需要修复；原有效范围或空范围已保留。" }
        if let problem = d["runtime_error"] as? String,!problem.isEmpty { return problem }
        if d["paused"] as? Bool == true { return "索引已暂停 · \(count) 项；搜索使用旧结果，恢复后追赶变化。" }
        if d["repairing"] as? Bool == true { return "正在后台修复 · \(count) 项；查询继续使用旧索引。" }
        if d["rebuild_required"] as? Bool == true {
            return (d["auto_repair"] as? Bool == false ? "索引不完整，自动修复已关闭；请手动重建。" : "索引不完整，等待空闲/退避后修复。") + " " + (d["rebuild_reason"] as? String ?? "")
        }
        let labels = ["starting":"正在启动","loading":"正在加载索引","scanning":"正在扫描","updating":"正在追赶文件变化","ready":"就绪","stopped":"已停止"]
        return "\(labels[d["state"] as? String ?? ""] ?? "未知状态") · \(count) 项 · 遍历 \(d["walks"] ?? 0) 次"
    }
    static func redacted(_ d:[String:Any]) -> [String:Any] {
        var value = d
        for key in ["root","support_dir","ignore_paths","include_paths"] { value.removeValue(forKey:key) }
        if let problem = value["configuration_error"] as? String, !problem.isEmpty { value["configuration_error"] = "配置读取失败（路径已省略）；请在设置中查看原错误" }
        value["diagnostic_scope"] = "不含搜索历史、文件内容、结果路径或索引范围"
        return value
    }
    static func export(engine:Engine,window:NSWindow?) {
        guard !Prefs.dryRun("export diagnostics",[]),let window else { return }
        let panel = NSSavePanel();panel.nameFieldStringValue = "Sift-diagnostics.json"
        panel.beginSheetModal(for:window) { response in
            guard response == .OK,let url = panel.url else { return }
            do { let data = try JSONSerialization.data(withJSONObject:redacted(engine.details()),options:[.prettyPrinted,.sortedKeys]);try data.write(to:url,options:.atomic) }
            catch { NSApp.presentError(error) }
        }
    }
    static func feedback(engine:Engine,window:NSWindow?) {
        guard !Prefs.dryRun("feedback",[]),let window else { return }
        let alert = NSAlert();alert.messageText = "反馈问题";alert.informativeText = "写明操作、期望与实际结果。保存本机说明和脱敏诊断后交给维护者，不会自动发送。"
        let input = NSTextField(frame:NSRect(x:0,y:0,width:380,height:80));input.placeholderString = "例如：输入什么、按了哪个键、实际出现什么…";alert.accessoryView = input
        alert.addButton(withTitle:"保存反馈…");alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:window) { result in
            guard result == .alertFirstButtonReturn else { return }
            let note = input.stringValue
            let panel = NSSavePanel();panel.nameFieldStringValue = "Sift-feedback.json"
            panel.beginSheetModal(for:window) { result in
                guard result == .OK,let url = panel.url else { return }
                do { let data = try JSONSerialization.data(withJSONObject:["description":note,"diagnostics":redacted(engine.details())],options:[.prettyPrinted,.sortedKeys]);try data.write(to:url,options:.atomic) }
                catch { NSApp.presentError(error) }
            }
        }
    }
}
