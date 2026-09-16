import Foundation
import WebKit

// MARK: - 数据结构

/// 三级查询结果：三条发布通道 + 官方发布时间映射 + 实际命中的来源（诊断用）
struct UpdateAvailability {
    let stable: String?      // npm latest（三级兜底后所得；nil = 全部来源失败）
    let alpha: String?       // npm alpha dist-tag（GitHub 兜底不解析 → nil）
    let next: String?        // npm next dist-tag——官方 rc/预览通道（GitHub 兜底时为
                             // 比稳定线更新的预发布 tag，无发布时间）
    /// 版本 → 官方发布时间（npm packument 自带的 time 映射；GitHub 兜底为空表）。
    /// 「按官方发布时间判断新旧」的数据源：dist-tag 挂哪个通道会滞后/错挂
    /// （真机实锤：0.1.2-rc.1 挂 next，只看 latest/alpha 永远"已是最新"），发布时间不会。
    let times: [String: Date]
    let source: QuerySource
}

enum QuerySource: String {
    case official = "npm 官方源"
    case mirror = "npmmirror 镜像"
    case github = "GitHub tags 兜底"
}

/// 自检单项结果
struct CheckResult: Identifiable {
    let id: String
    let name: String
    let ok: Bool
    let detail: String
}

/// 自检未通过时抛出的聚合错误（UI 据此弹回滚对话框）
struct SelfCheckFailure: Error {
    let results: [CheckResult]
    var failures: [CheckResult] { results.filter { !$0.ok } }
}

/// 语义化版本比较：逐段数字；同号时预发布(-rc/-alpha) < 正式版。
/// 例：0.1.1-rc.2 < 0.1.1；0.1.2-alpha.2 > 0.1.1-rc.2；0.1.10 > 0.1.9；
/// 0.1.2-alpha.2 < 0.1.2-alpha.3；0.1.2-alpha.2 < 0.1.2
enum SemVer {
    /// 语义化比较（SemVer 2.0.0 规则）。【真机实测补的洞】旧版只比较核心号
    /// 加"是否预发布"——同号不同预发布细号（0.1.2-alpha.2 与 0.1.2-alpha.3）
    /// 返回 0，导致装了 alpha.2 后检查更新永远不出现 alpha.3 的"安装预发布版"
    /// 按钮（alpha 通道无法迭代）。现按规范完整比较：核心号逐段；无预发布 >
    /// 有预发布；预发布标识符逐个比——纯数字按数值、数字 < 字母数字、字母数字
    /// 按 ASCII；前缀相等时标识符少者小。构建元数据（+build）忽略。
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let parse = { (v: String) -> (core: [Int], pre: [String]) in
            let noBuild = v.split(separator: "+").first.map(String.init) ?? v
            let halves = noBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let core = (halves.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            let pre = halves.count > 1 ? (halves.last ?? "").split(separator: ".").map(String.init) : []
            return (core, pre)
        }
        let a = parse(lhs), b = parse(rhs)
        for i in 0..<max(a.core.count, b.core.count) {
            let av = i < a.core.count ? a.core[i] : 0
            let bv = i < b.core.count ? b.core[i] : 0
            if av != bv { return av < bv ? -1 : 1 }
        }
        switch (a.pre.isEmpty, b.pre.isEmpty) {
        case (true, true): return 0      // 双方均无预发布
        case (true, false): return 1     // 正式版 > 预发布
        case (false, true): return -1
        default: break                    // 双方都有：逐标识符比
        }
        for i in 0..<max(a.pre.count, b.pre.count) {
            guard i < a.pre.count else { return -1 }   // 标识符少者小
            guard i < b.pre.count else { return 1 }
            let x = a.pre[i], y = b.pre[i]
            if let xi = Int(x), let yi = Int(y) {
                if xi != yi { return xi < yi ? -1 : 1 }   // 纯数字按数值
            } else if Int(x) != nil {
                return -1                                  // 数字 < 字母数字
            } else if Int(y) != nil {
                return 1
            } else if x != y {
                return x < y ? -1 : 1                      // 字母数字按 ASCII
            }
        }
        return 0
    }
}

// MARK: - 三级版本查询

/// 版本真相三级链：npm 官方 → npmmirror → GitHub tags。
/// 设计取舍：逐级仅在失败/超时后降级，不做双源比对——镜像同步滞后只会导致
/// "晚发现新版"，不会误报（安装阶段还有版本一致性校验兜底）。
enum UpdateEngine {
    static let npmOfficial = "https://registry.npmjs.org"
    static let npmMirror = "https://registry.npmmirror.com"
    static let githubTags = "https://api.github.com/repos/deepseek-ai/deepseek-harness/tags?per_page=100"
    static let tarballBase = "https://registry.npmjs.org/@deepseek-ai/dsh/-"

