import SwiftUI
import AppKit
import UserNotifications

// MARK: - 菜单栏数据模型（rev1.7.2 SwiftUI 数据驱动路线）
//
// 菜单全部由 SwiftUI .commands 声明式承载。AppKit 全量装配路线已被证伪：
// SwiftUI 即使无 .commands 仍对 mainMenu 做重协调修剪外来项（切换主题必触发，
// menu-lab Exp1b 实证），故菜单所有权归还 SwiftUI，本模型只承载「槽位」数据。
//
// 机制背书（/tmp/menu-lab 实验产物 + 真机实测）：
// - 槽位 CommandMenu（if groups.count > index 结构化声明）：出现/消失/标题热切换
//   可靠；内容切换会冻结，靠「脉冲」（deactivate + activate + makeKey）解冻（Exp5 T5/T6）
// - 空体腾空 CommandGroup(replacing: .newItem/.undoRedo/.pasteboard)：从启动无条件
//   声明，系统文件/编辑菜单整个消失且抗重协调（LAB4/5 顶级 dump 无系统 File/Edit）
// - 系统显示/窗口/帮助菜单固有项腾不掉（Exp5 T7 回填实证），不尝试腾空
// - role 项等价重建走 NSApp.sendAction 响应链（Exp2b 剪贴板端到端实证）
// - 【真机偏差修正】同名 CommandMenu 并入「活的」系统菜单不成立（Exp2 T13 的
//   [Edit] 实为腾空后的独立槽位，非合并；真机 DSH 实测显示/帮助出现重复菜单）——
//   与在场系统菜单同名的主题组改走 CommandGroup placement 并入（显示→before:.toolbar、
//   帮助→before:.help，主题项在上），与 Exp2 的真实合并机制一致

/// 菜单项规格（声明式纯数据）
struct MenuItemSpec {
    var label: String = ""
    var separator = false
    /// 响应链 selector（系统 role 语义等价重建：关闭窗口/剪切/拷贝/粘贴等）
    var selector: Selector? = nil
    /// 快捷键主键（须单字符；nil = 无快捷键）
    var key: Character? = nil
    var modifiers: EventModifiers = []
    /// 主题命令 id（协议 §5-5 下行通道）：点击 → ThemeCoordinator.dispatchMenuCommand
    var dispatchId: String? = nil
}

/// 菜单组规格（槽位 = CommandMenu；合并组 = 系统 menu 内的 placement 组）
struct MenuGroupSpec {
    var title: String
    var items: [MenuItemSpec]
}

/// 槽位数据源：官方态 = 内置官方组（文件/编辑；显示/窗口/帮助不占槽 = 系统原生），
/// 主题态 = manifest.menus 转换（由 ThemeCoordinator 两拍切换驱动写入）
@MainActor
final class MenuBarModel: ObservableObject {
    static let shared = MenuBarModel()

    /// 槽位组（官方态/主题态统一承载；切空数组 = 结构销毁，下一拍装新组）
    @Published var groups: [MenuGroupSpec] = MenuBarModel.officialGroups
    /// 同名合并组（键 = 规范化角色 "view"/"help"）：经 placement 并入系统菜单
    @Published var mergedGroups: [String: MenuGroupSpec] = [:]
    /// 兜底重渲染戳：脉冲前的强制 objectWillChange 一次（menu-lab Exp5 tag 兜底）
    @Published var renderTag = 0

