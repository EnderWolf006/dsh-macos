import Foundation

// MARK: - 更新说明（Release Notes）拉取与清洗
//
// 更新确认弹窗的数据源：GitHub Release body → 纯文本，按版本降序聚合多版本（新版在上）。
// 设计铁律：notes 只是锦上添花——任何网络/解析失败一律回空，绝不 throw 到
// 调用方，与更新主流程（下载/安装/回滚）零耦合。npm dist-tags 无 changelog，
// 后端 notes 一律走 GitHub releases（tag→release 映射）。

/// 单版本更新说明（version 供区间过滤与排序；tag 原样保留供跳转/对账）
struct ReleaseNotes {
    let version: String      // 剥掉 dsh-v / v 前缀的纯版本号（SemVer 可比较）
    let tag: String          // GitHub 原始 tag，如 dsh-v0.1.2-alpha.2 / v1.0.1
    let title: String?       // release 的 name 字段（常与 tag 近似；缺失为 nil）
    let publishedAt: Date?   // GitHub Release 的 published_at（官方发布时间；异常为 nil）
    let cleanedBody: String  // clean() 清洗后的纯文本；空串 = 官方未提供
}

enum UpdateNotesEngine {
    // 三条更新链路各自的 notes 来源仓库
    static let dshUpstream = "deepseek-ai/deepseek-harness"   // 后端 dsh（tag 带 dsh-v 前缀）
    static let appRepo = "EnderWolf006/dsh-macos"            // 前端应用自身
    static let launcherRepo = "iiiiiei/dsh-launcher"         // 菜单栏伴侣应用

    /// 聚合 (from, to] 区间的所有 release notes，按版本**降序**返回
    /// （新版在上：用户最关心的是目标版改了什么，旧版变更往下看）。
    /// 任何失败 → []，调用方据此显示"官方未提供本次更新说明"。
    static func fetch(repo: String, from: String, to: String) async -> [ReleaseNotes] {
        // 列表端点每页含 tag_name/name/body；dsh 发版节奏下 20 条足以覆盖任意跨度
        guard !repo.isEmpty, !from.isEmpty, !to.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")
        else { return [] }
        guard let notes = await get(url: url, asList: true) else { return [] }
        // 过滤：> from 且 <= to；SemVer 复用 UpdateEngine.swift（同模块无需 import）
        let hit = notes.filter { SemVer.compare(from, $0.version) < 0 && SemVer.compare($0.version, to) <= 0 }
        // 【陷阱】SemVer 对"同号不同预发布号"返回 0（只判是否预发布，不比 prerelease
        // 细号），排序会退化成 GitHub 列表的倒序——相等时用字符串序兜底
        // （alpha.1 < alpha.2 恰为字典序，跨主版本号仍由 SemVer 主导）
        return hit.sorted {
            let c = SemVer.compare($0.version, $1.version)
            return c == 0 ? $0.version > $1.version : c > 0
        }
    }

    /// 单版本便捷入口（releases/tags/{tag} 直查；body 为该 tag 的完整 release）。
    /// 失败 → nil。
    static func fetchOne(repo: String, tag: String) async -> ReleaseNotes? {
        guard !repo.isEmpty, !tag.isEmpty,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")
        else { return nil }
        return await get(url: url, asList: false)?.first
    }

    // MARK: - 清洗（纯函数，无 IO）

