//  SPDX-FileCopyrightText: 2026 Tequila <2638884601@qq.com>
//  SPDX-License-Identifier: GPL-3.0-or-later
import Cocoa
import FinderSync

class FinderSync: FIFinderSync {

    override init() {
        super.init()
        let root = URL(fileURLWithPath: "/")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let volumes = URL(fileURLWithPath: "/Volumes")
        let iCloud = home.appendingPathComponent("Library/Mobile Documents")
        FIFinderSyncController.default().directoryURLs = [root, home, volumes, iCloud]
        NSLog("[FastZip] FinderSync initialized with %lu directory URLs", FIFinderSyncController.default().directoryURLs?.count ?? 0)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "在 FastZip 中打开", action: #selector(openInFastZip(_:)), keyEquivalent: "")
        // 用主 App 图标
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.example.FastZip") {
            item.image = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        item.image?.size = NSSize(width: 16, height: 16)
        menu.addItem(item)
        return menu
    }

    @objc func openInFastZip(_ sender: Any) {
        guard let items = FIFinderSyncController.default().selectedItemURLs() else { return }
        let paths = items.map { $0.path(percentEncoded: false) }.joined(separator: "|")
        let encoded = paths.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "fastzip://open?files=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}
