import Foundation

// MARK: - 数据模型（协议 §4 接口面）

struct ThemeInfo: Identifiable {
    let id: String
    let name: String
    let version: String?
    let state: String?
    let active: Bool
    let incompatible: Bool
}

extension ThemeInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, version, state, active, incompatible
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "unknown"
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        version = try? c.decode(String.self, forKey: .version)
        state = try? c.decode(String.self, forKey: .state)
        active = (try? c.decode(Bool.self, forKey: .active)) ?? false
        incompatible = (try? c.decode(Bool.self, forKey: .incompatible)) ?? false
    }
}

struct BootInfo: Decodable {
    let active: String?
    let iconVersion: String?

    private enum CodingKeys: String, CodingKey { case active, iconVersion }

    init(active: String?, iconVersion: String?) {
        self.active = active
        self.iconVersion = iconVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try? c.decode(String.self, forKey: .active)
        iconVersion = try? c.decode(String.self, forKey: .iconVersion)
    }
}

/// theme.json manifest（宿主只消费 entry/icons/menus 等少量字段）
struct ThemeManifest: Decodable {
    /// rev 1.7 菜单声明（声明式纯数据，命令语义由主题页自定义）
    struct MenuGroup: Decodable {
        struct Item: Decodable {
            let id: String?
            let title: String?
            let shortcut: String?
            let separator: Bool?

            private enum CodingKeys: String, CodingKey { case id, title, shortcut, separator }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decode(String.self, forKey: .id)
                title = try? c.decode(String.self, forKey: .title)
                shortcut = try? c.decode(String.self, forKey: .shortcut)
                separator = try? c.decode(Bool.self, forKey: .separator)
            }
        }

        let title: String?
        let items: [Item]

        private enum CodingKeys: String, CodingKey { case title, items }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decode(String.self, forKey: .title)
            items = (try? c.decode([Item].self, forKey: .items)) ?? []
        }
    }

    struct DockIcons: Decodable {
        let light: String?
        let dark: String?

        private enum CodingKeys: String, CodingKey { case light, dark }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            light = try? c.decode(String.self, forKey: .light)
            dark = try? c.decode(String.self, forKey: .dark)
        }
    }

    struct Entry: Decodable {
        let index: String?
        private enum CodingKeys: String, CodingKey { case index }
        init(from decoder: Decoder) throws {
            index = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .index)
        }
    }

    let id: String?
    let name: String?
    let version: String?
    let entry: Entry?
    let icons: DockIcons?
    let menus: [MenuGroup]?
    let appName: String?
    let repository: String?

    private enum CodingKeys: String, CodingKey { case id, name, version, entry, icons, menus, appName, repository }

    init(id: String?, name: String?, version: String?, entry: Entry?, icons: DockIcons?,
         menus: [MenuGroup]? = nil, appName: String? = nil, repository: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.entry = entry
        self.icons = icons
        self.menus = menus
        self.appName = appName
        self.repository = repository
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(String.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        version = try? c.decode(String.self, forKey: .version)
        entry = try? c.decode(Entry.self, forKey: .entry)
        icons = try? c.decode(DockIcons.self, forKey: .icons)
        menus = try? c.decode([MenuGroup].self, forKey: .menus)
        appName = try? c.decode(String.self, forKey: .appName)
        repository = try? c.decode(String.self, forKey: .repository)
    }
}

/// GET /api-theme/backend 响应（协议 §10.1 后端描述符；壳只消费版本与方言字段）
struct BackendDescriptor: Decodable {
    let dshVersion: String?
    let wireDialect: String?
    let auth: String?

    private enum CodingKeys: String, CodingKey { case dshVersion, wireDialect, auth }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dshVersion = try? c.decode(String.self, forKey: .dshVersion)
        wireDialect = try? c.decode(String.self, forKey: .wireDialect)
        auth = try? c.decode(String.self, forKey: .auth)
    }
}

/// POST /api-theme/preflight 响应内的单主题裁决（协议 §10.4）
struct PreflightVerdict: Decodable {
    let id: String
    let verdict: String?          // "ok" | "auto" | "needs-work"
    let reasons: [String]

    init(id: String, verdict: String?, reasons: [String]) {
        self.id = id
        self.verdict = verdict
        self.reasons = reasons
    }

    private enum CodingKeys: String, CodingKey { case id, verdict, reasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? "unknown"
        verdict = try? c.decode(String.self, forKey: .verdict)
        reasons = (try? c.decode([String].self, forKey: .reasons)) ?? []
    }
}

// MARK: - HTTP 面

enum ThemeAPI {
    enum FetchError: Error, Equatable {
        case notFound                    // /themes 404 → dsh-theme-sdk 未安装
        case unavailable(String)
    }

    private static func request(_ url: URL, method: String = "GET", body: Data? = nil,
                                timeout: TimeInterval = 4) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func status(of response: URLResponse?) -> Int? {
        (response as? HTTPURLResponse)?.statusCode
    }