    /// 官方态内置组：文件（关闭窗口 ⌘W）+ 编辑（撤销/重做/剪切/拷贝/粘贴/全选，
    /// 全部 role 项经响应链重建）。显示/窗口/帮助官方态不占槽 = 系统原生。
    static let officialGroups: [MenuGroupSpec] = [
        MenuGroupSpec(title: "文件", items: [
            MenuItemSpec(label: "关闭窗口",
                         selector: #selector(NSWindow.performClose(_:)),
                         key: "w", modifiers: .command),
        ]),
        MenuGroupSpec(title: "编辑", items: [
            MenuItemSpec(label: "撤销", selector: Selector(("undo:")), key: "z", modifiers: .command),
            MenuItemSpec(label: "重做", selector: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]),
            MenuItemSpec(separator: true),
            MenuItemSpec(label: "剪切", selector: Selector(("cut:")), key: "x", modifiers: .command),
            MenuItemSpec(label: "拷贝", selector: Selector(("copy:")), key: "c", modifiers: .command),
            MenuItemSpec(label: "粘贴", selector: Selector(("paste:")), key: "v", modifiers: .command),
            MenuItemSpec(label: "全选", selector: Selector(("selectAll:")), key: "a", modifiers: .command),
        ]),
    ]

    /// 在场系统菜单快照（去重判定的数据源）。必须在清空槽位**之前**取：
    /// 清空会触发 SwiftUI 重协调把系统菜单临时腾空（首轮真机实证：装配中途
    /// 读到 0 项，语义去重失灵），稳定态快照才含系统固有项。
    struct SystemMenuSnapshot {
        let title: String
        let labels: Set<String>
        let roles: Set<String>
    }

    static func systemMenuSnapshot() -> [SystemMenuSnapshot] {
        var menus: [SystemMenuSnapshot] = []
        for item in NSApp.mainMenu?.items ?? [] {
            guard let sub = item.submenu else { continue }
            menus.append(SystemMenuSnapshot(
                title: item.title,
                labels: Set(sub.items.map(\.title)),
                roles: Set(sub.items.compactMap { canonicalItemRole($0.title) })
            ))
        }
        return menus
    }

    /// 主题 manifest.menus → 槽位组 + 同名合并组（rev1.7.2 合并语义落地）：
    /// - 窗口角色组一律不建槽位（安全阀：整组让位系统窗口菜单原生形态）
    /// - 「通用」宿主保留名恒忽略
    /// - 显示（view）/帮助（help）角色组：同名 CommandMenu 并不并入活的系统菜单
    ///   （真机实测产生重复菜单）→ 走 CommandGroup placement 并入系统菜单位置
    ///   （置于系统功能区之前），并剔除与系统固有项语义重合的声明项，防同菜单双份
    /// - 文件/编辑角色组走槽位（宿主从启动即空体腾空系统文件/编辑菜单，槽位是唯一
    ///   承载）：声明项做 role 项级语义匹配改挂系统 selector，缺席的系统标准项补齐
    ///   重建；主题未声明 file/edit 组时回装宿主默认组（协议 §5-1/§5-3 降级兜底）
    /// 系统菜单本地化标题/固有项以 systemMenus 快照实测为准，不写死（随系统语言变化）。
    /// previousLabels = 上一态由本模型装出去的主题项标签：快照抓在重协调中途时
    /// 系统菜单里还残留着这些项（真机实证），不扣除会把主题自己的声明项误去重掉。
    static func themeSpecs(from manifest: ThemeManifest?,
                           systemMenus: [SystemMenuSnapshot],
                           previousLabels: Set<String> = []) -> (slots: [MenuGroupSpec], merged: [String: MenuGroupSpec]) {
        var slots: [MenuGroupSpec] = []
        var merged: [String: MenuGroupSpec] = [:]
        var coveredSlotRoles = Set<String>()
        if manifest == nil {
            Log.warn("manifest 不可用（缺 menus 声明或磁盘读取失败）：文件/编辑将回装宿主默认组（协议 §5-1/§5-3 降级）")
        }
        for group in manifest?.menus ?? [] {
            guard let title = group.title, !title.isEmpty, !group.items.isEmpty else { continue }
            let role = ThemeCoordinator.canonicalMenuRole(title)
            if role == "host-reserved" {
                Log.info("菜单装配：主题父级「\(title)」撞宿主保留菜单名「通用」，忽略（宿主主权面，rev1.7.2）")
                continue
            }
            if role == "window" {
                Log.info("安全阀：窗口组「\(title)」整组并入系统窗口菜单（系统窗口菜单固有项腾不掉，"
                         + "宿主不重复承载），不建槽位、用系统窗口菜单原生形态")
                continue
            }
            if role == "view" || role == "help" {
                // 快照里该标题的系统菜单可能因重协调中途被腾空（读不到固有项），
                // 此时按系统不变量兜底：系统显示菜单恒含「进入全屏幕」类固有项；
                // 残留的上一态主题项不算系统固有项（previousLabels 扣除）
                let host = systemMenus.first(where: { $0.title == title })
                let hostLabels = (host?.labels ?? []).subtracting(previousLabels)
                let hostRoles = Set(hostLabels.compactMap { canonicalItemRole($0) })
                let fallbackRoles: Set<String> = hostLabels.isEmpty && role == "view" ? ["fullscreen"] : []
                let spec = convertedGroup(
                    group,
                    dedupAgainst: (title: title, labels: hostLabels, roles: hostRoles.union(fallbackRoles))
                )
                if let spec {
                    if merged[role!] != nil {
                        Log.info("菜单合并：主题父级「\(title)」与既有 \(role!) 合并组同名同角色，后者覆盖")
                    }
                    merged[role!] = spec
                    Log.info("菜单合并：主题父级「\(title)」经 placement 并入系统「\(title)」菜单位置"
                             + "（置于系统功能区之前，\(spec.items.count) 项，rev1.7.2）")
                } else {
                    Log.info("菜单合并：主题父级「\(title)」声明项全部与系统固有项重合，系统菜单原生形态整体承担")
                }
                continue
            }
            // file/edit/自定义角色 → 槽位承载（file/edit 组做 role 项级语义重建）
            guard let spec = convertedGroup(group, dedupAgainst: nil, slotRole: role) else { continue }
            if slots.count >= slotCapacity {
                Log.warn("菜单装配：主题父级「\(title)」为第 \(slots.count + 1) 组，"
                         + "超出槽位上限（\(slotCapacity)）未挂载")
                continue
            }
            slots.append(spec)
            if let role { coveredSlotRoles.insert(role) }
        }
        // 降级兜底：主题未声明 file/edit 角色组时回装宿主默认组——系统原件已被空体
        // 腾空、槽位是文件/编辑的唯一承载，缺失即违反协议 §5-1「保持宿主默认」/§5-3
        for official in officialGroups {
            guard let role = ThemeCoordinator.canonicalMenuRole(official.title),
                  !coveredSlotRoles.contains(role) else { continue }
            if slots.count >= slotCapacity {
                Log.error("主题未声明文件/编辑组且回装失败：槽位已被主题组占满（\(slotCapacity)），"
                          + "无法回装宿主默认组（协议 §5-1 承载上限冲突）")
                continue
            }
            slots.append(official)
            Log.warn("菜单装配：主题未声明\(official.title)组，回装宿主默认组（协议 §5-1/§5-3 降级兜底）")
        }
        // 快捷键冲突巡检（槽位 + 合并组全局查重；只 WARN 不阻断，系统按菜单焦点优先响应）
        var combos: [String: [String]] = [:]
        for group in slots + Array(merged.values) {
            for item in group.items {
                guard let key = item.key else { continue }
                let name = shortcutDescription(key: key, modifiers: item.modifiers)
                combos[name, default: []].append("「\(group.title)/\(item.label)」")
            }
        }
        for (name, labels) in combos.sorted(by: { $0.key < $1.key }) where labels.count > 1 {
            Log.warn("快捷键冲突巡检：\(labels.joined(separator: " / ")) 共用 \(name)（不阻断，按菜单焦点响应）")
        }
        return (slots, merged)
    }

    /// 槽位容量（.commands 第二段 MenuSlot 数量；超出组 WARN 留痕不挂载）
    static let slotCapacity = 6

    /// 系统 role 项等价重建表（file/edit 槽位专用）：主题声明项命中 role → 改挂
    /// 系统 selector 与标准快捷键（§5-1 合并条款：role 项系统语义与快捷键原样保留）
    static let roleRebuildTable: [String: (label: String, selector: Selector, key: Character?, modifiers: EventModifiers)] = [
        "close":      (label: "关闭窗口", selector: #selector(NSWindow.performClose(_:)), key: "w", modifiers: .command),
        "undo":       (label: "撤销", selector: Selector(("undo:")), key: "z", modifiers: .command),
        "redo":       (label: "重做", selector: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]),
        "cut":        (label: "剪切", selector: Selector(("cut:")), key: "x", modifiers: .command),
        "copy":       (label: "拷贝", selector: Selector(("copy:")), key: "c", modifiers: .command),
        "paste":      (label: "粘贴", selector: Selector(("paste:")), key: "v", modifiers: .command),
        "select-all": (label: "全选", selector: Selector(("selectAll:")), key: "a", modifiers: .command),
    ]
    /// file/edit 组的系统标准 role 集（补齐判定用，顺序即呈现顺序）
    private static let standardRolesBySlotRole: [String: [String]] = [
        "file": ["close"],
        "edit": ["undo", "redo", "cut", "copy", "paste", "select-all"],
    ]

    /// 快捷键组合描述（冲突巡检日志用）
    static func shortcutDescription(key: Character, modifiers: EventModifiers) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + String(key).uppercased()
    }

    /// 单组转换（快捷键/命令 id/分隔线）；dedup 非 nil 时剔除与该系统菜单固有项
    /// 语义重合的声明项；slotRole 为 file/edit 时做 role 项级语义重建与标准项补齐；
    /// 转换后无有效项返回 nil
    private static func convertedGroup(_ group: ThemeManifest.MenuGroup,
                                       dedupAgainst host: (title: String, labels: Set<String>, roles: Set<String>)?,
                                       slotRole: String? = nil) -> MenuGroupSpec? {
        guard let title = group.title, !title.isEmpty else { return nil }
        let rebuildRoles = slotRole.flatMap { standardRolesBySlotRole[$0] }
        var items: [MenuItemSpec] = []
        var coveredRoles = Set<String>()
        for item in group.items {
            if item.separator == true {
                items.append(MenuItemSpec(separator: true))
                continue
            }
            guard let label = item.title, !label.isEmpty else { continue }
            if let host, host.labels.contains(label) {
                Log.info("同名合并去重：「\(host.title)」声明项「\(label)」与系统固有项同名，不重建（由系统项承担）")
                continue
            }
            if let host, let itemRole = canonicalItemRole(label), host.roles.contains(itemRole) {
                Log.info("同名合并去重：「\(host.title)」声明项「\(label)」与系统固有项语义重合（\(itemRole)），不重建")
                continue
            }
            var spec = MenuItemSpec(label: label, dispatchId: item.id ?? "")
            if let sc = ThemeCoordinator.parseShortcut(item.shortcut) {
                if sc.key.count == 1 {
                    spec.key = Character(sc.key)
                    spec.modifiers = eventModifiers(from: sc.mask)
                } else {
                    Log.info("快捷键「\(item.shortcut ?? "")」（项「\(label)」）非单字符键，忽略快捷键渲染")
                }
            }
            // P1-2：file/edit 槽位声明项命中系统 role → 改挂系统语义（不再派发主题页）；
            // 主题自带快捷键时保留主题快捷键，缺省补系统标准快捷键
            if let rebuildRoles, let itemRole = canonicalItemRole(label), let rebuild = roleRebuildTable[itemRole] {
                spec.selector = rebuild.selector
                spec.dispatchId = nil
                if spec.key == nil, let key = rebuild.key {
                    spec.key = key
                    spec.modifiers = rebuild.modifiers
                }
                coveredRoles.insert(itemRole)
                Log.info("role 项等价重建：「\(title)」声明项「\(label)」同名 role 项已改挂系统语义"
                         + "（\(itemRole)，系统剪贴板/编辑语义与快捷键原样保留），不再派发主题页")
            }
            items.append(spec)
        }
        // P1-2 补齐：主题未声明的系统标准 role 项，分隔线后按宿主默认补齐重建
        if let rebuildRoles {
            let missing = rebuildRoles.filter { !coveredRoles.contains($0) }
            if !missing.isEmpty {
                items.append(MenuItemSpec(separator: true))
                for role in missing {
                    guard let rebuild = roleRebuildTable[role] else { continue }
                    items.append(MenuItemSpec(label: rebuild.label, selector: rebuild.selector,
                                              key: rebuild.key, modifiers: rebuild.modifiers))
                }
                Log.info("role 项等价重建：「\(title)」未声明的系统标准项（"
                         + missing.map { roleRebuildTable[$0]?.label ?? $0 }.joined(separator: " / ")
                         + "）已按宿主默认补齐（分隔线后）")
            }
        }
        while items.first?.separator == true { items.removeFirst() }
        while items.last?.separator == true { items.removeLast() }
        if items.isEmpty { return nil }
        return MenuGroupSpec(title: title, items: items)
    }

    /// 系统固有项规范化角色（中英别名同判）：同名合并组内剔除与系统项语义重合的
    /// 声明项用（最小化/缩放/全屏/拷贝等），与组级 canonicalMenuRole 配套
    static func canonicalItemRole(_ label: String) -> String? {
        switch label.lowercased() {
        case "minimize", "最小化": return "minimize"
        case "zoom", "缩放": return "zoom"
        case "enter full screen", "toggle full screen", "exit full screen", "full screen",
             "进入全屏幕", "切换全屏", "退出全屏幕", "全屏": return "fullscreen"
        case "bring all to front", "全部置前": return "bring-all-to-front"
        case "close", "关闭", "关闭窗口": return "close"
        case "cut", "剪切": return "cut"
        case "copy", "拷贝", "复制": return "copy"
        case "paste", "粘贴": return "paste"
        case "select all", "全选": return "select-all"
        case "undo", "撤销": return "undo"
        case "redo", "重做": return "redo"
        default: return nil
        }
    }

    /// NSEvent.ModifierFlags（ThemeCoordinator.parseShortcut 产物）→ SwiftUI EventModifiers
    static func eventModifiers(from mask: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if mask.contains(.command) { m.insert(.command) }
        if mask.contains(.option) { m.insert(.option) }
        if mask.contains(.shift) { m.insert(.shift) }
        if mask.contains(.control) { m.insert(.control) }
        return m
    }
}

