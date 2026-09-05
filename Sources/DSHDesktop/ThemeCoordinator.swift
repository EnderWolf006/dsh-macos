import SwiftUI
import AppKit
import WebKit
import Combine
import UserNotifications

/// 主题外观（协议 §5 池内可见面：official 虚拟主题 / 某个已装主题）
enum ThemeAppearance: Equatable {
    case official
    case theme(String)

    var id: String {
        switch self {
        case .official: return "official"
        case .theme(let id): return id
        }
    }

    static func make(_ id: String) -> ThemeAppearance {
        id == "official" ? .official : .theme(id)
    }
}

/// 主题编排中枢（宿主义务 B1–B6）：
/// - B1 WebView 池（协议 §5：全池 ≤3 = official 1（现有 HarnessWebView）+ 主题 ≤2；
///   共享存储由 ThemeWebView/HarnessWebView 同用默认 WKWebsiteDataStore 满足）
/// - B2 握手 + 看门狗（§6，裁决在 ThemeWebView，此处消费回调执行显隐切换）
/// - B4 首装激活（/themes 首次成功且此前快照为空 → 自动激活一次，绝不覆盖用户已有选择）
/// - B5 重连跟随（boot-info 1s 轮询跟随 active；后端重启/重连 → refreshThemes + 活跃主题页重载）
/// - B6 Dock 图标（活跃主题 manifest icons.dock-{light,dark} 跟系统外观切换；official 还原）
///
/// 与参考宿主 GrokDesktop 的关键差异：本壳不拥有后端生命周期（ServerManager 已有）、
/// 不做官方视图的加载/重载（WebView.swift 已有，SwiftUI 持有 official 实例），
/// 本类只做「主题面」的池编排。
@MainActor
final class ThemeCoordinator: NSObject, ObservableObject {
    static let shared = ThemeCoordinator()

    private let app = AppState.shared
    private let server = ServerManager.shared

    // MARK: 池状态（official 常驻由 SwiftUI 持有；主题实例 ≤2）
    private var container: ThemeContainerView?
    private var themeViews: [String: ThemeWebView] = [:]
    private var staleSince: [ObjectIdentifier: Date] = [:]
    private(set) var activeAppearance: ThemeAppearance = .official
    private var pendingTarget: ThemeAppearance?
    /// official 尚未就绪（首次加载未完成）时想去的主题，就绪后 reconcile
    private var themeWantedBeforeOfficialReady: String?
    /// 官方 Web 面是否在屏（与 ContentView 的 showWeb 同公式：running 或「error 且
    /// 页面已载」的断连态；false=状态面板在屏，主题层让位）。由协调器从
    /// server.status + pageLoaded 推导，不经 SwiftUI 桥同步
    private var webSurfaceAvailable = false

    // MARK: 主题面轮询（§4）
    private var themesPollTask: Task<Void, Never>?
    private var bootInfoTask: Task<Void, Never>?
    private var lastIconVersion: String?
    private var manifests: [String: ThemeManifest] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var webLoadedObserver: NSObjectProtocol?
    /// 主窗口获焦（didBecomeKey）→ 容器装机/迁移的观察者
    private var windowObserver: NSObjectProtocol?
    /// 一次性层级 dump 已做标记（z-order 排障证据链）
    private var didDumpHierarchy = false
    /// 首次切换到主题后的那份 dump 的标记
    private var didDumpHierarchyAfterSwitch = false
    private var interfaceObserver: NSObjectProtocol?
    /// 新 launch token 到达 → 官方页下次 didFinish（Cookie 已落入共享存储）后重载主题页（§12-5）
    private var pendingThemeResync = false
    /// boot-info 轮询失败去重键（同因只 WARN 一次，恢复后复位）
    private var lastBootInfoFailureKey: String?
    /// boot-info 最近一次上报的 active（变化才打 INFO，避免 1s 轮询刷屏）
    private var lastReportedActive: String?
    /// §5 失败处理「SHOULD 单次重试后回退」：boot-info 跟随驱动的自动建页按主题 id
    /// 计失败次数，≥2 次后静默放弃（防对永不握手的旧主题无限重建 WebView）；
    /// 后端重连或用户显式 select 时清零重来
    private var autoPrepareFailures: [String: Int] = [:]
    /// 放弃告警去重（每个 id 只在进入放弃态时打一条 ERROR）
    private var gaveUpLogged: Set<String> = []

