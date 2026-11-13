# WJXTester for iOS

这是现有 `tghWxdt` 测试脚本的原生 iOS 版本，支持：

- 手动填写或生成 6 位测试工号和测试姓名；
- 经授权确认后单次提交；
- 粘贴 10、100 条或更多名单，使用 1–10 个并发任务批量提交；
- 名单支持 `123456,张三`，也支持仅填写姓名并自动生成 6 位工号；
- 提交等待时间可设为 1–15 秒，并逐条展示执行结果；
- 显示答卷号和结果页；
- 出现安全验证时切换到内嵌网页，由用户手动完成验证；
- 通过 GitHub Actions 构建无证书 IPA。

## GitHub 构建

1. 把仓库推送到 GitHub。
2. 打开仓库的 **Actions** 页面。
3. 选择 **Build unsigned IPA**，点击 **Run workflow**。
4. 构建完成后，从任务底部的 **Artifacts** 下载 `WJXTester-unsigned-ipa`。

下载得到的是无证书 IPA，不能直接安装到普通 iPhone。需要使用 AltStore、SideStore、
Sideloadly 或开发者证书签名后安装。

## 本机 Xcode 构建

需要 macOS、Xcode 以及 XcodeGen：

```bash
brew install xcodegen
cd ios
xcodegen generate
open WJXTester.xcodeproj
```

批量任务在应用切换页面后会继续执行；应用进入系统后台时会申请有限的后台执行时间，
但 iOS 仍可能暂停长时间任务。应用仅用于本人管理或已获授权的问卷测试，不包含验证码绕过功能。
