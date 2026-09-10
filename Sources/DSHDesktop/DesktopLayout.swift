import AppKit

/// 布局常量：按用户约定的几何规则推导，目标是把红绿灯作为不可变参考系。
///
/// 规则：
/// 1. 红绿灯整体平移，不改按钮相对位置；红灯左上角距离窗口左/上边缘等量。
///    以标准 12×12pt 按钮、8pt 间距推算，中心锚点为 (23, 23)。
/// 2. 折叠侧栏宽度由“红绿灯组中心在侧栏宽度中心”推出：
///    灯组中心 x = 43（红灯中心 23 + 间距 20），故侧栏宽 = 43×2 = 86。
/// 3. 透明拖拽带以红绿灯水平中心线（y=23）为轴，红绿灯在带内垂直居中，
///    故拖拽带行高 = 23×2 = 46。
enum DesktopLayout {
    /// 红绿灯组中心相对窗口左上角的锚点。
    /// 整体移动按钮组时使用；按钮自身的尺寸与间距仍由 AppKit 决定。
    static let trafficLightCenterX: CGFloat = 23
    static let trafficLightCenterY: CGFloat = 23

    /// 标准 macOS 交通灯组几何（用于推导安全区与侧栏宽度）。
    /// 按钮 12×12pt，按钮间间距 8pt；这些尺寸来自 AppKit 实测。
    static let trafficLightButtonSize: CGFloat = 12
    static let trafficLightSpacing: CGFloat = 8

    /// 折叠侧栏视觉总宽：红绿灯组中心 x=43 必须位于侧栏水平中心，
    /// 因此侧栏宽 = 43×2 = 86。官方 56px 轨在其中居中。
    static let sidebarCollapsedWidth: CGFloat = 86
    /// 官方折叠轨宽度（不改官方轨内图标尺寸或 x 值）
    static let sidebarRailWidth: CGFloat = 56

    /// 透明拖拽带行高：以红绿灯水平中心线为轴，红绿灯垂直居中。
    static let dragStripHeight: CGFloat = 46

    /// 左侧安全区：覆盖整个交通灯组最右边界（绿灯右缘 ≈ 69），
    /// 避免透明拖拽带抢走红绿灯点击。
    static let trafficLightSafeWidth: CGFloat = 80

    /// 顶部右侧控件安全区；原生 overlay 没有 Electron 的 no-drag 语义，
    /// 预留这段空间让 Session log 等顶部按钮继续接收点击。
    static let topControlsSafeWidth: CGFloat = 180

    /// 侧栏顶部内容起始偏移：让 logo 行下边界对齐右侧会话顶栏下边界。
    /// 右侧会话顶栏高度约 56px；logo 行高约 24px，故内容从 32px 开始。
    static let sidebarContentTopOffset: CGFloat = 32
}

/// 透明拖拽带：覆盖顶部除系统按钮/右侧控件外的区域，实现原生窗口拖拽。
/// 通过调用 NSWindow.performDrag(with:) 让 AppKit 自己处理移动、贴边、
/// 屏幕边缘吸附；通过检测双击调用 NSWindow.zoom(_:) 实现最大化/恢复。
final class DragStripView: NSView {
    override var isOpaque: Bool { false }

    /// 页面悬停目标是否为可交互元素（WebView 的 hover 探针经 scriptMessageHandler
    /// 回传，主线程读写）。为 true 时拖拽带对自己的 hitTest 返回 nil，点击穿透给
    /// 下方 webview——否则顶部 46pt 带内的页面按钮（0.1.5 侧边栏标签条的
    /// 新建/关闭标签页等）会被拖拽带吞掉鼠标按下，点了没反应。
    nonisolated(unsafe) static var hoverOverInteractive = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if Self.hoverOverInteractive { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            return
        }
        if event.clickCount == 2 {
            // 双击标题栏：最大化 / 恢复（与 macOS 原生行为一致）
            window.zoom(nil)
            return
        }
        // 把拖拽事件交给 AppKit，这样拖动到屏幕边缘会触发贴边（mission-control）
        window.performDrag(with: event)
    }
}
