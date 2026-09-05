import Foundation
@preconcurrency import WebKit
import AppKit

// MARK: - 握手 payload（协议 §6-2）

struct ThemeHandshake {
    var type: String?
    var id: String?
    var version: String?
    var protocolVersion: String?
    var clientVersion: String?
    var adapter: String?
    var compat: String?          // "ok" | "fail"
    var compatReason: String?
    var caps: [String] = []

    /// compat:'fail' 也算握手成功（§6-4：允许显示，只读降级由主题页自身呈现，壳照常切换）
    var compatOK: Bool { (compat ?? "ok") != "fail" }

    /// 接受原生 message body（字典或 JSON 字符串）
    static func parse(_ body: Any) -> ThemeHandshake? {
        var dict: [String: Any]?
        if let d = body as? [String: Any] {
            dict = d
        } else if let s = body as? String {
            dict = jsonObject(s)
        }
        guard let d = dict else { return nil }
        var hs = ThemeHandshake()
        hs.type = d["type"] as? String
        hs.id = d["id"] as? String
        hs.version = d["version"] as? String
        if let n = d["protocol"] as? NSNumber { hs.protocolVersion = n.stringValue }
        hs.clientVersion = d["clientVersion"] as? String
        hs.adapter = d["adapter"] as? String
        hs.compat = d["compat"] as? String
        hs.compatReason = d["compatReason"] as? String
        hs.caps = d["caps"] as? [String] ?? []
        return hs
    }

    static func jsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - 原生消息通道（协议 §6-1 首选：window.webkit.messageHandlers.themeReady）

/// WKUserContentController 强持有本对象；本对象只弱引用 webview，无环。
final class ThemeReadyBroker: NSObject, WKScriptMessageHandler {
    weak var target: ThemeWebView?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == ThemeWebView.themeReadyHandlerName else { return }
        let body = message.body
        Task { @MainActor [weak target] in
            target?.receiveThemeReady(body: body)
        }
    }
}

// MARK: - 委托（宿主编排入口；全部在主线程回调）

@MainActor
protocol ThemeWebViewDelegate: AnyObject {
    func themeWebViewDidFail(_ web: ThemeWebView, provisional: Bool)
    func themeWebViewHandshakeResolved(_ web: ThemeWebView, handshake: ThemeHandshake)
    func themeWebViewHandshakeTimedOut(_ web: ThemeWebView)
    /// 渲染进程崩溃（协议 §6-5）：自报协调器，由其回收并回退 official
    func themeWebViewContentProcessTerminated(_ web: ThemeWebView)
    /// 主题页内触发的会话导出导航（不拦截会整页跳走）
    func themeWebViewDidRequestExport(_ web: ThemeWebView, url: URL)
}

// MARK: - 池内主题 WebView 实例（主题专用；official 由现有 HarnessWebView 担任，不经本类）

final class ThemeWebView: WKWebView {
    static let themeReadyHandlerName = "themeReady"
    /// §6-1 兜底通道：documentElement.dataset.themeReady → data-theme-ready 属性
    private static let domProbeJS = "document.documentElement.getAttribute('data-theme-ready') || ''"

    let themeID: String
    weak var poolDelegate: ThemeWebViewDelegate?

    private(set) var handshake: ThemeHandshake?
    private(set) var handshakeResolved = false
    private var watchdogTask: Task<Void, Never>?
    private var domPollTask: Task<Void, Never>?

