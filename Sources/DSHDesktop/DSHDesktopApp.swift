import SwiftUI
import AppKit
import WebKit
import UserNotifications

@main
struct DSHDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var server = ServerManager.shared
    @StateObject private var desktop = DesktopIntegration.shared

    var body: some Scene {
        WindowGroup("DSH Desktop", id: "main") {
            ContentView(appState: appState, server: server)
                .environment(\.locale, Locale(identifier: desktop.language))
        }
        .defaultSize(width: 1280, height: 840)
        .windowStyle(.hiddenTitleBar)
        // rev1.7.2 菜单栏 SwiftUI 数据驱动路线（AppKit 装配路线已被证伪：SwiftUI
        // commands 重协调会修剪外来项）。单块 .commands 语句上限 10 条 → 链式三段。
        .commands {
            // 第一段：空体腾空系统文件/编辑菜单——从启动无条件声明、永不切换；
            // 腾空可靠且抗 SwiftUI 重协调（menu-lab LAB4/5 顶级 dump 无系统 File/Edit）
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .undoRedo) { }
            CommandGroup(replacing: .pasteboard) { }
        }
        .commands {
            // 第二段：6 个槽位 + 同名合并组（MenuBarModel 数据驱动，官方态/主题态统一
            // 承载；同名合并/窗口安全阀等语义在 MenuBarModel.themeSpecs 装配时落地）
            MenuSlot(index: 0)
            MenuSlot(index: 1)
            MenuSlot(index: 2)
            MenuSlot(index: 3)
            MenuSlot(index: 4)
            MenuSlot(index: 5)
            MergedMenuCommands()
        }
        .commands {
            // 第三段：宿主面（服务器/通用，b1727d1 回迁改造）
            ServerMenu()
        }
        Settings {
            SettingsView(appState: appState, server: server)
                .environment(\.locale, Locale(identifier: desktop.language))
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SIGTERM/SIGINT/SIGHUP → NSApp.terminate 的信号源（必须持有防释放）
    private var signalSources: [DispatchSourceSignal] = []
    private var dragStrip: DragStripView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从终端直接运行二进制时也需要常规 Dock 应用行为
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 【真机实测的孤儿后端 bug】killall / kill <pid> / 注销等 SIGTERM 类退出
        // 不走 applicationWillTerminate，自 spawn 的后端会变成孤儿 node（实测
        // 存活并继续占端口）。把 SIGTERM/SIGINT/SIGHUP 引导回 NSApp.terminate，
        // 让既有停服清理生效；SIGKILL 无法捕获，但那类场景下次启动的 attach
        // 机制会把残留实例当外部后端接管，属良性降级。DispatchSource 必须被
        // 持有，否则事件源立即释放失效。
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        // 原生通知：应用在前台时也显示横幅
        UNUserNotificationCenter.current().delegate = self
        // 预请求通知授权：macOS 只在 App 调用过 requestAuthorization 后，
        // 才会在"系统设置 → 通知"里出现该 App 的条目。提前请求一次使通道可用。
        Task {
            try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }

        // 认证链装配（0.1.2-alpha.1+）：ServerManager 从后端 stdout 捕获到
        // 带 token 的完整 launch URL（每进程仅一次）时推给 AppState，
        // 供 HarnessWebView 首载完成一次性授权换 Cookie。旧版后端
        // （0.1.1-rc.2）没有 token 行，回调不触发，首载仍走裸 URL。
        ServerManager.shared.onLaunchTokenURL = { url in
            AppState.shared.authLaunchURL = url
            // 主题宿主（组合接线）：保留上方既有转存行为，追加通知主题协调器。
            // 协调器据此在官方授权导航完成（新 Cookie 落入池共享存储）后重载
            // 主题页接管新会话（协议 §12-5）；绝不替换/打断原有认证链。
            ThemeCoordinator.shared.handleLaunchToken(url)
        }

        // 主题宿主化（主题插件协议 v1 rev1.5 宿主义务）：WebView 池（B1）、
        // 主题面轮询与重连跟随（B5）、首装激活（B4）、Dock 图标联动（B6）。
        // 握手看门狗（B2）由 ThemeWebView 承载、ThemeCoordinator 消费回调。
        // 主题 WebView 渲染进程崩溃经其委托自报协调器回退 official（§6-5）。
        ThemeCoordinator.shared.launch()
        DesktopIntegration.shared.start()

        // 沉浸式窗口：等主窗口出现后设置透明标题栏 + 内容延伸（红绿灯悬浮、内容顶到顶）。
        // 受「沉浸式标题栏」开关控制（默认开，关闭后回到系统标准标题栏）。
        applyWindowEnhancements()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        // 设置变化（UserDefaults）时幂等重放窗口增强，支持运行时开关
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyWindowEnhancements()
            }
        }
        // 迷你框三态判定支持（launcher 联动，v1 接入）：主窗口最小化/恢复/获焦时
        // 经分布式通知向 Launcher 广播可见性。事件驱动零轮询；接收方是
        // Launcher 的 VisibilityMonitor（内存布尔位，即用即弃）。
        let broadcastVisibility: (Bool) -> Void = { visible in
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("com.deepseek-ai.dsh-desktop.windowState"),
                object: nil,
                userInfo: ["visible": visible],
                deliverImmediately: true
            )
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow, w.title.hasPrefix("DSH Desktop") { broadcastVisibility(false) }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow, w.title.hasPrefix("DSH Desktop") { broadcastVisibility(true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            if let w = note.object as? NSWindow, w.title.hasPrefix("DSH Desktop") { broadcastVisibility(true) }
        }
        // Cmd+H 应用级隐藏/恢复也计入可见性（增量审计 P2-5）。注意不监听
        // didResignKey——设置窗口抢焦点等场景会误报"隐藏"。
        NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification, object: nil, queue: .main
        ) { _ in broadcastVisibility(false) }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUnhideNotification, object: nil, queue: .main
        ) { _ in broadcastVisibility(true) }
        // 窗口尺寸变化时跟随拖拽带（Low Memory：事件驱动，无轮询）
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            let windowNumber = window.windowNumber
            Task { @MainActor [weak self] in
                guard let window = NSApp.window(withWindowNumber: windowNumber),
                      window.title.hasPrefix("DSH Desktop"),
                      AppState.shared.immersiveTitlebar else { return }
                self?.layoutDragStrip(window)
            }
        }
        // 网页加载完成后把拖拽带重新置顶（SwiftUI 晚插入的 WKWebView 会盖住先加入的拖拽带）
        NotificationCenter.default.addObserver(
            forName: .dshWebViewLoaded, object: nil, queue: .main
        ) { [weak self] notification in
            guard let webView = notification.object as? WKWebView,
                  let windowNumber = webView.window?.windowNumber else { return }
            Task { @MainActor [weak self] in
                guard let window = NSApp.window(withWindowNumber: windowNumber),
                      AppState.shared.immersiveTitlebar else { return }
                self?.installDragStrip(in: window)
            }
        }

        // 「文件 → 新建窗口」无需再单独隐藏：文件菜单已整体改由槽位 CommandMenu
        // 承载（空体腾空 .newItem 使系统文件菜单整个消失，含新建窗口），见 .commands。
    }

    // MARK: - 沉浸式窗口（顶到顶）

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        applyWindowEnhancements()
    }

    /// 沉浸式标题栏（幂等，可逆）：
    /// 开 = 红绿灯悬浮、内容顶到顶；关 = 系统标准标题栏（恢复官方观感）
    private func applyWindowEnhancements() {
        let immersive = AppState.shared.immersiveTitlebar
        for window in NSApp.windows where window.title.hasPrefix("DSH Desktop") {
            // 窗口最小尺寸：即使内容区再小也保留可用的 Web GUI（与 ContentView.min 一致）
            let min = NSSize(width: 600, height: 360)
            window.minSize = min
            window.contentMinSize = min
            if immersive {
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarSeparatorStyle = .none
                alignTrafficLights(in: window)
            } else {
                window.titlebarAppearsTransparent = false
                window.titleVisibility = .visible
                window.styleMask.remove(.fullSizeContentView)
                window.titlebarSeparatorStyle = .automatic
            }
            // 拖拽带只属于沉浸式标题栏；关闭沉浸式时恢复原生标题栏的点击区域。
            if immersive {
                installDragStrip(in: window)
            } else {
                removeDragStrip(from: window)
            }
        }
    }

    // MARK: - 拖拽带（方案1：红绿灯右侧约 32 CSS px 透明拖拽）

    /// 将系统按钮组整体平移到用户约定的中心锚点 (23, 23)，不改按钮相对位置。
    ///
    /// 红灯左上角距离窗口左/上边缘等量；按钮组整体平移，保留 AppKit
    /// 自己决定的按钮尺寸与间距。
    private func alignTrafficLights(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let host = close.superview else { return }

        let buttons = [close, mini, zoom]
        let closeFrame = close.frame
        let horizontalOffsets = buttons.map { $0.frame.minX - closeFrame.minX }
        let targetMidY = host.isFlipped
            ? DesktopLayout.trafficLightCenterY
            : host.bounds.height - DesktopLayout.trafficLightCenterY
        let targetCloseMinX = DesktopLayout.trafficLightCenterX - closeFrame.width / 2

        for (button, offset) in zip(buttons, horizontalOffsets) {
            var frame = button.frame
            frame.origin.x = targetCloseMinX + offset
            frame.origin.y = targetMidY - frame.height / 2
            button.frame = frame
        }

    }

    private func installDragStrip(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        if let strip = dragStrip, strip.window === window {
            // 拖拽带必须始终是 contentView 的最后一个子视图（最上层）：
            // SwiftUI 在服务器就绪后插入的 WKWebView 会排到拖拽带之上，
            // 导致拖拽带永远收不到鼠标事件（不可拖拽的根因）。
            if contentView.subviews.last !== strip {
                strip.removeFromSuperview()
                contentView.addSubview(strip)
            }
            layoutDragStrip(window)
            return
        }
        let strip = DragStripView(frame: .zero)
        contentView.addSubview(strip)
        dragStrip = strip
        layoutDragStrip(window)
    }

    private func removeDragStrip(from window: NSWindow) {
        guard let strip = dragStrip, strip.window === window else { return }
        strip.removeFromSuperview()
        dragStrip = nil
    }

    /// 拖拽带：覆盖顶部透明行，行高 = 红绿灯水平中心线 × 2 = 46。
    /// 红绿灯在该行内垂直居中（中心 y=23），左右留出系统按钮/右侧控件安全区。
    private func layoutDragStrip(_ window: NSWindow) {
        guard let strip = dragStrip, let contentView = window.contentView else { return }
        alignTrafficLights(in: window)
        let rowHeight = DesktopLayout.dragStripHeight
        let y = contentView.isFlipped
            ? 0
            : contentView.bounds.height - rowHeight
        let safeWidth = DesktopLayout.trafficLightSafeWidth
        let rightSafeWidth = min(
            DesktopLayout.topControlsSafeWidth,
            max(0, contentView.bounds.width - safeWidth)
        )
        strip.frame = NSRect(
            x: safeWidth,
            y: y,
            width: max(0, contentView.bounds.width - safeWidth - rightSafeWidth),
            height: rowHeight
        )
    }

    /// 关闭最后一个窗口时不退出（常驻 Dock）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 退出时，若服务器由我们启动且用户未要求保持，则同步停掉。
    /// 若正在执行 dsh 更新（下载/校验/换新进程阶段），跳过停服——
    /// 否则会把更新刚换上的新后端误作旧进程杀掉，导致更新后的服务器不可用。
    func applicationWillTerminate(_ notification: Notification) {
        let server = ServerManager.shared
        if server.isUpdating { return }
        if server.startedByUs && !AppState.shared.keepServerOnQuit {
            server.stopAndWait()
        }
    }
}

extension Notification.Name {
    static let dshReloadRequested = Notification.Name("dshReloadRequested")
    static let dshWebViewLoaded = Notification.Name("dshWebViewLoaded")
}


// 原生通知：应用在前台时也显示横幅（默认前台不弹）
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