    /// Release body → 纯文本。五件事：双语截断 / HTML 剥壳留内文 / 链接降级与
    /// 图片锚点行删除 / 行首装饰还原 / 空行压缩。
    /// 【实测 dsh 体】首行 `[中文](#cn-x) | [English](#en-x)`，正文 <h3 id="cn-x">分节，
    /// 英文段以 <h3 id="en-x"> 起头且前面隔一行 `---`；
    /// 【实测自家体】DSH-MacOS / Launcher 的 body 为纯 markdown（无 HTML、无双语）。
    static func clean(_ md: String) -> String {
        // ⓪ 换行归一。【实测陷阱】GitHub release body 是 CRLF；而 Swift 把 "\r\n"
        //    视作单个 Character（grapheme cluster），split(separator: "\n") 在 CRLF
        //    处完全不切分——不归一则整篇被当成一行，逐行清洗/空行压缩全部失效。
        //    replacingOccurrences 按 Unicode 标量匹配，不受字位簇影响，可正确替换。
        var text = md.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        // ① 双语截断：中文用户只看中文段。主判据 <h3 id="en-（dsh 实测锚点）；
        //    防御纯 markdown 双语体——顶部含 ](#en- 锚链接但无 HTML 时改找英文标题行。
        //    截断后尾部残留的 `---` 分隔线由 ② 按整行删除。
        if let r = text.range(of: "<h3 id=\"en-") {
            text = String(text[..<r.lowerBound])
        } else if text.contains("](#en-"),
                  let r = firstMatch(text, #"(?m)^#{1,6}[^\n]*English[^\n]*$"#) {
            text = String(text[..<r.lowerBound])
        }
        // ② 逐行清洗。【陷阱】图片必须在链接降级之前删——`![alt](url)` 同样匹配
        //    链接规则，顺序颠倒会把 alt 文本漏进正文。
        var kept: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            line = rxReplace(line, pattern: #"!\[[^\]]*\]\([^)]*\)"#, with: "")   // markdown 图片
            line = rxReplace(line, pattern: #"<img[^>]*>"#, with: "")             // HTML 图片
            // 锚点导航行：剥掉全部 #锚点链接后只剩 | 与空白 → 整行丢（dsh 首行即此形态）
            let probe = rxReplace(line, pattern: #"\[[^\]]*\]\(#[^)]*\)"#, with: "")
            if probe.drop(while: { $0 == "|" || $0.isWhitespace }).isEmpty { continue }
            // 水平分隔线（≥3 个 -_* 组成的行）：仅是排版噪音
            // 【陷阱】trim 用 whitespacesAndNewlines——CharacterSet.whitespaces 只含
            // 空格与制表符，行尾残留的 \r 会让 allSatisfy 判定意外失败
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count >= 3, trimmed.allSatisfy({ "*-_ ".contains($0) }),
               trimmed.contains(where: { $0 != " " }) { continue }
            // markdown 链接降级为纯文本（保留链接文字，丢弃目标）
            kept.append(rxReplace(line, pattern: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1"))
        }
        var out = kept.joined(separator: "\n")
        // ③ HTML：块级闭合标签与 <br> 折成换行——否则剥壳后相邻段落内文会黏成
        //    一行（<h3>标题</h3> 的内文必须独占一行）；其余标签直接剥壳。
        //    【陷阱】实体还原必须放在剥壳之后：先还原会把 &lt;foo&gt; 变回
        //    <foo> 而被标签规则误删。
        out = rxReplace(out, pattern: #"(?i)</(h[1-6]|p|li|tr|div|ul|ol|table|blockquote|section)>"#, with: "\n")
        out = rxReplace(out, pattern: #"(?i)<br\s*/?>"#, with: "\n")
        out = rxReplace(out, pattern: #"<[^>]+>"#, with: "")
        for (entity, plain) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                                ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: plain)
        }
        // ④ 行首装饰还原：显示层是只读 NSTextView 纯文本，markdown 记号是噪音。
        //    标题 # 后必须跟空白（#{1,6}[ \t]+）——防误吞 "#123 issue 引用" 行首。
        out = rxReplace(out, pattern: #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#, with: "")
        out = rxReplace(out, pattern: #"(?m)^[ \t]{0,3}>[ \t]?"#, with: "")
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        // ⑤ 空行压缩 ≤1 + 每行去尾空白 + 首尾 trim（lastBlank 初值 true 天然吞掉文首空行）
        var lines: [String] = []
        var lastBlank = true
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty {
                if !lastBlank { lines.append(""); lastBlank = true }
            } else {
                lines.append(t); lastBlank = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 私有工具

    /// 统一的 GitHub API GET（8s 超时 + 禁缓存 + UA/Accept 头，与 UpdateEngine 同规）。
    /// 列表与单查两个端点的 JSON 形状不同（数组 vs 对象），asList 归一处理。
    /// 任何失败 → nil（不 throw——本引擎全链路静默降级）。
    private static func get(url: URL, asList: Bool) async -> [ReleaseNotes]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("DSH-Desktop-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let json = try? JSONSerialization.jsonObject(with: data)
            let rows: [[String: Any]] = asList
                ? (json as? [[String: Any]]) ?? []
                : (json as? [String: Any]).map { [$0] } ?? []
            return rows.compactMap(makeNotes)
        } catch {
            return nil
        }
    }

    /// 一行 release JSON → ReleaseNotes；缺 tag_name 的行（异常数据）丢弃。
    private static func makeNotes(_ row: [String: Any]) -> ReleaseNotes? {
        guard let tag = row["tag_name"] as? String, !tag.isEmpty else { return nil }
        return ReleaseNotes(version: plainVersion(tag), tag: tag,
                            title: row["name"] as? String,
                            publishedAt: parseDate(row["published_at"] as? String),
                            cleanedBody: clean(row["body"] as? String ?? ""))
    }

    /// GitHub ISO8601 时间解析（published_at 形如 2026-08-30T12:34:56Z，
    /// 偶带小数秒）；任何不符返回 nil——日期只是展示增强，不参与任何判定。
    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        return ISO8601DateFormatter().date(from: raw)   // 无小数秒的常规形态
    }

    /// tag → 纯版本号：dsh-v0.1.2 → 0.1.2；v1.0.1 → 1.0.1；无前缀原样返回。
    /// 【陷阱】前缀必须长的先判（dsh-v 先于 v），否则会剥成 "v0.1.2" 二次残留。
    private static func plainVersion(_ tag: String) -> String {
        for prefix in ["dsh-v", "dsh-", "v"] where tag.hasPrefix(prefix) {
            return String(tag.dropFirst(prefix.count))
        }
        return tag
    }

    private static func rxReplace(_ text: String, pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                           withTemplate: template)
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> Range<String.Index>? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return r
    }
}
