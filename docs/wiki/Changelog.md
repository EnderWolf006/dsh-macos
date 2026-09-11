# 版本历史

## theme-host-1.1.0-full 分支（2026-09-07~11，未发版；/Applications 已部署同源构建）

主题宿主化主线（B1-B7 菜单栏 SwiftUI 数据驱动重写 + 主题面容器 + 双通道派发）+ 0.1.5-rc.2 后端兼容三修：

- **菜单栏 10s 周期闪烁根修**（f02a411）：`refreshThemes` 等值回写 `@Published` 触发菜单重协调，把应用菜单首项标题重置回 bundle 名，≤1s 后巡检补写 manifest.appName——一错一对肉眼闪烁。修复：ThemeInfo 加 Equatable、清单未变整轮静默、首装快照未变不再 set+synchronize
- **ES2025 迭代器助手垫片**（a66bd82）：0.1.5 新 client 条目（sidebar-documentpreview）引用裸 `Iterator` 全局，WKWebView JSC 未内建，单条目 ImportError 阻塞整个启动图。document-start 用户脚本注入最小垫片（from/map/filter/take/drop/flatMap/reduce/toArray/some/every/find），已内建系统空操作
- **顶部拖拽带点击穿透**（512fbe3）：DragStripView 吞掉顶部 46pt 整带的页面点击（0.1.5 侧边栏标签条正落带内，新建/关闭标签页真鼠标无效）。hover 探针（mouseover+closest 可交互选择器→scriptMessageHandler）+ hitTest 穿透：悬停可交互元素时放行点击，其余区域照常拖拽
- 生产后端 **0.1.5-rc.2** 活体验证：插件全量加载、设置弹窗主题行（官方 settings.general.item 插槽/锚点注入双路径）、主题菜单全链正常

## v1.0.7（2026-09-01，同日热修 09-01）

0.1.2-alpha.3 兼容版（壳零改动验证）+ 退出孤儿后端修复。**同日热修**：`SemVer.compare` 补预发布细号比较（SemVer 2.0.0 规则，14 例测试）——旧版同号预发布返回 0，装 alpha.2 后检查更新永远不出现 alpha.3 安装按钮；Release 资产已替换为含修复构建：

- **alpha.3 适配度**：壳依赖的 6 个关键文件（认证链/启动图/插件扫描/stdout 打印/前端门禁/RPC 门禁）alpha.2↔alpha.3 逐字节相同；沙箱全链复验（token 正则、404→401 启动序列、303+Cookie、401 文案）通过——**v1.0.6 起的壳无需任何改动即可运行 alpha.3**
- **修复退出孤儿后端**：killall/强退/注销等 SIGTERM 类退出不走 applicationWillTerminate，自 spawn 的后端曾实测变成孤儿 node 继续占端口；现将 SIGTERM/SIGINT/SIGHUP 引导回 NSApp.terminate，停服清理恢复生效（SIGKILL 不可捕获，由下次启动的 attach 机制良性接管）
- 配套（dsh-launcher 仓）：mini-dialog 插件 client 声明修复——inject 改官方 ui-workspace 同款 9 包列表（原 `dsh-client-runtime` 已不存在，悬空边曾炸浏览器启动图致白屏）；汉化插件在 0.1.2-alpha 上原样可用

## v1.0.6（2026-08-31）

alpha.2 后端适配——认证链全自动换发（真机端到端验收：壳 spawn alpha.2 → GUI 完整渲染、桥接已连接）：

- **token 捕获**：spawn 的 stdout 逐行扫描（跨 chunk 字节级行缓冲），命中 `dsh web: <url>` 提取一次性 launch token URL，每进程至多一次
- **WebView 授权导航**：每个新 token 触发一次带稳态门的加载——先等根路径进入稳态（200 / 401+认证文案）再把一次性 token 打出去，避开后端"路由未就绪 404 窗口"（真机实测：窗口期内花掉 token = 本进程授权永久失败白屏）；覆盖首载与断连重连（旧页面挂横幅时新 token 同样触发导航）
- **健康/身份语义**：isHealthy 接受 401+认证文案；attach 身份判定接受 401 证据；更新稳定性复探接受 401
- **自检升级**：401 时借 WKWebView 会话 Cookie 重试做真校验；根页面 404 自动复探 8s（启动窗口防误报回滚）
- **文案**：alpha「已知影响」改为"已适配"口径（版本门控不变）

### 已知限制（alpha.2 运行时，非壳代码）

