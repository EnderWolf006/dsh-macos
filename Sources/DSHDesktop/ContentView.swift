import SwiftUI

/// 主窗口内容：服务器未就绪时显示状态面板，就绪后内嵌 Web GUI
struct ContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var server: ServerManager

    var body: some View {
        // running ⇄ 连接中断 之间切换时不能重建 WebView（会丢掉 SPA 里的
        // 会话位置），因此用一个布尔统一决定 WebView 分支的身份；断连提示
        // 作为覆盖层挂在上面，而不是把分支换回状态面板。
        let disconnected: String? = {
            if case .error(let message) = server.status, appState.pageLoaded {
                return message
            }
            return nil
        }()
        let showWeb = server.status == .running || disconnected != nil

        // alignment: .top 让断连横幅锚定窗口顶部（拖拽带下方），而不是
        // 随 ZStack 默认对齐悬浮在中央；WebView/面板自身撑满，不受影响
        ZStack(alignment: .top) {
            if showWeb {
                // authURL：后端打印的一次性 token 链接（旧版后端为 nil，
                // 走裸 URL 首载，行为不变）。消费即清空，防止 token 复用。
                HarnessWebView(
                    url: appState.url,
                    authURL: appState.authLaunchURL,
                    onAuthConsumed: { appState.authLaunchURL = nil }
                ) { state in
                    switch state {
                    case .loaded:
                        if !appState.pageLoaded { appState.pageLoaded = true }
                    case .failed:
                        // 幂等：仅在值变化时赋值，避免触发无意义的重渲染
                        if appState.pageLoaded { appState.pageLoaded = false }
                    }
                }
            } else {
                StatusPanel(
                    status: server.status,
                    onStart: { server.start() },
                    spinner: server.status == .starting || server.status == .unknown
                )
            }
            // 主题池容器层（主题插件协议 §5）：叠在官方 WebView 之上，主题实例由
            // ThemeCoordinator 加进/移出该容器；official 态整层隐藏（不挡官方交互），
            // 官方 WebView 的 SwiftUI 生命周期原样不动（禁止 re-parent）。状态面板
            // 在屏时该层自动让位（surfaceAvailable=false）。
            ThemePoolHost(surfaceAvailable: showWeb)
            if let disconnected {
                DisconnectBanner(message: disconnected)
            }
        }
        .frame(minWidth: 600, minHeight: 360)
        // 顶到顶：会话顶部栏需要覆盖透明拖拽行；侧栏单独由 desktop-layout.js
        // 预留标题行，不把整个会话区整体下推。
        .ignoresSafeArea()
        // 顶到顶：内容忽略 safe area（否则 SwiftUI 会把 WebView 从标题栏下方排布，
        // 顶部露出窗口背景色横条）
        .onAppear {
            bootstrap()
        }
    }

    /// 启动时：attach 已有实例 → 按设置自动启动 → 启动桥接轮询
    private func bootstrap() {
        Task {
            await server.attach()
            if appState.autoStartServer && !server.status.isActive {
                server.start()
            }
            BridgeClient.shared.start(appState: appState, server: server)
        }
    }
}

/// 断连横幅：本地回环的瞬时抖动由轮询自动恢复，横幅随之消失；
/// 不接收点击（allowsHitTesting 关闭），避免挡住顶部拖拽带与官方控件
struct DisconnectBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("与服务器的连接中断（\(message)）· 正在自动重试；恢复后此提示自动消失，也可用菜单“刷新页面”")
                .font(.callout)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        // DesktopLayout.dragStripHeight = 46，再留 8pt 间距，避让透明拖拽带
        .padding(.top, 54)
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
    }
}

/// 服务器未运行时的状态面板
struct StatusPanel: View {
    let status: ServerStatus
    let onStart: () -> Void
    let spinner: Bool

    var body: some View {
        VStack(spacing: 14) {
            if spinner {
                ProgressView()
                    .controlSize(.small)
            }
            Image(systemName: "server.rack")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("DeepSeek Harness 服务器")
                .font(.title2)
                .fontWeight(.semibold)
            Text(status.label)
                .foregroundStyle(.secondary)
            if case .starting = status {
                Text("正在冷启动 DSH 服务器（首次约需数秒）…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if case .error = status {
                Text("请检查启动命令与端口设置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button(action: onStart) {
                Label("启动服务器", systemImage: "play.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(status == .starting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