    static func fetchAvailability() async -> UpdateAvailability {
        // T1 / T2：registry 元数据（全量 JSON 较大但一次性，取 dist-tags 三字段 + time 映射）
        for (base, source) in [(npmOfficial, QuerySource.official), (npmMirror, QuerySource.mirror)] {
            if let tags = await fetchDistTags(base) {
                return UpdateAvailability(stable: tags.latest, alpha: tags.alpha, next: tags.next,
                                          times: tags.times, source: source)
            }
        }
        // T3：GitHub tags 兜底（无 time 映射 → times 空表，新旧判断退化为「版本 != 本机」；
        // 稳定线照旧只认正式版，混列的较新预发布 tag 顺带解析为 next）
        let fallback = await fetchGitHubTags()
        return UpdateAvailability(stable: fallback.stable, alpha: nil, next: fallback.next,
                                  times: [:], source: .github)
    }

    /// npm registry packument →（dist-tags 三字段，版本 → 官方发布时间）。
    /// dist-tags 三通道：latest（稳定）/ alpha（抢先）/ next（官方 rc/预览）。
    /// time 映射：npm 官方与 npmmirror 的 packument 均自带；created/modified 是
    /// 元信息不是版本号，跳过；ISO8601 解析失败的条目丢弃（时间缺失只影响新旧
    /// 判断的精度，不影响通道版本本身，绝不因此丢整个 packument）。
    private static func fetchDistTags(_ base: String) async -> (latest: String?, alpha: String?, next: String?, times: [String: Date])? {
        guard let url = URL(string: "\(base)/@deepseek-ai/dsh") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tags = obj["dist-tags"] as? [String: String] else { return nil }
            var times: [String: Date] = [:]
            if let rawTimes = obj["time"] as? [String: String] {
                for (version, raw) in rawTimes {
                    guard version != "created", version != "modified",
                          let date = ReleaseTimeParser.parse(raw) else { continue }
                    times[version] = date
                }
            }
            return (tags["latest"], tags["alpha"], tags["next"], times)
        } catch {
            return nil
        }
    }

    /// 是否预发布版本（SemVer 主版本号后带 "-pre" 段；构建元数据 +build 不算）
    private static func isPrerelease(_ version: String) -> Bool {
        let noBuild = version.split(separator: "+").first.map(String.init) ?? version
        return noBuild.contains("-")
    }

    /// T3：GitHub tags →（稳定线，比稳定线更新的预发布）。tag 形如 dsh-v0.1.2-rc.1。
    /// stable 取「正式版（无预发布后缀）」最大——与 npm latest 的语义对齐；旧实现取
    /// 全列 SemVer 最大，核心号更高的 rc 会冒充稳定线（如只有 dsh-v0.1.2-rc.1 而无
    /// dsh-v0.1.2 时，rc 被当稳定版送进稳定确认窗）。比 stable 更新的最高预发布解析
    /// 为 next（GitHub 不提供发布时间，调用方置空 times）；alpha 恒为 nil——tags
    /// 无法区分 alpha/next 通道归属。无正式版 tag 时退回全局最大（与旧实现一致，
    /// 至少给出一个可用版本；两版本全失败时 stable/next 均为 nil，由上游判失败）。
    private static func fetchGitHubTags() async -> (stable: String?, next: String?) {
        guard let url = URL(string: githubTags) else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // GitHub API 惯例：标注 UA 与 JSON Accept
        request.setValue("DSH-Desktop-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return (nil, nil) }
            // dsh-v 前缀剥掉后做 SemVer 排序
            let versions = arr.compactMap { row -> String? in
                guard let name = row["name"] as? String, name.hasPrefix("dsh-v") else { return nil }
                return String(name.dropFirst("dsh-v".count))
            }
            guard !versions.isEmpty else { return (nil, nil) }
            let top = { (list: [String]) -> String? in list.max { SemVer.compare($0, $1) < 0 } }
            let stable = top(versions.filter { !isPrerelease($0) }) ?? top(versions)!
            let next = top(versions.filter { isPrerelease($0) && SemVer.compare($0, stable) > 0 })
            return (stable, next)
        } catch {
            return (nil, nil)
        }
    }
}

// MARK: - 三级安装

