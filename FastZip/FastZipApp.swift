//  SPDX-FileCopyrightText: 2026 Tequila <2638884601@qq.com>
//  SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

@main
struct FastZipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 手动注册 URL scheme，避免 SwiftUI 自动开新窗口
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == "fastzip" else { return }

        // 激活已有窗口
        NSApp.windows.first?.makeKeyAndOrderFront(nil)

        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let filesParam = queryItems.first(where: { $0.name == "files" })?.value,
              let decoded = filesParam.removingPercentEncoding else { return }

        let paths = decoded.components(separatedBy: "|").filter { !$0.isEmpty }
        guard !paths.isEmpty else { return }

        NotificationCenter.default.post(
            name: .fastZipOpenFiles,
            object: nil,
            userInfo: ["paths": paths]
        )
    }
}

extension Notification.Name {
    static let fastZipOpenFiles = Notification.Name("fastZipOpenFiles")
}
