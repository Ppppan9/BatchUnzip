import AppKit

// 批量解压 —— 从 Finder「打开方式」批量解压 zip/rar/7z/tar 等
// GUI: 接收 Finder 的 odoc Apple Event → 询问密码 → 逐个解压 → 汇总结果
// CLI: BatchUnzip [-p 密码] 文件... （无界面，用于脚本/测试）

let fm = FileManager.default
// .001~.099 是 7z/zip 等分卷的编号扩展名：首卷(.001)可直接解压，后续卷由 isContinuationVolume 跳过
var archiveExtensions: Set<String> = [
    "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "z", "lzma", "cab",
]
for i in 1...99 {
    archiveExtensions.insert(String(format: "%03d", i))
}

struct Outcome {
    let path: String
    let outDir: String?
    let ok: Bool
    let message: String?
    var partial: Bool = false  // 解压成功但内部有失败项（结果目录仍有价值，可揭示）
}

// MARK: - 后端检测

func findExecutable(_ names: [String]) -> String? {
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        for n in names {
            let p = dir + "/" + n
            if fm.isExecutableFile(atPath: p) { return p }
        }
    }
    return nil
}

// 应用包内置的引擎（vendor 进 app 的官方 7zz），优先于系统安装的版本——
// 让 Release 下载的用户不装任何依赖就是全格式
func bundledTool(_ name: String) -> String? {
    guard let execURL = Bundle.main.executableURL else { return nil }
    let p = execURL.deletingLastPathComponent().appendingPathComponent(name).path
    return fm.isExecutableFile(atPath: p) ? p : nil
}

var unarPath = findExecutable(["unar"])
var sevenZipPath = bundledTool("7zz") ?? findExecutable(["7zz", "7z"])
var sevenZipBundled = sevenZipPath != nil && sevenZipPath == bundledTool("7zz")
var unrarPath = findExecutable(["unrar"])
var unzipPath = findExecutable(["unzip"])
let bsdtarPath = "/usr/bin/bsdtar"

/// 安装/环境变化后重新检测引擎
func rediscoverEngines() {
    unarPath = findExecutable(["unar"])
    sevenZipPath = bundledTool("7zz") ?? findExecutable(["7zz", "7z"])
    sevenZipBundled = sevenZipPath != nil && sevenZipPath == bundledTool("7zz")
    unrarPath = findExecutable(["unrar"])
    unzipPath = findExecutable(["unzip"])
}

func ext(_ path: String) -> String {
    (path as NSString).pathExtension.lowercased()
}

// 跟踪运行中的解压子进程，退出应用时能一并终止，避免孤儿进程继续写文件
final class ChildProcessTracker {
    private let lock = NSLock()
    private var children: [Process] = []

    func register(_ p: Process) {
        lock.lock(); children.append(p); lock.unlock()
    }

    func unregister(_ p: Process) {
        lock.lock(); children.removeAll { $0 === p }; lock.unlock()
    }

    func terminateAll() {
        lock.lock(); let snapshot = children; lock.unlock()
        for p in snapshot where p.isRunning { p.terminate() }
    }
}

let childTracker = ChildProcessTracker()

func runProcess(_ launchPath: String, _ args: [String]) -> (code: Int32, err: String) {
    let r = runProcessCapture(launchPath, args)
    return (r.code, r.err)
}

// 捕获 stdout 的版本（探测加密状态需要读列表输出）
func runProcessCapture(_ launchPath: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    task.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    task.standardOutput = outPipe
    let errPipe = Pipe()
    task.standardError = errPipe
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "en_US.UTF-8"
    task.environment = env
    // run 之前注册，消灭「取消落在 run 与 register 之间」的逃逸窗口；
    // terminateAll 对未启动/已退出的进程有 isRunning 保护
    childTracker.register(task)
    defer { childTracker.unregister(task) }
    do { try task.run() } catch { return (127, "", "\(error)") }
    // stderr 用 handler 并发排空：损坏包的 stderr 可能超过管道缓冲，
    // 串行先读 stdout 会互锁；handler 在独立线程持续读，stdout 读到 EOF 后再 wait
    let errLock = NSLock()
    var errBuf = Data()
    errPipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty {
            h.readabilityHandler = nil
            return
        }
        errLock.lock()
        if errBuf.count < 1_048_576 { errBuf.append(d) }  // 病态包防护：stderr 超 1MB 截断，防内存膨胀
        errLock.unlock()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    errLock.lock(); var errData = errBuf; errLock.unlock()
    errData += errPipe.fileHandleForReading.readDataToEndOfFile()
    return (task.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "")
}

/// 探测这批文件里是否存在需要密码的压缩包（7zz 列表并行探测，tar 系不可能加密直接跳过）。
/// 无法判断（如没有 7zz）时返回 nil，调用方保守地弹出密码框。
func probeAnyEncrypted(_ files: [String]) -> Bool? {
    guard let sz = sevenZipPath else { return nil }
    let neverEncrypted: Set<String> = ["tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz"]
    let targets = files.filter { !neverEncrypted.contains(ext($0)) }
    if targets.isEmpty { return false }
    var results = [Bool](repeating: false, count: targets.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: targets.count) { i in
        // -p 给个占位密码：未加密包忽略它；头加密包直接报 wrong password
        let r = runProcessCapture(sz, ["l", "-slt", "-pBZPROBE", targets[i]])
        let encrypted = r.out.lowercased().contains("encrypted = +")
            || (r.code != 0 && isPasswordError(r.err))
        lock.lock()
        results[i] = encrypted
        lock.unlock()
    }
    logLine("加密探测：\(targets.count) 个待查，结果=\(results.contains(true) ? "有加密" : "全部未加密")")
    return results.contains(true)
}

// MARK: - 解压命令构造