- 官方 web 工作区（`~/.dsh/profiles/web`）需要 pnpm 装配 `dsh.profile.bundles`（dsh-base/dsh-web-app），首次升级后需手工 `pnpm add`（0.1.2-alpha.2 实测；装完 SPA 才能启动）
- dsh-mini-dialog 的 client 声明（`dsh.client.inject → @deepseek-ai/dsh-client-runtime`）在 alpha.2 启动图中无此包，会把浏览器端启动图解析炸成白屏——部署副本已摘 client 声明（host API 保留，迷你框后台链路正常，会话级跳转暂缺）；dsh-l10n-zh（纯 client）暂时下架。两者待 dsh-launcher 出兼容 client 包后恢复

## v1.0.5（2026-08-31）

更新确认窗持续打磨：

- **官方发布日期**：每个版本分节标题下新增「发布于 YYYY-MM-DD」，运行时取自 GitHub Release `published_at`（零硬编码），本地时区日粒度显示；解析失败整行省略
- **头部居中根治**：头部三行（版本跨度/红警示/橙补充）合并为一个全宽居中文本块 + 弃用 NSStackView 改手写约束（栈的行宽/行位语义此前三次翻车：重力区分布、高度锚竞争、单行标签右挂）
- **选中瑕疵防御**：说明区选区属性钉成系统标准（深蓝灰底）；头部/脚注标签显式不可选中——杜绝任何路径把标签送入字段编辑器后以默认属性（左对齐+白字）重渲染
- **文案去硬编码**：四条更新链路的全部确认窗固定文案集中到 `UpdateCopy.swift` 目录；alpha「已知影响」按目标版本门控（认证链提示仅当目标 ≥ 0.1.2-alpha.1 时显示）

## v1.0.4（2026-08-31）

更新确认窗四项体验修复（真机像素级验收）：

- **三行头信息真居中**：换行段落的 `cell.alignment` 不生效（整块居中、块内逐行左对齐），居中现写入 attributed 段样式，逐行居中
- **说明区动态尺寸**：删除与栈拉伸需求打架的 340@750 高度锚（宽高同时拉大时多余高度曾塞进行间空隙），滚动区成为全栈唯一可伸缩行——任意方向调窗即时跟随
- **版本分节间新增居中虚线分隔**：固定短长度（约 220pt）适配任意窗宽，二级标签色
- **取消确认窗悬浮置顶**：floating → 普通层级，不再盖在其他应用之上（弹出时仍一次性抢焦点）

## v1.0.3（2026-08-31）

更新确认窗重做 + Launcher 更新全自动对齐：

- **修复说明区完全空白（关键 bug）**：NSTextView 以零尺寸创建为滚动文档视图且缺必备配置，排版宽度恒 0——数据在、渲染丢（无障碍能读到，视觉全空）。按标准姿势（垂直可伸缩/宽度跟随/容器高度无限）配置后正常显示
- **竖版窗口**：默认 480×620 可拉伸（贴合 GitHub release notes 竖向阅读排版）；等宽 Menlo 换系统字体 13pt 加行距
- **Launcher 全自动更新**：`LauncherSelfUpdater` 三段式（查询 Release → 下载解包校验 → 插件同步 + 换壳重启），对齐应用自更新模式；插件同步失败自动恢复原状并整体中止；旧包备份保留 2 份。设置页确认按钮从"前往 GitHub 下载"改为"下载并自动更新重启"
- **alpha 警示拆两行**：红字结论 + 橙字影响面（浏览器认证链 401 与回滚路径）
- **说明按版本降序聚合**：新版在上，往下看历史
- 真换行标签修复橙字单行溢出（只设 lineBreakMode 的标签陷阱，曾把窗口撑宽）

## v1.0.2（2026-08-31）

更新确认弹窗独立化——升级前可见官方更新内容：

- **独立确认窗**（四处：后端稳定版 / 后端预发布 / 应用自更新 / Launcher）：NSWindow 560×480 可拉伸，说明区可上下滚动（系统 alert 无法承载长文）
- **官方更新说明**：后端取自上游 GitHub Release（中英双语自动截中文段），前端与 Launcher 取自自家 Release；markdown/HTML 清洗为纯文本
- **跨版本聚合**：领先一个版本显示该版说明；领先多版本按升序逐版分节（`── vX.Y.Z ──`），标题行标注"跨 N 个版本"
- **三态降级**：说明加载中 / 官方未提供 / 正文；任何网络失败不阻断更新流程
- 预发布警示（含 401 已知影响）红字置于窗顶；Launcher 为"说明+前往下载"（自动安装留待后续）

## v1.0.1（2026-08-31）

更新模块全面强化（三级链 + 自检回滚 + 双通道弹窗）：