/// 下载安装三级链：npx@官方 → npx@镜像 → curl 官方 tarball 直链。
/// T3 的落位依赖 resolveCommand 第四级扫描 ~/.npm/_npx/*/node_modules/@deepseek-ai/dsh
/// ——解包出的目录天然可被启动链发现，无需触碰 npx 内部状态。
enum UpdateInstaller {
    /// 安装指定 distTag（"latest" / "alpha"）；version 用于安装后一致性校验。
    /// 返回实际安装成功的版本号。进度经 progress 回调（主线程跳转由调用方负责）。
    static func install(distTag: String, version: String,
                        progress: @escaping (String) -> Void) async throws -> String {
        // T1：官方源 npx（PTY 实时进度沿用既有模式）
        progress("① 尝试 npm 官方源（npx @deepseek-ai/dsh@\(distTag)）…")
        do {
            #if ROLLBACK_TEST
            throw NSError(domain: "test", code: 99)
            #else
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmOfficial,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  官方源返回 v\(v) 与目标不符（同步异常），降级镜像重试…")
            #endif
        } catch {
            progress("  官方源失败：\(error.localizedDescription)，降级镜像重试…")
        }
        // T2：镜像源 npx（历史稳定路径）
        progress("② 尝试 npmmirror 镜像（npx @deepseek-ai/dsh@\(distTag)）…")
        do {
            #if ROLLBACK_TEST
            throw NSError(domain: "test", code: 99)
            #else
            let v = try await ServerManager.pullViaNpx(registry: UpdateEngine.npmMirror,
                                                       distTag: distTag, progress: progress)
            if SemVer.compare(v, version) == 0 { return v }
            progress("  镜像同步滞后（返回 v\(v)），降级官方 tarball 直链…")
            #endif
        } catch {
            progress("  镜像失败：\(error.localizedDescription)，降级官方 tarball 直链…")
        }
        // T3：裸 HTTP 直链 tarball（绕过 npm CLI 全链路）
        progress("③ 尝试官方 tarball 直链（curl \(version).tgz）…")
        return try await installViaTarball(version: version, progress: progress)
    }

    /// T3：下载官方 tgz 并解包到新的 _npx 缓存目录（resolveCommand 可发现）。
    private static func installViaTarball(version: String,
                                          progress: @escaping (String) -> Void) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-\(version)-\(UUID().uuidString.prefix(8))")
        let tgz = tmp.appendingPathExtension("tgz")
        let targetRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx/update-fallback-\(UUID().uuidString.prefix(8))")
        let pkgDir = targetRoot.appendingPathComponent("node_modules/@deepseek-ai/dsh")

        do {
            try await curl(version: version, to: tgz)
            // 解包（tgz 顶层为 package/）与校验放到后台线程执行
            try await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                proc.arguments = ["-xzf", tgz.path, "-C", tmp.path]
                try proc.run(); proc.waitUntilExit()
                guard proc.terminationStatus == 0 else {
                    throw NSError(domain: "update", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "tarball 解包失败"])
                }
                let unpacked = tmp.appendingPathComponent("package")
                guard fm.fileExists(atPath: unpacked.appendingPathComponent("package.json").path) else {
                    throw NSError(domain: "update", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "tarball 结构异常（缺 package.json）"])
                }
                try fm.createDirectory(at: pkgDir.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: unpacked, to: pkgDir)
            }.value
            progress("  ✓ 直链安装完成：\(pkgDir.lastPathComponent)（v\(version)）")
            return version
        } catch {
            // 清理半成品
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: targetRoot)
            throw error
        }
    }

    private nonisolated static func curl(version: String, to dest: URL) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-fSL", "--max-time", "120", "--retry", "1",
                          "-o", dest.path,
                          "\(UpdateEngine.tarballBase)/dsh-\(version).tgz"]
        try proc.run()
        // 等待 + 180s 兜底超时
        let deadline = Date().addingTimeInterval(180)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if proc.isRunning {
            proc.terminate(); proc.waitUntilExit()
            throw NSError(domain: "update", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "tarball 下载超时"])
        }
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "tarball 下载失败（HTTP \(proc.terminationStatus)）"])
        }
        return proc.terminationStatus
    }
}

// MARK: - 快照 / 自检 / 回滚

