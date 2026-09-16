# 使用

完整使用指南：安装、界面、设置、通知、导出与插件。进阶问题见 [FAQ](FAQ.md)。

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。
>
> 导航：[Home](Home.md) · [架构](Architecture.md) · [构建](Build.md) · [更新](Update.md) · [FAQ](FAQ.md) · [版本历史](Changelog.md)

---

## 1. 安装

一键命令（推荐，两个发布源任选其一）：

**抢先源（iiiiiei，第一时间获取最新版）：**

```bash
curl -fsSL https://raw.githubusercontent.com/EnderWolf006/dsh-macos/main/install.sh | bash
```

**稳定镜像源（Farverge，可能与抢先源存在同步延迟）：**

```bash
curl -fsSL https://raw.githubusercontent.com/EnderWolf006/dsh-macos/main/install.sh | bash
```

> 注：抢先源第一时间获取最新版；稳定镜像源版本可能滞后于抢先源（两源差异详见 README「一键安装」）。

手动方式：到 [EnderWolf006/dsh-macos Releases](https://github.com/EnderWolf006/dsh-macos/releases) 下载 `DSH.MacOS.Desktop.zip`，解压后把 `DSH Desktop.app` 拖入 /Applications。

前提：**macOS 13+**、已安装 **Node.js**（终端 `node -v` 有输出）。应用启动时会自动拉起 dsh 后端。

## 2. 界面入口

### 主窗口

- 后端未就绪 → 状态面板（检测中 / 启动中 / 已停止），含「启动服务器」按钮
- 就绪 → 切换为官方 Web GUI
- **连接中断时不会丢失页面**：顶部出现非交互横幅提示自动重试，恢复后自动消失；期间会话位置保留
- 深浅色跟随系统；沉浸式标题栏（红绿灯锚定 + 透明拖拽带，双击拖拽带最大化）

### 顶部菜单「服务器」

| 菜单项 | 作用 | 说明 |
|---|---|---|
| 启动 / 停止服务器 | 手动控制后端 | 外部实例（attach）时「停止」自动禁用——进程不归应用管理 |
| 刷新页面 | 重载 Web GUI | 布局 overlay 也会随刷新重新注入 |
| 显示主窗口 | 调到前台 | |
| 在浏览器中打开 | 用系统浏览器打开 3080 | |
| 前往开放平台 | 打开 platform.deepseek.com | 管理 API Key |
| 发送测试通知 | 验证通知通道 | |

关闭窗口 ≠ 退出（Dock 常驻）；彻底退出用 **Cmd+Q**。

## 3. 设置（Cmd+,）

| 区块 | 内容 |
|---|---|
| 服务器 | 端口（只读 3080）、启动命令、开机自动拉起后端、退出是否保持服务器 |
| 桌面集成 | 开机自动启动（SMAppService，需在 /Applications 且签名有效） |
| 菜单栏插件 | 可选 DSH Launcher 的信息与启停开关（未安装则整栏不显示） |
| 状态 | 服务器状态、连接地址、桥接插件信息（pid / 版本 / 运行时长） |
| 关于 | 应用版本、DSH 版本、检查更新 ×2、更新日志终端 |

修改「启动命令」立即生效（解析缓存随配置失效）；端口固定 3080 不可改。

## 4. 通知

- 基于 UserNotifications；首次启动请求授权
- 授权后在 系统设置 → 通知 自由管理
- 会话导出完成会发通知并自动在 Finder 中定位文件
- 「发送测试通知」验证通道

## 5. 会话导出

在官方界面导出会话时自动接管：保存到 `~/Downloads/session-log-<会话ID>.zip` → 系统通知 → Finder 定位。

## 6. 插件

### DSH Launcher（菜单栏常驻，独立仓库可选装）
鲸鱼图标常驻菜单栏，左键唤起主应用。安装于 `~/Library/Application Support/DSH Launcher.app`（启动台不显示）；不装不影响任何功能。Launcher 与 norm 相互独立：安装 Launcher 不附带 norm。

### dsh-plugin-norm 协议层（独立选装，独立仓库）
norm 为独立选装组件（仓库 [iiiiiei/dsh-plugin-norm](https://github.com/iiiiiei/dsh-plugin-norm)，当前 1.1.1），与 DSH Launcher 分属两个独立仓库、分开选装，launcher 一键安装不含它；mini-dialog 0.2.1+ 的会话跳转依赖它（norm ≥ 1.0.1）。部署方式：将插件拷入 `~/.dsh/profiles/web/node_modules/`，在 `cordis.patch.yml` 中添加对应装配条目，重启后生效。

### 桥接插件 dsh-desktop-bridge（已内置）
随 v1.0.0 内置部署于 dsh 配置目录，为设置页「状态」提供 pid / 版本 / 运行时长，并为生态预留 `/api/desktop/notify` 原生通知通道。无需用户做任何事。

## 7. 服务器操作速查

- 手动启停：菜单「服务器」
- 彻底重来：`lsof -iTCP:3080 -sTCP:LISTEN` 找 PID kill，再重开应用
- 升级后端：设置 → 关于 → 检查 DSH 更新（详见 [Update](Update.md)）

## 8. 退出与卸载

退出：Cmd+Q（默认带走自启的后端；「保持运行」开启时除外）。

卸载：
1. Cmd+Q
2. 删除 `/Applications/DSH Desktop.app`
3. （若装了）删除 `~/Library/Application Support/DSH Launcher.app`
4. `killall Dock` 刷新残留图标

后端数据在 `~/.dsh/`，彻底清理请一并处理。

See also：[FAQ](FAQ.md) · [Update](Update.md) · [Build](Build.md)
