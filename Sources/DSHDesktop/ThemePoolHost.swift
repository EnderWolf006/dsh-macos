import SwiftUI
import AppKit

// MARK: - 池容器：承载 ≤2 个主题 WebView 实例（协议 §5 全池 ≤3：official 由现有
// HarnessWebView 担任、SwiftUI 持有、永不回收；主题实例至多「活跃 + 预热」两席）

final class ThemeContainerView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 主题是整面替换件：容器自身不透底，避免切换间隙露出下层内容
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// 全尺寸钉住一个实例
    func attach(_ view: NSView) {
        guard view.superview !== self else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// 实例间显隐互换 + 150ms crossfade（协议 §5：切换 <200ms 目标）
    func crossfade(from: NSView?, to: NSView, duration: CFTimeInterval = 0.15) {
        guard from !== to else {
            to.isHidden = false
            to.alphaValue = 1
            return
        }
        to.isHidden = false
        // 目标置顶：重叠期点击落在目标实例上
        addSubview(to, positioned: .above, relativeTo: from)
        to.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            to.animator().alphaValue = 1
            from?.animator().alphaValue = 0
        }, completionHandler: { [to, from] in
            if let from, from !== to { from.isHidden = true }
        })
    }
}

// MARK: - SwiftUI 桥（容器由 ThemeCoordinator 持有，SwiftUI 重建视图身份时迁移池实例，
// 绝不重建 WebView；official 态整层隐藏，露出下方现有官方 WebView）

struct ThemePoolHost: NSViewRepresentable {
    /// 官方 Web 面是否在屏（ContentView 的 showWeb）；false（状态面板在屏）时
    /// 主题容器必须让位，否则会盖住状态面板与「启动服务器」按钮
    var surfaceAvailable: Bool

    func makeNSView(context: Context) -> ThemeContainerView {
        ThemeCoordinator.shared.attachContainer()
    }

    func updateNSView(_ nsView: ThemeContainerView, context: Context) {
        ThemeCoordinator.shared.adoptContainer(nsView)
        ThemeCoordinator.shared.setWebSurfaceAvailable(surfaceAvailable)
    }
}
