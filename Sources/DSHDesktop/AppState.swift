import Foundation
import Combine

/// Token 用量统计（对齐 DSH 官方 StatsLine 口径，见 client-ui-conversation）

/// DSH 服务器状态
enum ServerStatus: Equatable {
    case unknown
    case stopped
    case starting
    case running
    case error(String)

    var label: String {
        switch self {
        case .unknown: return "检测中…"
        case .stopped: return "已停止"
        case .starting: return "启动中…"
        case .running: return "运行中"
        case .error(let message): return "错误：\(message)"
        }
    }

    var isActive: Bool {
        switch self {
        case .running, .starting: return true
        default: return false
        }
    }
}

/// 全局应用状态：设置 + 页面状态 + 桥接状态
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: ServerStatus = .unknown
    /// 官方页面是否曾成功加载过。断连（.error）时据此保留 WebView 而不是
    /// 换回状态面板——销毁 WebView 会丢掉 SPA 里的会话位置（见 ContentView）
    @Published var pageLoaded: Bool = false
    @Published var bridgeConnected: Bool = false
    /// 桥接明细文案（pid/版本/运行时长）。刻意**不**作为 @Published：
    /// uptime 秒数每次轮询都不同，若走 objectWillChange 会以数秒节奏
    /// 空转整个 App scene（含命令菜单），诱发“窗口菜单打开后原生项被
    /// 渐进裁剪”的系统性问题。明细只在设置页渲染时读取最新值。
    var bridgeDetail: String = ""

    /// 认证链：后端 stdout 捕获的 launch token URL（每进程一次）。
    /// 非空且未被消费时，WebView 首载改用该 URL 完成一次性授权换 Cookie。
    @Published var authLaunchURL: URL?

    // MARK: - 主题面（主题插件协议 v1；字段名为接口契约，供后续设置页 UI 消费，勿改名）
    // 由 ThemeCoordinator 维护，AppState 只做发布态承载

    /// GET /themes 的主题清单（含 official）
    @Published var themes: [ThemeInfo] = []
    /// 当前外观 id（"official" 默认 | 主题 id）
    @Published var activeThemeID: String = "official"
    /// dsh-theme-sdk 是否已装（/themes 路由可达；404 = 未装）
    @Published var themeSDKAvailable: Bool = false
    // 主题活跃仓址/名（rev1.7.1 四出口数据源；ThemeCoordinator 于 confirmSwitch 写入）
    @Published var activeThemeRepository: String?
    @Published var activeThemeName: String?

    // MARK: - 窗口增强（持久化）

    @Published var immersiveTitlebar: Bool = true

    // MARK: - 设置（UserDefaults 持久化）

    /// DSH 后端固定监听端口（不可改，避免误改导致连不上后端）
    static let defaultPort = 3080
    @Published var serverCommand: String
    @Published var autoStartServer: Bool
    @Published var keepServerOnQuit: Bool

    private let defaults = UserDefaults.standard

    private init() {
        serverCommand = defaults.string(forKey: "serverCommand") ?? "dsh --profile web"
        autoStartServer = defaults.object(forKey: "autoStartServer") as? Bool ?? true
        keepServerOnQuit = defaults.object(forKey: "keepServerOnQuit") as? Bool ?? false
        immersiveTitlebar = defaults.object(forKey: "immersiveTitlebar") as? Bool ?? true
    }

    var url: URL {
        return URL(string: "http://127.0.0.1:\(Self.defaultPort)")!
    }

    func saveSettings() {
        defaults.set(serverCommand, forKey: "serverCommand")
        defaults.set(autoStartServer, forKey: "autoStartServer")
        defaults.set(keepServerOnQuit, forKey: "keepServerOnQuit")
        defaults.set(immersiveTitlebar, forKey: "immersiveTitlebar")
    }
}