func unarArgs(outDir: String, password: String, path: String, encoding: String? = nil) -> [String] {
    var args = ["-f", "-D", "-o", outDir]
    if let enc = encoding { args += ["-e", enc] }
    if !password.isEmpty { args += ["-p", password] }
    args.append(path)
    return args
}

func sevenZipArgs(outDir: String, password: String, path: String, withProgress: Bool = false) -> [String] {
    var args = ["x", "-y", "-bso0", withProgress ? "-bsp1" : "-bsp0"]
    if !password.isEmpty { args.append("-p" + password) }
    args.append("-o" + outDir)
    args.append(path)
    return args
}

func unrarArgs(outDir: String, password: String, path: String) -> [String] {
    var args = ["x", "-y"]
    if !password.isEmpty { args.append("-p" + password) }
    args.append(path)
    args.append(outDir + "/")
    return args
}

func unzipArgs(outDir: String, password: String, path: String) -> [String] {
    var args = ["-o", "-d", outDir]
    if !password.isEmpty { args += ["-P", password] }
    args.append(path)
    return args
}

// MARK: - 解压后端

// 每种格式按优先级列出可用后端；密码作为参数传入，失败自动降级到下一个
struct Backend {
    let name: String
    let path: String
    let makeArgs: (_ outDir: String, _ password: String, _ path: String) -> [String]
}