// MARK: - 槽位渲染（结构化声明：if groups.count > index 包裹，出现/消失可靠）

/// 第 index 个槽位 CommandMenu（官方态/主题态统一承载）
struct MenuSlot: Commands {
    let index: Int
    @ObservedObject private var model = MenuBarModel.shared
    @ObservedObject private var desktop = DesktopIntegration.shared

    var body: some Commands {
        if model.groups.count > index, !["文件", "File", "显示", "View", "通用", "General"].contains(model.groups[index].title) {
            CommandMenu(desktop.localized(model.groups[index].title)) {
                ForEach(Array(model.groups[index].items.enumerated()), id: \.offset) { _, item in
                    MenuSlotItem(item: item, menuTitle: model.groups[index].title)
                }
                if ["编辑", "Edit"].contains(model.groups[index].title) {
                    Divider()
                    Button(desktop.text("查找…", "Find…")) { desktop.find() }
                        .keyboardShortcut("f", modifiers: .control)
                    Button(desktop.text("放大", "Zoom In")) { desktop.changeZoom(0.1) }
                        .keyboardShortcut("+", modifiers: .command)
                    Button(desktop.text("缩小", "Zoom Out")) { desktop.changeZoom(-0.1) }
                        .keyboardShortcut("-", modifiers: .command)
                    Button(desktop.text("实际大小", "Actual Size")) { desktop.changeZoom(1 - desktop.zoom) }
                        .keyboardShortcut("0", modifiers: .command)
                }
            }
        }
    }
}