    /// GET /themes → 200 {themes:[…]}；404 = sdk 未装
    static func fetchThemes(base: URL) async -> Result<[ThemeInfo], FetchError> {
        guard let url = URL(string: base.absoluteString + "/themes") else {
            return .failure(.unavailable("URL 非法"))
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            switch status(of: response) {
            case 200:
                struct Envelope: Decodable { let themes: [ThemeInfo]? }
                let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
                return .success(envelope?.themes ?? [])
            case 404:
                return .failure(.notFound)
            case let code?:
                return .failure(.unavailable("HTTP \(code)"))
            default:
                return .failure(.unavailable("无状态码"))
            }
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    enum SelectError: Error {
        case http(Int)
        case transport
    }

    /// POST /api-theme/select {id} → 200 {id}；404 未装 / 403 禁用 / 409 不兼容
    static func selectTheme(base: URL, id: String) async -> Result<Void, SelectError> {
        guard let url = URL(string: base.absoluteString + "/api-theme/select") else {
            return .failure(.transport)
        }
        let payload = try? JSONSerialization.data(withJSONObject: ["id": id])
        do {
            let (_, response) = try await URLSession.shared.data(
                for: request(url, method: "POST", body: payload))
            if status(of: response) == 200 { return .success(()) }
            return .failure(.http(status(of: response) ?? -1))
        } catch {
            return .failure(.transport)
        }
    }

    /// boot-info 轮询结果（R2-SHELL 可观测性：失败必须带状态码/原因供 WARN 去重）
    enum BootInfoOutcome {
        case ok(BootInfo)
        case http(Int)              // 非 200（404=SDK 未装等）
        case transport(String)      // 网络不可达 / 无状态码
        case badPayload(String)     // 200 但响应不可解码
    }

    /// GET /api-theme/boot-info {active, iconVersion}
    static func fetchBootInfo(base: URL) async -> BootInfoOutcome {
        guard let url = URL(string: base.absoluteString + "/api-theme/boot-info") else {
            return .transport("URL 非法")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request(url))
            guard let code = status(of: response) else { return .transport("无状态码") }
            guard code == 200 else { return .http(code) }
            guard let info = try? JSONDecoder().decode(BootInfo.self, from: data) else {
                return .badPayload("200 但响应不可解码（\(data.prefix(80))）")
            }
            return .ok(info)
        } catch {
            return .transport(error.localizedDescription)
        }
    }

    /// GET /themes/<id>/theme.json（静态根 = 主题包根）
    static func fetchManifest(base: URL, id: String) async -> ThemeManifest? {
        guard let url = URL(string: "\(base.absoluteString)/themes/\(id)/theme.json") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              status(of: response) == 200 else { return nil }
        return try? JSONDecoder().decode(ThemeManifest.self, from: data)
    }

    /// 取主题静态资产（如 dock 图标 png）
    static func fetchData(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request(url, timeout: 10)),
              status(of: response) == 200 else { return nil }
        return data
    }

    /// GET /api-theme/backend → 后端描述符（§10.1；更新检查取 dshVersion 用）
    static func fetchBackendDescriptor(base: URL) async -> BackendDescriptor? {
        guard let url = URL(string: base.absoluteString + "/api-theme/backend") else { return nil }
        guard let (data, response) = try? await URLSession.shared.data(for: request(url)),
              status(of: response) == 200 else { return nil }
        return try? JSONDecoder().decode(BackendDescriptor.self, from: data)
    }

    /// POST /api-theme/preflight {toVersion} → 200 {themes:[{id,verdict,reasons}]}（§10.1/§10.4）
    static func preflight(base: URL, toVersion: String) async -> Result<[PreflightVerdict], FetchError> {
        guard let url = URL(string: base.absoluteString + "/api-theme/preflight") else {
            return .failure(.unavailable("URL 非法"))
        }
        let payload = try? JSONSerialization.data(withJSONObject: ["toVersion": toVersion])
        do {
            let (data, response) = try await URLSession.shared.data(
                for: request(url, method: "POST", body: payload, timeout: 10))
            switch status(of: response) {
            case 200:
                struct Envelope: Decodable { let themes: [PreflightVerdict]? }
                let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
                return .success(envelope?.themes ?? [])
            case 404:
                return .failure(.notFound)      // dsh-theme-sdk 未装
            case let code?:
                return .failure(.unavailable("HTTP \(code)"))
            default:
                return .failure(.unavailable("无状态码"))
            }
        } catch {
            return .failure(.unavailable(error.localizedDescription))
        }
    }

    /// §6-2 握手回执试探：POST /api-theme/report-handshake（payload 对齐 SDK HandshakeReport）。
    /// 当前 dsh-theme-sdk 未暴露该 HTTP 路由（routes 仅 /themes 与 /api-theme/{select,
    /// boot-info,backend,preflight}；reportHandshake 只经主题侧 ctx.themeSdk 可达），
    /// 真机实测：未注册 POST 路径 dsh 网关回 405（404 语义等同）——壳以 404/405
    /// 判定「无回执路由」并降级为日志记录（返回状态码供调用方裁决）。
    static func reportHandshake(base: URL, handshake: ThemeHandshake) async -> Int {
        guard let url = URL(string: base.absoluteString + "/api-theme/report-handshake") else { return -1 }
        var payload: [String: Any] = ["type": "theme:ready"]
        payload["id"] = handshake.id ?? "unknown"
        if let v = handshake.version { payload["version"] = v }
        if let v = handshake.clientVersion { payload["clientVersion"] = v }
        if let v = handshake.adapter { payload["adapter"] = v }
        if let v = handshake.compat { payload["compat"] = v }
        if let v = handshake.compatReason { payload["compatReason"] = v }
        let body = try? JSONSerialization.data(withJSONObject: payload)
        do {
            let (_, response) = try await URLSession.shared.data(
                for: request(url, method: "POST", body: body, timeout: 4))
            return status(of: response) ?? -1
        } catch {
            return -1
        }
    }
}
