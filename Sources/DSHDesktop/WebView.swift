import SwiftUI
@preconcurrency import WebKit
import UserNotifications

/// 内嵌 DSH Web GUI 的 WKWebView 封装
struct HarnessWebView: NSViewRepresentable {
    let url: URL
    /// 一次性授权 URL（优先于 url 首载）。0.1.2-alpha.1+ 的后端在 stdout
    /// 打印 `dsh web: http://127.0.0.1:port/?token=...`，首载先访问它，
    /// 服务端 303 回裸 "/" 并 Set-Cookie（HttpOnly），此后 WKWebView
    /// 自动持有 Cookie；裸 URL 首载只会停在 401 文本页。
    var authURL: URL? = nil
    /// 发起授权加载后立即回调（上层清掉 authLaunchURL）：token 一次性，
    /// 加载一经发起就必须作废，防止重渲染时二次复用
    var onAuthConsumed: (() -> Void) = {}
    var onLoadState: (LoadState) -> Void = { _ in }

    enum LoadState {
        case loaded(title: String)
        case failed
        // 注意：刻意没有 .loading —— didStartProvisional 只驱动内部的
        // isLoading 守卫，不对外发事件；历史上曾有过从未被发射的死分支
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// 拖拽带悬停探针：页面 mouseover 时回报悬停目标是否为可交互元素，
    /// 供 DragStripView.hitTest 决定放行（可交互→穿透给 webview）或拖拽。
    private static let dragStripHoverProbe = """
    (function () {
      "use strict";
      var INTERACTIVE = "button,a,input,select,textarea,label,[role=button],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=combobox],[contenteditable=true]";
      var last = null;
      function report(interactive) {
        if (interactive === last) return;
        last = interactive;
        try { window.webkit.messageHandlers.dshDragStripProbe.postMessage(interactive); } catch (e) {}
      }
      document.addEventListener("mouseover", function (e) {
        var t = e.target;
        report(!!(t && t.closest && t.closest(INTERACTIVE)));
      }, true);
      document.addEventListener("scroll", function () { report(false); }, true);
    })();
    """