/// 槽位项：分隔线 / role 项（响应链等价重建）/ 主题命令项（下行派发）
struct MenuSlotItem: View {
    @ObservedObject private var desktop = DesktopIntegration.shared
    let item: MenuItemSpec
    let menuTitle: String

    var body: some View {
        if item.separator {
            Divider()
        } else if let key = item.key {
            Button(desktop.localized(item.label)) { fire() }
                .keyboardShortcut(KeyEquivalent(key), modifiers: item.modifiers)
        } else {
            Button(desktop.localized(item.label)) { fire() }
        }
    }

    private func fire() {
        if let selector = item.selector {
            // 响应链留痕：sendAction 返回是否被响应者受理（role 项系统语义生效证据）
            let handled = NSApp.sendAction(selector, to: nil, from: nil)
            Log.info("菜单 role 项响应链：「\(menuTitle)/\(item.label)」\(selector)"
                     + (handled ? " 已由响应链受理" : " 无响应者受理"))
        } else if let id = item.dispatchId, !id.isEmpty {
            ThemeCoordinator.shared.dispatchMenuCommand(menu: menuTitle, id: id)
        }
    }
}

/// 同名合并组渲染（rev1.7.2 合并语义）：主题组经 placement 并入系统菜单位置，
/// 主题项在上——显示（view 角色）→ 系统显示菜单顶部（before:.toolbar）；
/// 帮助（help 角色）→ 系统帮助菜单顶部（before:.help）。
/// 【真机偏差修正】同名 CommandMenu 并不并入活的系统菜单（真机实测产生重复菜单），
/// Exp2 T13 的「合并」实为 placement 机制，此处按其真实机制落地。
struct MergedMenuCommands: Commands {
    @ObservedObject private var model = MenuBarModel.shared

