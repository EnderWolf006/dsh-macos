import SwiftUI
import WebKit
import UserNotifications

@MainActor
final class DesktopIntegration: NSObject, ObservableObject, WKScriptMessageHandler {
    static let shared = DesktopIntegration()
    @Published var language = UserDefaults.standard.string(forKey: "desktopLanguage") ?? (Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en")
    @Published var completionMode = UserDefaults.standard.string(forKey: "completionMode") ?? "unfocused" { didSet { save() } }
    @Published var permissionNotifications = UserDefaults.standard.object(forKey: "permissionNotifications") as? Bool ?? true { didSet { save() } }
    @Published var questionNotifications = UserDefaults.standard.object(forKey: "questionNotifications") as? Bool ?? true { didSet { save() } }
    @Published var zoom = UserDefaults.standard.object(forKey: "desktopZoom") as? Double ?? 1.0
    @Published var syncError: String?
    private let views = NSHashTable<WKWebView>.weakObjects()
    private var tray: NSStatusItem?
    private var keyMonitor: Any?
    private var menuObserver: NSObjectProtocol?
    private var started = false

    func text(_ zh: String, _ en: String) -> String { language == "zh" ? zh : en }
    func localized(_ key: String) -> String {
        guard language == "en", let path = Bundle.main.path(forResource: "en", ofType: "lproj"), let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    func configure(_ config: WKWebViewConfiguration) {
        config.userContentController.add(self, name: "dshDesktop")
        if let url = Bundle.main.url(forResource: "desktop-integration", withExtension: "js", subdirectory: "overlays"),
           let script = try? String(contentsOf: url) {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
    func register(_ view: WKWebView) {
        views.add(view)
        view.pageZoom = zoom
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == "127.0.0.1",
              let body = message.body as? [String: String], let kind = body["kind"] else { return }
        if kind == "language", let value = body["value"], ["zh", "en"].contains(value) {
            language = value
            UserDefaults.standard.set(value, forKey: "desktopLanguage")
            rebuildTray()
            return
        }
        if kind == "completion" {
            guard completionMode != "never", completionMode == "always" || !NSApp.isActive else { return }
        }
        if kind == "permission" && !permissionNotifications { return }
        if kind == "question" && !questionNotifications { return }
        let messages = ["completion": text("本轮回答已完成", "Your turn is complete"),
                        "permission": text("DSH 需要你的授权", "DSH needs your permission"),
                        "question": text("DSH 需要你的回答才能继续", "DSH needs your input to continue")]
        guard let message = messages[kind] else { return }
        let content = UNMutableNotificationContent()
        content.title = "DSH Desktop"
        content.body = message
        content.sound = .default
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
    }
    func setLanguage(_ value: String) {
        guard ["zh", "en"].contains(value) else { return }
        let web = views.allObjects.first { !($0 is ThemeWebView) }
        web?.evaluateJavaScript("window.__desktopSetLanguage?.('\(value)') === true") { result, error in
            Task { @MainActor in
                guard error == nil, result as? Bool == true else {
                    self.syncError = self.text("请等待 DSH 页面连接后再切换语言。", "Wait for DSH to connect before changing language.")
                    return
                }
                self.syncError = nil
                self.language = value
                UserDefaults.standard.set(value, forKey: "desktopLanguage")
                self.rebuildTray()
            }
        }
    }
    func changeZoom(_ delta: Double) {
        zoom = min(2.0, max(0.5, zoom + delta))
        UserDefaults.standard.set(zoom, forKey: "desktopZoom")
        for view in views.allObjects { view.pageZoom = zoom }
    }
    func find() {
        guard let view = views.allObjects.first(where: { $0.window?.isKeyWindow == true && !$0.isHidden && $0.alphaValue > 0 }) else { return }
        let panel = NSAlert()
        panel.messageText = text("查找", "Find")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        panel.accessoryView = field
        panel.addButton(withTitle: text("查找下一个", "Find Next"))
        panel.addButton(withTitle: text("取消", "Cancel"))
        panel.window.initialFirstResponder = field
        if panel.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            let config = WKFindConfiguration()
            config.wraps = true
            view.find(field.stringValue, configuration: config) { _ in }
        }
    }
    func start() {
        guard !started else { return }
        started = true
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "whale-icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            tray?.button?.image = image
        } else {
            tray?.button?.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "DSH Desktop")
        }
        tray?.button?.toolTip = "DSH Desktop"
        rebuildTray()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers.contains(.control), key == "f" { self.find(); return nil }
            if modifiers.contains(.command) {
                if key == "=" || key == "+" { self.changeZoom(0.1); return nil }
                if key == "-" { self.changeZoom(-0.1); return nil }
                if key == "0" { self.changeZoom(1 - self.zoom); return nil }
            }
            return event
        }
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.hideMenus() }
        }
        hideMenus()
    }
    private func hideMenus() {
        for item in NSApp.mainMenu?.items ?? [] {
            if ["显示", "View", "文件", "File", "通用", "General"].contains(item.title) { item.isHidden = true }
        }
    }
    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(completionMode, forKey: "completionMode")
        defaults.set(permissionNotifications, forKey: "permissionNotifications")
        defaults.set(questionNotifications, forKey: "questionNotifications")
    }
    private func rebuildTray() {
        let menu = NSMenu()
        for (title, action) in [(text("显示 DSH", "Show DSH"), #selector(show)), (text("设置…", "Settings…"), #selector(settings)), (text("退出 DSH", "Quit DSH"), #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        tray?.menu = menu
    }
    @objc private func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title.hasPrefix("DSH Desktop") })?.makeKeyAndOrderFront(nil)
    }
    @objc private func settings() { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func quit() { NSApp.terminate(nil) }
}

struct DesktopPreferences: View {
    @ObservedObject private var desktop = DesktopIntegration.shared
    var body: some View {
        Section(desktop.text("语言", "Language")) {
            Picker(desktop.text("与 DSH 同步", "Sync with DSH"), selection: Binding(get: { desktop.language }, set: { desktop.setLanguage($0) })) {
                Text("中文").tag("zh")
                Text("English").tag("en")
            }
            if let error = desktop.syncError { Text(error).foregroundStyle(.red) }
        }
        Section(desktop.text("通知", "Notifications")) {
            Picker(desktop.text("回合完成通知", "Turn completion notifications"), selection: $desktop.completionMode) {
                Text(desktop.text("从不", "Never")).tag("never")
                Text(desktop.text("仅在失焦时", "Only when unfocused")).tag("unfocused")
                Text(desktop.text("始终", "Always")).tag("always")
            }
            Text(desktop.text("设置 DSH 完成回答后何时提醒你", "Set when DSH alerts you that it has finished")).font(.caption).foregroundStyle(.secondary)
            Toggle(desktop.text("启用权限通知", "Enable permission notifications"), isOn: $desktop.permissionNotifications)
            Text(desktop.text("需要授权时提醒", "Show alerts when permission is required")).font(.caption).foregroundStyle(.secondary)
            Toggle(desktop.text("启用提问通知", "Enable question notifications"), isOn: $desktop.questionNotifications)
            Text(desktop.text("需要你的回答才能继续时提醒", "Show alerts when input is needed to continue")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
