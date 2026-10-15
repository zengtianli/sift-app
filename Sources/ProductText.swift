import AppKit

/// Bundled Chinese copy with an optional per-Mac override; never supplies actions or paths.
enum SiftText {
    private static let titles:[String:(String,String)] = [
        "About Sift":("menu.about","关于 Sift"),"Settings…":("menu.settings","设置…"),
        "Hide Sift":("menu.hide","隐藏 Sift"),"Hide Others":("menu.hide.others","隐藏其他"),"Show All":("menu.show.all","显示全部"),"Quit Sift":("menu.quit","退出 Sift"),
        "File":("menu.file","文件"),"Edit":("menu.edit","编辑"),"Search":("menu.search","搜索"),"Window":("menu.window","窗口"),
        "Open":("menu.open","打开"),"Show in Finder":("menu.reveal","在 Finder 中显示"),"Quick Look":("menu.preview","快速查看"),"Move to Trash":("menu.trash","移到废纸篓"),
        "Undo":("menu.undo","撤销"),"Redo":("menu.redo","重做"),"Cut":("menu.cut","剪切"),"Copy":("menu.copy","复制"),"Paste":("menu.paste","粘贴"),"Select All":("menu.select.all","全选"),
        "Copy Path":("menu.copy.path","复制路径"),"Copy Name":("menu.copy.name","复制文件名"),"Find":("menu.find","查找"),"Focus Search Field":("menu.focus","聚焦搜索框"),
        "Recent Searches":("menu.history","最近搜索"),"Limit to Folders":("menu.scope","文件夹范围"),"Match Case":("menu.case","区分大小写"),
        "Sort by Name":("menu.sort.name","按名称排序"),"Sort by Folder":("menu.sort.folder","按文件夹排序"),"Sort by Size":("menu.sort.size","按大小排序"),
        "Sort by Date Modified":("menu.sort.modified","按修改时间排序"),"Sort by Date Created":("menu.sort.created","按创建时间排序"),"Re-index Everything":("menu.reindex","重建索引"),
        "Search Window":("menu.show","搜索窗口"),"Minimize":("menu.minimize","最小化"),"Choose Folder to Index…":("index.choose","选择索引文件夹…"),"Grant Full Disk Access…":("index.access","授予完全磁盘访问权限…"),
        "Search file names":("search.placeholder","搜索文件名或路径"),"In folders matching…":("search.folder","在匹配的文件夹中…"),"Name":("column.name","名称"),"Folder":("column.folder","文件夹"),"Size":("column.size","大小"),"Modified":("column.modified","修改时间"),"Created":("column.created","创建时间"),
        "No recent searches":("history.empty","暂无最近搜索"),"Clear Recent Searches":("history.clear","清除最近搜索")
    ]
    private static let copy:[String:String] = {
        func read(_ url:URL?) -> [String:String] {
            guard let url,let data = try? Data(contentsOf:url),data.count <= 65536,
                  let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let copy = object["copy"] as? [String:String],copy.count <= 256,
                  copy.values.allSatisfy({ !$0.isEmpty && $0.count <= 2048 }) else { return [:] };return copy
        }
        var values = read(Bundle.main.url(forResource:"UI.zh-Hans",withExtension:"json"))
        let external = URL(fileURLWithPath:ProcessInfo.processInfo.environment["SIFT_SUPPORT_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/cyou.tianli.sift")).appendingPathComponent("ui.json")
        for (key,value) in read(external) { values[key] = value };return values
    }()
    static func title(_ original:String) -> String {
        guard let (key,fallback) = titles[original] else { return original };return copy[key] ?? fallback
    }
    static func menu(_ menu:NSMenu) {
        menu.title = title(menu.title)
        for item in menu.items { item.title = title(item.title);if let submenu = item.submenu { self.menu(submenu) } }
    }
}
