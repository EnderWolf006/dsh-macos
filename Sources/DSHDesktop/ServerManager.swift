import Foundation

/// 管理 dsh 服务器进程：检测 / 启动 / 监控 / 停止
@MainActor
final class ServerManager: ObservableObject {
    static let shared = ServerManager(appState: .shared)

    @Published var status: ServerStatus = .unknown
    @Published private(set) var serverProcess: Process?
    @Published private(set) var lastCommand: String = ""

    /// 本次运行中是否由我们启动了服务器（用于退出时决定是否停止）
    private(set) var startedByUs = false

    private let appState: AppState
    private var pollTask: Task<Void, Never>?
    private var stopping = false
    private var outputPipe: Pipe?
    private var updateLock = false
    /// 是否正在执行 dsh 更新（下载/校验/重启阶段）。应用退出时应避免在
    /// 更新过程中误杀刚换上的新后端，故对外暴露只读判断。
    var isUpdating: Bool { updateLock }
    /// 更新过程中的阶段/明细回调（UI 展示）
    var onUpdateProgress: (@MainActor (String) -> Void)?
    /// 认证链：从后端 stdout 捕获到的 launch token URL（每进程一次，轮换）。
    /// 由应用层接线设置（转存 AppState.authLaunchURL 供 WebView 首载授权）。
    var onLaunchTokenURL: (@MainActor (URL) -> Void)?
    /// 镜像源（国内 CDN，比 registry.npmjs.org 快）

    init(appState: AppState) {
        self.appState = appState
    }

    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - 检测

    /// 检测目标端口上是否已有 DSH 实例在运行（attach 模式，不归我们管）。
    /// 仅在我们没有亲自启动服务器时执行：否则会把 startedByUs 误置为
    /// false，导致退出应用时本该带走的服务器变成孤儿进程。
    func attach() async {
        guard serverProcess == nil else { return }
        let url = appState.url
        let healthy = await isDSHInstance(url)
        // 探测在途期间用户可能已手动点了启动（冷启动头几百毫秒内可行）：
        // 以探测返回后的最新状态为准，否则会把我们自己刚拉起的服务器
        // 误标为外部实例（startedByUs=false），退出时该带走的服务器变孤儿
        guard serverProcess == nil else { return }
        if healthy {
            startedByUs = false
            status = .running
            startPolling()
        } else if status != .starting {
            // 用户可能在 attach 完成前手动点了“启动”（status=.starting），
            // 此时不能把状态覆盖回 .stopped
            status = .stopped
        }
    }

    // MARK: - 启动 / 停止

    func start() {
        guard serverProcess == nil, status != .starting else { return }
        stopping = false
        status = .starting
        lastCommand = appState.serverCommand

        let command = appState.serverCommand
        let port = AppState.defaultPort

        Task {
            do {
                let resolved = try await Self.resolveCommand(command)
                // 解析期间用户可能又点了启动/停止，防止重复 spawn
                guard self.serverProcess == nil else {
                    return
                }
                // 后端唯一性：spawn 前确认端口上没有已健康的 DSH 实例
                //（外部终端启动的、或上一轮未收尾的）。已有实例则转为
                // attach，绝不重复拉起第二个后端。
                if await self.isDSHInstance(self.appState.url) {
                    self.startedByUs = false
                    self.status = .running
                    self.startPolling()
                    return
                }
                try spawn(resolved: resolved, port: port)
                startPolling()
            } catch {
                // 启动失败必须回落状态面板显示错误原因：清掉上一轮遗留的
                // “曾加载”标记，否则会短暂呈现空白 WebView + 断连横幅
                appState.pageLoaded = false
                status = .error("无法启动服务器：\(error.localizedDescription)")
            }
        }
    }

