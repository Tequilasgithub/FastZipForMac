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
    ///   - archivePath: .7z 文件路径
    ///   - outputPath: 输出目录路径
    ///   - password: 可选密码
    /// - Returns: 解压出的文件/文件夹列表
    func extract(
        archivePath: String,
        outputPath: String,
        password: String? = nil
    ) async throws -> [String] {
        let sevenZ = try locateSevenZ()

        // 确保输出目录存在
        try FileManager.default.createDirectory(
            atPath: outputPath,
            withIntermediateDirectories: true
        )

        // -aou 遇同名自动重命名 / -bb1 详细输出计数
        var args = ["x", archivePath, "-o" + outputPath, "-aou", "-bb1"]

        if let pwd = password, !pwd.isEmpty {
            args.append("-p" + pwd)
        } else {
            args.append("-p")  // 不加 -p 加密 zip/7z 会挂死等交互输入
        }

        // 执行 7z 命令
        let output = try await shellWithProgress(sevenZ, args)

        // 解析输出，提取解压出的文件名
        let files = parseOutput(output, basePath: outputPath)
        return files
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
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sevenZ)
                process.arguments = ["l", path, "-slt"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    var total: UInt64 = 0
                    for line in output.components(separatedBy: .newlines) {
                        if line.hasPrefix("Size = ") {
                            let numStr = line.replacingOccurrences(of: "Size = ", with: "").trimmingCharacters(in: .whitespaces)
                            if let s = UInt64(numStr) { total += s }
                        }
                    }
                    cont.resume(returning: total > 0 ? total : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// 检测压缩文件是否加密
    func isArchiveEncrypted(at path: String) async -> Bool {
        guard let sevenZ = try? locateSevenZ() else { return false }

        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sevenZ)
                process.arguments = ["l", path, "-slt", "-p"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()

                do {
                    try process.run()
                    let deadline = DispatchTime.now() + .seconds(10)
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        process.waitUntilExit()
                        group.leave()
                    }
                    _ = group.wait(timeout: deadline)
                    if process.isRunning { process.terminate() }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    cont.resume(returning: output.contains("Encrypted = +"))
                } catch {
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

        process.waitUntilExit()

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
            return """
            未找到 7z 命令。

            请先通过 Homebrew 安装 p7zip：
              brew install p7zip

            安装完成后重启本应用即可。
            """
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