- **三级版本查询**：npm 官方 → npmmirror → GitHub tags 兜底；返回稳定线与 alpha 线
- **三级下载安装**：npx@官方 → npx@镜像 → 官方 tarball 直链；版本一致性校验
- **更新前快照**：整目录备份 + manifest 差集登记（回滚锚点）
- **后端切换修正**：attach 模式下外部实例显式停止（此前新版起不来、自检假通过）
- **兼容性自检**：根页面/桥接/mini 三探针 + 3 秒稳定性复探；失败弹回滚对话框
- **一键回滚**：异版本残留清理、staging 原子恢复、恢复不完整联网自愈重装
- **双通道弹窗**：rc 稳定版确认框与 alpha 预发布警示框（列明已知影响）分离
- **修正**：版本提取整行倒序匹配（npm 弃用警告误抓）、currentDSHVersion 优先取桥接在线值（缓存陈旧值曾致 alpha 提示消失）
- **质量**：自审修复 P0×1/P1×3/P2×2；alpha 真机全链实测（安装→自检失败→回滚弹窗→执行）；回滚文件逻辑无头断言 10/10

## v1.0.0

首个公开版本。

### 功能

- 原生 macOS 外壳（SwiftUI / AppKit，应用本体约 850 KB）+ WKWebView 内嵌官方 Web GUI
- dsh 后端进程托管：attach 探测 → spawn 前唯一性复查 → 六级命令解析链（来源绑定缓存）→ 双频健康轮询 → 优雅停止（terminate + 超时 SIGKILL）
- attach 身份双重校验（HTTP 200 + 根页面 `__DSH_BOOT__` 官方标记），外部实例退出时不带走、「停止服务器」菜单自动禁用
- 断连韧性：瞬时断连保留 WebView 与 SPA 会话位置，页内横幅提示自动重试；手动停止/进程崩溃仍回状态面板
- 桌面布局 overlay v3（纯 CSS）：红绿灯锚定 (23,23)、折叠态 86px 外壳列 + 36px 内容盒居中、logo 行对齐顶栏底线；选择器只依赖官方字面量 data 属性（`data-sidebar-collapsed` 等）、槽位锚点（`data-slot="sidebar"`）与语义类名，抗官方重建；尊重系统减少动态效果设置
- 会话导出拦截：原生下载至 `~/Downloads` + UserNotifications 通知 + Finder 定位
- 原生通知通道：启动预请求授权；前台横幅展示
- DSH 后端更新链：联网查询 → 确认 → 镜像源拉取（PTY 实时进度）→ 完整性校验 → 清理旧/残缺缓存 → 停服 → 冷启动；`isUpdating` 防误杀；清理前保护自身与终端侧使用中的 npx 缓存目录
- 桥接插件 dsh-desktop-bridge（源码随仓库 `bridge/`，部署副本位于 `~/.dsh/profiles/node_modules/`）：status 路由供设置页展示（pid / 版本 / 运行时长），notify 路由为生态预留；版本字段经模块解析报告真实后端版本
- 可选菜单栏插件（DSH Launcher，独立仓库）：按 bundleID 精确检测、启停管理
- 稳定化 ad-hoc 签名（identifier Designated Requirement）：辅助功能等系统授权跨构建持续有效
- 一键安装脚本 `install.sh`：curl | bash，下载最新 Release 安装并启动（无隔离标记、无 Gatekeeper 拦截）

### 修复（相对开发期中间版本的演进记录）

- 启动命令解析缓存绑定配置来源：修改「启动命令」立即生效，不再被旧缓存绑架
- `stop()` 延迟 SIGKILL 以进程实例身份比对：3 秒窗口内重启不会误杀新后端
- WebView Coordinator 两处块观察者 token 存储并在 deinit 移除，消除重建泄漏
- attach 探测返回后复查进程归属，杜绝把自启服务器误标为外部实例（退出孤儿问题）
- 折叠动画改用可插值的对称内边距方案（替代不可插值的限宽跳变），消除控件闪现感
- 桥接明细移出 `@Published`：消除秒级 objectWillChange 空转，修复「窗口菜单展开期间原生项被渐进裁剪」的系统级症状
- 命令解析首 token 单次替换：`dsh --tag dsh` 类命令不再被误改
- `isDSHInstance` 采用 lossy 解码，64KB 截断多字节字符不再导致身份误判

### 已知边界（有意保留 / 记录在案）

- `stopAndWait()` 在主线程忙等 ≤4s（仅更新收尾与退出路径调用）
- 更新锁占用期间按钮静默忽略重复点击
- 启动命令经 zsh 执行属用户可信输入，未做 argv 边界拆分
- 折叠态新建会话按钮悬停为 12px 圆角方块（官方样式原样保留）
- 折叠态鲸鱼图形含 2px 视觉配重位移（可在 overlay 中调整）

---

许可：MIT · 免责声明见仓库 README
