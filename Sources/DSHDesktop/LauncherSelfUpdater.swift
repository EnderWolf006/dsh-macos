import AppKit
import Foundation

// MARK: - Launcher 自更新

/// Launcher 全自动更新链（三段式，对齐 AppSelfUpdater）：
/// 查询 Release → 下载解包校验 → 插件同步 + 换壳重启。
///
/// 与主应用自更新的两点差异（install.sh 是安装布局的唯一事实来源）：
/// 1. 安装位不在 /Applications，而在 ~/Library/Application Support/DSH Launcher.app；
/// 2. zip 内还平级携带 dsh-mini-dialog 插件载荷（可缺失，缺失不算错），需同步到
///    ~/.dsh/profiles/web/node_modules/dsh-mini-dialog（内层官方依赖树）并幂等维护
///    cordis.patch.yml 装配条目。
///
/// 本文件刻意不做版本比较（是否需要更新由调用方用 compareLauncherVersions 判定），
/// 只负责"确定要装"之后的下载、校验、落位与重启。
///
/// 顺序敏感性：插件同步必须放在最前——此刻 Launcher 仍活着、本应用也仍活着，
/// 任一步出错都能完整回滚；一旦终止了 Launcher 进程，就再没有退路只能向前换壳。
enum LauncherSelfUpdater {
    /// 双发布源（与应用自更新同一策略）：iiiiiei = 抢先发布，Farverge = 组织稳定
    /// 镜像（Actions 同步存在分钟级延迟）。双源意义：镜像可交叉验证用户实际拿到
    /// 的版本，两源不一致时由 UI 弹窗交代差异而非静默择一。
    static let primaryRepo = "iiiiiei/dsh-launcher"
    static let mirrorRepo = "Farverge/dsh-launcher"

    struct Release {
        let tag: String            // 形如 v1.0.1
        let version: String        // 去掉 v 前缀
        let zipURL: URL?           // 稳定资产名 DSH.Launcher.zip（GitHub 把空格归一为点号）
        let publishedAt: Date?     // published_at 解析结果（nil = 解析失败 → 弹窗显示「发布时间未知」）
    }

    /// 解包产物：.app 目录必在；插件目录可缺失（缺失仅跳过插件同步，不视为错误）
    struct Payload {
        let app: URL
        let plugin: URL?
    }

    private static let bundleID = "com.deepseek-ai.dsh-launcher"
    private static let assetName = "DSH.Launcher.zip"
    private static let pluginName = "dsh-mini-dialog"

