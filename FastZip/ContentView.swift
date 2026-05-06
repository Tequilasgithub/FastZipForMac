//  SPDX-FileCopyrightText: 2026 Tequila <2638884601@qq.com>
//  SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

// MARK: - 压缩文件条目

struct ArchiveItem: Identifiable {
    let id = UUID()
    let url: URL
    var isSelected: Bool = true

    var name: String { url.lastPathComponent }
    var relativePath: String { url.path(percentEncoded: false) }
}

// MARK: - 密码管理器（基于 Keychain 加密存储）

class PasswordManager: ObservableObject {
    static let shared = PasswordManager()

    @Published var items: [StoredItem] = []
    @Published var lastError: String?

    private let store = KeychainPasswordStore.shared

    private init() {
        loadFromKeychain()
    }

    func loadFromKeychain() {
        // 先从 Keychain 读
        if let loaded = try? store.loadAll(), !loaded.isEmpty {
            objectWillChange.send()
            items = loaded
            lastError = nil
            return
        }
        // Keychain 失败或为空，回退到 UserDefaults 备份
        if let data = UserDefaults.standard.data(forKey: "passwordBackup"),
           let loaded = try? JSONDecoder().decode([StoredItem].self, from: data),
           !loaded.isEmpty {
            objectWillChange.send()
            items = loaded
            lastError = nil
            // 恢复成功后写回 Keychain
            try? store.saveAll(loaded)
            return
        }
        items = []
    }

    func add(password: String, name: String = "", isManual: Bool = true) {
        let trimmed = password.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let itemName = name.trimmingCharacters(in: .whitespaces)
        // 手动添加不能含有「破解获得」
        if isManual && itemName.contains("破解获得") {
            lastError = "密码名不能含有「破解获得」"
            return
        }
        // 不允许密码名+密码值完全相同的条目
        if items.contains(where: { $0.name == itemName && $0.password == trimmed }) {
            lastError = "相同密码名和密码值的条目已存在"
            return
        }
        // 密码名：空名和「破解获得」允许多个，其余必须唯一
        if !itemName.isEmpty && itemName != "破解获得" && items.contains(where: { $0.name == itemName }) {
            lastError = "密码名「\(itemName)」已存在"
            return
        }
        let newItem = StoredItem(id: UUID().uuidString, name: itemName, password: trimmed, label: "FastZip")
        items.append(newItem)
        persist()
    }

    func delete(id: String) {
        items.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        items.removeAll()
        persist()
    }

    private func persist() {
        do {
            try store.saveAll(items)
            // 同步备份到 UserDefaults
            if let data = try? JSONEncoder().encode(items) {
                UserDefaults.standard.set(data, forKey: "passwordBackup")
            }
            objectWillChange.send()
            lastError = nil
        } catch {
            lastError = "保存失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    // 目录（保存到 UserDefaults）
    @State private var sourceDirectory: URL?
    @State private var outputDirectory: URL?

    // 格式筛选（持久化）
    let allExtensions = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz"]
    @State private var selectedExtensions: Set<String> = {
        if let saved = UserDefaults.standard.stringArray(forKey: "selectedExtensions") {
            return Set(saved)
        }
        return ["zip", "7z", "rar"]
    }()

    // 选项（@AppStorage 自动持久化）
    @AppStorage("deleteAfterExtraction") private var deleteAfterExtraction = false
    @AppStorage("createSubfolder") private var createSubfolder = false
    @AppStorage("recursiveScan") private var recursiveScan = true

    // 扫描结果
    @State private var scannedItems: [ArchiveItem] = []

    // 处理状态
    @State private var isProcessing = false
    @State private var processedCount = 0
    @State private var totalCount = 0
    @State private var successCount = 0

    // 单文件进度
    struct FileProgress: Identifiable {
        let id: String
        let fileName: String
        var totalBytes: UInt64 = 0
        var extractedBytes: UInt64 = 0
        var isDone: Bool = false
    }
    @State private var fileProgresses: [FileProgress] = []

    // 撤销
    struct TrashEntry { let original: URL; let trash: URL }
    @State private var deletedFileMappings: [TrashEntry] = []
    var deletedCount: Int { deletedFileMappings.count }

    // 日志
    @State private var logEntries: [LogEntry] = []

    // 密码（共享单例，供主窗口和密码管理窗口共用）
    @ObservedObject private var passwordManager = PasswordManager.shared
    @State private var passwordWindow: NSWindow?

    // 密码清除确认
    @State private var showClearPasswordAlert = false
    @State private var revealedPasswordIDs: Set<String> = []

    // 弹窗
    @State private var showAlert = false
    @State private var alertMessage = ""

    // 破解
    @State private var crackerText: String = ""
    @State private var crackerPasswords: [String] = []
    @State private var isCracking = false
    @State private var crackerTotal = 0
    @State private var crackerTested = 0
    @State private var crackerFound: [(file: String, password: String)] = []
    @State private var crackerError: String?
    @State private var selectedDictName = ""
    @State private var availableDicts: [String] = []

    // MARK: - Body

    var body: some View {
        VStack(spacing: 6) {
            // 拖拽区域提示
            if sourceDirectory == nil {
                dragHintView
            }
            headerView
            Divider()
            directorySection
            formatSection
            optionsSection
            actionButtons
            fileListView
            progressSection
            crackerSection
            logSection
                .frame(maxHeight: .infinity)
        }
        .padding(14)
        .frame(minWidth: 680)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
        .onAppear {
            restoreSavedState()
            scanAvailableDicts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastZipOpenFiles)) { notification in
            guard let paths = notification.userInfo?["paths"] as? [String], let first = paths.first else { return }
            let url = URL(fileURLWithPath: first)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first, isDirectory: &isDir) {
                if isDir.boolValue {
                    sourceDirectory = url
                    scannedItems = []
                    logEntries = []
                    if outputDirectory == nil { outputDirectory = url }
                } else {
                    sourceDirectory = url.deletingLastPathComponent()
                    scannedItems = []
                    logEntries = []
                    if outputDirectory == nil { outputDirectory = url.deletingLastPathComponent() }
                }
            }
        }
        .onChange(of: selectedExtensions) { newValue in
            UserDefaults.standard.set(Array(newValue), forKey: "selectedExtensions")
        }
        .alert("提示", isPresented: $showAlert) {
            Button("确定") {}
        } message: {
            Text(alertMessage)
        }
        .alert("确认清除全部密码？", isPresented: $showClearPasswordAlert) {
            Button("取消", role: .cancel) {}
            Button("清除全部", role: .destructive) {
                passwordManager.deleteAll()
            }
        } message: {
            Text("此操作不可撤销，所有保存的解压密码将被永久删除。")
        }
    }