    var body: some Commands {
        if let group = model.mergedGroups["view"] {
            CommandGroup(before: .toolbar) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    MenuSlotItem(item: item, menuTitle: group.title)
                }
            }
        }
        if let group = model.mergedGroups["help"] {
            CommandGroup(before: .help) {
                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                    MenuSlotItem(item: item, menuTitle: group.title)
                }
            }
        }
    }
}

// MARK: - 宿主面菜单（b1727d1 回迁；原 @objc 动作改闭包直调）

/// 「服务器」菜单：动态启停标题随 server.status（serverProcess 是 @Published，
/// attach 完成后菜单自动刷新）
struct ServerMenu: Commands {
    @ObservedObject private var desktop = DesktopIntegration.shared
    @ObservedObject private var server = ServerManager.shared

    var body: some Commands {
        CommandMenu(desktop.text("服务器", "Server")) {
            Button(server.status == .running
                   ? desktop.text("停止服务器", "Stop server")
                   : desktop.text("启动服务器", "Start server")) {
                if server.status == .running {
                    server.stop()
                } else {
                    server.start()
                }
            }
            // starting 中不可再操作；running 但进程不归我们管（attach 的外部实例）
            // 时「停止」是空操作，禁用以免菜单撒谎
            .disabled(server.status == .starting
                      || (server.status == .running && server.serverProcess == nil))

            Divider()

            Button(desktop.text("刷新页面", "Reload page")) { refreshSurface() }
            Button(desktop.text("显示主窗口", "Show main window")) { showMainWindow() }
            Button(desktop.text("在浏览器中打开", "Open in browser")) { NSWorkspace.shared.open(AppState.shared.url) }
            Button(desktop.text("前往开放平台", "Open API platform")) {
                if let url = URL(string: "https://platform.deepseek.com/") { NSWorkspace.shared.open(url) }
            }

            Divider()

            Button(desktop.text("发送测试通知", "Send test notification")) {
                Task { await sendTestNotification() }
            }
        }
    }