    /// 安装位（install.sh 同款布局：~/Library/Application Support/DSH Launcher.app）
    private static var installDest: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DSH Launcher.app")
    }
    /// 与主应用共用的备份区（本文件写入的备份名 DSH Launcher.app.bak-<时间戳>）
    private static var backupsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DSH Backups")
    }
    /// 插件部署位 = 内层官方依赖树（profiles/web/node_modules）。外层 profiles/node_modules
    /// 是 rc.2 时代旧树，插件放外层会让 imports 解析到旧模块（双树冲突教训）。
    private static var pluginDest: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/web/node_modules/dsh-mini-dialog")
    }
    /// ~/.dsh/profiles/web 不存在 = DSH 后端尚未初始化过，插件同步应静默跳过
    private static var profileWebDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/web")
    }
    private static var patchFile: URL { profileWebDir.appendingPathComponent("cordis.patch.yml") }

    // MARK: ① 查询 Release

    /// 请求头/超时/无缓存与 AppSelfUpdater.fetchLatestRelease 完全一致。
    /// repo 带默认值 = 主源（既有调用点零改动）；双源检查时由调用方传 mirrorRepo。
    static func fetchLatestRelease(repo: String = "iiiiiei/dsh-launcher") async -> Release? {
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
                    guard let name = asset["name"] as? String, name == assetName,
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

    // MARK: ② 下载与校验

    /// 下载 zip → 解包校验（.app 结构 + Info.plist 版本与 Release 一致）。
    /// 校验通过才返回 Payload；任何不符抛错且不触碰已安装的 Launcher。
    static func downloadAndVerify(release: Release,
                                  progress: @escaping (String) -> Void) async throws -> Payload {
        guard let zipURL = release.zipURL else {
            throw NSError(domain: "launcherupdate", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Release 缺少 \(assetName) 资产"])
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dshlauncher-\(UUID().uuidString.prefix(8))")
        let zip = tmp.appendingPathExtension("zip")
        progress("→ \(zipURL.lastPathComponent)")
        let (data, response) = try await URLSession.shared.data(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
            throw NSError(domain: "launcherupdate", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "下载失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）"])
        }
        try data.write(to: zip)
        progress("✓ 下载完成（\(data.count / 1024)KB）")

        // 解包与结构校验放后台线程（照抄 AppSelfUpdater 的 Task.detached 模式）
        let payload = try await Task.detached(priority: .userInitiated) { () -> Payload in
            let fm = FileManager.default
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", zip.path, tmp.path]   // ditto 解 zip 保权限
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw NSError(domain: "launcherupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "zip 解包失败"])
            }
            // zip 内是两个平级条目：DSH Launcher.app/ 与 dsh-mini-dialog/（后者可缺失）
            let app = tmp.appendingPathComponent("DSH Launcher.app")
            let plist = app.appendingPathComponent("Contents/Info.plist")
            guard fm.fileExists(atPath: plist.path),
                  fm.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/DSHLauncher").path),
                  let info = NSDictionary(contentsOf: plist),
                  let v = info["CFBundleShortVersionString"] as? String else {
                throw NSError(domain: "launcherupdate", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "包结构异常（缺 .app/Info.plist/可执行文件）"])
            }
            guard v == release.version else {
                throw NSError(domain: "launcherupdate", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "包内版本 \(v) 与 Release \(release.version) 不符，拒装"])
            }
            let plugin = tmp.appendingPathComponent(pluginName)
            return Payload(app: app,
                           plugin: fm.fileExists(atPath: plugin.path) ? plugin : nil)
        }.value
        progress("✓ 校验通过：DSH Launcher.app v\(release.version)" +
                 (payload.plugin != nil ? "（含 mini-dialog 插件载荷）" : "（未含插件载荷，将跳过插件同步）"))
        return payload
    }

    // MARK: ③ 插件同步 + 换壳重启

    /// 顺序敏感（不可调换）：
    /// a. 先同步插件——Launcher 还活着，插件链路失败可完整回滚且绝不连坐主程序；
    /// b. 新包暂存到安装目录旁的 DSH Launcher.app.new；
    /// c. 终止 Launcher 进程（自此只能向前）；
    /// d. 分离脚本：sleep 1 → 旧包入备份 → 暂存换入（失败回滚 mv）→ open 新版
    ///    → 备份修剪（只留最近 2 个）→ 脚本自删。
    /// 修剪放在脚本里而非本进程：新备份由脚本落地，落地后再修剪才能精确"保留 2 个"，
    /// 且天然避开与脚本 sleep 1 的竞态。
    static func swapAndRelaunch(payload: Payload,
                                progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        // 本次更新会话统一时间戳：插件备份与 .app 备份同源，便于人工排查对应关系
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        // a. 插件同步最先做：此刻一切尚未被破坏，失败即可无损中止
        do {
            try syncPlugin(payload: payload, stamp: stamp, progress: progress)
        } catch {
            // 主程序与已装 Launcher 均未被动过；清掉解包临时目录即可全身而退
            try? fm.removeItem(at: payload.app.deletingLastPathComponent())
            throw error
        }

        // b. 新包暂存（.new 与正式位同级，最终换入只是一次原子 mv）
        let staging = installDest.deletingLastPathComponent()
            .appendingPathComponent("DSH Launcher.app.new")
        try? fm.removeItem(at: staging)
        try runDitto(from: payload.app, to: staging, failure: "暂存拷贝失败")
        // 暂存已完整，下载/解包的临时目录可清（/tmp 系统兜底，此处主动收尾）
        try? fm.removeItem(at: payload.app.deletingLastPathComponent())

        // c. 终止 Launcher。此刻起没有回头路：老包即将被换走，必须先让它退场，
        //    否则脚本 open 的新实例与残留旧实例会在菜单栏并存
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if !running.isEmpty {
            progress("→ 正在退出运行中的 Launcher（\(running.count) 个实例）…")
            for inst in running { _ = inst.terminate() }
            // 最多等 3s 优雅退出（对齐 install.sh 的 sleep 3）。等不到也不阻断——
            // POSIX 下 mv 正在运行的 .app 依然成立，退不干净的旧实例在用户下次
            // 手动退出时自然消亡（install.sh 对此同样只提示不强制）
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline,
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        // d. 分离脚本换壳（模式照抄 AppSelfUpdater.swapAndRelaunch：脚本脱离本进程
        // 生命周期独立完成换入与重启；sleep 1 等 Launcher 退干净）。
        // 备份修剪解释：sort -r 后 ISO8601 时间戳字典序=时间序，tail -n +3 跳过最新
        // 两个、删更旧的；只匹配 'DSH Launcher.app.bak-' 前缀，不碰同目录的主应用
        // 备份（DSH Desktop.app.bak-*）与插件备份。自删失败也无妨，/tmp 系统兜底。
        let script = """
        #!/bin/bash
        sleep 1
        mv '\(installDest.path)' '\(backupsRoot.path)/DSH Launcher.app.bak-\(stamp)' 2>/dev/null
        mv '\(staging.path)' '\(installDest.path)' || { mv '\(backupsRoot.path)/DSH Launcher.app.bak-\(stamp)' '\(installDest.path)'; exit 1; }
        open '\(installDest.path)'
        cd '\(backupsRoot.path)' && ls -1 'DSH Launcher.app.bak-'* 2>/dev/null | sort -r | tail -n +3 | while read -r f; do rm -rf "$f"; done
        rm -f "$0"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-launcher-swap-\(UUID().uuidString.prefix(6)).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [scriptURL.path]
        runner.qualityOfService = .userInitiated
        try runner.run()
        progress("✓ 换壳脚本已派生，Launcher 即将由新版接管")
    }

    // MARK: 插件同步（install.sh deploy_plugin 的 Swift 版）

    /// 四步：旧插件备份 → 删旧 → 拷新 → patch 幂等写入。
    /// 回滚语义：备份之后的任何一步失败，都先把旧插件原样 ditto 回原位再抛错，
    /// 由调用方（swapAndRelaunch）中止整个更新——插件失败绝不连坐 Launcher 主程序。
    private static func syncPlugin(payload: Payload, stamp: String,
                                   progress: @escaping (String) -> Void) throws {
        guard let newPlugin = payload.plugin else {
            progress("→ 资产包未携带插件载荷，跳过插件同步")
            return
        }
        let fm = FileManager.default
        // 与 install.sh 的 deferred 分支同语义：后端配置目录不存在 = DSH 尚未初始化过，
        // 此时装插件毫无意义（patch 也无处安放），静默跳过不算错误
        guard fm.fileExists(atPath: profileWebDir.path) else {
            progress("→ 未发现 ~/.dsh/profiles/web（DSH 后端未初始化），跳过插件同步")
            return
        }
        progress("→ 同步 mini-dialog 插件…")
        let backup = backupsRoot.appendingPathComponent("\(pluginName).bak-\(stamp)")
        let hadOld = fm.fileExists(atPath: pluginDest.path)
        if hadOld {
            try? fm.removeItem(at: backup)               // 幂等：清掉同名残留
            // 备份失败即中止：此刻还没改动任何东西，无需回滚
            try runDitto(from: pluginDest, to: backup, failure: "旧插件备份失败")
        }
        do {
            if hadOld { try fm.removeItem(at: pluginDest) }
            try runDitto(from: newPlugin, to: pluginDest, failure: "插件部署失败")
            try ensurePatchEntry(progress: progress)
        } catch {
            // 回滚：清掉可能写到一半的新目录，再把备份原样恢复
            // （此前从未装过则恢复为"无插件"的初始状态）
            progress("  ✗ \(error.localizedDescription)")
            try? fm.removeItem(at: pluginDest)
            if hadOld {
                try? runDitto(from: backup, to: pluginDest, failure: "插件回滚失败")
                progress("  ✓ 已恢复原插件（备份 \(backup.lastPathComponent)）")
            }
            throw NSError(domain: "launcherupdate", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "插件同步失败，已恢复原状并中止更新（\(error.localizedDescription)）"])
        }
        progress("  ✓ 插件已部署 → ~/.dsh/profiles/web/node_modules/dsh-mini-dialog")
    }

    /// cordis patch 装配条目的幂等写入——路径与三种分支的格式均以 install.sh 的
    /// deploy_plugin 为唯一事实来源，字节级保持一致：
    ///   已含条目 → 跳过（install.sh 用 grep -q "dsh-mini-dialog" 判同）；
    ///   已有文件 → 追加 4/6 空格缩进的两行条目；
    ///   无文件   → 创建带维护注释的最小结构。
    private static func ensurePatchEntry(progress: @escaping (String) -> Void) throws {
        let fm = FileManager.default
        let patch = patchFile
        if let text = try? String(contentsOf: patch, encoding: .utf8),
           text.contains(pluginName) {
            progress("  ✓ 装配条目已存在（幂等跳过）")
            return
        }
        if fm.fileExists(atPath: patch.path) {
            // 追加两行与 install.sh 的 printf 完全一致；仅当原文件不以换行结尾时
            // 补一个换行，避免条目粘到上一行（install.sh 隐式依赖 YAML 自带尾换行）
            let existing = (try? String(contentsOf: patch, encoding: .utf8)) ?? ""
            let separator = existing.hasSuffix("\n") ? "" : "\n"
            try (existing + separator + "    - id: mini-dialog\n      name: 'dsh-mini-dialog'\n")
                .write(to: patch, atomically: true, encoding: .utf8)
            progress("  ✓ 装配条目已追加 → cordis.patch.yml")
        } else {
            // 最小结构 heredoc 原样照搬 install.sh（含维护注释，卸载脚本按图索骥）
            let yaml = """
            # DSH Launcher 附装插件（mini-dialog：迷你对话框会话创建/跳转）。随 Launcher 安装/卸载脚本维护。
            - insert:
                - id: mini-dialog
                  name: 'dsh-mini-dialog'
            """
            try (yaml + "\n").write(to: patch, atomically: true, encoding: .utf8)
            progress("  ✓ 已创建 \(patch.path)")
        }
    }

    // MARK: 工具

    /// ditto 拷贝（保权限保元数据；本文件所有备份/暂存/落位动作统一走它）
    private static func runDitto(from src: URL, to dst: URL, failure: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = [src.path, dst.path]
        try proc.run(); proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "launcherupdate", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "\(failure)（ditto 退出码 \(proc.terminationStatus)）"])
        }
    }
}
