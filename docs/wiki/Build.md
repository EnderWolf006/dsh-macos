# 构建

> **定位声明**：社区项目，非 DeepSeek 官方出品，与官方无隶属或背书关系。完整免责声明见仓库 [README](../../README.md#免责声明)。
>
> 导航：[Home](Home.md) · [使用](Usage.md) · [架构](Architecture.md) · [更新](Update.md) · [FAQ](FAQ.md) · [版本历史](Changelog.md)

本页说明如何从源码构建 DSH Desktop，以及分发注意事项。

> 环境要求：macOS 13+、Command Line Tools（含 swiftc），无需完整 Xcode。开发机实测 macOS 15.2 / arm64。

## 快速构建

```bash
bash scripts/build.sh
open "build/DSH Desktop.app"
```

## 构建脚本做了什么

`scripts/build.sh` 依次执行：

1. **工具链修复**：CLT 半更新状态导致 `redefinition of module 'SwiftBridging'` 时，生成 `-vfsoverlay` 自动绕过
2. **编译**：`swiftc -O` 编译 `Sources/DSHDesktop/*.swift` → `.build/DSHDesktop`
3. **组装 bundle**：Contents/MacOS + Contents/Resources，拷入二进制与 Info.plist（版本 1.0.0）
4. **图标**：`make-icon.swift` 以 `whale.svg` 矢量源生成 `AppIcon.icns`（白底黑鲸）+ 菜单栏模板 PNG
5. **资源**：拷贝 overlay（`Resources/overlays/*.js`）
6. **签名——稳定化 ad-hoc**：

```bash
codesign --force --deep -s - \
  --requirements '=designated => identifier "com.deepseek-ai.dsh-desktop"' \
  "$APP"
```

### 为什么是"稳定化 ad-hoc"

普通 ad-hoc 签名的 Designated Requirement 锁定为 cdhash，**每次重编译必然改变**，导致 TCC 系统授权（辅助功能等）跨构建失效。显式指定 identifier 规则后，DR 不再随构建漂移，授权跨版本持续有效。

代价与边界：

- 校验从"精确到字节"放宽为"精确到标识符"（自用与信任链可控场景可接受）
- 从旧版迁移需一次性执行 `tccutil reset Accessibility com.deepseek-ai.dsh-desktop` 并在系统设置重新勾选，此后永久稳定
- **它不能替代 Developer ID + 公证**：对陌生下载者，Gatekeeper 依然会拦截 ad-hoc 应用

## 分发（GitHub 社区做法）

推荐主线是一键安装脚本（脚本位于仓库根 `install.sh`）：

```bash
curl -fsSL https://raw.githubusercontent.com/Farverge/DSH-MacOS/main/install.sh | bash
```

原理与约定：

- curl 下载的文件**不带隔离标记**，Gatekeeper 全程不介入，ad-hoc 签名直接可用
- 脚本命中 Release 最新版的固定资产名 **`DSH.MacOS.Desktop.zip`**（GitHub 会把空格归一化为点号，故直接用点号命名）
- zip 内根级必须是 `DSH Desktop.app`
- 打包命令：

```bash
ditto -c -k --keepParent "build/DSH Desktop.app" DSH-MacOS-Release.zip
# 重命名为 DSH.MacOS.Desktop.zip 后作为 Release 资产上传
```

可选补充：自建 Homebrew tap（仓库名必须为 `homebrew-*`，这是 brew 的硬性解析规则）获得 `brew search` 可发现性；对陌生下载者的无摩擦体验则需 Developer ID + 公证（未采用）。

## 校验与排障

| 检查 | 命令 |
|---|---|
| 验证签名与 DR | `codesign -dv -r- "build/DSH Desktop.app"` |
| DR 应显示 | `designated => identifier "com.deepseek-ai.dsh-desktop"` |
| SwiftBridging 报错 | 确认 vfsoverlay 未被改坏；`rm -rf .build/toolchain-fix` 后重试 |

`.build/` 为中间产物目录，可安全删除，构建时重建。

---

免责声明见仓库 [README](../../README.md#免责声明)
