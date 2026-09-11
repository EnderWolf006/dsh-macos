# 架构

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。
>
> 导航：[Home](Home.md) · [使用](Usage.md) · [构建](Build.md) · [更新](Update.md) · [FAQ](FAQ.md) · [版本历史](Changelog.md)

## 项目定位

DSH Desktop 是 DeepSeek Harness（`dsh`）的 macOS 社区桌面外壳，是一个「薄壳」：**不重写官方界面**，用原生 macOS 技术把官方 Web GUI 装进原生窗口，并代管 dsh 服务器进程生命周期。

```text
双击 App → 冷启动(约 1 秒) → 后端自动拉起 → 窗口内呈现官方 Web GUI
```

---

## 分层架构

```text
DSH Desktop
├── ① UI 层（SwiftUI / AppKit）
│     ├── 主窗口（状态面板 ⇄ WebView，断连横幅覆盖层）
│     ├── 「服务器」命令菜单 · Settings（Cmd+,）
│     └── AppDelegate：沉浸式标题栏 · 红绿灯锚定 · 拖拽带
├── ② Web 层（WebKit）
│     ├── WKWebView 内嵌官方 GUI · 首次加载保护 · SPA 不打断
│     ├── 导出拦截 / 弹窗接管 / 权限处理 / 断连横幅
│     └── desktop-layout.js：纯 CSS 布局 overlay（v3）
├── ③ 进程层（ServerManager）
│     ├── 身份探测 attach → 唯一性复查 → 六级解析链(来源绑定缓存)
│     ├── spawn(zsh exec) → 双频健康轮询 → terminate+SIGKILL
│     └── 更新链：查询→确认→镜像拉取→校验→清缓存→停服→重启
└── ④ 桥接层
      ├── dsh-desktop-bridge 插件（status / notify 路由）
      └── BridgeClient 轮询 · MenuBarPluginManager
```

## 各层要点

### ① UI 层

- 主窗口 `WindowGroup` 以 `server.status` 驱动分支；**running ↔ 连接中断之间共享同一 WebView 实例**（单一布尔决定分支身份），断连以非交互横幅覆盖提示，恢复即消失
- 「服务器」菜单的启停按钮在 starting 或外部实例（attach、`serverProcess == nil`）时禁用，避免无效操作
- 沉浸式标题栏：红绿灯锚定 (23,23)、透明拖拽带（双击最大化、边缘贴边由 AppKit 接管）、内容顶到顶
- 窗口菜单原生项裁剪问题的根因修复：**状态发布纪律**——秒级变化的数据（桥接明细 uptime 等）一律不走 `@Published`，防止高频 objectWillChange 拖动整个 scene 连同命令菜单重建

### ② Web 层

- **首次加载保护**：仅首次进入时发起加载；SPA 路由变化不重载根页面；手动刷新走菜单
- **导出拦截**：捕获 `/api/session.export` 导航，原生下载至 `~/Downloads` 并通知 + Finder 定位
- **弹窗接管**：`target=_blank` 在当前视图打开；麦克风/摄像头权限直接授予
- **overlay v3（纯 CSS，零 JS）**：选择器只依赖三类稳定信号——
  1. 官方 AppFrame 字面量 data 属性：`data-sidebar-collapsed` / `data-details-collapsed` / `data-dragging`（React 条件渲染为空串，规则统一加 `:not([…="false"])` 防御未来显式布尔化）
  2. 槽位锚点：官方渲染器给每个槽位 occupant 包 `<div data-slot="…" style="display:contents">`，`[data-slot="sidebar"] > [class*="_root"]` 可零歧义命中侧栏根
  3. CSS Modules 语义后缀包含匹配（`_frame`/`_sidebarCol`/`_collapsed`/`_rail`/`_settingsArea`/`sessionRow`…）