    /// 主题态刷新主题页，官方态走既有「刷新页面」通知链
    private func refreshSurface() {
        if case .theme = ThemeCoordinator.shared.activeAppearance {
            ThemeCoordinator.shared.reloadVisible()
        } else {
            NotificationCenter.default.post(name: .dshReloadRequested, object: nil)
        }
    }

    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.title.hasPrefix("DSH Desktop") }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 原生通知（UserNotifications）：归属 DSH Desktop，系统设置 → 通知 里可见可管；
    /// 首次发送时请求授权
    private func sendTestNotification() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = "DSH Desktop"
        content.body = desktop.text("原生通知通道正常", "Native notifications are working")
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        ))
    }
}

/// 宿主保留菜单「通用」（主题插件协议 §5 rev1.7/1.7.1，B3 拍板形态）：
/// 切换到默认主题 + 已装主题列表 + repository 派生四出口（关于/检查更新/发送反馈/
/// 帮助中心；OWNER/ 占位仓址不出入口）
struct GeneralThemeMenu: View {
    @ObservedObject private var appState = AppState.shared

    private var selectableThemes: [ThemeInfo] {
        appState.themes.filter {
            $0.id != "official" && !$0.incompatible
                && ($0.state == "enabled" || $0.state == "installed")
        }
    }

    var body: some View {
        Button("切换到默认主题") {
            ThemeCoordinator.shared.selectOfficial()
        }
        .disabled(appState.activeThemeID == "official" || !appState.themeSDKAvailable)
        if !selectableThemes.isEmpty {
            Divider()
            ForEach(selectableThemes) { info in
                Button("切换到 \(info.name)") {
                    ThemeCoordinator.shared.select(info.id)
                }
                .disabled(info.active)
            }
        }
        if let repo = appState.activeThemeRepository, !repo.isEmpty, !repo.hasPrefix("OWNER/"),
           let name = appState.activeThemeName {
            Divider()
            Button("关于 \(name)") { ThemeCoordinator.shared.openRepoPage(repo, "/releases") }
            Button("检查更新（\(name)）") { ThemeCoordinator.shared.openRepoPage(repo, "/releases") }
            Button("发送反馈") { ThemeCoordinator.shared.openRepoPage(repo, "/issues/new/choose") }
            Button("帮助中心") { ThemeCoordinator.shared.openRepoPage(repo, "/wiki") }
        }
    }
}