    init(themeID: String) {
        self.themeID = themeID
        let config = WKWebViewConfiguration()
        // 全池共享同一网站数据存储（协议 §5 rev1.5 MUST）：
        // launch token 一次性，签名 Cookie 落默认 WKWebsiteDataStore 即全池生效；
        // 官方 WebView（HarnessWebView）用 configuration 默认值，同为 .default()，天然共享
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "DSHDesktop/1.0"
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.preferences.isElementFullscreenEnabled = true
        let broker = ThemeReadyBroker()
        config.userContentController.add(broker, name: Self.themeReadyHandlerName)
        super.init(frame: .zero, configuration: config)
        broker.target = self
        navigationDelegate = self
        uiDelegate = self
        allowsBackForwardNavigationGestures = false
        // 与官方 WebView 同款沉浸式底色（不做官方那套 overlay 注入：主题是整面替换件）
        underPageBackgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: 加载

    /// 主题静态入口 /themes/<id>/（协议 §4：栅栏外，无需 token；Cookie 由共享存储带出）
    func loadThemePage(_ url: URL) {
        load(URLRequest(url: url))
    }

    // MARK: 就绪握手 + 5s 看门狗（协议 §6-3）

    func beginHandshakeWatch(timeout: TimeInterval = 5) {
        cancelHandshakeWatch()
        handshakeResolved = false
        handshake = nil
        let deadline = Date().addingTimeInterval(timeout)
        // 主看门狗：5s 未握手 → 失败路径（停留当前外观 + 回收预热实例）
        watchdogTask = Task { @MainActor [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !self.handshakeResolved else { return }
            }
            guard let self, !self.handshakeResolved else { return }
            self.cancelHandshakeWatch()
            Log.error("握手看门狗 5s 超时（theme:\(self.themeID)）")
            self.poolDelegate?.themeWebViewHandshakeTimedOut(self)
        }
        // 兜底通道：DOM 标记轮询（≤500ms 间隔）
        domPollTask = Task { @MainActor [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !self.handshakeResolved else { return }
                self.probeDOMHandshake()
            }
        }
    }

    func cancelHandshakeWatch() {
        watchdogTask?.cancel()
        watchdogTask = nil
        domPollTask?.cancel()
        domPollTask = nil
    }

    private func probeDOMHandshake() {
        Task { @MainActor [weak self] in
            guard let self, !self.handshakeResolved else { return }
            guard let result = (try? await self.evaluateJavaScript(Self.domProbeJS)) as? String,
                  !result.isEmpty else { return }
            self.receiveThemeReady(body: result)
        }
    }

    /// themeReady 消息（原生通道或 DOM 兜底）统一入口，含 §6-2 payload 校验
    @MainActor
    func receiveThemeReady(body: Any) {
        guard !handshakeResolved, let hs = ThemeHandshake.parse(body) else { return }
        // payload 校验（协议 §6-2）：type 必须为 'theme:ready'，id 必须匹配所请求主题；
        // 不合法一律忽略、继续等看门狗裁决
        guard hs.type == "theme:ready" else {
            Log.warn("themeReady payload type 非法（\(hs.type ?? "nil")），忽略（theme:\(themeID)）")
            return
        }
        guard hs.id == themeID else {
            Log.warn("themeReady payload id 不匹配（\(hs.id ?? "nil") ≠ \(themeID)），忽略")
            return
        }
        handshakeResolved = true
        handshake = hs
        cancelHandshakeWatch()
        Log.info("themeReady 握手收到：id=\(hs.id ?? "-") clientVersion=\(hs.clientVersion ?? "-")"
                 + " adapter=\(hs.adapter ?? "-") compat=\(hs.compat ?? "ok")")
        poolDelegate?.themeWebViewHandshakeResolved(self, handshake: hs)
    }

    // MARK: 回收（official 由 SwiftUI 持有永不回收；主题实例按池策略回收）

    func recycle() {
        cancelHandshakeWatch()
        stopLoading()
        navigationDelegate = nil
        uiDelegate = nil
        configuration.userContentController.removeAllScriptMessageHandlers()
        removeFromSuperview()
    }
}

// MARK: - 导航策略 / 生命周期

extension ThemeWebView: WKNavigationDelegate, WKUIDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.info("theme:\(themeID) 页面加载完成（URL=\(webView.url?.absoluteString ?? "-")）")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let delegate = poolDelegate
        Task { @MainActor in delegate?.themeWebViewDidFail(self, provisional: true) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let delegate = poolDelegate
        Task { @MainActor in delegate?.themeWebViewDidFail(self, provisional: false) }
    }

    /// 渲染进程崩溃（主题代码最坏情况，协议 §6-5）→ 自报协调器：回收 + 回退 official
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let delegate = poolDelegate
        Task { @MainActor in delegate?.themeWebViewContentProcessTerminated(self) }
    }

    // MARK: 导航决策

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 主框架导航全量留痕（回答「主题页此刻要去哪」）
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url {
            Log.info("导航[theme:\(themeID)] → \(url.absoluteString)")
        }
        // /api/session.export：不拦截会整页跳到 ZIP 字节流毁掉主题页 → 交协调器原生下载
        if let url = navigationAction.request.url,
           url.path.contains("/api/session.export") {
            decisionHandler(.cancel)
            let delegate = poolDelegate
            Task { @MainActor in delegate?.themeWebViewDidRequestExport(self, url: url) }
            return
        }

        // 仅 127.0.0.1/localhost 壳内打开；外域主框架导航交系统浏览器（与官方 WebView 策略一致）。
        // 只拦主框架：页面内外部子资源（字体/图片等）照常渲染。
        if navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let host = url.host?.lowercased(),
           host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
            decisionHandler(.cancel)
            Task { @MainActor in NSWorkspace.shared.open(url) }
            return
        }

        decisionHandler(.allow)
    }

    /// 新窗口请求（target=_blank / window.open）：外域交系统浏览器，本机仍在壳内
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           let host = url.host?.lowercased(),
           host != "127.0.0.1", host != "localhost", !host.hasSuffix(".localhost") {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        } else if navigationAction.targetFrame == nil {
            load(navigationAction.request)
        }
        return nil
    }

    /// 麦克风 / 摄像头（主题内语音输入等场景，与官方 WebView 策略一致）
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}