    // MARK: - 拖拽处理

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let path = String(data: data, encoding: .utf8),
                      let url = URL(string: path) else { return }
                DispatchQueue.main.async {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
                        sourceDirectory = dir
                        scannedItems = []
                        logEntries = []
                        if outputDirectory == nil { outputDirectory = dir }
                    }
                }
            }
        }
    }

    private var dragHintView: some View {
        HStack {
            Image(systemName: "arrow.down.doc")
                .font(.title2).foregroundColor(.secondary)
            Text("将文件夹或压缩文件拖拽到此处以选择源目录")
                .font(.callout).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4])))
    }

    // MARK: - 标题

    private var headerView: some View {
        Text("批量解压工具")
            .font(.title)
            .fontWeight(.bold)
    }

    // MARK: - 目录选择

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("源目录：")
                Text(sourceDirectory?.path(percentEncoded: false) ?? "未选择")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(sourceDirectory == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button(sourceDirectory != nil ? "更换" : "选择...") { selectSourceDirectory() }
            }
            HStack {
                Text("输出目录：")
                Text(outputDirectory?.path(percentEncoded: false) ?? sourceDirectory?.path(percentEncoded: false) ?? "未选择")
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                Button("与源目录一致") {
                    outputDirectory = sourceDirectory
                    if let src = sourceDirectory {
                        saveDirectoryPath(src, key: "outputDirectory")
                    }
                }
                .disabled(sourceDirectory == nil || outputDirectory == sourceDirectory)
                Button("更换") { selectOutputDirectory() }
            }
        }
    }

    // MARK: - 格式筛选

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("解压格式：")
                    .font(.caption).foregroundColor(.secondary)
                Button("全选") { selectedExtensions = Set(allExtensions) }
                    .buttonStyle(.borderless).font(.caption)
                Button("清除") { selectedExtensions = [] }
                    .buttonStyle(.borderless).font(.caption)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 2, alignment: .leading)], spacing: 2) {
                ForEach(allExtensions, id: \.self) { ext in
                    Toggle(isOn: binding(for: ext)) {
                        Text(".\(ext)").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    // MARK: - 选项

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("解压成功后删除原压缩文件")
                Spacer()
                Toggle("", isOn: $deleteAfterExtraction)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
            }
            HStack {
                Text("为每个文件创建同名子文件夹")
                Spacer()
                Toggle("", isOn: $createSubfolder)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
            }
            HStack {
                Text("递归扫描子目录")
                Spacer()
                Toggle("", isOn: $recursiveScan)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()
            }

            HStack {
                Spacer()
                Button {
                    showPasswordWindow()
                } label: {
                    Label("管理密码", systemImage: "lock.shield.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button("扫描文件") { scanArchives() }
                .disabled(sourceDirectory == nil || isProcessing)

            Button("开始批量解压") { startBatchExtraction() }
                .buttonStyle(.borderedProminent)
                .disabled(scannedItems.filter(\.isSelected).isEmpty || isProcessing)

            if !deletedFileMappings.isEmpty && !isProcessing {
                Button("撤销删除 (\(deletedCount))") { undoDeletions() }
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - 文件列表（始终可见）

    @ViewBuilder
    private var fileListView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("扫描结果：\(scannedItems.isEmpty ? "暂无" : "共 \(scannedItems.count) 个文件")")
                    .font(.caption).foregroundColor(.secondary)
                if !scannedItems.isEmpty {
                    Spacer()
                    Button("全选") {
                        for i in scannedItems.indices { scannedItems[i].isSelected = true }
                    }
                    .buttonStyle(.borderless).font(.caption)
                    Button("取消全选") {
                        for i in scannedItems.indices { scannedItems[i].isSelected = false }
                    }
                    .buttonStyle(.borderless).font(.caption)

                }
            }

            if scannedItems.isEmpty {
                Text("点击「扫描文件」查看可解压文件列表")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach($scannedItems) { $item in
                            HStack(spacing: 4) {
                                Toggle("", isOn: $item.isSelected)
                                    .toggleStyle(.checkbox)
                                Text(item.relativePath)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundColor(item.isSelected ? .primary : .secondary)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(height: scannedItems.isEmpty ? 56 : min(140, CGFloat(scannedItems.count * 24 + 36)))
        .padding(8)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.15))
        )
    }

    // MARK: - 进度

    @ViewBuilder
    private var progressSection: some View {
        if isProcessing && totalCount > 0 {
            VStack(spacing: 6) {
                // 批量进度概览
                if totalCount > 0 {
                    ProgressView(value: Double(min(processedCount, totalCount)), total: Double(totalCount))
                }
                Text("\(processedCount) / \(totalCount)")
                    .font(.caption).foregroundColor(.secondary)

                // 各并发文件独立进度（隐藏已完成）
                ForEach(fileProgresses.filter { !$0.isDone }) { fp in
                    if fp.totalBytes > 0 {
                        VStack(spacing: 2) {
                            ProgressView(value: Double(min(fp.extractedBytes, fp.totalBytes)), total: Double(max(fp.totalBytes, 1)))
                            HStack {
                                Text(fp.fileName)
                                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                                Spacer()
                                Text("\(formatBytes(fp.extractedBytes)) / \(formatBytes(fp.totalBytes))")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 日志（始终可见）

    @ViewBuilder
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("日志").font(.headline)
                Spacer()
                if !logEntries.isEmpty {
                    Button("保存日志") { saveLog() }.buttonStyle(.borderless).font(.caption)
                    Button("清空日志") { logEntries.removeAll() }.buttonStyle(.borderless).font(.caption)
                }
                Button("打开输出目录") { openOutputDirectory() }.buttonStyle(.borderless).font(.caption)
            }

            if logEntries.isEmpty {
                Text("暂无日志，解压操作后将在此显示")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.15))
                    )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            let text = logEntries.map { entry in
                                let ts = timestampFormatter.string(from: entry.timestamp)
                                let name = entry.fileName.isEmpty ? "" : "[\(entry.fileName)] "
                                return "\(ts) \(entry.icon) \(name)\(entry.message)"
                            }.joined(separator: "\n")
                            Text(text)
                                .font(.caption)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                        .onChange(of: logEntries.count) { _ in
                            if let last = logEntries.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.15))
                    )
                    .frame(maxHeight: .infinity)
                }
            }
        }
    }

    // MARK: - 密码管理 Sheet


    // MARK: - 复选框绑定

    private func binding(for ext: String) -> Binding<Bool> {
        Binding(
            get: { selectedExtensions.contains(ext) },
            set: { newValue in
                if newValue { selectedExtensions.insert(ext) }
                else { selectedExtensions.remove(ext) }
            }
        )
    }

    // MARK: - 目录选择

    private func selectSourceDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择包含压缩文件的目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourceDirectory = url
        saveDirectoryPath(url, key: "sourceDirectory")
        scannedItems = []
        logEntries = []
        if outputDirectory == nil {
            outputDirectory = url
            saveDirectoryPath(url, key: "outputDirectory")
        }
    }

    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "选择解压输出目录"
        panel.directoryURL = sourceDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url
        saveDirectoryPath(url, key: "outputDirectory")
    }

    // MARK: - 密码管理窗口

    private func showPasswordWindow() {
        if let existing = passwordWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "解压密码管理"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PasswordManagementView(window: window))
        window.center()
        window.makeKeyAndOrderFront(nil)
        passwordWindow = window
    }

    // MARK: - 状态持久化

    private func restoreSavedState() {
        sourceDirectory = loadDirectoryPath(key: "sourceDirectory")
        outputDirectory = loadDirectoryPath(key: "outputDirectory")
    }

    private func saveDirectoryPath(_ url: URL, key: String) {
        UserDefaults.standard.set(url.path(percentEncoded: false), forKey: key)
    }

    private func loadDirectoryPath(key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key),
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - 扫描

    private func scanArchives() {
        guard let source = sourceDirectory else { return }

        Task {
            let files = await UnzipService.shared.findArchives(
                in: source.path(percentEncoded: false),
                extensions: Array(selectedExtensions),
                recursive: recursiveScan
            )
            await MainActor.run {
                scannedItems = files.map { ArchiveItem(url: $0, isSelected: true) }
                if files.isEmpty {
                    alertMessage = "未找到匹配的压缩文件"
                    showAlert = true
                }
            }
        }
    }

    // MARK: - 批量解压

    private func startBatchExtraction() {
        guard let output = outputDirectory ?? sourceDirectory else { return }

        let selected = scannedItems.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        // 检测 7z 是否安装
        if !UnzipService.isAvailable() {
            showInstallP7zipAlert()
            return
        }

        isProcessing = true
        totalCount = selected.count
        processedCount = 0
        successCount = 0
        let items = selected.map { $0.url }
        let useSubfolder = createSubfolder

        addLog("开始批量解压（3 并发），共 \(items.count) 个文件（\(useSubfolder ? "已启用" : "已禁用")子文件夹）", icon: "🚀", color: .blue)

        let maxConcurrent = 3

        Task {
            let queue = items
            var nextIndex = maxConcurrent

            await withTaskGroup(of: Void.self) { group in
                // 初始添加 maxConcurrent 个任务
                for i in 0..<min(maxConcurrent, queue.count) {
                    group.addTask {
                        await self.processOneFile(file: queue[i], output: output, createSubfolder: useSubfolder)
                        await MainActor.run {
                            processedCount += 1
                            if let idx = fileProgresses.firstIndex(where: { $0.id == queue[i].path(percentEncoded: false) }) {
                                fileProgresses[idx].isDone = true
                            }
                        }
                    }
                }
                // 每完成一个，补一个
                for await _ in group {
                    if nextIndex < queue.count {
                        let idx = nextIndex
                        nextIndex += 1
                        group.addTask {
                            await self.processOneFile(file: queue[idx], output: output, createSubfolder: useSubfolder)
                            await MainActor.run {
                                processedCount += 1
                                if let pi = fileProgresses.firstIndex(where: { $0.id == queue[idx].path(percentEncoded: false) }) {
                                    fileProgresses[pi].isDone = true
                                }
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                fileProgresses.removeAll()
                addLog("全部完成！成功 \(successCount) / \(items.count)", icon: "🎉", color: .blue)
                if !deletedFileMappings.isEmpty {
                    addLog("有 \(deletedCount) 个文件已被删除，可点击「撤销删除」从废纸篓恢复", icon: "💡", color: .orange)
                }
                isProcessing = false
            }
        }
    }

    private func processOneFile(file: URL, output: URL, createSubfolder: Bool) async {
        let archiveName = file.lastPathComponent
        let extractDir: String

        if createSubfolder {
            let baseName = (archiveName as NSString).deletingPathExtension
            // 保留源目录下的相对路径结构
            let relativeParent: String = {
                guard let source = sourceDirectory else { return "" }
                var srcPath = source.path(percentEncoded: false)
                if !srcPath.hasSuffix("/") { srcPath += "/" }
                let fileParent = file.deletingLastPathComponent().path(percentEncoded: false) + "/"
                if fileParent.hasPrefix(srcPath) {
                    let rel = String(fileParent.dropFirst(srcPath.count))
                    return rel.hasSuffix("/") ? String(rel.dropLast()) : rel
                }
                return ""
            }()
            let subPath = relativeParent.isEmpty ? baseName : relativeParent + "/" + baseName
            extractDir = output.path(percentEncoded: false) + "/" + subPath
        } else {
            extractDir = output.path(percentEncoded: false)
        }

        // 0. 注册进度条目
        let progressId = file.path(percentEncoded: false)
        await MainActor.run {
            fileProgresses.removeAll { $0.id == progressId }
            fileProgresses.append(FileProgress(id: progressId, fileName: archiveName))
        }
        if let total = await UnzipService.shared.totalUncompressedSize(at: file.path(percentEncoded: false)) {
            await MainActor.run {
                if let idx = fileProgresses.firstIndex(where: { $0.id == progressId }) {
                    fileProgresses[idx].totalBytes = total
                }
            }
        }

        var progressTask: Task<Void, Never>? = nil
        func startPolling(_ dir: String) {
            progressTask?.cancel()
            progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    fileProgresses.firstIndex(where: { $0.id == progressId }).map {
                        let size = dirSize(dir)
                        fileProgresses[$0].extractedBytes = min(size, fileProgresses[$0].totalBytes)
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        // 1. 用 7z l 预检是否加密（不挂死），非加密直接解
        let encrypted = await UnzipService.shared.isArchiveEncrypted(at: file.path(percentEncoded: false))

        if !encrypted {
            startPolling(extractDir)
            do {
                let extractedItems = try await UnzipService.shared.extract(
                    archivePath: file.path(percentEncoded: false),
                    outputPath: extractDir
                )
                progressTask?.cancel()
                await MainActor.run {
                    if let idx = fileProgresses.firstIndex(where: { $0.id == progressId }) {
                        fileProgresses[idx].extractedBytes = fileProgresses[idx].totalBytes
                    }
                    addLog("解压成功 (\(extractedItems.count) 个项目)", icon: "✅", color: .green, fileName: archiveName)
                    successCount += 1
                }
                await handlePostExtraction(file: file, archiveName: archiveName)
                return
            } catch {
                progressTask?.cancel()
                await MainActor.run { fileProgresses.removeAll { $0.id == progressId } }
                await addLogAsync(error.localizedDescription, icon: "❌", color: .red, fileName: archiveName)
                return
            }
        }

        // 2. 尝试已保存的密码（独立临时目录，避免并发冲突）
        let tmpDir = extractDir + "/.tmp_" + UUID().uuidString

        if !passwordManager.items.isEmpty {
            await addLogAsync("需要密码，尝试已保存的 \(passwordManager.items.count) 个密码...", icon: "🔒", color: .yellow, fileName: archiveName)

            for stored in passwordManager.items {
                try? FileManager.default.removeItem(atPath: tmpDir)

                do {
                    startPolling(tmpDir)
                    let extractedItems = try await UnzipService.shared.extract(
                        archivePath: file.path(percentEncoded: false),
                        outputPath: tmpDir,
                        password: stored.password
                    )
                    moveContents(from: tmpDir, to: extractDir)
                    try? FileManager.default.removeItem(atPath: tmpDir)
                    progressTask?.cancel()
                    await MainActor.run {
                        if let idx = fileProgresses.firstIndex(where: { $0.id == progressId }) {
                            fileProgresses[idx].extractedBytes = fileProgresses[idx].totalBytes
                        }
                        addLog("密码匹配，解压成功 (\(extractedItems.count) 个项目)", icon: "🔓", color: .green, fileName: archiveName)
                        successCount += 1
                    }
                    await handlePostExtraction(file: file, archiveName: archiveName)
                    return
                } catch {
                    continue
                }
            }
            try? FileManager.default.removeItem(atPath: tmpDir)
            await addLogAsync("已保存的 \(passwordManager.items.count) 个密码均不匹配", icon: "🔒", color: .yellow, fileName: archiveName)
        }

        // 3. 弹窗让用户手动输入密码
        guard let result = promptForPassword(archiveName: archiveName),
              !result.password.isEmpty else {
            await addLogAsync("用户跳过，解压失败", icon: "⏭", color: .orange, fileName: archiveName)
            return
        }

        try? FileManager.default.removeItem(atPath: tmpDir)
        do {
            startPolling(tmpDir)
            let extractedItems = try await UnzipService.shared.extract(
                archivePath: file.path(percentEncoded: false),
                outputPath: tmpDir,
                password: result.password
            )
            moveContents(from: tmpDir, to: extractDir)
            try? FileManager.default.removeItem(atPath: tmpDir)
            progressTask?.cancel()
            await MainActor.run {
                if let idx = fileProgresses.firstIndex(where: { $0.id == progressId }) {
                    fileProgresses[idx].extractedBytes = fileProgresses[idx].totalBytes
                }
                addLog("密码正确，解压成功 (\(extractedItems.count) 个项目)", icon: "🔓", color: .green, fileName: archiveName)
                successCount += 1
            }
            if result.shouldSave {
                passwordManager.add(password: result.password, name: result.name)
            }
            await handlePostExtraction(file: file, archiveName: archiveName)
        } catch {
            try? FileManager.default.removeItem(atPath: tmpDir)
            await addLogAsync("密码错误，解压失败", icon: "❌", color: .red, fileName: archiveName)
        }
    }

    // MARK: - 内嵌破解面板

    private var crackerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("密码破解").font(.headline)
                Spacer()
                Button {
                    let files = scannedItems.filter(\.isSelected).map(\.url)
                    startCrackingSelected(files)
                } label: {
                    Label("破解密码", systemImage: "key.horizontal").font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(scannedItems.filter(\.isSelected).isEmpty || isCracking)
            }

            TextEditor(text: .constant(String(crackerText.prefix(500))))
                .font(.system(.caption, design: .monospaced))
                .frame(height: 50)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.2)))
                .foregroundColor(.secondary)
                .disabled(true)

            HStack {
                Picker(selection: $selectedDictName) {
                    Text("未选中").tag("")
                    ForEach(availableDicts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.menu)
                .onChange(of: selectedDictName) { name in
                    if name.isEmpty {
                        crackerText = ""
                        crackerPasswords = []
                    } else {
                        loadCrackerBuiltin(name)
                    }
                }
                .fixedSize()

                Button("加载文件…") { loadCrackerFile() }
                    .buttonStyle(.bordered).controlSize(.small).font(.caption)

                if crackerPasswords.isEmpty {
                    Text("请选择字典").font(.caption).foregroundColor(.orange)
                } else {
                    Text("已加载 \(crackerPasswords.count) 个").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            if isCracking {
                HStack {
                    ProgressView(value: Double(crackerTested), total: Double(crackerTotal))
                    Text("\(crackerTested) / \(crackerTotal)").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("停止") {
                        isCracking = false
                        addLog("用户手动停止破解", icon: "⏹", color: .orange)
                    }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }

            if !crackerFound.isEmpty {
                ForEach(crackerFound, id: \.file) { item in
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("[\(item.file)] \(item.password)")
                            .font(.caption).foregroundColor(.green).textSelection(.enabled)
                    }
                }
            }

            if let err = crackerError {
                Text(err).font(.caption).foregroundColor(.red)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.04))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.15)))
    }

    private func parseCrackerDict(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func scanAvailableDicts() {
        guard let resourceDir = Bundle.main.resourceURL else { return }
        let dictsDir = resourceDir.appendingPathComponent("Dictionaries")
        if let contents = try? FileManager.default.contentsOfDirectory(at: dictsDir, includingPropertiesForKeys: nil) {
            availableDicts = contents
                .filter { $0.pathExtension == "txt" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()
        }
    }

    private func loadCrackerBuiltin(_ name: String) {
        selectedDictName = name
        // 文件夹引用模式下文件在 Dictionaries 子目录
        let fileURL = Bundle.main.resourceURL?
            .appendingPathComponent("Dictionaries")
            .appendingPathComponent("\(name).txt")
        guard let url = fileURL,
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            crackerError = "字典「\(name)」加载失败"
            return
        }
        crackerText = content
        crackerPasswords = parseCrackerDict(content).sorted(by: { $0.count < $1.count })
    }

    private func loadCrackerFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.message = "选择密码字典文件（每行一个密码）"
        guard panel.runModal() == .OK, let url = panel.url,
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        crackerText = content
        crackerPasswords = parseCrackerDict(content).sorted(by: { $0.count < $1.count })
    }

    private func startCrackingSelected(_ files: [URL]) {
        guard !isCracking else { return }

        guard !crackerPasswords.isEmpty else {
            alertMessage = "请先在下方密码破解面板中选择一个密码字典"
            showAlert = true
            return
        }

        isCracking = true
        crackerFound = []
        crackerError = nil
        crackerTotal = crackerPasswords.count
        crackerTested = 0

        Task {
            for file in files {
                guard isCracking else { break }
                let path = file.path(percentEncoded: false)
                let name = file.lastPathComponent

                let encrypted = await UnzipService.shared.isArchiveEncrypted(at: path)
                guard encrypted else {
                    await addLogAsync("非加密文件，跳过", icon: "⏭", color: .secondary, fileName: name)
                    continue
                }

                await addLogAsync("开始破解...", icon: "🔑", color: .yellow, fileName: name)
                await MainActor.run { crackerTested = 0 }
                for pwd in crackerPasswords {
                    guard isCracking else { break }
                    let match = await UnzipService.shared.testPassword(path: path, password: pwd)
                    crackerTested += 1
                    if match {
                        await MainActor.run {
                            crackerFound.append((file: name, password: pwd))
                            passwordManager.add(password: pwd, name: "破解获得", isManual: false)
                        }
                        await addLogAsync("密码找到：\(pwd)", icon: "✅", color: .green, fileName: name)
                        break
                    }
                }

                if crackerTested == crackerPasswords.count && crackerFound.allSatisfy({ $0.file != name }) {
                    await addLogAsync("未找到匹配密码", icon: "❌", color: .red, fileName: name)
                }
            }

            await MainActor.run { isCracking = false }
        }
    }

    // MARK: - 手动密码弹窗

    @MainActor
    private func promptForPassword(archiveName: String) -> (password: String, name: String, shouldSave: Bool)? {
        let alert = NSAlert()
        alert.messageText = "需要解压密码"
        alert.informativeText = "「\(archiveName)」已加密，请输入解压密码："
        alert.alertStyle = .informational
        alert.addButton(withTitle: "解压")
        alert.addButton(withTitle: "跳过")

        // 密码名称
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        nameField.placeholderString = "密码名称（可选）"

        // 密码输入框
        let textField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        textField.placeholderString = "输入解压密码"

        let saveCheckbox = NSButton(checkboxWithTitle: "保存此密码以便后续使用", target: nil, action: nil)
        saveCheckbox.state = .on

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 82))
        nameField.frame = NSRect(x: 0, y: 56, width: 280, height: 22)
        textField.frame = NSRect(x: 0, y: 30, width: 280, height: 22)
        saveCheckbox.frame = NSRect(x: 0, y: 4, width: 280, height: 18)
        container.addSubview(nameField)
        container.addSubview(textField)
        container.addSubview(saveCheckbox)
        alert.accessoryView = container

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let pwd = textField.stringValue
            let name = nameField.stringValue
            return (pwd, name, saveCheckbox.state == .on && !pwd.isEmpty)
        }
        return nil
    }

    /// 清理目录中的乱码空条目
    private func removeGarbledEntries(in dir: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for item in items {
            // 检测乱码：含非 ASCII 且变 GBK 后不同
            guard let data = item.data(using: .isoLatin1),
                  data.contains(where: { $0 >= 0x80 }),
                  fixGBKFilename(item) != item else { continue }
            let path = dir + "/" + item
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// 把临时目录的内容逐文件移到正式目录，自动修复中文乱码文件名
    private func moveContents(from src: String, to dst: String) {
        // 先清理正式目录中由 7z 失败尝试产生的空目录
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dst) {
            for e in existing {
                let ep = dst + "/" + e
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: ep, isDirectory: &isDir), isDir.boolValue {
                    let c = (try? FileManager.default.contentsOfDirectory(atPath: ep)) ?? []
                    if c.isEmpty { try? FileManager.default.removeItem(atPath: ep) }
                }
            }
        }

        guard let items = try? FileManager.default.contentsOfDirectory(atPath: src) else { return }
        for item in items {
            let srcPath = src + "/" + item
            let fixedName = fixGBKFilename(item)
            let dstPath = dst + "/" + fixedName
            try? FileManager.default.removeItem(atPath: dstPath)
            try? FileManager.default.moveItem(atPath: srcPath, toPath: dstPath)
            // 子目录递归修复
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dstPath, isDirectory: &isDir), isDir.boolValue {
                fixGBKInDirectory(dstPath)
            }
        }
    }

    /// GBK 乱码文件名 → UTF-8
    private func fixGBKFilename(_ name: String) -> String {
        guard let data = name.data(using: .isoLatin1) ?? name.data(using: .ascii, allowLossyConversion: true),
              data.contains(where: { $0 >= 0x80 }) else { return name }
        let enc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let fixed = String(data: data, encoding: String.Encoding(rawValue: enc)) {
            return fixed
        }
        return name
    }

    /// 递归修复目录下所有文件的 GBK 乱码
    private func fixGBKInDirectory(_ dir: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for item in items {
            let oldPath = dir + "/" + item
            let newName = fixGBKFilename(item)
            if newName != item {
                let newPath = dir + "/" + newName
                try? FileManager.default.removeItem(atPath: newPath)
                try? FileManager.default.moveItem(atPath: oldPath, toPath: newPath)
            }
            var isDir: ObjCBool = false
            let checkPath = newName != item ? (dir + "/" + newName) : oldPath
            if FileManager.default.fileExists(atPath: checkPath, isDirectory: &isDir), isDir.boolValue {
                fixGBKInDirectory(checkPath)
            }
        }
    }

    private func isPasswordError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("wrong password") ||
               lower.contains("cannot open encrypted") ||
               lower.contains("can not open encrypted")
    }

    private func handlePostExtraction(file: URL, archiveName: String) async {
        guard deleteAfterExtraction else { return }
        do {
            try recycleFile(file, archiveName: archiveName)
        } catch {
            await addLogAsync("删除失败: \(error.localizedDescription)", icon: "⚠️", color: .yellow, fileName: archiveName)
        }
    }

    private func recycleFile(_ url: URL, archiveName: String) throws {
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        if let trash = trashURL as URL? {
            deletedFileMappings.append(TrashEntry(original: url, trash: trash))
            addLog("已移至废纸篓", icon: "🗑", color: .orange, fileName: archiveName)
        }
    }

    // MARK: - 撤销删除

    private func undoDeletions() {
        var restored = 0
        for mapping in deletedFileMappings {
            if FileManager.default.fileExists(atPath: mapping.trash.path(percentEncoded: false)) {
                do {
                    try FileManager.default.moveItem(at: mapping.trash, to: mapping.original)
                    restored += 1
                } catch {
                    addLog("恢复失败", icon: "⚠️", color: .yellow, fileName: mapping.original.lastPathComponent)
                }
            }
        }
        deletedFileMappings.removeAll()
        if restored > 0 {
            addLog("已从废纸篓恢复 \(restored) 个文件", icon: "↩️", color: .green)
        }
    }

    // MARK: - 日志

    private func addLog(_ message: String, icon: String, color: Color, fileName: String? = nil) {
        logEntries.append(LogEntry(
            fileName: fileName ?? "",
            message: message,
            icon: icon,
            color: color
        ))
    }

    private func addLogAsync(_ message: String, icon: String, color: Color, fileName: String? = nil) async {
        await MainActor.run {
            addLog(message, icon: icon, color: color, fileName: fileName)
        }
    }

    private let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// 递归计算目录字节总数
    nonisolated private func dirSize(_ path: String) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        while let file = enumerator.nextObject() as? String {
            let fp = path + "/" + file
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fp),
               let size = attrs[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    /// 格式化字节显示
    private func formatBytes(_ bytes: UInt64) -> String {
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }

    private func showInstallP7zipAlert() {
        let alert = NSAlert()
        alert.messageText = "未找到 7z 解压工具"
        alert.informativeText = "FastZip 依赖 p7zip 进行压缩文件解压。\n点击「安装」将通过 Homebrew 自动安装 p7zip。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "安装")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            installP7zip()
        }
    }

    private func installP7zip() {
        addLog("开始安装 p7zip...", icon: "📦", color: .blue)
        Task {
            // 自动检测 brew 路径（Apple Silicon > Intel > Shell 查找）
            let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            var brewPath = "/opt/homebrew/bin/brew"
            for p in brewPaths where FileManager.default.isExecutableFile(atPath: p) {
                brewPath = p; break
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = ["install", "p7zip"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    await addLogAsync("p7zip 安装成功，现在可以解压了", icon: "✅", color: .green)
                } else {
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    await addLogAsync("安装失败: \(out)", icon: "❌", color: .red)
                }
            } catch {
                await addLogAsync("安装出错: \(error.localizedDescription)\n请手动运行: brew install p7zip", icon: "❌", color: .red)
            }
        }
    }

    private func saveLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "解压日志_\(dateString()).txt"
        panel.message = "保存日志文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let lines = logEntries.map { entry in
            let namePart = entry.fileName.isEmpty ? "" : "[\(entry.fileName)] "
            return "\(namePart)\(entry.message)"
        }
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            alertMessage = "保存日志失败"
            showAlert = true
        }
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private func openOutputDirectory() {
        let dir = outputDirectory ?? sourceDirectory
        guard let dir else { return }
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - 日志条目

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let fileName: String
    let message: String
    let icon: String
    let color: Color
}