/// 更新安全网：装前快照、装后自检、失败一键回滚。
/// 快照固定落位 ~/.npm/_npx-preupdate-snapshot/（manifest.json 记录来源与新增目录）。
enum UpdateSafety {
    #if ROLLBACK_TEST
    /// 无头测试桩注入的沙盒根（仅测试构建）
    static var testRoot: URL?
    #endif
    static var snapshotRoot: URL {
        #if ROLLBACK_TEST
        if let testRoot { return testRoot.appendingPathComponent("_npx-preupdate-snapshot") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx-preupdate-snapshot")
    }
    static var npxRootForOps: URL {
        #if ROLLBACK_TEST
        if let testRoot { return testRoot.appendingPathComponent("_npx") }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".npm/_npx")
    }
    static var manifestURL: URL { snapshotRoot.appendingPathComponent("manifest.json") }

    struct Manifest: Codable {
        var sourcePath: String     // 更新前 dsh 包所在目录（回滚恢复目标）
        var version: String        // 更新前版本
        var installedNewDirs: [String]  // 本次安装新产生的缓存目录（回滚时移除）
        var createdAt: Double
    }

    /// 定位当前在用的 dsh 缓存目录：优先匹配运行中进程的命令行引用，
    /// 退回 _npx 下 mtime 最新的 @deepseek-ai/dsh。
    static func locateCurrentPackageDir() -> (dir: URL, version: String)? {
        let fm = FileManager.default
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        // 运行中后端进程的命令行（含 bin.js 绝对路径）
        var runningBin: String?
        if let out = runCapture("/usr/bin/pgrep", ["-fl", "@deepseek-ai/dsh/lib/bin.js"]) {
            // 形如 "123 /opt/.../node /Users/.../_npx/xxxx/node_modules/@deepseek-ai/dsh/lib/bin.js ..."
            if let range = out.range(of: "(/[^ ]+)/node_modules/@deepseek-ai/dsh/lib/bin.js") {
                runningBin = String(out[range]).description
            }
        }
        var best: (URL, Date)?
        guard let entries = try? fm.contentsOfDirectory(atPath: npxRoot.path) else { return nil }
        for entry in entries {
            let pkg = npxRoot.appendingPathComponent(entry)
                .appendingPathComponent("node_modules/@deepseek-ai/dsh")
            guard fm.fileExists(atPath: pkg.appendingPathComponent("package.json").path),
                  let data = try? Data(contentsOf: pkg.appendingPathComponent("package.json")),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else { continue }
            if let bin = runningBin {
                let binPkg = bin.hasSuffix("/lib/bin.js") ? String(bin.dropLast("/lib/bin.js".count)) : bin
                if binPkg == pkg.path {
                    return (pkg, version)   // 运行中实例优先，直接命中
                }
            }
            let mtime = (try? fm.attributesOfItem(atPath: pkg.path)[.modificationDate] as? Date) ?? .distantPast
            if best == nil || mtime > best!.1 { best = (pkg, mtime) }
        }
        guard let (pkg, _) = best,
              let data = try? Data(contentsOf: pkg.appendingPathComponent("package.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String else { return nil }
        return (pkg, version)
    }

    /// 更新前快照：ditto 当前包目录 + 记录基线（含安装前已存在的缓存目录清单，
    /// 供安装后差集出 installedNewDirs）。
    static func snapshotCurrent() throws -> Manifest? {
        guard let (pkg, version) = locateCurrentPackageDir() else { return nil }
        let fm = FileManager.default
        try? fm.removeItem(at: snapshotRoot)         // 幂等：清掉上次快照（首跑目录不存在不视为错误）
        let copyDest = snapshotRoot.appendingPathComponent("package")
        try fm.createDirectory(at: snapshotRoot, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [pkg.path, copyDest.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "update", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "快照失败（ditto 退出码 \(proc.terminationStatus)）"])
        }
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        let existing = (try? fm.contentsOfDirectory(atPath: npxRoot.path)) ?? []
        let manifest = Manifest(sourcePath: pkg.path, version: version,
                                installedNewDirs: existing, createdAt: Date().timeIntervalSince1970)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return manifest
    }

    /// 安装后差集登记：把新出现的缓存目录写回 manifest（回滚移除名单）。
    static func recordNewDirs(_ manifest: inout Manifest) {
        let fm = FileManager.default
        let npxRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent(".npm/_npx")
        let current = (try? fm.contentsOfDirectory(atPath: npxRoot.path)) ?? []
        let before = Set(manifest.installedNewDirs)
        manifest.installedNewDirs = current.filter { !before.contains($0) }
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL)
        }
    }

    /// 兼容性自检（三项，各 10s 超时）。后端需已重启并开始监听。
    static func selfCheck() async -> [CheckResult] {
        var results: [CheckResult] = []
        results.append(await probeRoot())
        results.append(await probeBridge())
        results.append(await probeMini())
        return results
    }

    /// 从 WKWebView 共享 Cookie 库借出 dsh 认证 Cookie（dsh-auth- 前缀），
    /// 拼成 Cookie 头返回；无认证 Cookie 返回 nil。WKHTTPCookieStore 回调在主线程。
    private static func dshAuthCookieHeader() async -> String? {
        // 认证 Cookie 是 HttpOnly 的（JS 与 URLSession 都读不到），只存在
        // WKWebsiteDataStore.default 的共享库里——壳的 WebView 首载 token URL
        // 后由后端 Set-Cookie 写入，30 天有效。探针想以"浏览器会话"的身份
        // 验证新版，只能从这里借。
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        // 只借 dsh 认证链的签名 Cookie，且域须为本机后端；其余 Cookie 不掺和，
        // 避免把无关身份错当会话凭证
        let auth = cookies.filter {
            $0.name.hasPrefix("dsh-auth-") && $0.domain.contains("127.0.0.1")
        }
        guard !auth.isEmpty else { return nil }
        return auth.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 探针通用执行：发请求 → 若 401 自动借 WKWebView 会话 Cookie 重试一次 →
    /// 把（重试后的）状态码与 JSON 交给 validate 裁决。第三参 retriedWithCookie
    /// 标记"结果是否来自带 Cookie 的重试"，供各探针区分"无认证直接 200（旧版）"
    /// 与"认证链放行了浏览器会话（新版+壳已授权）"两种 ok 文案。
    private static func probe(_ path: String, name: String,
                              validate: @escaping ([String: Any], Int, Bool) -> CheckResult) async -> CheckResult {
        guard let url = URL(string: "http://127.0.0.1:3080\(path)") else {
            return CheckResult(id: name, name: name, ok: false, detail: "URL 构造失败")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            var (data, response) = try await URLSession.shared.data(for: request)
            // 【真机实测的启动窗口】0.1.2-alpha.2 刚监听时有一段"路由未就绪"
            // 期：根路径先返回 404，稳态才变为 401/200——自检恰在窗口内执行
            // 就会把健康后端误判成"根页面 404"触发回滚弹窗。404 时最多再等
            // 8s 复探（新版根路径稳态不会是 404，等待安全；仅根路径如此）。
            let steadyDeadline = Date().addingTimeInterval(8)
            while path == "/",
                  (response as? HTTPURLResponse)?.statusCode == 404,
                  Date() < steadyDeadline {
                try? await Task.sleep(nanoseconds: 400_000_000)
                (data, response) = try await URLSession.shared.data(for: request)
            }
            var code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            var retriedWithCookie = false
            // 0.1.2-alpha.1+ 的认证链让未签名请求一律 401，而 URLSession 不共享
            // WKWebView 的 Cookie——直接判 fail 会把"对浏览器会话完全正常"的新版
            // 误杀回滚。所以借壳的会话 Cookie 重试一次：能借到且重试恢复预期响应，
            // 说明新版只是加了认证而非坏了。无 Cookie 可借或重试仍 401 时 code
            // 停留在 401，validate 按"无 Cookie"分支处理（各探针 401 文案已覆盖）。
            if code == 401, let cookieHeader = await dshAuthCookieHeader() {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
                let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
                code = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                obj = (try? JSONSerialization.jsonObject(with: retryData) as? [String: Any]) ?? [:]
                retriedWithCookie = true
            }
            return validate(obj, code, retriedWithCookie)
        } catch {
            return CheckResult(id: name, name: name, ok: false, detail: "不可达：\(error.localizedDescription)")
        }
    }

    private static func probeRoot() async -> CheckResult {
        await probe("/", name: "根页面") { _, code, retriedWithCookie in
            switch code {
            case 200:
                // 直接 200 = 旧版未启用认证链；借 Cookie 重试后 200 = 认证链
                // 已启用且对壳会话放行
                return CheckResult(id: "根页面", name: "根页面", ok: true,
                    detail: retriedWithCookie ? "认证链已启用，壳会话 Cookie 有效" : "HTTP 200")
            case 401:
                // 走到这说明无 Cookie 可借或带 Cookie 仍 401。根页面是用户可见的
                // 第一屏，壳自己都过不了认证 = 新版对当前壳不可用，此处必须 fail
                //（API 探针可宽容，根页面不行），并指明完成授权的途径。
                return CheckResult(id: "根页面", name: "根页面", ok: false,
                    detail: "HTTP 401：新版认证链已启用但壳尚未完成授权（等待 WebView 首载 token URL；若为外部 attach 实例，其 token 打印在启动它的终端里）")
            case 403:
                return CheckResult(id: "根页面", name: "根页面", ok: false,
                    detail: "HTTP \(code)：新版启用了浏览器认证（launch token + Cookie），当前壳尚未适配该流程")
            default:
                return CheckResult(id: "根页面", name: "根页面", ok: false, detail: "HTTP \(code)")
            }
        }
    }

    private static func probeBridge() async -> CheckResult {
        await probe("/api/desktop/status", name: "桥接状态") { obj, code, retriedWithCookie in
            if code == 200, obj["ok"] as? Bool == true {
                // 直接 200 = 旧版；借 Cookie 后 200 = 认证链保护 API 且壳会话
                // 验证通过
                return CheckResult(id: "桥接状态", name: "桥接状态", ok: true,
                    detail: retriedWithCookie ? "认证链保护 API，带会话 Cookie 验证通过" : "ok")
            }
            if code == 401 {
                // 桥接 API 只在 WebView 会话内被真实调用，壳外探针拿不到会话
                // 不等于功能坏了——降级为非致命提示而非触发回滚的硬失败，
                // 以 WebView 内实际功能为准。
                return CheckResult(id: "桥接状态", name: "桥接状态", ok: false,
                    detail: "HTTP 401（认证链拦截 API 且无可用会话 Cookie——以 WebView 内实际功能为准）")
            }
            return CheckResult(id: "桥接状态", name: "桥接状态", ok: false,
                detail: "HTTP \(code)（桥接插件路由未按预期响应）")
        }
    }

    private static func probeMini() async -> CheckResult {
        await probe("/api/mini/options", name: "迷你框插件") { _, code, retriedWithCookie in
            if code == 200 {
                return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: true,
                    detail: retriedWithCookie ? "认证链保护 API，带会话 Cookie 验证通过" : "ok")
            }
            if code == 401 {
                // 迷你框路由同样只在 WebView 会话里被真实使用；无 Cookie 的探针
                // 无法区分"被认证链拦"与"路由坏了"，按非致命降级处理并明示局限
                return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: false,
                    detail: "HTTP 401（认证链拦截，无法在无 Cookie 会话中验证插件路由）")
            }
            if code == 404 {
                return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: false,
                    detail: "HTTP 404（mini-dialog 插件未随新后端加载）")
            }
            return CheckResult(id: "迷你框插件", name: "迷你框插件", ok: false, detail: "HTTP \(code)")
        }
    }

    /// 一键回滚：移除新增目录 → 清除版本不符残留 → 原子恢复快照 → 自愈校验。
    /// progress 逐行回报（经 ServerManager 转发到终端日志区）。
    static func rollback(progress: @escaping (String) -> Void = { _ in }) async throws -> String {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "找不到更新前快照（manifest 缺失）"])
        }
        let fm = FileManager.default
        let npxRoot = npxRootForOps

        // ① 移除新增目录（FileManager 失败时 /bin/rm 兜底——实测有静默失败场景）
        for dir in manifest.installedNewDirs {
            try? fm.removeItem(at: npxRoot.appendingPathComponent(dir))
            forceRemove(npxRoot.appendingPathComponent(dir))
        }
        // ①' 清除版本不符残留：回滚语义=回到快照版本。残留异版本目录会被解析器
        // 按 mtime 优先命中 → 回滚失效（实测踩坑）
        if let entries = try? fm.contentsOfDirectory(atPath: npxRoot.path) {
            for entry in entries {
                let pkg = npxRoot.appendingPathComponent(entry)
                    .appendingPathComponent("node_modules/@deepseek-ai/dsh/package.json")
                guard let data = try? Data(contentsOf: pkg),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let v = obj["version"] as? String, v != manifest.version else { continue }
                progress("  清除异版本残留目录 \(entry)（v\(v)）")
                try? fm.removeItem(at: npxRoot.appendingPathComponent(entry))
                forceRemove(npxRoot.appendingPathComponent(entry))
            }
        }

        // ② 原子恢复：先拷到同级临时位 → 校验完整性 → 再换入原位。
        // 【实测教训】"先删原位再拷"在快照内容异常时会留下空壳目录（入口丢失、
        // 依赖被清），且尾部无条件清快照导致无法二次恢复。
        let dest = URL(fileURLWithPath: manifest.sourcePath)
        let staging = dest.deletingLastPathComponent().appendingPathComponent("__dsh_restore_staging")
        try? fm.removeItem(at: staging)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [snapshotRoot.appendingPathComponent("package").path, staging.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              fm.fileExists(atPath: staging.appendingPathComponent("lib/bin.js").path) else {
            // 恢复材料不完整：保留快照供人工抢救，绝不清原位
            throw NSError(domain: "update", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "快照内容不完整（缺 lib/bin.js），已保留快照目录未动原位：\(snapshotRoot.path)"])
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)

        // ③ 自愈校验：恢复位完整即可收尾；不完整则联网重装快照版本（pinned distTag
        // = 具体版本号，npx 支持精确版本安装）
        if !fm.fileExists(atPath: dest.appendingPathComponent("lib/bin.js").path) {
            #if ROLLBACK_TEST
            progress("  [测试] 恢复位不完整（跳过联网自愈）")
            #else
            progress("  恢复位不完整，联网自愈重装 v\(manifest.version)…")
            _ = try? await ServerManager.pullViaNpx(
                registry: UpdateEngine.npmOfficial,
                distTag: manifest.version,
                progress: progress)
            #endif
        }
        // ④ 快照收尾：仅在恢复/自愈完成后清除
        try? fm.removeItem(at: snapshotRoot)
        return manifest.version
    }

    /// 强删兜底：FileManager.removeItem 对运行中进程占用的目录偶发静默失败，
    /// 退回 /bin/rm -rf（POSIX 语义对打开中的文件同样生效）
    private static func forceRemove(_ target: URL) {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/rm")
        proc.arguments = ["-rf", target.path]
        try? proc.run(); proc.waitUntilExit()
    }

    /// 回滚后由 ServerManager 调用：杀 3080 后端进程（外部实例也杀——回滚场景必须
        /// 让旧版本重新接管），等端口空闲后交由 forwardStart 冷启动。
    static func killBackendForRollback() async {
        guard let out = runCapture("/usr/sbin/lsof", ["-tiTCP:3080", "-sTCP:LISTEN"]),
              !out.isEmpty else { return }
        let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        for pid in pids { kill(pid, SIGTERM) }
        // 最多等 5s 优雅退出，超时 SIGKILL
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let still = runCapture("/usr/sbin/lsof", ["-tiTCP:3080", "-sTCP:LISTEN"]) ?? ""
            if still.isEmpty { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        for pid in pids { kill(pid, SIGKILL) }
    }

    private nonisolated static func runCapture(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if proc.isRunning { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 前端应用自更新（v1.0.1）

/// GitHub Release `published_at` 的防御性解析（双源一致性弹窗要展示各源的发布时间）。
/// 为什么单独封装：GitHub API 文档承诺 ISO8601，但真实响应里"带小数秒 / 不带小数秒"
/// 两种形态都出现过（不同网关、代理可能改写），所以各试一次、全失败返回 nil——
/// 弹窗对 nil 的兜底是「发布时间未知」，绝不因时间字段解析失败丢弃整个 Release
/// （版本号与 zip 资产才是更新链的硬依赖，时间只是展示性信息）。
enum ReleaseTimeParser {
    /// ISO8601 双形态解析：带小数秒优先（信息更全），失败退回无小数秒形态
    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// 弹窗展示用「YYYY-MM-DD」。固定格式必须锁 en_US_POSIX：不锁的话用户系统地区
    /// 为非公历（如佛历、 Islamic）时会输出意外历法文本；入参 nil 返回 nil，
    /// 由调用方显示「发布时间未知」。
    static func dayString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 应用自身更新：GitHub Release 查询（防降级）→ 下载校验 → 暂存换壳 → 分离脚本换入并重启。
/// 与后端更新同一安全哲学：任一步失败不动现有安装；换壳动作由脱离本进程的脚本完成
/// （应用不能可靠地替换正在运行的自身）。
enum AppSelfUpdater {
    /// 双发布源：iiiiiei 个人仓 = 抢先发布（第一现场）；Farverge 组织仓 = 用户侧
    /// 稳定镜像（由 Actions 自动同步，存在分钟级延迟）。镜像仓库名保持小写。
    /// 双源意义：主源改动快但偶有回补/重发，镜像可交叉验证"用户实际会拿到什么"，
    /// 两源不一致时弹窗向用户交代差异，而不是静默挑一个装。
    static let primaryRepo = "EnderWolf006/dsh-macos"
    static let mirrorRepo = "Farverge/dsh-macos"

    struct Release {
        let tag: String            // 形如 v1.0.1
        let version: String        // 去掉 v 前缀
        let zipURL: URL?           // 稳定名资产 DSH.MacOS.Desktop.zip
        let publishedAt: Date?     // published_at 解析结果（nil = 解析失败 → 弹窗显示「发布时间未知」）
    }

    /// repo 带默认值 = 主源，既有调用点零改动；双源检查时由调用方传 mirrorRepo 取镜像源。
    static func fetchLatestRelease(repo: String = primaryRepo) async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DSH-Desktop-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return nil }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            var zipURL: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                zipURL = assets.compactMap { asset -> URL? in
                    guard let name = asset["name"] as? String, name == "DSH.MacOS.Desktop.zip",
                          let link = asset["browser_download_url"] as? String else { return nil }
                    return URL(string: link)
                }.first
            }
            return Release(tag: tag, version: version, zipURL: zipURL,
                           publishedAt: ReleaseTimeParser.parse(obj["published_at"] as? String))
        } catch {
            return nil
        }
    }

    /// 下载 zip → 解包校验（.app 结构 + Info.plist 版本与 Release 一致）。
    /// 返回解包出的 .app 目录；任何不符抛错且不触碰 /Applications。
    static func downloadAndVerify(release: Release,
                                  progress: @escaping (String) -> Void) async throws -> URL {
        guard let zipURL = release.zipURL else {
            throw NSError(domain: "appupdate", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Release 缺少 DSH.MacOS.Desktop.zip 资产"])
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshapp-\(UUID().uuidString.prefix(8))")
        let zip = tmp.appendingPathExtension("zip")
        progress("→ \(zipURL.lastPathComponent)")
        let (data, response) = try await URLSession.shared.data(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw NSError(domain: "appupdate", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）"])
        }
        try data.write(to: zip)
        progress("✓ 下载完成（\(data.count / 1024)KB）")

        // 解包与结构校验放后台线程
        let unpacked = try await Task.detached(priority: .userInitiated) { () -> URL in
            let fm = FileManager.default
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zip.path, tmp.path]   // ditto 解 zip 保权限
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "appupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "zip 解包失败"])
            }
            let app = tmp.appendingPathComponent("DSH Desktop.app")
            let plist = app.appendingPathComponent("Contents/Info.plist")
            guard fm.fileExists(atPath: plist.path),
                  fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/DSHDesktop").path),
                  let info = NSDictionary(contentsOf: plist),
                  let v = info["CFBundleShortVersionString"] as? String else {
                throw NSError(domain: "appupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "包结构异常（缺 .app/Info.plist/可执行文件）"])
            }
            guard v == release.version else {
                throw NSError(domain: "appupdate", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "包内版本 \(v) 与 Release \(release.version) 不符，拒装"])
            }
            return app
        }.value
        progress("✓ 校验通过：DSH Desktop.app v\(release.version)")
        return unpacked
    }

    /// 换壳三部曲：新包暂存入 /Applications → 旧包移入备份区 → 分离脚本完成换入并重启。
    /// 本进程在脚本派生后立即退出（脚本 sleep 1 等本进程退干净）。
    static func swapAndRelaunch(newApp: URL,
                                progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let dest = URL(fileURLWithPath: "/Applications/DSH Desktop.app")
        let staging = URL(fileURLWithPath: "/Applications/DSH Desktop.app.new")
        let backups = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DSH Backups")
        try? fm.removeItem(at: staging)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = [newApp.path, staging.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "appupdate", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "暂存拷贝失败"])
        }
        // 暂存已完整，下载/解包的临时目录可清（/tmp 系统兜底，此处主动收尾）
        try? fm.removeItem(at: newApp.deletingLastPathComponent())
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let script = """
        #!/bin/bash
        sleep 1
        mv '/Applications/DSH Desktop.app' '\(backups.path)/DSH Desktop.app.bak-\(stamp)' 2>/dev/null
        mv '/Applications/DSH Desktop.app.new' '/Applications/DSH Desktop.app' || { mv '\(backups.path)/DSH Desktop.app.bak-\(stamp)' '/Applications/DSH Desktop.app'; exit 1; }
        open '/Applications/DSH Desktop.app'
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-swap-\(UUID().uuidString.prefix(6)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        // 分离执行：nohup 让脚本脱离本进程生命周期；应用随后退出
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [scriptURL.path]
        runner.qualityOfService = .userInitiated
        try runner.run()
        progress("✓ 换壳脚本已派生，应用即将退出并由新版接管")
    }
}