    /// ES2025 迭代器助手垫片：官方 0.1.5 起 client 条目（sidebar-documentpreview
    /// 等）引用裸 `Iterator` 全局（Iterator.from/map/filter…），本机 WKWebView 的
    /// JavaScriptCore 尚未内建，启动图一个条目 ImportError 会阻塞整个插件加载。
    /// 仅在缺失时注入；已内建（未来系统）则为空操作。
    private static let iteratorHelpersPolyfill = """
    (function () {
      "use strict";
      if (typeof window.Iterator !== "undefined") return;
      function IteratorShim() {}
      Object.defineProperty(IteratorShim.prototype, Symbol.iterator, {
        value: function () { return this; }, writable: true, configurable: true
      });
      IteratorShim.from = function (source) {
        if (source instanceof IteratorShim) return source;
        var it;
        if (typeof source === "string" || (source && typeof source[Symbol.iterator] === "function")) {
          it = source[Symbol.iterator]();
        } else if (source && typeof source.next === "function") {
          it = source;
        } else {
          throw new TypeError("Iterator.from: source is not iterable");
        }
        var wrapper = new IteratorShim();
        wrapper.next = function (v) { return it.next(v); };
        if (typeof it.return === "function") wrapper.return = function (v) { return it.return(v); };
        if (typeof it.throw === "function") wrapper.throw = function (v) { return it.throw(v); };
        return wrapper;
      };
      function helper(name, fn) {
        Object.defineProperty(IteratorShim.prototype, name, {
          value: fn, writable: true, configurable: true, enumerable: false
        });
      }
      helper("map", function (fn) {
        var self = IteratorShim.from(this), i = 0;
        return IteratorShim.from((function* () { for (var v of self) yield fn(v, i++); })());
      });
      helper("filter", function (fn) {
        var self = IteratorShim.from(this), i = 0;
        return IteratorShim.from((function* () { for (var v of self) if (fn(v, i++)) yield v; })());
      });
      helper("take", function (n) {
        var self = IteratorShim.from(this), remaining = Number(n) || 0;
        return IteratorShim.from((function* () { for (var v of self) { if (remaining-- <= 0) return; yield v; } })());
      });
      helper("drop", function (n) {
        var self = IteratorShim.from(this), remaining = Number(n) || 0;
        return IteratorShim.from((function* () {
          for (var v of self) { if (remaining > 0) { remaining--; continue; } yield v; }
        })());
      });
      helper("flatMap", function (fn) {
        var self = IteratorShim.from(this), i = 0;
        return IteratorShim.from((function* () {
          for (var v of self) {
            var inner = fn(v, i++);
            if (typeof inner === "string") { yield* inner; continue; }
            yield* inner;
          }
        })());
      });
      helper("reduce", function (fn, initial) {
        var acc = arguments.length > 1 ? initial : undefined, has = arguments.length > 1;
        for (var v of this) { acc = has ? fn(acc, v) : v; has = true; }
        return acc;
      });
      helper("toArray", function () { return Array.from(this); });
      helper("some", function (fn) { for (var v of this) if (fn(v)) return true; return false; });
      helper("every", function (fn) { for (var v of this) if (!fn(v)) return false; return true; });
      helper("find", function (fn) { for (var v of this) if (fn(v)) return v; return undefined; });
      // ES 模块与经典脚本共享同一全局：必须显式挂到 window，模块里的裸
      // `Iterator` 标识符才能解析到垫片
      window.Iterator = IteratorShim;
    })();
    """

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "DSHDesktop/1.0"
        config.preferences.isElementFullscreenEnabled = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // 兼容垫片必须在任何页面脚本之前求值（document start / 主框架）
        let polyfill = WKUserScript(
            source: Self.iteratorHelpersPolyfill,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(polyfill)
        // 拖拽带悬停探针 + 消息回报通道
        let hoverProbe = WKUserScript(
            source: Self.dragStripHoverProbe,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(hoverProbe)
        config.userContentController.add(DragStripProbeHandler(), name: "dshDragStripProbe")

        let webView = WKWebView(frame: .zero, configuration: config)
        // 沉浸式：页面背景透明（配合 fullSizeContentView 顶到顶；WKWebView 的
        // isOpaque 只读，透明由 underPageBackgroundColor 提供）
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView
        context.coordinator.observeReload()
        context.coordinator.observeEnhancements()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // 认证链（0.1.2-alpha.1+）：**每个新 token** 都要触发一次授权导航——
        // 不止首载：后端重启换新 token 时 WebView 往往还挂着旧页面（断连
        // 横幅态，hasLoadedOnce=true），不主动导航它就永远拿不到新会话
        // Cookie（旧页面的 API 重试会一直 401）。靠"上次已消费的 token
        // URL"判新：authLaunchURL 每进程只被 ServerManager 发一次、
        // 消费即清空，非空即代表新 token 到达。
        if let auth = authURL, context.coordinator.lastAuthURL != auth {
            // 【真机实测的竞态】后端刚监听时有一段"路由未就绪"窗口（根路径
            // 返回 404，就绪后才变为 401/200）。token 是一次性的：若在窗口
            // 期内花掉，303 换 Cookie 的交换会直接失败且本进程再无第二次
            // 机会（页面停在空白）。故授权加载必须先等根路径进入稳态
            // （200 或 401+认证文案），才把这张一次性牌打出去。
            context.coordinator.lastAuthURL = auth
            context.coordinator.isLoading = true   // 挡住等待期间裸 URL 抢载
            let bare = url
            Task { @MainActor [weak webView] in
                await Self.waitRootSteady(base: bare, timeout: 10)
                webView?.load(URLRequest(url: auth))
                // token 一次性：加载已发起，立即回调上层清掉 authLaunchURL。
                // 随之而来的重渲染会被 lastAuthURL/isLoading 守卫拦住，不会
                // 补发裸 URL 加载去打断这次授权导航。
                onAuthConsumed()
            }
            return
        }
        // 只在首次加载时由我们发起；此后 SPA 的路由变化（pushState 等）
        // 会改变 webView.url，不能再按地址差异重载根页面，否则会打断应用。
        // 手动刷新走菜单栏“刷新页面”（reload）。
        guard !context.coordinator.hasLoadedOnce else { return }
        guard !context.coordinator.isLoading else { return }
        let target = url
        if webView.url?.absoluteString != target.absoluteString {
            // 同步置位 isLoading，避免 didStartProvisional 异步到达前
            // 被另一次 updateNSView 重复发起加载
            context.coordinator.isLoading = true
            webView.load(URLRequest(url: target))
        }
    }

    /// 等根路径进入稳态：HTTP 200（旧版无认证）或 401 且 body 含 dsh 认证
    /// 文案（新版认证链就绪）。超时后放行（尽力而为，不再无限等）。
    /// nonisolated：纯 URLSession 轮询。
    nonisolated private static func waitRootSteady(base: URL, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: base)
            request.timeoutInterval = 2
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                if http.statusCode == 200 { return }
                if http.statusCode == 401,
                   String(decoding: data, as: UTF8.self)
                       .contains("dsh web authentication required") { return }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: HarnessWebView
        weak var webView: WKWebView?
        private var reloadObserver: NSObjectProtocol?
        private var enhancementsObserver: NSObjectProtocol?
        var isLoading = false
        private(set) var hasLoadedOnce = false
        /// 最近一次已消费的授权 token URL：非空且与新到的 authLaunchURL 不同
        /// = 新进程的新 token 到达，需要再做一次授权导航（含断连重连场景）
        var lastAuthURL: URL?

        init(_ parent: HarnessWebView) {
            self.parent = parent
        }

        deinit {
            // 块观察者必须显式移除；否则每次 WebView 重建（状态面板 ⇄ 页面
            // 切换）都会在 NotificationCenter 里留下一个永久触发的空转 token
            if let reloadObserver {
                NotificationCenter.default.removeObserver(reloadObserver)
            }
            if let enhancementsObserver {
                NotificationCenter.default.removeObserver(enhancementsObserver)
            }
        }

        /// 菜单栏“刷新页面”支持
        func observeReload() {
            reloadObserver = NotificationCenter.default.addObserver(
                forName: .dshReloadRequested, object: nil, queue: .main
            ) { [weak self] _ in
                self?.webView?.reload()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncEnhancements(webView)
            // 通知宿主：网页已加载（AppDelegate 借此把拖拽带重新置顶——
            // SwiftUI 晚于拖拽带插入 WKWebView 会盖住拖拽带）
            NotificationCenter.default.post(name: .dshWebViewLoaded, object: webView)
            isLoading = false
            hasLoadedOnce = true
            parent.onLoadState(.loaded(title: webView.title ?? "DeepSeek Harness"))
        }

        // MARK: - 增强 Overlay 同步（桌面外壳布局）

        private func syncEnhancements(_ webView: WKWebView) {
            // 本地桌面外壳 Overlay（幂等注入：固定 style id）。
            // 它只约束根 Frame 的外层列/行，不测量或改写官方功能组件。
            if let layoutPath = Bundle.main.path(forResource: "desktop-layout", ofType: "js", inDirectory: "overlays"),
               let layout = try? String(contentsOfFile: layoutPath, encoding: .utf8) {
                webView.evaluateJavaScript(layout) { _, _ in }
            }
        }

        /// 设置变化时联动（UserDefaults 通知）
        func observeEnhancements() {
            enhancementsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let webView = self?.webView, webView.url != nil else { return }
                self?.syncEnhancements(webView)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
        }

        // MARK: - 导航策略

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               url.path.contains("/api/session.export") {
                decisionHandler(.cancel)
                Task {
                    await Self.download(url: url)
                }
                return
            }

            // 外部域名的主框架导航交给系统默认浏览器：官方界面里点击的任何
            // 站外链接都不应占据壳窗口（否则整窗被外部页面接管且无可见退路）。
            // 仅拦截主框架；页面内的外部子资源（字体/图片等）照常放行渲染。
            // 本机 127.0.0.1 / localhost 的所有导航照常放行。
            if navigationAction.targetFrame?.isMainFrame == true,
               let url = navigationAction.request.url,
               let host = url.host?.lowercased(),
               host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
                decisionHandler(.cancel)
                Task { @MainActor in
                    NSWorkspace.shared.open(url)
                }
                return
            }

            decisionHandler(.allow)
        }