- 折叠几何：86px 外壳列 + 根节点左右各 25px 对称内边距（36px 内容盒恰居中，官方控件贴内容盒左缘排列）+ padding 过渡插值（尊重 `prefers-reduced-motion`）；鲸鱼图形含 2px 视觉配重位移

### ③ 进程层（ServerManager）

- **六级解析链**（零 PATH 依赖）：缓存命中（校验首 token 存在且与配置来源一致）→ 绝对路径 → 常见 bin 目录探测 → 登录 shell 解析 → 绝对 node 直跑 npx 缓存入口 → 绝对 npx 兜底。修改启动命令即时失效缓存
- **身份探测 attach**：HTTP 200 之外校验根 HTML 前 64KB 含 `__DSH_BOOT__`（lossy 解码防截断误判）；探测返回后复查进程归属，避免自启实例被误标为外部
- **唯一性保证**：spawn 前再次身份复核，已有实例转 attach，绝不双后端
- **停止**：terminate → 3s 超时 SIGKILL（以 Process 实例身份比对，重启场景不误杀）；`stopAndWait` 供退出与更新收尾
- **更新链**：查询（npm view，不停服）→ 用户确认 → 镜像拉取（registry.npmmirror.com + PTY 进度）→ 校验（退出码 + 版本号合规）→ 清理旧/残缺 npx 缓存（保护集 = 自身解析目标 + `ps` 快照中任何进程引用的目录，边界感知前缀同名目录）→ 停服 → 冷启动；任一步失败不动旧版；更新中退出有 `isUpdating` 保护

### ④ 桥接层

- **dsh-desktop-bridge**（源码随仓库 `bridge/`，部署副本在 `~/.dsh/profiles/node_modules/`）：
  - `GET /api/desktop/status`：pid / 版本 / 运行时长。版本经 `createRequire` 解析 `@deepseek-ai/dsh/package.json`（profile 内 @deepseek-ai 树是指向运行副本的符号链接，天然同版本）。语义约束：绝不报告插件自身版本
  - `POST /api/desktop/notify`：osascript 原生通知，供生态插件预留
- **BridgeClient**：仅轮询 status；连接状态变化才发 objectWillChange（见①的状态发布纪律）
- **MenuBarPluginManager**：按 bundleID 扫描 `~/Library/Application Support` 的可选 DSH Launcher

## 冷启动链路（本机实测）

```text
双击 App（launchd，PATH 极简）
  ├─ 身份探测 attach（无实例 → 继续）
  ├─ 解析链：缓存命中 0s / 首次约 +0.4s
  ├─ spawn：zsh -c "exec <绝对node> <绝对bin.js> --port"
  ├─ 0.5s 加密轮询发现就绪
  └─ WKWebView 加载官方 GUI
────────────────────────────────────────
就绪总耗时：约 1 秒
```

## 关键设计决策

1. **不重写官方 UI**：内嵌 WebView 让所有 Cordis 插件自动获得桌面 UI
2. **零 PATH 依赖**：解析链按确定性降级 + 来源绑定缓存，可插拔（未来内嵌运行时只需插入最高优先级一级）
3. **后端唯一**：spawn 前身份复核，杜绝双后端与误 attach
4. **状态发布纪律**：`@Published` 只承载"需要 UI 响应的低频状态变化"，秒级数据走普通属性
5. **更新安全**：先查后问、失败不碰旧版、更新中退出不误杀、清理不伤使用中目录
6. **布局不碰官方源码**：overlay 只挂稳定 hook，纯 CSS 与官方动画同帧生效

## 与"原生重写"对比

| 维度 | 内嵌 Web UI（本项目） | 原生重写聊天界面 |
|---|---|---|
| 内存 | node 进程 + 系统 WebKit（共享进程池） | 省渲染进程但失去生态 |
| 插件生态 | **100% 保留**，新插件自动获得桌面 UI | 每个插件 UI 都要重写 |
| 维护成本 | 跟随官方自动更新 | 需持续同步官方变化 |

---

免责声明见仓库 [README](../../README.md#免责声明)
