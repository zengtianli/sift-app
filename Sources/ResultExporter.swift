import AppKit
import UniformTypeIdentifiers

enum ResultExporter {
    private final class FormatSelection:NSObject {
        weak var panel:NSSavePanel?
        init(_ panel:NSSavePanel) { self.panel = panel }
        @objc func changed(_ sender:NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard let panel,(0...2).contains(index) else { return }
            let ext = ["json","csv","txt"][index]
            panel.allowedContentTypes = [[UTType.json],[.commaSeparatedText],[.plainText]][index]
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        }
    }
    static func write(engine:Engine,results:ResultSet,to destination:URL,format:Int) throws -> Int {
        guard (0...2).contains(format) else { throw NSError(domain:"Sift",code:2) }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".sift-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:staging) }
        FileManager.default.createFile(atPath:staging.path,contents:Data())
        let file = try FileHandle(forWritingTo:staging);defer { try? file.close() }
        func write(_ s:String) throws { try file.write(contentsOf:Data(s.utf8)) }
        if format == 0 { try write("{\"total\":\(results.count),\"results\":[") }
        else if format == 1 { try write("path,kind,size,modified,created\r\n") }
        var count = 0
        for start in stride(from:0,to:results.count,by:1024) {
            let expected = min(1024,results.count-start), rows = engine.rows(results,start:start,count:min(1024,results.count-start))
            guard rows.count == expected else { throw NSError(domain:"Sift",code:1,userInfo:[NSLocalizedDescriptionKey:"导出期间索引有变化，请重试；原文件已保留"]) }
            for row in rows {
                let kind = ["file","dir","symlink","unknown"][min(Int(row.kind),3)]
                if format == 0 {
                    if count > 0 { try write(",") }
                    var value:[String:Any] = ["path":row.path,"kind":kind]
                    if row.known { if !row.isDirectory { value["size"] = row.size };value["mtime"] = row.mtime;value["ctime"] = row.ctime }
                    try file.write(contentsOf:JSONSerialization.data(withJSONObject:value,options:.sortedKeys))
                } else if format == 1 {
                    let values = [row.path,kind,row.known && !row.isDirectory ? String(row.size) : "",row.known ? String(row.mtime) : "",row.known ? String(row.ctime) : ""].map{"\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\""}
                    try write(values.joined(separator:",") + "\r\n")
                } else { try write(row.path + "\n") }
                count += 1
            }
        }
        if format == 0 { try write("],\"exported\":\(count)}\n") }
        try file.synchronize();try file.close()
        if FileManager.default.fileExists(atPath:destination.path) { _ = try FileManager.default.replaceItemAt(destination,withItemAt:staging) }
        else { try FileManager.default.moveItem(at:staging,to:destination) }
        return count
    }
    static func export(engine:Engine,results:ResultSet,window:NSWindow) {
        let panel = NSSavePanel();panel.nameFieldStringValue = "Sift-results.json"
        let format = NSPopUpButton();format.addItems(withTitles:["JSON","CSV","路径清单"]);panel.accessoryView = format
        let selection = FormatSelection(panel);format.target = selection;format.action = #selector(FormatSelection.changed(_:));selection.changed(format)
        panel.beginSheetModal(for:window) { [selection] response in
            _ = selection // NSControl's target is weak; retain it for this sheet's lifetime.
            guard response == .OK,let destination = panel.url else { return }
            let selected = format.indexOfSelectedItem
            DispatchQueue.global(qos:.utility).async {
                do {
                    let count = try write(engine:engine,results:results,to:destination,format:selected)
                    DispatchQueue.main.async { let alert = NSAlert();alert.messageText = "已导出 \(count) 项结果";alert.informativeText = destination.path;alert.beginSheetModal(for:window,completionHandler:nil) }
                } catch { DispatchQueue.main.async{NSApp.presentError(error)} }
            }
        }
    }
}
