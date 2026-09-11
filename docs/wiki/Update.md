# 更新

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。
>
> 导航：[Home](Home.md) · [使用](Usage.md) · [架构](Architecture.md) · [构建](Build.md) · [FAQ](FAQ.md) · [版本历史](Changelog.md)

本应用有三个独立更新入口：后端与本体在 **设置 → 关于**，Launcher 在 **设置 → 菜单栏插件**。

---

## 1. DSH 后端更新（核心）

**入口**：设置 → 关于 → **检查 DSH 更新**

### 准确流程

1. **三级联网查询**（官方 npm → npmmirror 镜像 → GitHub tags 兜底）：URLSession 直取 dist-tags，仅失败降级；镜像滞后只影响"晚发现"不误报（安装校验兜底）。同时返回稳定线（latest）与预发布线（alpha）
2. **无新版** → 提示"已是最新版本（数据来源）"，结束
3. **发现稳定新版** → rc 确认弹窗（稳定版通道）→ 确认后进入安装
4. **发现预发布**（可选体验）→ 独立"安装预发布版"按钮 → 专用警示弹窗（列明已知影响，如浏览器认证链启用）→ 确认后进入安装
5. **更新前快照**：当前 dsh 缓存目录整目录备份（`~/.npm/_npx-preupdate-snapshot/`，manifest 记录来源与差集）——回滚锚点
6. **三级下载安装**：npx@官方 → npx@镜像 → 官方 tarball 直链（curl 解包至 npx 缓存布局）；版本一致性校验防镜像滞后装旧版
7. **切换后端**：自管实例温和停止；外部实例（attach 模式）显式停 3080 监听者后由新版接管
8. **兼容性自检**（三项＋稳定性复探）：根页面 HTTP 语义（401=新版认证链未适配）、桥接 status、mini-dialog options；自检通过 3 秒后再探一次防"装完即崩"
9. **自检未通过** → 回滚对话框（失败清单 + 回滚 / 暂不处理 / 重试自检）
   - **一键回滚**：移除新增目录 → 清除异版本残留 → 同级 staging 原子恢复快照（先校验后换入）→ 恢复不完整时联网自愈重装 → 杀后端重启旧版

> [!NOTE]
> 版本通道说明：更新模块默认只跟 npm 的 `latest` 稳定线。官方预发布走 npm `alpha` dist-tag（如 `0.1.2-alpha.2`，2026-08-30 出现；更早的 alpha.1 曾只打 GitHub tag）——预发布仅在检查结果中以独立按钮提示，需二次确认才安装。手动尝鲜：`npx @deepseek-ai/dsh@alpha`，风险自担。

> [!NOTE]
> **alpha 通道适配说明（v1.0.6+，2026-09-02 更新至 alpha.5）**：壳已全自动适配 0.1.2-alpha 认证链（stdout 捕获 launch token → WebView 稳态门后换发 Cookie，含断连重连）。alpha 通道使用要点：
> - 升级后需在 `~/.dsh/profiles/web` 执行一次 `pnpm add @deepseek-ai/dsh-base@<版本> @deepseek-ai/dsh-web-app@<版本>`（官方 web 工作区装配，缺它 SPA 白屏）
> - 自制插件 bundle 只能经页面启动图（`__DSH_BOOT__`）的合并 URL 加载，纯路径 `/plugins/<id>/client.js` 返回 404 属官方行为（排查勿被误导）
> - dsh-mini-dialog 自 2026-09-01 起支持 0.1.2-alpha（inject 已改官方 9 包列表）；dsh-l10n-zh 原样可用
> - v1.0.7 后端通道体检项会如实区分「稳定通道形态（200）」与「alpha 认证链形态（401 健康）」；官方 alpha.5 已修复 rc.2/a3 → alpha 升级的启动失败与标题丢失，alpha 升级目标建议直接取最新 alpha

### 桥接版本显示的生效时机

更新后的首次冷启动会让桥接插件重新加载，设置页「桥接信息」即显示真实后端版本（如 `dsh v0.1.1-rc.2`）。仅重启桌面应用而后端存活（attach）时不会刷新插件，属预期。

## 2. 应用本体更新（DSH Desktop）

- 重新运行一键安装命令即可覆盖到最新版（两个发布源任选其一）：

```bash
# 抢先源（iiiiiei，第一时间获取最新版）
curl -fsSL https://raw.githubusercontent.com/iiiiiei/dsh-macos/main/install.sh | bash

# 稳定镜像源（Farverge，可能与抢先源存在同步延迟）
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash
```

> 注：抢先源（iiiiiei）第一时间获取最新版；稳定镜像源（Farverge）由 Actions 自动同步 main 分支与 Wiki，Release 不参与同步，版本可能滞后于抢先源。

- 或到 Releases 手动下载 `DSH.MacOS.Desktop.zip`（[抢先源](https://github.com/iiiiiei/dsh-macos/releases) · [稳定镜像](https://github.com/Farverge/DSH-MacOS/releases)）
- 应用内「检查应用更新」读取 GitHub Releases 最新 tag，语义化比较（远端较旧视为最新，防降级误报）；发现新版确认后自动下载 DSH.MacOS.Desktop.zip → 结构与版本校验 → 暂存换壳 → 自动重启，旧版备份到 `~/Library/Application Support/DSH Backups/`

### 权限说明

本项目采用稳定化 ad-hoc 签名（identifier Designated Requirement），**正常情况下升级不影响系统授权**。若从极早期版本升级后遇到辅助功能类授权失效，执行一次：

```bash
tccutil reset Accessibility com.deepseek-ai.dsh-desktop
```

然后到系统设置重新勾选 `/Applications` 里的 DSH Desktop.app 即可，此后跨版本永久稳定。

## 3. Launcher 更新（DSH Launcher）

入口：设置 → 菜单栏插件 → **检查 Launcher 更新**（v1.0.3 起与前两条链路同级的全自动安装）：

1. 读取 Launcher 双发布源的最新 Release（主源 `iiiiiei/dsh-launcher` 抢先发布，镜像 `Farverge/dsh-launcher` 稳定兜底；tag 与 `DSH.Launcher.zip` 资产），与本地 manifest.json 版本语义比较
2. 发现新版 → 确认窗（官方更新说明 + 备份策略）→ 确认后自动执行：
   - 下载 zip → 解包校验（.app 结构 + 可执行文件 + Info.plist 版本与 Release 一致）
   - **先同步 mini-dialog 插件**到 `~/.dsh/profiles/web/node_modules/`（内层官方依赖树；此步失败自动恢复原插件并整体中止，绝不连坐）；幂等维护 `cordis.patch.yml` 装配条目
   - 退出 Launcher → 分离脚本换壳（旧包备份至 `~/Library/Application Support/DSH Backups/`，保留最近 2 份）→ 自动启动新版
3. 无新版 / 网络失败均只提示不动作；Launcher 从未安装时提示先安装

## 4. 排障

| 现象 | 处理 |
|---|---|
| "检查 DSH 更新"查询失败 | 确认能访问 npm registry 与镜像源 |
| "检查应用更新"请求失败 | 仓库需已有 Release |
| "检查 Launcher 更新"请求失败 | 仓库需已有 Release 且含 `DSH.Launcher.zip` 资产 |
| 更新很久没动静 | 观察进度区；镜像源偶发慢属正常，稍等或重试 |
| 更新后服务器没自动起来 | 菜单「启动服务器」，或走设置重试一次检查更新 |

---

免责声明见仓库 [README](../../README.md#免责声明)