    /// B4 首装激活的「此前主题清单快照」（持久化：保证自动激活一生只发生一次，
    /// 绝不覆盖用户跨启动的已有选择）
    private static let knownThemeIDsKey = "theme.firstInstallKnownIDs"

    // MARK: - 启动接线（AppDelegate.applicationDidFinishLaunching 调用）

    func launch() {
        observeBackendStatus()
        observeOfficialReadiness()
        observeOfficialPageLoads()
        observeInterfaceChanges()
        observeWindows()
        startThemePlanePolls()
        updateWebSurfaceAvailable()
        ensureContainerInstalled()   // 窗口已存在则立即装；否则等 didBecomeKey
        Log.info("ThemeCoordinator 已接线（主题面轮询启动）")
    }

    /// B5：后端健康流（ServerManager.status）→ 重连/冷启动进入 running 时刷新主题面
    /// + 重载活跃主题页。冷启动首刷与后端重启续刷同走此路。
    private func observeBackendStatus() {
        server.$status.removeDuplicates().sink { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateWebSurfaceAvailable()
                guard status == .running else { return }
                await self.backendRunningPulse()
            }
        }
        .store(in: &cancellables)
    }

    /// official 就绪门：现有 WebView.swift 的加载状态（pageLoaded）翻真 = 官方页
    /// 首载完成（token 已换成 Cookie 落共享存储），此刻才允许主题建页（防 401 闪烁）
    private func observeOfficialReadiness() {
        app.$pageLoaded.removeDuplicates().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateWebSurfaceAvailable()
                self.reconcileAfterOfficialReady()
            }
        }
        .store(in: &cancellables)
    }

    /// 官方页每次 didFinish 都会广播 .dshWebViewLoaded（WebView.swift 既有行为）。
    /// 借它感知「新 token 的授权导航已完成」：此刻新 Cookie 已在共享存储，
    /// 重载主题页即可无损接管新会话（协议 §12-5），无需改动 WebView.swift。
    private func observeOfficialPageLoads() {
        webLoadedObserver = NotificationCenter.default.addObserver(
            forName: .dshWebViewLoaded, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.officialPageDidFinish()
            }
        }
    }

    private func officialPageDidFinish() {
        ensureContainerInstalled()
        dumpWindowHierarchyOnce()
        guard pendingThemeResync else { return }
        pendingThemeResync = false
        let ids = themeViews.keys.sorted()
        guard !ids.isEmpty else { return }
        Log.info("新 Cookie 已落共享存储，重载主题页接管新会话：\(ids.joined(separator: ","))")
        for (_, web) in themeViews {
            web.reload()
        }
    }

    /// onLaunchTokenURL 组合接线（DSHDesktopApp 侧保留原有转存行为后追加调用）：
    /// 仅登记「有新 token 待同步」，真正的重载等官方页 didFinish 再做
    func handleLaunchToken(_ url: URL) {
        pendingThemeResync = true
        Log.info("捕获 launch token URL（主题面待官方授权导航完成后重载）")
    }

    private func backendRunningPulse() async {
        // 重连＝新的尝试机会：清空自动建页失败计数与放弃态
        autoPrepareFailures.removeAll()
        gaveUpLogged.removeAll()
        await refreshThemes()
        // 重连场景：活跃主题页重载以接管新会话（冷启动时无实例，空操作）
        if case .theme(let id) = activeAppearance {
            themeViews[id]?.reload()
        }
    }

    // MARK: - 容器与池

    /// 主窗口获焦/出现时装容器（SwiftUI 窗口在 didFinishLaunching 之后才创建，
    /// launch() 时通常还不存在；新窗口获焦时容器整体迁移过去，池实例不重建）
    private func observeWindows() {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let window = note.object as? NSWindow,
                  window.title.hasPrefix("DSH Desktop") else { return }
            Task { @MainActor [weak self] in
                self?.ensureContainerInstalled()
            }
        }
    }

    /// 容器装入主窗口。幂等：已在当前主窗口壳内则只同步可见性。
    /// 结构（根治 z-order，见 ThemeContainerView 头注释）：
    /// window.contentView = WindowShellView [ NSHostingView(官方 WebView), 主题容器, 拖拽带 ]
    private func ensureContainerInstalled() {
        guard let window = Self.mainDSHWindow() else { return }
        wrapContentViewIfNeeded(window)
        guard let shell = window.contentView else { return }
        let view = container ?? ThemeContainerView()
        container = view
        if view.superview === shell {
            syncContainerVisibility()
            return
        }
        view.removeFromSuperview()
        view.frame = shell.bounds
        view.autoresizingMask = [.width, .height]
        // 壳内恒在 hosting（官方 WebView）之上、拖拽带之下（顶部拖拽不受影响）
        if let strip = shell.subviews.first(where: { $0 is DragStripView }) {
            shell.addSubview(view, positioned: .below, relativeTo: strip)
        } else {
            shell.addSubview(view)
        }
        Log.info("主题层容器已装入窗口壳（frame=\(Int(view.frame.width))x\(Int(view.frame.height))）")
        syncContainerVisibility()
    }

    /// 把 SwiftUI 窗口的 contentView（NSHostingView）原地包进 WindowShellView。
    /// 已是壳则跳过。包壳时迁移已直装在 hosting 里的既有覆盖层（拖拽带等），
    /// 防其留在 hosting 内被 SwiftUI 重排盖住（拖拽带历史 bug 的残留路径）。
    private func wrapContentViewIfNeeded(_ window: NSWindow) {
        guard let hosting = window.contentView, !(hosting is WindowShellView) else { return }
        let shell = WindowShellView(frame: hosting.frame)
        shell.autoresizingMask = hosting.autoresizingMask
        let adopted = hosting.subviews.filter { $0 is DragStripView || $0 is ThemeContainerView }
        window.contentView = shell
        hosting.translatesAutoresizingMaskIntoConstraints = false
        shell.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: shell.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
        ])
        for overlay in adopted {
            shell.addSubview(overlay)   // 覆盖层入壳，恒在 hosting 之上
        }
        Log.info("主窗口 contentView 已包壳（NSHostingView → WindowShellView），覆盖层顺序归协调器")
    }

    /// 主窗口选择：优先当前获焦的 DSH 窗口（多窗时主题跟焦走），否则任一可见 DSH 窗
    private static func mainDSHWindow() -> NSWindow? {
        if let key = NSApp.keyWindow, key.title.hasPrefix("DSH Desktop") { return key }
        return NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("DSH Desktop") }
    }

    /// 一次性层级留痕（z-order 排障证据链）：主窗口 contentView 往下 3 层的视图树。
    /// afterSwitch=true 为切换后那一份（验证包壳顺序在 SwiftUI 重渲染后仍守住）
    private func dumpWindowHierarchyOnce(afterSwitch: Bool = false) {
        if afterSwitch {
            guard !didDumpHierarchyAfterSwitch else { return }
            didDumpHierarchyAfterSwitch = true
        } else {
            guard !didDumpHierarchy else { return }
            didDumpHierarchy = true
        }
        guard let contentView = Self.mainDSHWindow()?.contentView else { return }
        Log.info("== 主窗口层级 dump（一次性）==")
        func describe(_ view: NSView, depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            Log.info("\(pad)\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height))"
                     + " hidden=\(view.isHidden)")
            guard depth < 3 else { return }
            for sub in view.subviews { describe(sub, depth: depth + 1) }
        }
        describe(contentView, depth: 0)
    }

    /// 官方 Web 面在屏状态推导（与 ContentView 的 showWeb 同公式）+ 联动主题层显隐
    private func updateWebSurfaceAvailable() {
        var disconnected = false
        if case .error = server.status, app.pageLoaded { disconnected = true }
        webSurfaceAvailable = server.status == .running || disconnected
        syncContainerVisibility()
    }

    /// 容器可见性唯一写手：主题态且官方面在屏 → 可见；其余（official 态 / 状态面板在屏）→ 隐藏
    private func syncContainerVisibility() {
        guard let container else { return }
        var show = false
        if case .theme(let id) = activeAppearance, webSurfaceAvailable {
            show = true
            if let web = themeViews[id], web.isHidden || web.alphaValue == 0 {
                web.isHidden = false
                web.alphaValue = 1
            }
        }
        container.isHidden = !show
        container.alphaValue = 1
    }

    private func themeURL(_ id: String) -> URL {
        URL(string: "\(app.url.absoluteString)/themes/\(id)/")!
    }

    private func visibleThemeView(excluding id: String) -> NSView? {
        if case .theme(let current) = activeAppearance, current != id {
            return themeViews[current]
        }
        return nil
    }

    /// 池上限（协议 §5 MUST）：全池 ≤3，official 恒占 1 席 → 主题实例 ≤2。
    /// 新建预热实例前先回收已判陈旧者，其次回收最旧的未活跃实例。
    private func enforcePoolCap(for incoming: String) {
        let others = themeViews.filter { $0.key != incoming }
        guard others.count >= 2 else { return }
        let activeThemeID: String?
        if case .theme(let id) = activeAppearance {
            activeThemeID = id
        } else {
            activeThemeID = nil
        }
        let candidates = others
            .filter { $0.key != activeThemeID }
            .sorted {
                (staleSince[ObjectIdentifier($0.value)] ?? .distantFuture)
                    < (staleSince[ObjectIdentifier($1.value)] ?? .distantFuture)
            }
        var count = others.count
        for (id, web) in candidates {
            if count < 2 { break }
            recycleTheme(id, web)
            count -= 1
        }
    }

    // MARK: - 切换（握手通过才执行；150ms crossfade）

    /// 建页预热：/themes/<id>/ 载入 + 5s 看门狗；握手通过后才真正显隐切换
    func prepareTheme(_ id: String) {
        guard id != "official" else {
            selectOfficialLocal()
            return
        }
        // official 未就绪（首次加载未完成、Cookie 未落库）：推迟到就绪后 reconcile
        guard app.pageLoaded else {
            themeWantedBeforeOfficialReady = id
            return
        }
        ensureContainerInstalled()
        if case .theme(let current) = activeAppearance, current == id,
           let web = themeViews[id], web.handshakeResolved {
            pendingTarget = nil
            syncContainerVisibility()
            return
        }
        pendingTarget = .theme(id)
        if let web = themeViews[id] {
            // 已有实例：预热中（等握手）不动；已握手直接换
            if web.handshakeResolved {
                confirmSwitch(to: .theme(id))
            }
            return
        }
        enforcePoolCap(for: id)
        let web = ThemeWebView(themeID: id)
        web.poolDelegate = self
        web.alphaValue = 0
        web.isHidden = true
        themeViews[id] = web
        staleSince[ObjectIdentifier(web)] = nil
        container?.attach(web)
        web.loadThemePage(themeURL(id))
        web.beginHandshakeWatch(timeout: 5)   // 5s 看门狗（协议 §6-3）
    }

    /// 回 official 的本地显隐（sdk 缺席时也允许：§7 MUST 逃生门）
    func selectOfficialLocal() {
        pendingTarget = .official
        guard app.pageLoaded else {
            themeWantedBeforeOfficialReady = "official"
            return
        }
        confirmSwitch(to: .official)
    }

    private func confirmSwitch(to target: ThemeAppearance) {
        ensureContainerInstalled()
        // 先落位再显隐：syncContainerVisibility 读 activeAppearance 决定容器显藏，
        // 若等 switch 跑完再赋值，此刻仍是旧外观 → 容器被判藏（真机 dump 实锤过）
        activeAppearance = target
        app.activeThemeID = target.id
        Log.info("confirmSwitch → \(target.id)")
        switch target {
        case .official:
            // 整个主题容器淡出，露出下方现有官方 WebView（SwiftUI 持有，不动它）
            hideContainerAnimated()
        case .theme(let id):
            guard let web = themeViews[id] else {
                pendingTarget = nil
                return
            }
            syncContainerVisibility()
            if let container {
                crossfadeWithinContainer(from: visibleThemeView(excluding: id), to: web, in: container)
            }
            dumpWindowHierarchyOnce(afterSwitch: true)
        }
        pendingTarget = nil
        themeWantedBeforeOfficialReady = nil
        if case .theme(let switchedID) = target {
            // 切换成功：清该主题的自动建页失败计数与放弃态
            autoPrepareFailures.removeValue(forKey: switchedID)
            gaveUpLogged.remove(switchedID)
        }
        scheduleStaleRecycle()
        applyDockIcon()
    }

    private func reconcileAfterOfficialReady() {
        guard let wanted = themeWantedBeforeOfficialReady else { return }
        themeWantedBeforeOfficialReady = nil
        if wanted == "official" {
            confirmSwitch(to: .official)
        } else {
            prepareTheme(wanted)
        }
    }

    private func crossfadeWithinContainer(from: NSView?, to: NSView,
                                          in container: ThemeContainerView) {
        if from == nil {
            // official → 主题：无容器内旧实例，主题层整体淡入盖到官方 WebView 上
            container.crossfade(from: nil, to: to)
        } else {
            container.crossfade(from: from, to: to)
        }
    }

    private func hideContainerAnimated() {
        guard let container else { return }
        guard !container.isHidden, container.alphaValue != 0 else {
            container.isHidden = true
            container.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                // 淡出期间用户可能已切回主题：非 official 态不得落隐藏
                guard let self, case .official = self.activeAppearance else { return }
                container.isHidden = true
                container.alphaValue = 1
            }
        })
    }

    /// §5 失败处理：看门狗超时 / 加载失败 → MUST 停留当前外观 + 回收预热实例 + 错误提示。
    /// 失败计数供 boot-info 自动跟随的「单次重试后回退」；通知只在首次失败发一条防刷屏。
    private func switchFailed(theme id: String, reason: String) {
        pendingTarget = nil
        autoPrepareFailures[id] = (autoPrepareFailures[id] ?? 0) + 1
        let attempt = autoPrepareFailures[id] ?? 0
        Log.error("主题 \(id) 切换失败（第 \(attempt) 次）：\(reason)；停留当前外观 \(activeAppearance.id)")
        if let web = themeViews[id], activeAppearance != .theme(id) {
            recycleTheme(id, web)
        }
        if attempt == 1 {
            postLocalNotification(title: "主题切换失败", body: "主题 \(id)：\(reason)；已停留当前外观。")
        }
    }

    private func recycleTheme(_ id: String, _ web: ThemeWebView) {
        guard themeViews[id] === web else { return }
        themeViews.removeValue(forKey: id)
        staleSince[ObjectIdentifier(web)] = nil
        web.recycle()
    }

    /// 切换完成后多余实例延迟 ≥300s 回收（协议 §5 SHOULD）
    private func scheduleStaleRecycle() {
        let activeID = activeAppearance.id
        for (id, web) in themeViews where id != activeID {
            let key = ObjectIdentifier(web)
            guard staleSince[key] == nil else { continue }
            staleSince[key] = Date()
            let stamp = staleSince[key]
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self, self.staleSince[key] == stamp else { return }
                if self.activeAppearance.id == id {
                    self.staleSince[key] = nil
                    return
                }
                self.recycleTheme(id, web)
            }
        }
    }

    // MARK: - 对外动作（供后续设置页 UI / 首装激活调用）

    /// POST /api-theme/select + 池编排（404 未装 / 403 禁用 / 409 不兼容）
    func select(_ id: String) {
        if id == "official" {
            selectOfficial()
            return
        }
        guard app.themeSDKAvailable else {
            Log.warn("select(\(id)) 跳过：themeSDKAvailable=false（dsh-theme-sdk 未就绪），保持当前外观 \(activeAppearance.id)")
            return
        }
        if let info = app.themes.first(where: { $0.id == id }), info.incompatible {
            Log.error("select(\(id)) 拒绝：incompatible=true（后端兼容裁决），保持当前外观 \(activeAppearance.id)")
            postLocalNotification(title: "主题不可激活", body: "主题 \(id) 与当前后端不兼容，已保持当前外观。")
            return
        }
        Task {
            Log.info("select(\(id))：POST /api-theme/select {\"id\":\"\(id)\"} …（当前外观 \(activeAppearance.id)）")
            switch await ThemeAPI.selectTheme(base: app.url, id: id) {
            case .success:
                // 用户显式选择：清失败计数与放弃态，无论如何都给一次全新尝试
                autoPrepareFailures.removeValue(forKey: id)
                gaveUpLogged.remove(id)
                Log.info("select(\(id))：激活成功 → prepareTheme（建页 → 握手 → crossfade）")
                prepareTheme(id)
            case .failure(let error):
                let why: String
                switch error {
                case .http(404): why = "未安装（404）"
                case .http(403): why = "已禁用（403）"
                case .http(409): why = "不兼容（409）"
                case .http(let code): why = "HTTP \(code)"
                case .transport: why = "网络不可达"
                }
                Log.error("select(\(id)) 失败：\(why)；保持当前外观 \(activeAppearance.id)")
                postLocalNotification(title: "主题切换失败", body: "切换到 \(id) 失败（\(why)），已保持当前外观。")
            }
        }
    }

    /// 回 official（先尽力同步 sdk 侧状态，再本地显隐）
    func selectOfficial() {
        guard app.themeSDKAvailable else {
            selectOfficialLocal()
            return
        }
        Task {
            _ = await ThemeAPI.selectTheme(base: app.url, id: "official")
            selectOfficialLocal()
        }
    }

    /// 重载活跃主题页（重连跟随；官方面的刷新仍走既有「刷新页面」菜单链）
    func reloadVisible() {
        if case .theme(let id) = activeAppearance {
            themeViews[id]?.reload()
        }
    }

    // MARK: - 主题面轮询：/themes（B4 首装激活的数据源）

    /// GET /themes 轮询：成功 → 发布清单 + 首装激活检查；
    /// 404 = sdk 未装 → 静默休眠（不弹任何 UI，恢复后自动续上）
    private func refreshThemes() async {
        switch await ThemeAPI.fetchThemes(base: app.url) {
        case .success(let list):
            app.themes = list
            app.themeSDKAvailable = true
            maybeFirstInstallActivation(with: list)
        case .failure(.notFound):
            app.themeSDKAvailable = false
            Log.info("/themes 404（dsh-theme-sdk 未装），主题面静默休眠")
        case .failure(.unavailable(let message)):
            app.themeSDKAvailable = false
            Log.info("主题面不可达：\(message)")
        }
    }

    /// B4 首装激活：/themes 首次成功（此前快照为空）且发现主题 id → 自动激活一次。
    /// 快照持久化（UserDefaults）：一生只发一次；用户已有选择（非 official 态 /
    /// 切换进行中 / 候选 incompatible）一律不覆盖。
    private func maybeFirstInstallActivation(with list: [ThemeInfo]) {
        let known = UserDefaults.standard.stringArray(forKey: Self.knownThemeIDsKey) ?? []
        let ids = list.map { $0.id }
        defer {
            UserDefaults.standard.set(ids, forKey: Self.knownThemeIDsKey)
            UserDefaults.standard.synchronize()
        }
        guard known.isEmpty else { return }
        guard case .official = activeAppearance, pendingTarget == nil else {
            Log.info("首装激活跳过：用户已有选择在先（当前外观 \(activeAppearance.id)）")
            return
        }
        guard let candidate = list.first(where: { $0.id != "official" && !$0.incompatible }) else {
            Log.info("首装激活跳过：清单无可激活主题（[\(ids.joined(separator: ","))]）")
            return
        }
        Log.info("首装激活：首次见到主题清单且存在 \(candidate.id)（version=\(candidate.version ?? "-")）→ 自动激活一次")
        select(candidate.id)
    }

    // MARK: - boot-info 轮询（1s；active 驱动跟随切换，iconVersion 驱动 Dock 图标）

    private func startThemePlanePolls() {
        themesPollTask?.cancel()
        bootInfoTask?.cancel()
        themesPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.server.status == .running {
                    await self.refreshThemes()
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        bootInfoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.server.status == .running {
                    switch await ThemeAPI.fetchBootInfo(base: self.app.url) {
                    case .ok(let info):
                        self.reportBootInfoFailure(nil)
                        self.applyBootInfo(info)
                    case .http(let code):
                        self.reportBootInfoFailure("HTTP \(code)")
                    case .transport(let message):
                        self.reportBootInfoFailure("网络不可达：\(message)")
                    case .badPayload(let message):
                        self.reportBootInfoFailure("坏响应：\(message)")
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    /// boot-info 轮询失败留痕：同因只 WARN 一次；恢复（200）后复位并补一条恢复 INFO
    private func reportBootInfoFailure(_ key: String?) {
        if let key {
            guard key != lastBootInfoFailureKey else { return }
            lastBootInfoFailureKey = key
            Log.warn("boot-info 轮询失败：\(key)（同因去重，恢复后自动续查）")
        } else if let previous = lastBootInfoFailureKey {
            lastBootInfoFailureKey = nil
            Log.info("boot-info 轮询恢复 200（此前失败：\(previous)）")
        }
    }

    /// B5 跟随：sdk 侧 active 变化 → 跟随切换（含被外部 CLI 切换、主题被禁用/卸载回 official）
    private func applyBootInfo(_ info: BootInfo) {
        let active = info.active ?? "official"
        if active != lastReportedActive {
            Log.info("boot-info active=\(active)（本地可见 \(activeAppearance.id)，"
                     + "pendingTarget=\(pendingTarget?.id ?? "-")，iconVersion=\(info.iconVersion ?? "-")）")
            lastReportedActive = active
        }
        if active == "official" {
            if activeAppearance != .official, pendingTarget == nil {
                selectOfficialLocal()
            }
        } else if activeAppearance != .theme(active), pendingTarget != .theme(active) {
            // §5「SHOULD 单次重试后回退」：boot-info 跟随驱动的自动建页最多重试 1 次
            //（累计 2 次失败即静默放弃，防对永不握手的旧主题无限重建 WebView）；
            // 用户显式 select 或后端重连会清零计数
            let failures = autoPrepareFailures[active] ?? 0
            if failures >= 2 {
                if !gaveUpLogged.contains(active) {
                    gaveUpLogged.insert(active)
                    Log.error("主题 \(active) 自动建页连续 \(failures) 次失败，放弃自动重试（保持官方界面）；"
                              + "可在主题设置显式选择或重连后端后重试")
                }
            } else {
                gaveUpLogged.remove(active)
                prepareTheme(active)
            }
        }
        // 已不在 sdk 意向里的失败计数顺手清掉，防字典无界增长
        autoPrepareFailures = autoPrepareFailures.filter {
            $0.key == active || $0.key == activeAppearance.id
        }
        if info.iconVersion != lastIconVersion {
            Log.info("boot-info iconVersion 变化：\(String(describing: info.iconVersion))")
            lastIconVersion = info.iconVersion
            applyDockIcon()
        }
    }

    // MARK: - B6 Dock 图标联动（活跃主题 manifest icons.dock light/dark，按系统外观取）

    func applyDockIcon() {
        Task { await syncDockIcon() }
    }

    private func syncDockIcon() async {
        guard case .theme(let id) = activeAppearance else {
            NSApp.applicationIconImage = nil   // official → 还原应用图标
            return
        }
        let manifest = await self.manifest(for: id)
        let dark = Self.isDarkAppearance()
        // manifest.icons.dock = { light, dark } 相对路径（按系统外观选其一，缺项交叉兜底）
        let dock = manifest?.icons
        let primary = dark ? dock?.dark : dock?.light
        let fallback = dark ? dock?.light : dock?.dark
        guard let relative = primary ?? fallback else {
            NSApp.applicationIconImage = nil
            return
        }
        guard let url = URL(string: "\(app.url.absoluteString)/themes/\(id)/\(relative)") else { return }
        guard let data = await ThemeAPI.fetchData(url), let image = NSImage(data: data) else { return }
        NSApp.applicationIconImage = image
    }

    private func manifest(for id: String) async -> ThemeManifest? {
        if let cached = manifests[id] { return cached }
        guard let manifest = await ThemeAPI.fetchManifest(base: app.url, id: id) else { return nil }
        manifests[id] = manifest
        return manifest
    }

    /// 系统外观判定：直读 AppleInterfaceStyle（有值 = 深色），Auto 跟随模式下该键
    /// 缺失，回退 NSApp 实际生效外观
    @MainActor
    static func isDarkAppearance() -> Bool {
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle"), !style.isEmpty {
            return true
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func observeInterfaceChanges() {
        interfaceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyDockIcon() }
        }
    }

    // MARK: - 主题页会话导出（/api/session.export；不拦截会整页跳走毁掉主题页）

    /// 池共享存储里的 Cookie → 原生下载请求（认证链后端需要签名 Cookie），
    /// 存 ~/Downloads + 原生通知（与官方 WebView 的导出体验对齐）
    private func exportSession(from url: URL, store: WKWebsiteDataStore) async {
        let cookies: [HTTPCookie] = await store.httpCookieStore.allCookies()
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Log.error("主题页会话导出失败（HTTP \(code)）")
                return
            }
            let sessionId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "sessionId" })?.value ?? "session"
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let file = downloads.appendingPathComponent("session-log-\(sessionId).zip")
            try data.write(to: file)
            Log.info("主题页会话导出完成：\(file.lastPathComponent)")
            let content = UNMutableNotificationContent()
            content.title = "DSH Desktop 会话导出"
            content.body = "已保存 \(file.lastPathComponent)"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        } catch {
            Log.error("主题页会话导出失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 错误提示（§5 失败处理 MUST；壳无内嵌 toast，走既有原生通知通道）

    private func postLocalNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        Task {
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
        }
    }
}

