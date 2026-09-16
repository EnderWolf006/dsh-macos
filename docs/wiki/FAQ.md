# 常见问题（FAQ）

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。
>
> 导航：[Home](Home.md) · [使用](Usage.md) · [更新](Update.md) · [架构](Architecture.md) · [构建](Build.md) · [版本历史](Changelog.md)

## 启动与服务器

### 找不到 dsh 命令 / 启动报错
- 保持默认启动命令 `dsh --profile web`；六级解析链会兜底到 npx 缓存或绝对 npx
- 确认已安装 Node.js（终端 `node -v` 有输出）
- 修改过启动命令的话注意：解析缓存与配置来源绑定，改完即时按新命令解析

### 点了"启动服务器"但一直"启动中…"
- 首次冷启动需要拉取依赖，耐心数秒
- `lsof -iTCP:3080 -sTCP:LISTEN` 查看 3080 占用

### 端口被占用
应用会先做身份校验（HTTP 200 + 官方启动标记）：确实是 DSH 实例则 attach（视为外部实例，退出时不带走，「停止服务器」菜单自动禁用）；陌生服务不会被误认。废弃进程手动清理：

```bash
lsof -iTCP:3080 -sTCP:LISTEN   # 找 PID
kill <PID>
```

### 页面白屏 / 加载失败
菜单 → 刷新页面；断连时页面顶部会出现横幅自动重试，页面内容保留不丢。

### 折叠侧栏按钮位置不对 / 动画卡顿
确认使用 v1.0.0+ 的 overlay（v3 及以上为纯 CSS 方案），刷新页面即可生效。

## 通知

### 系统设置里没有 "DSH Desktop"
启动过应用即会触发授权请求；若曾拒绝，去 系统设置 → 通知 恢复。可用菜单「发送测试通知」验证通道。

## 辅助功能权限（高级用户）

本项目采用稳定化 ad-hoc 签名（identifier DR），正常使用无需任何辅助功能授权。仅当你主动授予过（例如用 AppleScript 自动化测试）且遇到"条目勾选却无效"：执行一次 `tccutil reset Accessibility com.deepseek-ai.dsh-desktop` 后重新勾选 `/Applications` 的应用本体即可，此后跨构建稳定。（历史上 ad-hoc 默认签名时代存在 cdhash 漂移导致的失效，v1.0.0 已根治。）

## 分发与安装

### 一键安装命令是什么
```bash
curl -fsSL https://raw.githubusercontent.com/EnderWolf006/dsh-macos/main/install.sh | bash
```
curl 安装不带隔离标记，无 Gatekeeper 拦截。浏览器下载 zip 的用户如遇"已损坏"，可移除隔离属性后再打开。

### 升级会丢系统权限吗
不会。稳定化签名保证辅助功能等授权跨版本有效。

## 菜单栏插件（DSH Launcher）

### 设置了"菜单栏插件"但没出现
未安装 DSH Launcher（独立仓库，可选装），或安装后未重新检测。不装不影响任何功能。

## 其它

### 想知道正在用的 dsh 版本
设置 → 关于 → DSH 版本（本地解析链读取）；装了桥接插件时状态区也会显示。

### 如何停掉后台的 dsh
由应用启动的后端：菜单「停止服务器」。外部实例请 `lsof -iTCP:3080 -sTCP:LISTEN` 按 PID 处理（应用内按钮对外部实例是禁用的，这是有意设计）。

### 卸载
Cmd+Q 退出 → 删除 `/Applications/DSH Desktop.app` → （若装了）删除 `~/Library/Application Support/DSH Launcher.app` → `killall Dock` 刷新残留图标。后端数据位于 `~/.dsh/`，如需彻底清理请一并处理。

---

Need more? 参见 [Usage](Usage.md) · [Update](Update.md) · [Architecture](Architecture.md)