        /// 原生下载 session 导出 ZIP 到 ~/Downloads，并用 UserNotifications 提示
        @MainActor
        static func download(url: URL) async {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            // 文件名：session-log-<id>.zip
            let sessionId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "sessionId" })?.value ?? "session"
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
            try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            let file = downloads.appendingPathComponent("session-log-\(sessionId).zip")
            try? data.write(to: file)
            // 原生通知（同应用内通道，不使用 osascript）
            let content = UNMutableNotificationContent()
            content.title = "DSH Desktop 会话导出"
            content.body = "已保存 \(file.lastPathComponent)"
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            )
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            parent.onLoadState(.failed)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            parent.onLoadState(.failed)
        }

        /// 新窗口请求（target=_blank / window.open）：外部站点交系统浏览器，
        /// 本机地址仍在壳内打开——与主框架导航策略保持一致
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                if let url = navigationAction.request.url,
                   let host = url.host?.lowercased(),
                   host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
                    Task { @MainActor in
                        NSWorkspace.shared.open(url)
                    }
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        /// 麦克风 / 摄像头权限（DSH 可能用于语音输入等）
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.grant)
        }
    }

/// 拖拽带悬停探针的消息回收：页面回报悬停目标是否可交互，DragStripView 据此
/// 决定 hitTest 放行。不持有 webview/coordinator，无保留环。
private final class DragStripProbeHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        DragStripView.hoverOverInteractive = (message.body as? Bool) == true
    }
}
}