// MARK: - 独立密码管理窗口

struct PasswordManagementView: View {
    @ObservedObject private var passwordManager = PasswordManager.shared

    let window: NSWindow?

    @State private var newPassword = ""
    @State private var passwordName = ""
    @State private var revealedIDs: Set<String> = []
    @State private var selectedIDs: Set<String> = []
    @State private var lockedIDs: Set<String> = []
    @State private var showDeleteSelectedAlert = false

    var body: some View {
        VStack(spacing: 16) {
            if let error = passwordManager.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
                    Text(error).font(.caption).foregroundColor(.red)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .cornerRadius(6)
            }

            if passwordManager.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lock.slash").font(.title).foregroundColor(.secondary)
                    Text("暂无保存的密码").foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 工具栏（固定高度，避免按钮出现/消失导致列表跳动）
                HStack {
                    Toggle("选中全部", isOn: Binding(
                        get: { selectedIDs.count == passwordManager.items.filter({ !lockedIDs.contains($0.id) }).count && !passwordManager.items.isEmpty },
                        set: { newValue in
                            selectedIDs = newValue
                                ? Set(passwordManager.items.filter { !lockedIDs.contains($0.id) }.map(\.id))
                                : []
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(passwordManager.items.isEmpty)

                    if !selectedIDs.isEmpty {
                        Button(role: .destructive) {
                            showDeleteSelectedAlert = true
                        } label: {
                            Label("删除选中 (\(selectedIDs.count))", systemImage: "trash").font(.caption)
                        }
                    } else {
                        // 占位，保持高度不变
                        Color.clear.frame(height: 16)
                    }
                    Spacer()
                }
                .frame(height: 22)

                List {
                    ForEach(passwordManager.items) { item in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { selectedIDs.contains(item.id) },
                                set: { newValue in
                                    if newValue { selectedIDs.insert(item.id) }
                                    else { selectedIDs.remove(item.id) }
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(lockedIDs.contains(item.id))

                            if !item.name.isEmpty {
                                Text(item.name)
                                    .font(.caption).fontWeight(.medium)
                                    .lineLimit(1)
                                Text("·").font(.caption).foregroundColor(.secondary)
                            }
                            if revealedIDs.contains(item.id) {
                                Text(item.password)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text(String(repeating: "•", count: min(item.password.count, 16)))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                if revealedIDs.contains(item.id) { revealedIDs.remove(item.id) }
                                else { revealedIDs.insert(item.id) }
                            } label: {
                                Image(systemName: revealedIDs.contains(item.id) ? "eye.slash" : "eye").font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.borderless)
                            Button {
                                if lockedIDs.contains(item.id) { lockedIDs.remove(item.id) }
                                else { lockedIDs.insert(item.id) }
                            } label: {
                                Image(systemName: lockedIDs.contains(item.id) ? "lock.fill" : "lock.open")
                                    .font(.caption)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            let id = passwordManager.items[i].id
                            if !lockedIDs.contains(id) {
                                passwordManager.delete(id: id)
                                selectedIDs.remove(id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 120)
            }

            Divider()

            VStack(spacing: 6) {
                TextField("密码名称（可选）", text: $passwordName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("输入新密码", text: $newPassword)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        passwordManager.add(password: newPassword, name: passwordName)
                        newPassword = ""
                        passwordName = ""
                    }
                    .disabled(newPassword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            HStack {
                Spacer()
                Button("关闭") {
                    window?.close()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 450)
        .alert("确认删除选中的密码？", isPresented: $showDeleteSelectedAlert) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                for id in selectedIDs where !lockedIDs.contains(id) {
                    passwordManager.delete(id: id)
                }
                selectedIDs = []
            }
        } message: {
            Text("将删除 \(selectedIDs.count) 条密码，此操作不可撤销。")
        }
    }
}

// MARK: - macOS 滑动开关样式

struct SwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Capsule()
                .fill(configuration.isOn ? Color.accentColor : Color.gray.opacity(0.35))
                .frame(width: 34, height: 20)
            Circle()
                .fill(Color.white)
                .frame(width: 16, height: 16)
                .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
                .offset(x: configuration.isOn ? 7 : -7)
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                configuration.isOn.toggle()
            }
        }
    }
}

