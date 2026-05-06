//  SPDX-FileCopyrightText: 2026 Tequila <2638884601@qq.com>
//  SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// 解压服务，负责调用系统上的 7z 命令行工具
actor UnzipService {
    static let shared = UnzipService()

    private var sevenZPath: String?

    /// 查找 7z 可执行文件路径
    private func locateSevenZ() throws -> String {
        if let cached = sevenZPath { return cached }

        // 可能的安装路径
        let candidates = [
            "/opt/homebrew/bin/7z",      // Apple Silicon Homebrew
            "/usr/local/bin/7z",         // Intel Homebrew
            "/usr/bin/7z",               // 系统路径
            "/opt/local/bin/7z",         // MacPorts
        ]

        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                sevenZPath = path
                return path
            }
        }

        // 最后尝试用 which 查找
        if let whichPath = try? shell("/bin/bash", ["-l", "-c", "which 7z"]).trimmingCharacters(in: .whitespacesAndNewlines),
           !whichPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: whichPath) {
            sevenZPath = whichPath
            return whichPath
        }

        throw UnzipError.sevenZNotFound
    }

    /// 解压文件
    /// - Parameters:
    ///   - archivePath: 压缩文件路径
    ///   - outputPath: 输出目录路径
    ///   - password: 可选密码（仅 7z/rar 格式生效）
    /// - Returns: 解压出的文件/文件夹列表
    func extract(
        archivePath: String,
        outputPath: String,
        password: String? = nil
    ) async throws -> [String] {
        // 确保输出目录存在
        try FileManager.default.createDirectory(
            atPath: outputPath,
            withIntermediateDirectories: true
        )

        let lower = archivePath.lowercased()
        let hasPassword = password.map { !$0.isEmpty } ?? false

        // 有密码 → 只有 7z 能处理（系统原生工具不支持密码）
        if !hasPassword {
            // ZIP → ditto（最快，不损坏 .app 签名）
            if lower.hasSuffix(".zip") {
                return try runNativeExtractor("/usr/bin/ditto", args: ["-xk", archivePath, outputPath],
                                              name: "ditto", outputDir: outputPath)
            }

            // tar 系列 → 系统 tar（自动检测压缩算法）
            if isTarLike(lower) {
                return try runNativeExtractor("/usr/bin/tar", args: ["-xf", archivePath, "-C", outputPath],
                                              name: "tar", outputDir: outputPath)
            }

            // 单文件 .gz → gunzip
            if lower.hasSuffix(".gz") {
                let stem = String((archivePath as NSString).lastPathComponent.dropLast(3))
                return try decompressStandalone(archivePath: archivePath, outputPath: outputPath,
                                                outputName: stem, tool: "/usr/bin/gunzip", args: ["-c"])
            }

            // 单文件 .bz2 → bunzip2
            if lower.hasSuffix(".bz2") {
                let stem = String((archivePath as NSString).lastPathComponent.dropLast(4))
                return try decompressStandalone(archivePath: archivePath, outputPath: outputPath,
                                                outputName: stem, tool: "/usr/bin/bunzip2", args: ["-c"])
            }

            // 单文件 .xz → xz
            if lower.hasSuffix(".xz") {
                let stem = String((archivePath as NSString).lastPathComponent.dropLast(3))
                return try decompressStandalone(archivePath: archivePath, outputPath: outputPath,
                                                outputName: stem, tool: "/usr/bin/xz", args: ["-d", "-c"])
            }
        }

        // 其余格式（7z / rar）走 7z
        let sevenZ = try locateSevenZ()

        var args = ["x", archivePath, "-o" + outputPath, "-aou"]

        if let pwd = password, !pwd.isEmpty {
            args.append("-p" + pwd)
        } else {
            args.append("-p")  // 不加 -p 加密 zip/7z 会挂死等交互输入
        }

        let output = try await shellWithProgress(sevenZ, args)
        let files = parseOutput(output, basePath: outputPath)
        return files
    }

    /// 判断是否可用系统原生工具解压（不支持密码，无需 7z 预检）
    static func isNativeFormat(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasSuffix(".zip") { return true }
        if lower.hasSuffix(".7z") || lower.hasSuffix(".rar") { return false }
        // tar / gz / bz2 / xz 都可用系统工具
        return lower.hasSuffix(".tar") || lower.hasSuffix(".gz") ||
               lower.hasSuffix(".bz2") || lower.hasSuffix(".xz") ||
               lower.hasSuffix(".tgz") || lower.hasSuffix(".tbz2") || lower.hasSuffix(".txz")
    }

    // MARK: - Private helpers

    /// 检查是否为 tar 系列格式
    private func isTarLike(_ lower: String) -> Bool {
        lower.hasSuffix(".tar") || lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") ||
        lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz2") ||
        lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz")
    }

    /// 运行系统原生解压工具，返回输出目录中的条目列表
    nonisolated private func runNativeExtractor(_ tool: String, args: [String],
                                                 name: String, outputDir: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UnzipError.extractionFailed(message: "\(name) 解压失败")
        }
        return listExtractedItems(in: outputDir)
    }

    /// 解压单文件格式（.gz / .bz2 / .xz），输出到指定文件名
    nonisolated private func decompressStandalone(archivePath: String, outputPath: String,
                                                   outputName: String, tool: String,
                                                   args toolArgs: [String]) throws -> [String] {
        let outFile = outputPath + "/" + outputName
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let escapedIn = archivePath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedOut = outFile.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = ["-c", "\(tool) \(toolArgs.joined(separator: " ")) '\(escapedIn)' > '\(escapedOut)'"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw UnzipError.extractionFailed(message: "\(tool) 解压失败")
        }
        return [outputName]
    }

    /// 列出目录中的条目
    nonisolated private func listExtractedItems(in directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory))?.sorted() ?? []
    }

    /// 递归搜索目录中匹配扩展名的压缩文件
    func findArchives(in directory: String, extensions: [String], recursive: Bool = true) -> [URL] {
        let dirURL = URL(fileURLWithPath: directory)

        if recursive {
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return [] }
            return filterArchives(from: enumerator, extensions: extensions)
        } else {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return filterArchives(from: urls, extensions: extensions)
        }
    }

    private func filterArchives(from items: Any, extensions: [String]) -> [URL] {
        var results: [URL] = []

        let fileURLs: [URL]
        if let enumerator = items as? FileManager.DirectoryEnumerator {
            fileURLs = enumerator.compactMap { $0 as? URL }
        } else if let urls = items as? [URL] {
            fileURLs = urls
        } else {
            return []
        }

        for fileURL in fileURLs {
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular else { continue }

            let ext = fileURL.pathExtension.lowercased()
            var matched = extensions.contains(ext)

            if !matched {
                let name = fileURL.lastPathComponent.lowercased()
                for e in extensions where e.contains(".") {
                    if name.hasSuffix("." + e) {
                        matched = true
                        break
                    }
                }
            }

            if matched {
                results.append(fileURL)
            }
        }

        return results.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 获取压缩文件解压后的总大小（字节）
    func totalUncompressedSize(at path: String) async -> UInt64? {
        guard let sevenZ = try? locateSevenZ() else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                guard let result = self.runWithTimeout(executable: sevenZ, arguments: ["l", path, "-slt"], timeout: 30) else {
                    cont.resume(returning: nil); return
                }
                var total: UInt64 = 0
                for line in result.output.components(separatedBy: .newlines) {
                    if line.hasPrefix("Size = ") {
                        let numStr = line.replacingOccurrences(of: "Size = ", with: "").trimmingCharacters(in: .whitespaces)
                        if let s = UInt64(numStr) { total += s }
                    }
                }
                cont.resume(returning: total > 0 ? total : nil)
            }
        }
    }

    nonisolated private func runWithTimeout(executable: String, arguments: [String], timeout: Int) -> (output: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let deadline = DispatchTime.now() + .seconds(timeout)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
            if group.wait(timeout: deadline) == .timedOut {
                process.terminate()
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
        } catch {
            return nil
        }
    }

    /// 检测压缩文件是否加密
    func isArchiveEncrypted(at path: String) async -> Bool {
        guard let sevenZ = try? locateSevenZ() else { return false }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                if let result = self.runWithTimeout(executable: sevenZ, arguments: ["l", path, "-slt"], timeout: 30) {
                    cont.resume(returning: result.output.contains("Encrypted = +"))
                } else {
                    cont.resume(returning: false)
                }
            }
        }
    }

    /// 检查 7z 是否可用
    static func isAvailable() -> Bool {
        let paths = [
            "/opt/homebrew/bin/7z",
            "/usr/local/bin/7z",
            "/usr/bin/7z",
        ]
        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return true
            }
        }
        return false
    }

    // MARK: - Private

    /// 同步执行 shell 命令，返回 stdout
    private func shell(_ command: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 异步执行 7z 并读取输出
    private func shellWithProgress(_ command: String, _ args: [String]) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runProcess(executable: command, arguments: args)
                switch result {
                case .success(let output):
                    continuation.resume(returning: output)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 同步执行进程并返回结果（不访问 actor 状态，故标记 nonisolated）
    nonisolated private func runProcess(executable: String, arguments: [String]) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return .failure(UnzipError.extractionFailed(message: error.localizedDescription))
        }

        // 预检类操作 15 秒超时，避免挂死
        let isPrecheck = arguments.first == "l" || arguments.first == "t"
        let deadline = DispatchTime.now() + (isPrecheck ? .seconds(15) : .seconds(600))
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return .failure(UnzipError.extractionFailed(message: "7z 超时未响应"))
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus == 0 {
            let output = String(data: data, encoding: .utf8) ?? ""
            return .success(output)
        } else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? ""
            return .failure(UnzipError.extractionFailed(
                message: errorMessage.isEmpty ? "7z 返回了错误码 \(process.terminationStatus)" : errorMessage
            ))
        }
    }

    /// 解析 7z -bb1 输出，提取解压出的文件名列表
    private func parseOutput(_ output: String, basePath: String) -> [String] {
        var files: [String] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // -bb1 输出中解压文件行以 "- " 开头，如 "- path/to/file.jpg"
            if trimmed.hasPrefix("- ") {
                let relativePath = String(trimmed.dropFirst(2))
                if !relativePath.isEmpty {
                    files.append(relativePath)
                }
            }
        }

        return files.sorted()
    }
}

// MARK: - 错误类型

enum UnzipError: LocalizedError {
    case sevenZNotFound
    case extractionFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .sevenZNotFound:
            return "未找到 7z"
        case .extractionFailed(let message):
            return "解压失败：\(message)"
        }
    }
}

// MARK: - 密码破解

extension UnzipService {
    /// 测试单个密码是否正确（用 7z t 不解压）
    func testPassword(path: String, password: String) async -> Bool {
        guard let sevenZ = try? locateSevenZ() else { return false }

        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sevenZ)
                process.arguments = ["t", path, "-p" + password]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                    cont.resume(returning: process.terminationStatus == 0)
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }
}