// MARK: - ThemeWebViewDelegate（主线程回调）

extension ThemeCoordinator: ThemeWebViewDelegate {

    func themeWebViewHandshakeResolved(_ web: ThemeWebView, handshake: ThemeHandshake) {
        let id = web.themeID
        // §6-4：compat:'fail' 也算握手成功——壳照常切换，只读降级由主题页自身呈现
        Log.info("握手裁决 theme:\(id)：compat=\(handshake.compat ?? "ok")"
                 + (handshake.compatOK ? "" : "（只读降级，由主题页自行提示）"))
        if pendingTarget == .theme(id) || activeAppearance == .theme(id) {
            confirmSwitch(to: .theme(id))
        }
    }

    func themeWebViewHandshakeTimedOut(_ web: ThemeWebView) {
        switchFailed(theme: web.themeID, reason: "握手 5 秒超时")
    }

    func themeWebViewDidFail(_ web: ThemeWebView, provisional: Bool) {
        if pendingTarget == .theme(web.themeID) {
            switchFailed(theme: web.themeID, reason: "页面加载失败")
        }
    }

    /// §6-5：渲染进程崩溃 → 回收该实例并回退 official；
    /// 若 sdk 侧 active 仍指向该主题，boot-info 跟随会重建（计入失败上限，
    /// 连续崩溃到上限后静默放弃，防无限重建循环）
    func themeWebViewContentProcessTerminated(_ web: ThemeWebView) {
        let id = web.themeID
        let wasActive = activeAppearance == .theme(id)
        recycleTheme(id, web)
        autoPrepareFailures[id] = (autoPrepareFailures[id] ?? 0) + 1
        guard wasActive else { return }
        activeAppearance = .official
        app.activeThemeID = "official"
        pendingTarget = nil
        syncContainerVisibility()
        applyDockIcon()
        Log.error("主题 \(id) 渲染进程崩溃，已回退官方界面")
        postLocalNotification(title: "主题已回退", body: "主题 \(id) 渲染进程崩溃，已回退官方界面。")
    }

    func themeWebViewDidRequestExport(_ web: ThemeWebView, url: URL) {
        Task { await exportSession(from: url, store: web.configuration.websiteDataStore) }
    }
}