    func stop() {
        guard let process = serverProcess else { return }
        pollTask?.cancel()
        pollTask = nil
        stopping = true
        status = .stopped
        // 进程即将离开运行态：清掉“曾加载”标记，避免下次启动失败时
        // 因陈旧标记误入“空白 WebView + 断连横幅”而不是错误面板
        appState.pageLoaded = false
        process.terminate()
        // 3 秒内未退出则强杀。只强杀“当初决定要杀”的这一个进程：
        // 若这 3 秒内用户重新点了启动，serverProcess 已指向新实例，
        // 旧任务绝不能把新服务器误杀（用实例身份比对而非非空判断）。
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard self.serverProcess === process, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// 同步停止并等待退出（用于应用退出 / 自测）
    func stopAndWait() {
        guard let process = serverProcess, process.isRunning else { return }
        pollTask?.cancel()
        pollTask = nil
        stopping = true
        process.terminate()
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        serverProcess = nil
        status = .stopped
        appState.pageLoaded = false
    }

    // MARK: - 进程

    private func spawn(resolved: String, port: Int) throws {
        // 端口边界保护：0 / 负值 / 越界会让应用连不上服务器
        let safePort = min(max(port, 1), 65535)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        var full = resolved
        // 追加 --no-open：dsh 的 web 子命令默认会在启动时自动打开默认浏览器（拉起 Safari），
        // 这对"用原生 WebView 内置页面"的壳是多余且干扰的，故显式禁用外部开浏览器。
        // 仅当命令是 web 场景（命令含 web / --profile web）时才注入；且用户已显式带 --no-open 时跳过。
        let isWebCommand = full.contains("--profile web") || full.contains(" web") || full.hasPrefix("web")
        if isWebCommand && !full.contains("--no-open") {
            full += " --no-open"
        }
        if !full.contains("--port") {
            full += " --port \(safePort)"
        }
        // exec 让 dsh 进程直接取代 shell，便于精确终止
        process.arguments = ["-c", "exec \(full)"]

        var env = ProcessInfo.processInfo.environment
        // 从终端安装后首次 `open` 会继承 NVM/fnm/Volta 的 PATH，而从 Finder/Dock
        // 重开只剩系统 PATH。缓存命令若是 ~/.nvm/.../bin/dsh，其 shebang
        // `#!/usr/bin/env node` 因而会找不到同目录 node 并以 127 退出。把已解析
        // 可执行文件的目录放到最前面，使首次启动与之后重开使用同一套运行时。
        var binDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let executable = resolved.split(separator: " ").first.map(String.init),
           executable.hasPrefix("/") {
            let resolvedBin = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            binDirs.removeAll { $0 == resolvedBin }
            binDirs.insert(resolvedBin, at: 0)
        }
        let existing = env["PATH"] ?? ""
        env["PATH"] = binDirs.joined(separator: ":") + ":" + existing
        if env["DSH_HOME"] == nil {
            env["DSH_HOME"] = "\(NSHomeDirectory())/.dsh"
        }
        process.environment = env

        // 把服务器输出转发到应用 stdout，便于排障；同时逐行扫描认证链的
        // launch token 行（dsh web 启动时在 stdout 打印一行带 token 的 URL）。
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        outputPipe = pipe
        // readabilityHandler 给到的 data 是“可读即回”的任意切割分片，
        // `dsh web: ...` 这一行可能被劈成多个 chunk 跨次到达，必须维护
        // 残余缓冲拼行、只对凑齐换行的完整行做匹配。切行在字节层面进行：
        // 若对残余整体解码，chunk 恰好落在多字节 UTF-8 序列中间时会被插入
        // 替换字符，token 就永久毁了。可变状态放引用盒 + 锁（与 pullViaNpx
        // 的 OutputBox 同一套路）；盒随本次 spawn 新建，一次性标记因此天然
        // 以“进程”为生命周期——重启后自动复位，可再捕获新进程的新 token。
        final class TokenScanBox {
            var residual = Data()  // 尚未凑齐换行的残余字节，等下一个 chunk 拼接
            var consumed = false   // 一次性标记：首个命中即置位，后续行全部忽略
        }
        let scanBox = TokenScanBox()
        let scanLock = NSLock()
        // 只编译一次正则：取行内第一个 http(s) URL。字符类排除空白与
        // 半/全角左右括号，避免把同行随后的 `(LAN: http://...)`（或无空格
        // 相邻的 `（局域网）`）一起吞进 token；dsh 的 launch URL 本身不含括号。
        let tokenRegex = try? NSRegularExpression(pattern: #"dsh web:[ \t]*(https?://[^\s()（）]+)"#)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // 空数据 = EOF；此时若残余还压着无换行结尾的最后一行，也要冲刷一次
            guard !data.isEmpty || !scanBox.residual.isEmpty else { return }
            // 原有转发行为保持不变：后端原始输出继续镜像到应用 stdout 便于排障
            if !data.isEmpty { FileHandle.standardOutput.write(data) }
            var captured: URL?
            scanLock.lock()
            scanBox.residual.append(data)
            while let nl = scanBox.residual.firstIndex(of: 0x0A) {
                let lineBytes = Data(scanBox.residual[..<nl])
                let after = scanBox.residual.index(after: nl)
                scanBox.residual = Data(scanBox.residual[after...])
                guard !scanBox.consumed,
                      let line = String(data: lineBytes, encoding: .utf8),
                      let raw = Self.launchTokenRawString(in: line, regex: tokenRegex) else {
                    continue
                }
                // 首个命中即置标记：launch token 每进程只打印一次且一次性使用，
                // 重复触发只会造成多余的授权加载，故后续一律忽略。
                // URL 解析失败则静默丢弃：不回调、不报错、不重试。
                scanBox.consumed = true
                if let url = URL(string: raw) { captured = url }
            }
            if data.isEmpty, !scanBox.residual.isEmpty {
                // EOF 冲刷：残余此时必无换行（有早在上面循环消费掉了），按整行扫
                let rest = scanBox.residual
                scanBox.residual.removeAll()
                if !scanBox.consumed,
                   let line = String(data: rest, encoding: .utf8),
                   let raw = Self.launchTokenRawString(in: line, regex: tokenRegex) {
                    scanBox.consumed = true
                    if let url = URL(string: raw) { captured = url }
                }
            }
            scanLock.unlock()
            guard let url = captured else { return }
            // 主线程回调：onLaunchTokenURL 是应用层接线点（转存 AppState 供
            // WebView 首载授权），不能在 pipe 回调线程上碰 @MainActor 状态
            Task { @MainActor [weak self] in
                self?.onLaunchTokenURL?(url)
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                if self.serverProcess === proc {
                    self.pollTask?.cancel()
                    self.pollTask = nil
                    self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self.outputPipe = nil
                    self.serverProcess = nil
                    if self.stopping {
                        self.status = .stopped
                    } else if case .error = self.status {
                        // 启动超时等路径已经提供了更准确的原因，保留原错误。
                    } else {
                        let code = proc.terminationStatus
                        let reason = "服务器进程已退出（状态码 \(code)）"
                        self.appState.pageLoaded = false
                        self.status = .error(reason)
                        Log.warn(reason)
                    }
                }
            }
        }

        try process.run()
        serverProcess = process
        startedByUs = true
    }

    /// 在单行 stdout 里找 `dsh web: <URL>` 认证行，返回捕获到的原始 URL
    /// 字符串（不含 `dsh web:` 前缀，首个 http(s) 链接）。
    /// nonisolated 纯函数：由 pipe 回调线程直接调用，绝不触碰隔离状态。
    private nonisolated static func launchTokenRawString(
        in line: String,
        regex: NSRegularExpression?
    ) -> String? {
        guard let regex else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1,
              match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// 只替换首个出现的首 token，避免命令里后续同名子串被误改
    /// （如 “dsh --tag dsh” 会把参数里的第二个 dsh 也换成绝对路径）
    private static func replacingFirst(_ source: String, _ target: String, with replacement: String) -> String {
        guard let range = source.range(of: target) else { return source }
        return source.replacingCharacters(in: range, with: replacement)
    }

    /// 把用户命令解析为一条**不依赖 PATH** 的绝对命令。
    /// 关键背景：双击 .app 启动时进程由 launchd 拉起，PATH 只有系统目录
    /// （没有 /opt/homebrew/bin，也没有 npx 缓存目录），所以不能指望
    /// 终端里能用的 `dsh` 在双击场景也可用。解析结果会缓存到
    /// UserDefaults，之后直接复用。
    private static func resolveCommand(_ command: String) async throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ServerError.emptyCommand }

        let tokens = trimmed.split(separator: " ").map(String.init)
        let first = tokens[0]

        // 0. 缓存命中：上一次成功解析的绝对命令。除校验首 token 仍存在外，
        //    还要求缓存记录的“配置命令原文”与当前设置一致——用户改了
        //    启动命令后旧缓存必须作废，否则新设置永远不生效。
        if let cached = UserDefaults.standard.string(forKey: "resolvedServerCommand"),
           let cachedFirst = cached.split(separator: " ").first.map(String.init),
           cachedFirst.hasPrefix("/"),
           FileManager.default.fileExists(atPath: cachedFirst),
           UserDefaults.standard.string(forKey: "resolvedServerCommandSource") == trimmed {
            return cached
        }

        // 1. 用户直接给了绝对路径
        if first.hasPrefix("/") {
            cacheResolved(trimmed, source: trimmed)
            return trimmed
        }

        // 2. 常见绝对位置
        let candidates = ["/opt/homebrew/bin/\(first)", "/usr/local/bin/\(first)", "/usr/bin/\(first)", "/bin/\(first)"]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                let resolved = replacingFirst(trimmed, first, with: candidate)
                cacheResolved(resolved, source: trimmed)
                return resolved
            }
        }

        // 3. 登录 shell 的 PATH 解析（shellResolve 已注入常见 bin 目录）
        if let resolved = await shellResolve(first) {
            let full = replacingFirst(trimmed, first, with: resolved)
            cacheResolved(full, source: trimmed)
            return full
        }

        // 4. dsh 特化：绝对 node 直跑 npx 缓存里的 dsh 入口（完全离线、无 PATH 依赖）
        if first == "dsh" {
            if let direct = resolveNpxCachedDsh() {
                let rest = tokens.dropFirst().joined(separator: " ")
                let full = "\(direct) \(rest)".trimmingCharacters(in: .whitespaces)
                cacheResolved(full, source: trimmed)
                return full
            }

            // 5. 绝对 npx 兜底（spawn 时的 PATH 已含 /opt/homebrew/bin，npx 能找到 node）
            for npx in ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"] {
                if FileManager.default.isExecutableFile(atPath: npx) {
                    let rest = tokens.dropFirst().joined(separator: " ")
                    let full = "\(npx) --yes @deepseek-ai/dsh \(rest)".trimmingCharacters(in: .whitespaces)
                    cacheResolved(full, source: trimmed)
                    return full
                }
            }
        }

        throw ServerError.unresolvedCommand(trimmed)
    }

    // MARK: - 更新

    /// 当前 dsh 版本。优先取桥接在线报文（真实在跑的进程），桥接离线才回退解析缓存
    /// ——【实测修正】纯读缓存会在更新失败/回滚后残留旧值（上次 alpha 尝试后标签
    /// 一直显示 0.1.2-alpha.2，实际在跑 rc.2），进而影响"是否提示新版"的判定。
    var currentDSHVersion: String? {
        if appState.bridgeConnected,
           let range = appState.bridgeDetail.range(of: "v[0-9][0-9A-Za-z.\\-]*",
                                                   options: .regularExpression) {
            let live = appState.bridgeDetail[range].dropFirst()   // 去掉前导 v
            if !live.isEmpty { return String(live) }
        }
        let cached = UserDefaults.standard.string(forKey: "resolvedServerCommand")
        guard let cached else { return nil }
        // 命令形如 “node <绝对 bin 路径> --profile web”，bin 不一定是最后一个 token，
        // 因此遍历每个绝对路径 token，找到能向上定位到 package.json 的那个。
        for token in cached.split(separator: " ").map(String.init) where token.hasPrefix("/") {
            var resolvedPath = token
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: token),
               dest.hasPrefix("/") {
                resolvedPath = dest
            }
            var dir = URL(fileURLWithPath: resolvedPath).deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("package.json")
                if FileManager.default.fileExists(atPath: candidate.path),
                   let data = try? Data(contentsOf: candidate),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = json["version"] as? String {
                    return version
                }
                let parent = dir.deletingLastPathComponent()
                guard parent.path != dir.path else { break }
                dir = parent
            }
        }
        return nil
    }

    /// v1.0.1：下载编排迁至 UpdateInstaller.install（三级链）；
    /// 进度转发收敛于此，供 applyDSHUpdate 使用。
    private func forwardProgress(_ line: String) {
        onUpdateProgress?(line)
    }

    /// 实际阻塞下载（nonisolated，可在后台线程执行）。不走 self 隔离状态，
    /// 进度通过 progress 回调（已封装为主线程跳转）抛出。
    /// v1.0.1：泛化为 registry + distTag 两参（三级安装链的 T1/T2 复用本函数）。
    nonisolated static func pullViaNpx(
        registry: String,
        distTag: String,
        progress: @escaping (String) -> Void
    ) throws -> String {
        let npxCandidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx", "/bin/npx"]
        guard let npx = npxCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未找到 npx（请确保已安装 Node.js）"])
        }
        // script -q /dev/null <cmd...>，分配 PTY 显真实进度
        let script = "/usr/bin/script"
        let args = ["-q", "/dev/null", npx, "--registry=\(registry)", "--yes", "@deepseek-ai/dsh@\(distTag)", "--version"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["NODE_OPTIONS"] = "--max-old-space-size=4096"
        env["FORCE_COLOR"] = "1"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        process.arguments = args
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // 用引用类型承接累积输出，配合 NSLock 访问，避免 @Sendable 闭包捕获可变 var
        final class OutputBox { var data = Data() }
        let outBox = OutputBox()
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            outBox.data.append(chunk)
            let text = String(data: chunk, encoding: .utf8) ?? ""
            // 转发给 UI（挑出可读行，过滤 ANSI 控制码）
            let clean = text.replacingOccurrences(of: "\u{1B}[^m]*m", with: "", options: .regularExpression)
            let lines = clean.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map(String.init)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    progress("  \(trimmed)")
                }
            }
            lock.unlock()
        }
        // 等待并超时
        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            process.terminate(); process.waitUntilExit()
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let data = outBox.data
        lock.unlock()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 校验：退出码 0 且输出含合法的 x.y.z（也可能带 -rc.N 后缀）
        let versionPattern = #"\d+\.\d+\.\d+([-.][^\s]*)?(\s|$)"#
        let valid = process.terminationStatus == 0 && !out.isEmpty && out.range(of: versionPattern, options: .regularExpression) != nil
        guard valid else {
            throw NSError(domain: "update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "npx 拉取失败，请检查网络（原始输出：\(out.prefix(200)))"])
        }
        // 提取纯版本号（x.y.z 或 x.y.z-rc.N），忽略安装日志
        let ver = out.firstMatch(of: #/\d+\.\d+\.\d+(?:[-.][A-Za-z0-9.]*)?/#)
        guard let v = ver.map({ String($0.0) }), !v.isEmpty else {
            throw NSError(domain: "update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法从输出解析版本号：\(out.prefix(120))"])
        }
        return v
    }

    /// 清理前必须跳过的 npx 缓存目录：
    /// ① 当前解析命令指向的目录（本应用自己正在用）；
    /// ② 任何运行中进程命令行引用的目录——npx 缓存是全机共享的，终端里
    ///    可能正有别的会话跑在旧缓存上，删掉会让该进程后续的 spawn 直接失败。
    private nonisolated static func protectedCacheDirs() -> Set<String> {
        var protected = Set<String>()
        let marker = "/node_modules/@deepseek-ai/dsh"
        func note(_ token: String) {
            guard token.hasPrefix("/"), let range = token.range(of: marker) else { return }
            // 边界确认：包目录后必须是路径分隔符或字符串结尾，
            // 防止 @deepseek-ai/dsh-something 这类前缀同名目录被误认；
            // 也兼容命令行 token 恰好以包目录结尾（无尾斜杠）的情况
            let next = token[range.upperBound...].first
            guard next == nil || next == "/" else { return }
            let entry = String(token[..<range.lowerBound])
            protected.insert(entry)
            protected.insert((entry as NSString).standardizingPath)
        }
        if let cached = UserDefaults.standard.string(forKey: "resolvedServerCommand") {
            for token in cached.split(separator: " ").map(String.init) { note(token) }
        }
        if let out = runCapture("/bin/ps", ["-axo", "command="]) {
            for line in out.split(whereSeparator: \.isNewline) {
                for token in line.split(separator: " ").map(String.init) { note(token) }
            }
        }
        return protected
    }

    /// 同步执行一个命令并捕获 stdout（用于 ps 快照；失败返回 nil）
    private nonisolated static func runCapture(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 清理旧版本与残缺缓存：保留 ~/.npm/_npx 中最新的 dsh，删除其余及残缺目录，
    /// 返回清理明细。仅在下载完整校验通过后调用。
    /// 使用中的缓存目录（见 protectedCacheDirs）一律跳过，绝不删除。
    nonisolated func cleanupOldDSHCaches(extraProtected: [String] = []) -> String {
        let npxRoot = "\(NSHomeDirectory())/.npm/_npx"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) else {
            return "无可清理的缓存目录（不存在 ~/.npm/_npx）"
        }
        var protectedDirs = Self.protectedCacheDirs()
        // 【实测教训】更新中途的清理必须额外保护：快照源目录（回滚目标）与快照根。
        // ps/defaults 两道保护在特定时序（外部实例 + 缓存被上轮更新改写）下同时失效
        for extra in extraProtected { protectedDirs.insert(extra) }
        struct Cand { let dir: String; let path: String; let mtime: Date }
        var cands: [Cand] = []
        var removed = 0
        var removedBytes: Int64 = 0
        var removedNames: [String] = []
        var skippedInUse = 0
        for entry in entries {
            let dir = "\(npxRoot)/\(entry)"
            // 使用中的目录（自己的或别的进程的）：整目录跳过，残缺也不碰
            if protectedDirs.contains(dir) || protectedDirs.contains((dir as NSString).standardizingPath) {
                skippedInUse += 1
                continue
            }
            let dshPath = (dir as NSString).appendingPathComponent("node_modules/@deepseek-ai/dsh")
            var isDir: ObjCBool = false
            // 只处理含 dsh 的 _npx 缓存目录
            guard FileManager.default.fileExists(atPath: dshPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // 该目录是否是“完整”的（存在 package.json 里的 version）
            let pkg = (dshPath as NSString).appendingPathComponent("package.json")
            let complete = FileManager.default.fileExists(atPath: pkg)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dshPath)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            cands.append(Cand(dir: dir, path: dshPath, mtime: mtime))
            if !complete {
                // 残缺目录直接删；只统计真正删除成功的，失败不虚报清理量
                let size = dirSize(dir) ?? 0
                do {
                    try FileManager.default.removeItem(atPath: dir)
                    removedBytes += size
                    removed += 1
                    removedNames.append(entry)
                } catch {}
            }
        }
        // 完整目录里保留最新，删其余（使用中的已在上面被排除）
        let completeCands = cands.filter { FileManager.default.fileExists(atPath: ($0.path as NSString).appendingPathComponent("package.json")) }
        if let newest = completeCands.max(by: { $0.mtime < $1.mtime }) {
            for c in completeCands where c.dir != newest.dir {
                // 同上：删除成功才计入统计
                let size = dirSize(c.dir) ?? 0
                do {
                    try FileManager.default.removeItem(atPath: c.dir)
                    removedBytes += size
                    removed += 1
                    removedNames.append(URL(fileURLWithPath: c.dir).lastPathComponent)
                } catch {}
            }
        }
        let skipNote = skippedInUse > 0 ? "；另保留 \(skippedInUse) 个使用中的缓存" : ""
        guard removed > 0 else {
            return skippedInUse > 0
                ? "无需清理：其余缓存均在使用中（\(skippedInUse) 个已保留）"
                : "无需清理：仅存在 1 份完整且最新的 dsh 缓存"
        }
        let names = removedNames.joined(separator: ", ")
        let mb = Double(removedBytes) / 1_048_576.0
        return String(format: "已清理 %d 个旧/残缺缓存（共约 %.1f MB）：%@", removed, mb, names + skipNote)
    }

    private nonisolated func dirSize(_ path: String) -> Int64? {
        guard let urls = FileManager.default.enumerator(atPath: path) else { return nil }
        var total: Int64 = 0
        for case let url as String in urls {
            let full = (path as NSString).appendingPathComponent(url)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               attrs[.type] as? FileAttributeType == .typeRegular,
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    /// 检查 dsh 是否有新版：联网查询最新版本，与当前已装版本对比。
    /// 有新版本回传版本号，没有新版回传 nil（此时不进入更新/重启流程）。
    /// v1.0.1：三级查询（官方→镜像→GitHub），回调携带稳定线+预发布线。
    func checkDSHUpdate(_ callback: @escaping @MainActor (Result<UpdateAvailability, Error>) -> Void) {
        // 【吞错修复】忙时早退必须回调告知：UI 侧在调用前已置检查态并禁用按钮，
        // 静默 return 会让回调永不触发、按钮永久卡在「检查中…」（真机"点击无反应"根因）
        guard !updateLock else {
            callback(.failure(NSError(domain: "update", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "已有 DSH 更新任务正在进行，请等待其完成后再检查"])))
            return
        }
        updateLock = true
        Task {
            let availability = await UpdateEngine.fetchAvailability()
            await MainActor.run {
                self.updateLock = false
                guard availability.stable != nil else {
                    callback(.failure(NSError(domain: "update", code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "版本查询失败：三级来源（npm 官方/镜像/GitHub）均不可达"])))
                    return
                }
                callback(.success(availability))
            }
        }
    }

    /// 执行 DSH 更新并自动重启后端。
    ///
    /// 【完整流程】
    ///   1. 镜像源 + 伪终端(PTY)下载 npx 到缓存，实时回传进度（onUpdateProgress）；
    ///   2. 完整性校验（退出码 + 版本号 + package.json）；
    ///   3. 校验通过后清理旧/残缺 ~/.npm/_npx 缓存，回传清理明细；
    ///   4. 停掉旧服务器、清解析缓存、用最新缓存冷启动。
    ///   任何一步失败都不碰服务器（继续旧的）。
    func applyDSHUpdate(distTag: String = "latest", version: String,
                        _ callback: @escaping @MainActor (Result<String, Error>) -> Void) {
        // 【吞错修复】同 checkDSHUpdate：忙时早退回调失败，让 UI 复位并给出原因，
        // 而不是静默吞掉导致按钮永久卡在「更新中…」
        guard !updateLock else {
            callback(.failure(NSError(domain: "update", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "已有更新或回滚任务正在进行，本次更新未开始（未做任何改动）"])))
            return
        }
        updateLock = true
        var snapshotManifest: UpdateSafety.Manifest?
        onUpdateProgress?(distTag == "latest"
            ? "开始更新（稳定版通道 · 三级下载兜底）…"
            : "开始安装预发布版（alpha 通道 · 三级下载兜底）…")
        Task {
            do {
                // ⓪ 更新前快照（失败不阻断——仅失去一键回滚能力）
                do {
                    snapshotManifest = try UpdateSafety.snapshotCurrent()
                    if let m = snapshotManifest {
                        onUpdateProgress?("✓ 已快照 v\(m.version)（回滚锚点就绪）")
                    }
                } catch {
                    onUpdateProgress?("! 快照失败（不阻断更新，回滚将不可用）：\(error.localizedDescription)")
                }
                // ① + ② 三级下载（官方 npx → 镜像 npx → 官方 tarball 直链）+ 完整性校验
                let installed = try await UpdateInstaller.install(distTag: distTag, version: version) { [weak self] line in
                    Task { @MainActor in self?.forwardProgress(line) }
                }
                onUpdateProgress?("✓ 下载完成并通过完整性校验：v\(installed)")
                // ②' 登记安装新增的缓存目录（回滚移除名单）——必须在清理前完成差集
                if snapshotManifest != nil {
                    var m = snapshotManifest!
                    UpdateSafety.recordNewDirs(&m)
                    snapshotManifest = m
                }
                // ③ 清理旧缓存（后台，不阻塞主线程）
                var cleanupNote = "已跳过缓存清理"
                let cleanupResult = await Task.detached(priority: .utility) {
                    self.cleanupOldDSHCaches(extraProtected: [
                        snapshotManifest?.sourcePath ?? "",
                        UpdateSafety.snapshotRoot.path,
                    ].filter { !$0.isEmpty })
                }.value
                cleanupNote = cleanupResult
                onUpdateProgress?("✓ 清理完成：\(cleanupNote)")
                // ④ 停服 → 清解析缓存 → 冷启动（新版本接管端口）
                // 【实测修正】attach 模式：后端是外部实例时 stopAndWait 够不着 →
                // 必须显式杀 3080 监听者，否则新版起不来、自检探到旧版假通过
                if self.serverProcess != nil {
                    await MainActor.run { self.stopAndWait() }
                } else {
                    await UpdateSafety.killBackendForRollback()
                }
                await MainActor.run {
                    UserDefaults.standard.removeObject(forKey: "resolvedServerCommand")
                    UserDefaults.standard.removeObject(forKey: "resolvedServerCommandSource")
                    self.status = .stopped
                    self.forwardStart()
                }
                // ⑤ 等新后端就绪（最多 30s，任何 HTTP 响应都算监听成功）再自检
                let backendUp = await Self.waitBackendResponding(timeout: 30)
                onUpdateProgress?(backendUp
                    ? "✓ 新后端已监听，开始兼容性自检…"
                    : "! 后端 30s 内未响应，仍执行自检记录现状…")
                var results = await UpdateSafety.selfCheck()
                if results.allSatisfy(\.ok) {
                    // 稳定性复探：自检瞬间存活≠稳定；3s 后桥接再探，崩了按失败处理
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    var stable = false
                    if let url = URL(string: "http://127.0.0.1:3080/api/desktop/status") {
                        var req = URLRequest(url: url); req.timeoutInterval = 5
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        if let (_, resp) = try? await URLSession.shared.data(for: req),
                           let code = (resp as? HTTPURLResponse)?.statusCode,
                           code == 200 || code == 401 {
                            // 401 也算稳定：新版 dsh 的认证链会拦截未带 Cookie 的
                            // /api/* 请求，后端在监听即稳定；403 等其他状态仍不算
                            stable = true
                        }
                    }
                    if !stable {
                        results.append(CheckResult(id: "稳定性复探", name: "稳定性复探", ok: false,
                            detail: "自检通过 3 秒后桥接不可达（后端疑似启动后退出）"))
                    }
                }
                let failures = results.filter { !$0.ok }
                await MainActor.run {
                    self.updateLock = false
                    if failures.isEmpty {
                        callback(.success("\(installed)（\(cleanupNote)）· 自检 3/3 通过"))
                    } else {
                        callback(.failure(SelfCheckFailure(results: results)))
                    }
                }
            } catch {
                // 任一步失败：不碰服务器（继续旧的），只回传错误
                await MainActor.run {
                    self.updateLock = false
                    onUpdateProgress?("✗ 更新失败：\(error.localizedDescription)")
                    callback(.failure(error))
                }
            }
        }
    }

    /// 等后端对任意 HTTP 请求产生响应（200/401/403 都算"已监听"）。
    /// nonisolated：纯 URLSession 轮询，不触隔离状态。
    nonisolated private static func waitBackendResponding(timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:3080/") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200...599).contains(http.statusCode) {
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// 自检失败后的一键回滚：恢复快照 → 杀后端 → 清解析缓存 → 冷启动旧版本。
    /// 回调返回恢复到的版本号；任何失败原样抛给 UI 展示。
    func rollbackFromFailedUpdate(_ callback: @escaping @MainActor (Result<String, Error>) -> Void) {
        // 【吞错修复】同 checkDSHUpdate：忙时早退回调失败，UI 才能复位并交代原因
        guard !updateLock else {
            callback(.failure(NSError(domain: "update", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "已有更新或回滚任务正在进行，本次回滚未执行（未做任何改动）"])))
            return
        }
        updateLock = true
        onUpdateProgress?("── 开始回滚到更新前版本 ──")
        Task {
            do {
                let restored = try await UpdateSafety.rollback { line in
                    Task { @MainActor in self.onUpdateProgress?(line) }
                }
                await UpdateSafety.killBackendForRollback()
                await MainActor.run {
                    UserDefaults.standard.removeObject(forKey: "resolvedServerCommand")
                    UserDefaults.standard.removeObject(forKey: "resolvedServerCommandSource")
                    if self.serverProcess != nil { self.stopAndWait() }
                    self.status = .stopped
                    self.forwardStart()
                    self.updateLock = false
                    self.onUpdateProgress?("✓ 已回滚至 v\(restored) 并重启后端")
                    callback(.success(restored))
                }
            } catch {
                await MainActor.run {
                    self.updateLock = false
                    self.onUpdateProgress?("✗ 回滚失败：\(error.localizedDescription)")
                    callback(.failure(error))
                }
            }
        }
    }

    /// 更新收尾时调用：等价于一次干净的 start()，但跳过端口预检的 attach 分支，
    /// 确保用 npx 刚拉取的最新缓存 spawn 新进程。
    private func forwardStart() {
        guard serverProcess == nil else { return }
        stopping = false
        status = .starting
        let command = appState.serverCommand
        let port = AppState.defaultPort
        Task {
            do {
                let resolved = try await Self.resolveCommand(command)
                guard self.serverProcess == nil else { return }
                // 更新场景：直接冷启动到最新缓存，不做端口 attach（端口应先已释放）
                try self.spawn(resolved: resolved, port: port)
                Self.cacheResolved(resolved, source: command.trimmingCharacters(in: .whitespaces))
                self.startPolling()
            } catch {
                // 同 start()：重启失败要回落错误面板，不能吃陈旧的 pageLoaded
                self.appState.pageLoaded = false
                self.status = .error("重启失败：\(error.localizedDescription)")
            }
        }
    }

    /// 在 ~/.npm/_npx/<hash>/node_modules/@deepseek-ai/dsh/lib/bin.js 中
    /// 定位 dsh 的真实入口（取最新的），返回 "绝对node 绝对bin.js"。
    private static func resolveNpxCachedDsh() -> String? {
        let npxRoot = "\(NSHomeDirectory())/.npm/_npx"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: npxRoot) else { return nil }
        var best: (Date, String)?
        for entry in entries {
            let binPath = "\(npxRoot)/\(entry)/node_modules/@deepseek-ai/dsh/lib/bin.js"
            guard FileManager.default.fileExists(atPath: binPath) else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: binPath)
            let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
            if best == nil || mtime > best!.0 {
                best = (mtime, binPath)
            }
        }
        guard let (_, binPath) = best else { return nil }
        let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node", "/bin/node"]
        guard let node = nodeCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return "\(node) \(binPath)"
    }

    private static func cacheResolved(_ command: String, source: String) {
        UserDefaults.standard.set(command, forKey: "resolvedServerCommand")
        // 记录该解析结果来自哪条配置命令原文；配置变更后缓存即失效
        //（见 resolveCommand 第 0 步的 source 比对）
        UserDefaults.standard.set(source, forKey: "resolvedServerCommandSource")
    }

    private static func shellResolve(_ name: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name) 2>/dev/null || true"]
        // launchd 环境下 PATH 极简（登录 shell 也未必有 Homebrew），先注入常见目录
        var env = ProcessInfo.processInfo.environment
        let binDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = binDirs.joined(separator: ":") + ":" + existing
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }

    // MARK: - 健康监控

    private func startPolling() {
        pollTask?.cancel()
        let url = appState.url
        pollTask = Task { [weak self] in
            guard let self else { return }
            var consecutiveFailures = 0
            let startupDeadline = Date().addingTimeInterval(30)
            while !Task.isCancelled {
                // 服务器已停止（手动 stop / 进程退出）：结束轮询，避免空转
                if self.status == .stopped { break }
                let ok = await self.isHealthy(url)
                if ok {
                    consecutiveFailures = 0
                    if self.status != .running {
                        self.status = .running
                    }
                    try? await Task.sleep(for: .seconds(5))
                } else {
                    consecutiveFailures += 1
                    if self.status == .starting, Date() >= startupDeadline {
                        let message = "服务器启动超时（30 秒内未监听 127.0.0.1:\(AppState.defaultPort)）"
                        self.appState.pageLoaded = false
                        self.status = .error(message)
                        Log.warn(message)
                        if let process = self.serverProcess, process.isRunning {
                            process.terminate()
                        }
                        break
                    }
                    if self.status == .running && consecutiveFailures >= 2 {
                        self.status = .error("与服务器的连接中断")
                    }
                    // 启动阶段（starting）0.5s 加密轮询尽快发现就绪；
                    // 其余状态 5s 慢轮询，避免空闲高频空转
                    try? await Task.sleep(for: self.status == .starting ? .milliseconds(500) : .seconds(5))
                }
            }
        }
    }

    func isHealthy(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return true }
                if http.statusCode == 401 {
                    // dsh ≥0.1.2-alpha.1 启用认证链后，未带签名 Cookie 的请求
                    // 一律 401，但 body 是 dsh 专属文案——收到它说明 HTTP 服务
                    // 在监听且确是 dsh，应视为“健康、仅缺会话”，而非断连
                    let body = String(decoding: data, as: UTF8.self)
                    return body.contains(Self.authChallengeText)
                }
            }
        } catch {
            // 未连接
        }
        return false
    }

    /// 根 HTML 内嵌的官方启动脚本字面量。任何恰好占用 3080 的其它本地
    /// HTTP 服务都不会带它——这是比“端口返回 200”强得多的身份证据。
    static let identityMarker = "__DSH_BOOT__"

    /// dsh 认证链的 401 响应 body 文案（纯文本、固定字符串）。未带签名
    /// Cookie 访问根页面 / /api/* 时返回；能收到它说明端口上监听的就是
    /// 启用了认证链的 dsh，而非恰好占用端口的陌生服务——与 __DSH_BOOT__
    /// 同级的强身份证据。
    static let authChallengeText = "dsh web authentication required"

    /// 身份确认：除健康检查外，还要求根页面确实是 DSH Web GUI，
    /// 避免把同端口的陌生服务误认成后端而 attach。
    func isDSHInstance(_ url: URL) async -> Bool {
        guard await isHealthy(url) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        // lossy 解码：64KB 窗口若恰好截断多字节 UTF-8 序列，严格解码返回
        // nil 会把真 DSH 误判成陌生服务；replacement 字符不影响标记查找
        let body = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        if http.statusCode == 200 {
            return body.contains(Self.identityMarker)
        }
        if http.statusCode == 401 {
            // 认证链启用后未带 Cookie 拿不到根 HTML 属预期，但 401 的 body
            // 是 dsh 专属认证文案——它本身就是“这是 dsh”的强身份证据
            return body.contains(Self.authChallengeText)
        }
        return false
    }
}

enum ServerError: LocalizedError {
    case emptyCommand
    case unresolvedCommand(String)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "启动命令为空"
        case .unresolvedCommand(let command):
            return "找不到命令：\(command)（请在设置中配置正确的启动命令）"
        }
    }
}