func backendsFor(path: String) -> [Backend] {
    var list: [Backend] = []
    let sevenZipName = sevenZipBundled ? "7-Zip (内置)" : "7-Zip"
    let e = ext(path)
    switch e {
    case "rar":
        if let u = unarPath {
            list.append(Backend(name: "unar", path: u, makeArgs: { outDir, pwd, p in
                unarArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let s = sevenZipPath {
            list.append(Backend(name: sevenZipName, path: s, makeArgs: { outDir, pwd, p in
                sevenZipArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let r = unrarPath { list.append(Backend(name: "unrar", path: r, makeArgs: unrarArgs)) }
    case "7z":
        if let s = sevenZipPath {
            list.append(Backend(name: sevenZipName, path: s, makeArgs: { outDir, pwd, p in
                sevenZipArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let u = unarPath {
            list.append(Backend(name: "unar", path: u, makeArgs: { outDir, pwd, p in
                unarArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
    case "zip":
        if let u = unarPath {
            list.append(Backend(name: "unar", path: u, makeArgs: { outDir, pwd, p in
                unarArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let s = sevenZipPath {
            list.append(Backend(name: sevenZipName, path: s, makeArgs: { outDir, pwd, p in
                sevenZipArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let z = unzipPath { list.append(Backend(name: "unzip", path: z, makeArgs: unzipArgs)) }
    case "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "z", "lzma":
        // tar 系几乎从不用密码；bsdtar 不支持密码，始终先试（失败自动降级）
        if fm.isExecutableFile(atPath: bsdtarPath) {
            list.append(Backend(name: "bsdtar", path: bsdtarPath,
                                makeArgs: { outDir, _, p in ["-xf", p, "-C", outDir] }))
        }
        if let u = unarPath {
            list.append(Backend(name: "unar", path: u, makeArgs: { outDir, pwd, p in
                unarArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let s = sevenZipPath {
            list.append(Backend(name: sevenZipName, path: s, makeArgs: { outDir, pwd, p in
                sevenZipArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
    default:
        if let u = unarPath {
            list.append(Backend(name: "unar", path: u, makeArgs: { outDir, pwd, p in
                unarArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
        if let s = sevenZipPath {
            list.append(Backend(name: sevenZipName, path: s, makeArgs: { outDir, pwd, p in
                sevenZipArgs(outDir: outDir, password: pwd, path: p)
            }))
        }
    }
    return list
}

// MARK: - 调试日志（绝不记录密码内容）

let logFilePath = NSHomeDirectory() + "/Library/Logs/BatchUnzip.log"
let logMaxBytes = 1_000_000  // 超过 1MB 就清空重写，避免无限增长
let logLock = NSLock()
let logDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()

func logLine(_ s: String) {
    // 简单封顶：超限则截断日志（保留最近一半由覆写自然丢失，日志仅用于排障）
    if let attrs = try? fm.attributesOfItem(atPath: logFilePath),
       let size = attrs[.size] as? Int, size > logMaxBytes {
        try? fm.removeItem(atPath: logFilePath)
    }
    guard let data = "[\(logDateFormatter.string(from: Date()))] \(s)\n".data(using: .utf8) else { return }
    logLock.lock()
    defer { logLock.unlock() }
    if let h = FileHandle(forWritingAtPath: logFilePath) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(data)
    } else {
        try? data.write(to: URL(fileURLWithPath: logFilePath))
    }
}

func briefError(_ err: String, maxLines: Int = 2) -> String {
    let parts = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return parts.suffix(maxLines).joined(separator: "；")
}

// MARK: - 单个解压（带密码/不带密码双轮尝试）

func extractOne(_ path: String, password userPassword: String, deleteArchiveOnSuccess: Bool = false, onFileProgress: ((Int) -> Void)? = nil, shouldCancel: (() -> Bool)? = nil, probeEncrypted: Bool? = nil) -> (ok: Bool, outDir: String?, message: String?) {
    guard let outDir = uniqueOutputDir(for: path) else {
        return (false, nil, "无法在原目录创建输出文件夹（可能没有写权限）")
    }
    let backends = backendsFor(path: path)
    if backends.isEmpty {
        cleanupIfEmpty(outDir)
        return (false, outDir, "没有可用的解压后端，请安装：brew install unar 7zip")
    }

    // 轮次规划：探测已有结论时只跑有意义的一轮，省掉注定失败的进程；
    // 探测不了（nil）才用双轮自愈策略
    let rounds: [String]
    switch probeEncrypted {
    case true:
        rounds = userPassword.isEmpty ? [""] : [userPassword]
    case false:
        rounds = [""]
    case nil:
        rounds = userPassword.isEmpty ? [""] : [userPassword, ""]
    }
    var attempts: [(backend: String, err: String)] = []
    let displayName = (path as NSString).lastPathComponent
    let cancelled = shouldCancel ?? { false }

    for (roundIndex, pwd) in rounds.enumerated() {
        if cancelled() { break }  // 取消后不再启动新的解压进程
        for b in backends {
            if cancelled() { break }
            let args = b.makeArgs(outDir, pwd, path)
            logLine("解压 \(displayName) | 后端 \(b.name) | 密码：\(pwd.isEmpty ? "无" : "已提供")")
            let r: (code: Int32, err: String)
            if b.name.hasPrefix("7-Zip"), let cb = onFileProgress {
                r = runProcessWithProgress(b.path,
                                           sevenZipArgs(outDir: outDir, password: pwd, path: path, withProgress: true),
                                           onPercent: cb)
            } else {
                r = runProcess(b.path, args)
            }
            // unzip 的退出码 1 表示「解出了内容但有警告」，视为成功
            let succeeded = r.code == 0 || (r.code == 1 && b.name == "unzip")
            if succeeded {
                if r.code == 1 { logLine("⚠️ unzip 有警告但已解出：\(briefError(r.err, maxLines: 1))") }
                // GBK 中文文件名修复：unar 自动探测可能把 GBK 误判为西里尔编码，检出特征时用 -e GBK 重解。
                // 交换全程校验：备份位置被占用则跳过；重解/建目录失败则回滚备份；回滚失败如实报错。
                if b.name == "unar", ext(path) == "zip", preferChineseGBKFallback(),
                   containsSuspiciousMojibake(outDir) {
                    logLine("疑似 GBK 文件名乱码，用 -e GBK 重解 \(displayName)")
                    let backup = outDir + ".gbk-bak"
                    var movedToBackup = false
                    var repaired = false
                    if fm.fileExists(atPath: backup) {
                        logLine("GBK 重解跳过（备份位置被占用），保留原结果 \(displayName)")
                    } else {
                        do {
                            try fm.moveItem(atPath: outDir, toPath: backup)
                            movedToBackup = true
                            try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
                            let r2 = runProcess(b.path, unarArgs(outDir: outDir, password: pwd, path: path, encoding: "GBK"))
                            if r2.code == 0 {
                                repaired = true
                                try? fm.removeItem(atPath: backup)
                                logLine("GBK 重解成功 \(displayName)")
                            }
                        } catch {
                            logLine("GBK 重解流程异常：\(error.localizedDescription)")
                        }
                        if movedToBackup && !repaired {
                            try? fm.removeItem(atPath: outDir)  // 清掉半成品，恢复备份
                            try? fm.moveItem(atPath: backup, toPath: outDir)
                            if !fm.fileExists(atPath: outDir) {
                                logLine("❌ GBK 回滚失败，原结果保留在 \(backup)")
                                return (false, outDir, "GBK 修复回滚异常，原结果保留在 \(backup)")
                            }
                            logLine("GBK 重解失败，保留原结果 \(displayName)")
                        }
                    }
                }
                logLine("✅ 成功 \(displayName)")
                // 内部（嵌套）压缩包解压成功后删除，只留最终内容；顶层用户文件永不删除
                if deleteArchiveOnSuccess {
                    try? fm.removeItem(atPath: path)
                    logLine("🗑 已删除解压出的内部压缩包 \(displayName)")
                }
                return (true, outDir, nil)
            }
            let err = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
            attempts.append((b.name, err))
            logLine("❌ \(b.name) 退出码 \(r.code)：\(briefError(err, maxLines: 1))")
            if isPasswordError(err) { break }
        }
        // 第一轮（带密码）若完全没有密码类错误，说明问题与密码无关，不必再跑一轮
        if roundIndex == 0 && rounds.count == 2 && !attempts.contains(where: { isPasswordError($0.err) }) {
            break
        }
    }

    if attempts.contains(where: { isPasswordError($0.err) }) {
        cleanupIfEmpty(outDir)
        return (false, outDir, userPassword.isEmpty ? "该压缩包需要密码，请重新解压时输入密码"
                                                    : "密码错误（请确认密码后重试，详见日志 ~/Library/Logs/BatchUnzip.log）")
    }
    cleanupIfEmpty(outDir)
    let detail = briefError(attempts.last?.err ?? "")
    return (false, outDir, detail.isEmpty ? "解压失败" : detail)
}

// 解压完全失败时删掉刚建的空输出文件夹，避免留下一堆空目录
func cleanupIfEmpty(_ dir: String) {
    guard let items = try? fm.contentsOfDirectory(atPath: dir), items.isEmpty else { return }
    try? fm.removeItem(atPath: dir)
}

// GBK 误判特征：unar 自动探测可能把 GBK 文件名解码成西里尔字母等非中文文本，据此检出乱码。
// 局限：zh 环境下真正的俄语文件名也会命中（信息上无法与「GBK 被误判」完美区分），
// 误触发时 -e GBK 重解会改写文件名但内容无损，且失败会回滚（见 README 已知限制）。
func containsSuspiciousMojibake(_ dir: String) -> Bool {
    guard let enumerator = fm.enumerator(atPath: dir) else { return false }
    for case let s as String in enumerator {
        for scalar in (s as NSString).lastPathComponent.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) { return true }
        }
    }
    return false
}

// 中文系统环境下才做 GBK 重解，避免误伤真正的俄语等压缩包
func preferChineseGBKFallback() -> Bool {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true
}

// 7zz 专用：-bsp1 把百分比写到 stdout，解析后实时回调（大文件细粒度进度）
func runProcessWithProgress(_ launchPath: String, _ args: [String], onPercent: @escaping (Int) -> Void) -> (code: Int32, err: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = args
    task.standardInput = FileHandle.nullDevice
    let outPipe = Pipe()
    task.standardOutput = outPipe
    let errPipe = Pipe()
    task.standardError = errPipe
    var env = ProcessInfo.processInfo.environment
    env["LC_ALL"] = "en_US.UTF-8"
    task.environment = env
    do { try task.run() } catch { return (127, "\(error)") }
    childTracker.register(task)
    defer { childTracker.unregister(task) }

    let lock = NSLock()
    var lastPercent = -1
    outPipe.fileHandleForReading.readabilityHandler = { handle in
        let d = handle.availableData
        if d.isEmpty {
            handle.readabilityHandler = nil
            return
        }
        guard let s = String(data: d, encoding: .utf8) else { return }
        var pct: Int?
        var searchStart = s.startIndex
        while let r = s.range(of: #"\d{1,3}%"#, options: .regularExpression, range: searchStart..<s.endIndex) {
            if let v = Int(s[r].dropLast()), (0...100).contains(v) { pct = v }
            searchStart = r.upperBound
        }
        guard let p = pct else { return }
        lock.lock()
        let changed = p > lastPercent
        if changed { lastPercent = p }
        lock.unlock()
        if changed { onPercent(p) }
    }
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    outPipe.fileHandleForReading.readabilityHandler = nil
    return (task.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
}

func isPasswordError(_ err: String) -> Bool {
    let l = err.lowercased()
    return l.contains("wrong password") || l.contains("incorrect password")
        || l.contains("enter password") || l.contains("bad password")
        || l.contains("cannot open encrypted") || l.contains("password is required")
        || l.contains("unable to get password")  // unzip 无密码遇加密包
        || l.contains("break signaled")  // 7zz 无密码遇到加密包时 stdin EOF 的表现
}

// MARK: - 输出目录

func archiveFileNameStem(_ path: String) -> String {
    let name = (path as NSString).lastPathComponent
    let lower = name.lowercased()
    for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".tbz2", ".txz"] {
        if lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
    }
    return (name as NSString).deletingPathExtension
}

// 并行解压时保证「查重 + 创建输出目录」原子化，避免同词干包拿到同一个目录
let outDirCreationLock = NSLock()

func uniqueOutputDir(for archivePath: String) -> String? {
    outDirCreationLock.lock()
    defer { outDirCreationLock.unlock() }
    let dir = (archivePath as NSString).deletingLastPathComponent
    let base = archiveFileNameStem(archivePath)
    var candidate = dir + "/" + base
    var n = 2
    while fm.fileExists(atPath: candidate) {
        candidate = dir + "/" + base + " \(n)"
        n += 1
    }
    do {
        try fm.createDirectory(atPath: candidate, withIntermediateDirectories: true)
        return candidate
    } catch {
        return nil
    }
}

// MARK: - 分卷去重（.partNN.rar / .zip.001 之类只解第一卷）

func firstRegexGroup(_ pattern: String, _ s: String) -> Int? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
          m.range(at: 1).location != NSNotFound else { return nil }
    return Int(ns.substring(with: m.range(at: 1)))
}

func isContinuationVolume(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    if let n = firstRegexGroup(#"\.part(\d+)\.rar$"#, name), n > 1 { return true }
    if let n = firstRegexGroup(#"\.(\d{3})$"#, name), n > 1 { return true }
    return false
}

// MARK: - 批量流程（GUI/CLI 共用：顶层并行解压 + 嵌套递归）

let maxNestingDepth = 8
// 并行度自适应 CPU 核数：每个引擎进程自身已是多线程，槽位给一半核数并夹在 2~6
let maxParallelExtractions = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))

// 线程安全的进度计数器（并行任务共享）
final class ProgressCounter {
    private let lock = NSLock()
    private var completedCount = 0
    private var totalCount = 0

    /// 增量调整并返回快照
    func change(completed: Int = 0, total: Int = 0) -> (completed: Int, total: Int) {
        lock.lock()
        completedCount += completed
        totalCount += total
        let r = (completedCount, totalCount)
        lock.unlock()
        return r
    }

    func snapshot() -> (completed: Int, total: Int) { change() }
}

// 快速扫描目录：URL 枚举器一次取多个属性，跳过隐藏目录/__MACOSX/符号链接
func findArchivesRecursively(in dir: String) -> [String] {
    guard !dir.isEmpty,
          let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: dir),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else { return [] }
    var result: [String] = []
    for case let url as URL in enumerator {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name.lowercased() == "__macosx" {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }
        guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
        if vals.isDirectory == true { continue }
        if vals.isSymbolicLink == true { continue }  // 防止解压出的链接把外部文件「代解压」
        if archiveExtensions.contains(ext(name)) {
            result.append(url.path)
        }
    }
    return result
}

func processFiles(
    _ paths: [String],
    password: String,
    shouldCancel: @escaping () -> Bool,
    onUpdate: @escaping (_ text: String, _ completed: Int, _ total: Int) -> Void,
    probeEncrypted: Bool? = nil
) -> [Outcome] {
    let counter = ProgressCounter()
    _ = counter.change(total: paths.count)
    var outcomes = [Outcome?](repeating: nil, count: paths.count)
    let outcomesLock = NSLock()
    let group = DispatchGroup()
    let semaphore = DispatchSemaphore(value: maxParallelExtractions)
    let queue = DispatchQueue(label: "com.houtao.batchunzip.extract", attributes: .concurrent)

    func report(_ text: String) {
        let (c, t) = counter.snapshot()
        onUpdate(text, c, t)
    }

    // 长作业优先（LPT）：按文件体积降序提交，混合批次里大包先占住并行槽，缩短整体耗时。
    // 结果仍按用户选择顺序存放（outcomes[index]），只影响启动顺序。
    let sizes: [Int] = paths.map { (try? fm.attributesOfItem(atPath: $0)[.size] as? Int) ?? 0 }
    let submitOrder = paths.indices.sorted { sizes[$0] > sizes[$1] }

    for index in submitOrder {
        let top = paths[index]
        group.enter()
        queue.async {
            defer { group.leave() }
            if shouldCancel() {
                outcomesLock.lock()
                outcomes[index] = Outcome(path: top, outDir: nil, ok: false, message: "已取消")
                outcomesLock.unlock()
                let (c, t) = counter.change(completed: 1)
                onUpdate("已取消：\((top as NSString).lastPathComponent)", c, t)
                return
            }
            semaphore.wait()
            defer { semaphore.signal() }
            let outcome = processTopLevel(top, password: password,
                                          shouldCancel: shouldCancel,
                                          counter: counter, report: report,
                                          probeEncrypted: probeEncrypted)
            outcomesLock.lock()
            outcomes[index] = outcome
            outcomesLock.unlock()
        }
    }
    group.wait()
    return outcomes.compactMap { $0 }
}

// 处理一个顶层压缩包及其整个嵌套树（任务内部串行；不同顶层之间由 processFiles 并行调度）
func processTopLevel(
    _ top: String,
    password: String,
    shouldCancel: @escaping () -> Bool,
    counter: ProgressCounter,
    report: @escaping (_ text: String) -> Void,
    probeEncrypted: Bool? = nil
) -> Outcome {
    let topName = (top as NSString).lastPathComponent
    if isContinuationVolume(top) {
        _ = counter.change(completed: 1, total: -1)
        report("跳过分卷：\(topName)")
        return Outcome(path: top, outDir: nil, ok: true, message: nil)
    }

    var queue: [(path: String, depth: Int)] = [(top, 0)]
    var okCount = 0
    var nestedFails: [String] = []
    var topOutDir: String? = nil
    var topFailed = false
    var topMessage: String? = nil

    while !queue.isEmpty {
        if shouldCancel() { break }
        let item = queue.removeFirst()
        let name = (item.path as NSString).lastPathComponent
        var lastReportedPercent = 0
        report("正在解压：\(name)（第 \(item.depth + 1) 层）")

        if item.depth > 0 && isContinuationVolume(item.path) {
            _ = counter.change(completed: 1, total: -1)
            continue
        }
        if item.depth >= maxNestingDepth {
            nestedFails.append("\(name)：嵌套超过 \(maxNestingDepth) 层，已停止")
            _ = counter.change(completed: 1)
            continue
        }

        let r = extractOne(item.path, password: password, deleteArchiveOnSuccess: item.depth > 0,
                           onFileProgress: { pct in
                               // 节流上报：百分比变化 ≥5 或到 100 才刷新，避免刷屏
                               if pct >= lastReportedPercent + 5 || pct == 100 {
                                   lastReportedPercent = pct
                                   report("正在解压：\(name)（第 \(item.depth + 1) 层）· \(pct)%")
                               }
                           },
                           shouldCancel: shouldCancel,
                           probeEncrypted: probeEncrypted)
        _ = counter.change(completed: 1)
        if r.ok {
            okCount += 1
            if item.depth == 0 { topOutDir = r.outDir }
            let nested = findArchivesRecursively(in: r.outDir ?? "")
            if !nested.isEmpty {
                _ = counter.change(total: nested.count)
                queue.append(contentsOf: nested.map { ($0, item.depth + 1) })
            }
            report("完成：\(name)")
        } else if item.depth == 0 {
            topFailed = true
            topMessage = r.message
            topOutDir = r.outDir
            break
        } else {
            nestedFails.append("\(name)：\(r.message ?? "解压失败")")
        }
    }

    let cancelledMidTree = !topFailed && !queue.isEmpty && shouldCancel()

    let outcome: Outcome
    if topFailed {
        outcome = Outcome(path: top, outDir: topOutDir, ok: false, message: topMessage)
    } else if cancelledMidTree {
        outcome = Outcome(path: top, outDir: topOutDir, ok: false,
                          message: "已取消（该压缩包树内已完成 \(okCount) 个）")
    } else if !nestedFails.isEmpty {
        // 嵌套项失败只作警告：主体内容已解出，顶层仍算成功
        outcome = Outcome(path: top, outDir: topOutDir, ok: true,
                          message: "内部有 \(nestedFails.count) 个压缩包未解压成功：\n• " + nestedFails.joined(separator: "\n• "),
                          partial: true)
    } else {
        outcome = Outcome(path: top, outDir: topOutDir, ok: true, message: nil)
    }
    report(topFailed ? "失败：\(topName)"
                     : (cancelledMidTree ? "已取消：\(topName)" : "完成：\(topName)"))
    return outcome
}

func filterArchives(_ paths: [String]) -> (valid: [String], ignored: Int) {
    var valid: [String] = []
    var ignored = 0
    var seen = Set<String>()
    for raw in paths {
        let p = raw.hasPrefix("/") ? raw : fm.currentDirectoryPath + "/" + raw
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
              archiveExtensions.contains(ext(p)) else {
            ignored += 1
            continue
        }
        guard seen.insert(p).inserted else { continue }  // 同一文件重复选择只解一次
        valid.append(p)
    }
    return (valid, ignored)
}

// MARK: - CLI 模式

let stdoutLock = NSLock()

// CLI 模式没有 NSApplication 的退出确认流程，靠信号处理兜底：
// SIGTERM/SIGINT 时先终止解压子进程再退出，避免孤儿进程继续写文件
var signalSources: [DispatchSourceSignal] = []

func installCLISignalHandlers() {
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)  // 屏蔽默认处理，交给 dispatch source
        let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
        src.setEventHandler {
            childTracker.terminateAll()
            exit(Int32(128 + Int(sig)))
        }
        src.resume()
        signalSources.append(src)
    }
}

func cliMain(_ argv: [String]) -> Int32 {
    var password = ""
    var files: [String] = []
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a == "-p" || a == "--password" {
            i += 1
            if i < argv.count { password = argv[i] }
        } else if a.hasPrefix("-p"), a.count > 2 {
            password = String(a.dropFirst(2))
        } else {
            files.append(a)
        }
        i += 1
    }
    if files.isEmpty || argv.contains("-h") || argv.contains("--help") {
        print("用法：BatchUnzip [-p 密码] 文件1.zip 文件2.rar ...")
        print("支持 zip/rar/7z/tar/gz/bz2/xz 等格式；自动递归解压嵌套压缩包；分卷只解第一卷。")
        return 2
    }
    let valid = filterArchives(files).valid
    if valid.isEmpty {
        print("没有可识别的压缩包文件")
        return 2
    }
    let outcomes = processFiles(valid, password: password, shouldCancel: { false }) { text, _, _ in
        stdoutLock.lock()
        print(text)
        stdoutLock.unlock()
    }
    var failed = 0
    for o in outcomes where !o.ok {
        failed += 1
        print("❌ \((o.path as NSString).lastPathComponent)：\(o.message ?? "未知错误")")
    }
    for o in outcomes where o.ok && o.message != nil {
        print("⚠️ \((o.path as NSString).lastPathComponent)：\(o.message ?? "")")
    }
    print("完成：成功 \(outcomes.count - failed)，失败 \(failed)")
    return failed == 0 ? 0 : 1
}

// MARK: - GUI：进度小窗

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

final class ProgressPanel: NSObject {
    let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "准备中…")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    var onCancel: (() -> Void)?

    init(statusText: String, cancellable: Bool = true) {
        onCancel = nil
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 124),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "批量解压"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        let iconView = NSImageView(frame: NSRect(x: 20, y: 74, width: 40, height: 40))
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = NSFont.boldSystemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 74, y: 88, width: 386, height: 20)
        titleLabel.autoresizingMask = [.width]

        detailLabel.font = NSFont.systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.frame = NSRect(x: 74, y: 70, width: 386, height: 16)
        detailLabel.autoresizingMask = [.width]

        bar.style = .bar
        bar.isIndeterminate = false
        bar.doubleValue = 0
        bar.frame = NSRect(x: 20, y: 38, width: 350, height: 20)
        bar.autoresizingMask = [.width]

        // 当前文件解压中的小转轮（大文件进度条不动时提示“还活着”）
        let spinner = NSProgressIndicator(frame: NSRect(x: 374, y: 38, width: 20, height: 20))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        spinner.startAnimation(nil)

        let cancel = NSButton(title: "取消", target: nil, action: nil)
        cancel.bezelStyle = .rounded
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        cancel.frame = NSRect(x: 400, y: 32, width: 60, height: 30)
        cancel.autoresizingMask = [.minXMargin]
        cancel.isHidden = !cancellable

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 124))
        content.addSubview(iconView)
        content.addSubview(titleLabel)
        content.addSubview(detailLabel)
        content.addSubview(bar)
        content.addSubview(spinner)
        content.addSubview(cancel)
        window.contentView = content
        self.spinner = spinner

        update(text: statusText, completed: 0, total: 0)
    }

    private var spinner: NSProgressIndicator?

    @objc private func cancelTapped() { onCancel?() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func update(text: String, completed: Int, total: Int) {
        // 文本形如「正在解压：a.zip（第 2 层）」，按全角冒号拆成标题行与详情行
        var head = text
        var tail = ""
        if let r = text.firstIndex(of: "：") {
            head = String(text[..<r])
            tail = String(text[text.index(after: r)...])
        }
        titleLabel.stringValue = tail.isEmpty ? head : "\(head)（\(completed)/\(total)）"
        detailLabel.stringValue = tail

        if total <= 0 || completed >= total {
            bar.doubleValue = total <= 0 ? 0 : 1.0
        } else {
            bar.doubleValue = Double(completed) / Double(total)
        }
        // 「正在解压」阶段亮起小转轮，文件完成即停
        let active = (head == "正在解压")
        spinner?.isHidden = !active
        if active {
            spinner?.startAnimation(nil)  // 重复调用无副作用
        } else {
            spinner?.stopAnimation(nil)
        }
        // Dock 角标同步进度，切到别的应用也能看到
        NSApp.dockTile.badgeLabel = (total > 0 && completed < total) ? "\(completed)/\(total)" : nil
    }

    func close() {
        window.orderOut(nil)
        NSApp.dockTile.badgeLabel = nil
    }
}

// MARK: - GUI：密码对话框（带显示密码开关，避免输入法吃字后无从核对）

final class PasswordDialog: NSObject {
    // NSTextField 不支持直接切换密文模式，用两个重叠字段互切
    let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
    let plainField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
    let showToggle = NSButton(checkboxWithTitle: "显示密码", target: nil, action: nil)

    @objc private func toggleShow(_ sender: NSButton) {
        let show = sender.state == .on
        if show {
            plainField.stringValue = secureField.stringValue
        } else {
            secureField.stringValue = plainField.stringValue
        }
        secureField.isHidden = show
        plainField.isHidden = !show
        (show ? plainField : secureField).becomeFirstResponder()
    }

    func run(count: Int) -> String? {
        showToggle.target = self
        showToggle.action = #selector(toggleShow(_:))
        showToggle.frame = NSRect(x: 0, y: 0, width: 120, height: 20)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        container.addSubview(secureField)
        container.addSubview(plainField)
        container.addSubview(showToggle)
        plainField.isHidden = true
        plainField.placeholderString = "解压密码（可留空）"

        secureField.placeholderString = "解压密码（可留空）"

        let alert = NSAlert()
        alert.messageText = "批量解压 \(count) 个压缩包"
        alert.informativeText = "密码只对加密的压缩包生效，没加密的包会自动忽略。如压缩包设有密码请在下方输入，无密码直接点「开始解压」。每个压缩包会解压到同目录下以其名字命名的文件夹。"
        alert.accessoryView = container
        alert.addButton(withTitle: "开始解压")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = secureField
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            return secureField.isHidden ? plainField.stringValue : secureField.stringValue
        }
        return nil
    }
}

// MARK: - GUI：主流程

final class Coordinator: NSObject, NSApplicationDelegate {
    private var queued: [[String]] = []
    private var processing = false
    private let cancelFlag = CancelFlag()
    private var panel: ProgressPanel?
    private var batchStart = Date()
    private var activePasswordDialog: PasswordDialog?  // 强持有：NSButton.target 是弱引用，临时实例会被提前释放导致「显示密码」失效

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        enqueue(filenames)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 延迟到下一轮 runloop 再弹选择框：让「打开方式」启动时携带的 odoc 事件先入队，
        // 避免打开面板的模态循环与文件打开事件竞态
        DispatchQueue.main.async { [weak self] in self?.showOpenPanelIfIdle() }
    }

    private func showOpenPanelIfIdle() {
        guard !processing, queued.isEmpty else { return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.message = "选择要解压的压缩包（可多选）"
        openPanel.prompt = "解压"
        if openPanel.runModal() == .OK, !openPanel.urls.isEmpty {
            enqueue(openPanel.urls.map(\.path))
        } else if !processing && queued.isEmpty {
            // 只有确实没有任何待处理工作时才退出（防止取消面板杀掉刚接收的解压任务）
            NSApp.terminate(nil)
        }
    }

    // Cmd-Q 时如果还在解压，先确认；确认退出则终止子进程，避免孤儿进程继续写文件
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard processing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "批量解压正在进行"
        alert.informativeText = "还有任务未完成，确定要退出吗？未完成的压缩包会保持原样。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "继续")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            cancelFlag.isCancelled = true
            childTracker.terminateAll()
            return .terminateNow
        }
        return .terminateCancel
    }

    private func enqueue(_ files: [String]) {
        queued.append(files)
        processNext()
    }

    private func processNext() {
        guard !processing, let files = queued.first else { return }
        queued.removeFirst()
        processing = true
        cancelFlag.isCancelled = false

        let (valid, ignored) = filterArchives(files)
        guard !valid.isEmpty else {
            showAlert(title: "没有可识别的压缩包",
                      text: ignored > 0 ? "所选文件中没有支持的压缩包（已忽略 \(ignored) 个文件）。\n支持：zip、rar、7z、tar、gz、bz2、xz 等。"
                                        : "支持：zip、rar、7z、tar、gz、bz2、xz 等。")
            finishBatch()
            return
        }

        // 安装建议/必需安装（rar/7z 无后端 → 必需；unar 缺失 → 仅提示一次）
        maybePrepareBackends(valid) { [weak self] ready in
            guard let self else { return }
            if ready {
                self.continueBatch(valid)
            } else {
                self.finishBatch()
            }
        }
    }

    private func continueBatch(_ valid: [String]) {
        // 探测放后台：大批量时每个文件要起一个 7zz 列表进程，主线程不能冻结
        let probePanel = ProgressPanel(statusText: "正在检查加密状态…", cancellable: false)
        probePanel.show()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let probeResult = probeAnyEncrypted(valid)  // nil = 无法判断
            DispatchQueue.main.async {
                probePanel.close()
                self?.runBatch(valid, probeEncrypted: probeResult)
            }
        }
    }

    private func runBatch(_ valid: [String], probeEncrypted: Bool?) {
        // 智能免密：探测确认全部未加密时直接开解，不弹密码框
        let needsPassword = probeEncrypted ?? true
        var password = ""
        if needsPassword {
            guard let pwd = promptPassword(count: valid.count) else {
                finishBatch()
                return
            }
            password = pwd
        }
        let p = ProgressPanel(statusText: "准备解压…")
        batchStart = Date()
        p.onCancel = { [weak self] in
            guard let self else { return }
            self.cancelFlag.isCancelled = true
            // 立即终止进行中的解压子进程（大文件不用等当前包跑完）
            childTracker.terminateAll()
        }
        panel = p
        p.show()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcomes = processFiles(valid, password: password,
                                        shouldCancel: { self.cancelFlag.isCancelled },
                                        onUpdate: { [weak self] text, done, total in
                guard let self else { return }
                DispatchQueue.main.async { self.panel?.update(text: text, completed: done, total: total) }
            }, probeEncrypted: probeEncrypted)
            DispatchQueue.main.async {
                self.panel?.close()
                self.panel = nil
                let retry = self.showSummary(outcomes)
                if retry {
                    let failed = outcomes.filter { !$0.ok }.map(\.path)
                    if !failed.isEmpty { self.queued.append(failed) }
                }
                self.finishBatch()
            }
        }
    }

    private func finishBatch() {
        processing = false
        if queued.isEmpty {
            NSApp.terminate(nil)
        } else {
            processNext()
        }
    }

    // MARK: 密码 / 结果对话框

    private func promptPassword(count: Int) -> String? {
        let dialog = PasswordDialog()
        activePasswordDialog = dialog
        defer { activePasswordDialog = nil }
        return dialog.run(count: count)
    }

    /// 返回是否要求用新密码重试失败项
    @discardableResult
    private func showSummary(_ outcomes: [Outcome]) -> Bool {
        let ok = outcomes.filter { $0.ok }
        let bad = outcomes.filter { !$0.ok }
        let warnings = outcomes.filter { $0.ok && $0.message != nil }
        let elapsed = -batchStart.timeIntervalSinceNow
        var text = "成功 \(ok.count) 个，用时 \(String(format: "%.1f", max(0, elapsed))) 秒"
        if !bad.isEmpty { text = "成功 \(ok.count) 个，失败 \(bad.count) 个，用时 \(String(format: "%.1f", max(0, elapsed))) 秒" }
        var lines: [String] = []
        for o in bad.prefix(8) {
            lines.append("• \((o.path as NSString).lastPathComponent)：\(o.message ?? "未知错误")")
        }
        if bad.count > 8 { lines.append("… 另有 \(bad.count - 8) 个失败未列出") }
        for o in warnings.prefix(4) {
            lines.append("⚠️ \((o.path as NSString).lastPathComponent)：\(o.message ?? "")")
        }

        // 应用不在前台时弹跳 Dock 图标提醒完成
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }

        let alert = NSAlert()
        alert.messageText = bad.isEmpty ? "全部解压完成 ✅" : "解压完成（有失败项）"
        var info = lines.isEmpty ? text : text + "\n" + lines.joined(separator: "\n")
        if !bad.isEmpty || !warnings.isEmpty {
            info += "\n\n详细日志：~/Library/Logs/BatchUnzip.log"
        }
        alert.informativeText = info

        // 按钮从右到左：好 | 打开文件夹 | 用新密码重试失败项
        var order: [Int] = [0]  // 0=好 1=打开文件夹 2=重试
        alert.addButton(withTitle: "好")
        let canReveal = ok.contains { $0.outDir != nil } || outcomes.contains(where: { $0.partial })
        if canReveal {
            alert.addButton(withTitle: "打开文件夹")
            order.append(1)
        }
        if !bad.isEmpty {
            alert.addButton(withTitle: "用新密码重试失败项")
            order.append(2)
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = alert.runModal()
        let idx = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let action = (idx >= 0 && idx < order.count) ? order[idx] : 0
        if action == 1 {
            let urls = outcomes.filter { $0.ok || $0.partial }
                .compactMap(\.outDir).prefix(10).map { URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
        return action == 2
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: 后端安装

    private func needsAdvancedBackend(_ files: [String]) -> Bool {
        let advanced: Set<String> = ["rar", "7z", "cab", "lzma"]
        return files.contains { advanced.contains(ext($0)) }
    }

    private func maybePrepareBackends(_ valid: [String], completion: @escaping (Bool) -> Void) {
        // 必需：所选文件含 rar/7z 等格式，但没有任何支持的后端
        if needsAdvancedBackend(valid) && unarPath == nil && sevenZipPath == nil && unrarPath == nil {
            installViaBrew(formulas: ["unar", "7zip"],
                           title: "缺少解压引擎",
                           prompt: "解压 rar/7z 需要安装 unar 和 7-Zip（通过 Homebrew，需联网，约 1-2 分钟）。现在安装吗？",
                           optional: false,
                           completion: completion)
            return
        }
        // 可选：unar 缺失时只建议一次（修复 GBK 编码 zip 的中文文件名乱码）
        if unarPath == nil && !UserDefaults.standard.bool(forKey: "offeredUnarInstall") {
            UserDefaults.standard.set(true, forKey: "offeredUnarInstall")
            installViaBrew(formulas: ["unar"],
                           title: "可选优化",
                           prompt: "安装 unar 后可自动修复老式 GBK 编码 zip 的中文文件名乱码，并增强格式兼容（通过 Homebrew，需联网）。现在安装吗？（仅询问这一次，可忽略）",
                           optional: true,
                           completion: completion)
            return
        }
        completion(true)
    }

    private func installViaBrew(formulas: [String], title: String, prompt: String,
                                optional: Bool, completion: @escaping (Bool) -> Void) {
        guard let brew = findExecutable(["brew"]) else {
            showAlert(title: title,
                      text: "需要通过 Homebrew 安装 \(formulas.joined(separator: " "))。\n请先安装 Homebrew（https://brew.sh），然后运行：\n\nbrew install \(formulas.joined(separator: " "))")
            completion(!optional ? false : true)
            return
        }
        let choice = NSAlert()
        choice.messageText = title
        choice.informativeText = prompt
        choice.addButton(withTitle: "安装")
        choice.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard choice.runModal() == .alertFirstButtonReturn else {
            completion(optional)
            return
        }
        let p = ProgressPanel(statusText: "正在安装 \(formulas.joined(separator: "、"))…", cancellable: false)
        panel = p
        p.show()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = runProcess(brew, ["install", "-q"] + formulas)
            // 重新检测
            rediscoverEngines()
            DispatchQueue.main.async {
                self?.panel?.close()
                self?.panel = nil
                let success = unarPath != nil || sevenZipPath != nil || unrarPath != nil
                if !success && !optional {
                    self?.showAlert(title: "安装失败",
                                    text: "未能安装解压引擎，请检查网络后手动运行：\n\nbrew install \(formulas.joined(separator: " "))")
                }
                completion(optional ? true : success)
            }
        }
    }
}

// MARK: - 主菜单（提供标准「编辑」菜单，密码框才能 ⌘V 粘贴）

func installMainMenu() {
    let mainMenu = NSMenu()

    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "关于 批量解压",
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                               keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "退出 批量解压",
                               action: #selector(NSApplication.terminate(_:)),
                               keyEquivalent: "q"))
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
    editMenu.addItem(NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "Z"))
    editMenu.addItem(.separator())
    editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = editMenu

    NSApp.mainMenu = mainMenu
}

// MARK: - 入口

let rawArgs = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn") }
if !rawArgs.isEmpty {
    installCLISignalHandlers()
    exit(cliMain(Array(rawArgs)))
}

let app = NSApplication.shared
installMainMenu()
let coordinator = Coordinator()
app.delegate = coordinator
app.setActivationPolicy(.regular)
app.run()
exit(0)
