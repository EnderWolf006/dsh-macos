import AppKit

// MARK: - 池容器：承载 ≤2 个主题 WebView 实例（协议 §5 全池 ≤3：official 由现有
// HarnessWebView 担任、SwiftUI 持有、永不回收；主题实例至多「活跃 + 预热」两席）
//
// 层级注意：容器不经 SwiftUI 挂载。SwiftUI 窗口的 contentView 即 NSHostingView，
// 其平台子视图（官方 WKWebView 的 PlatformViewHost 等）会随 SwiftUI 重渲染被
// 重排（真机实测：能排到我们直装进 hosting 的覆盖层之上；AppDelegate 拖拽带被
// 晚插入的 WKWebView 盖住是同一族怪癖）。根治：ThemeCoordinator 把 NSHostingView
// 原地包进 WindowShellView（普通 NSView）作为新 contentView，壳内顺序
// [hosting, 主题容器, 拖拽带] 完全由协调器决定，SwiftUI 只动 hosting 内部，
// 永远压不到覆盖层头上。

/// 主窗口 contentView 包壳：SwiftUI 的 NSHostingView 住里面；覆盖层
/// （ThemeContainerView / DragStripView）作为壳的子视图恒在其上。
final class WindowShellView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }
}

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
