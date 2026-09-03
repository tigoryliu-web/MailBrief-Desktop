# MailBrief Desktop

一款原生 macOS 桌面邮件摘要应用。它以桌面小组件的形式整理 Gmail、Outlook 及其他 IMAP 邮箱，并把每封邮件转换为简洁摘要和可勾选行动项。

## 当前实现

- 壁纸层无边框窗口，可拖动、缩放并记忆位置。
- 最多五个动态邮箱分区；支持添加、重命名、排序、断开和从本机移除账号。
- Gmail 与个人 Outlook 使用只读 OAuth；iCloud、Yahoo、QQ、163 等其他邮箱可通过 TLS IMAP 和应用专用密码接入。
- 折叠状态及紧急/重要/普通优先级排序。
- AI 在优先级后标注一个邮件类型：需要操作、学校、财务、购物、旅行、订阅通讯、垃圾／低优先级或其他。
- 推广广告会被彻底排除：Gmail“推广”分类及带明确群发营销标记的邮件在调用 OpenAI 前过滤，其余由 AI 判断；推广内容不进入摘要、通知或本地持久化数据。
- 完成圆圈可撤销；完成项在下一次成功刷新时移除。
- 保留手动刷新和单邮箱重试；也可启用最多五个每日固定刷新时间。
- 错过的定时刷新不会补刷；全部已连接邮箱在最近15分钟内成功刷新时跳过；定时失败不自动重试。
- 定时刷新只在发现新的紧急事项时通知，避免普通成功或单邮箱失败造成打扰。
- 菜单栏图标、设置窗口和登录时启动选项。
- OpenAI Responses API 结构化摘要，密钥存储于 macOS 钥匙串。
- 可在设置中切换简体中文／English；新摘要按当前应用语言生成，旧摘要不重写分类。
- PDF、DOCX、纯文本和图片 OCR 附件读取，20 MB 上限。
- 本地 JSON 状态持久化与合并通知。
- Gmail API 与 Microsoft Graph 只读同步；OAuth 令牌和 IMAP 应用专用密码保存在 macOS 钥匙串。
- 含明确日期的摘要可在用户点击确认后写入 Apple 默认日历；添加前会在本机检查已有日程冲突并防止重复添加。
- 演示模式和核心规则自动化测试。

## 编译

需要 Xcode 26 或兼容版本。

```sh
cd /path/to/MailBrief-Desktop
./scripts/build_app.sh
```

默认使用临时签名进行本地构建。如需使用自己的 Apple Development 证书，请只在本机终端设置环境变量，不要把签名身份写入源码：

```sh
MAIL_BRIEF_SIGNING_IDENTITY="Apple Development: your-account@example.com (TEAMID)" ./scripts/build_app.sh
```

生成的应用位于 `dist/邮件摘要.app`。

## 演示模式

演示模式只使用内置示例，不读取邮箱，也不会调用 OpenAI API：

```sh
open "dist/邮件摘要.app" --args --demo
```

## 隐私原则

- Gmail 与 Outlook 仅请求只读邮件权限；IMAP 使用 TLS 加密连接和只读命令读取收件箱。
- Apple 日历内容只在用户点击添加时于本机读取，用于检查时间冲突，不会发送给任何云端服务。
- API 密钥、OAuth 令牌和 IMAP 应用专用密码只保存在 macOS 钥匙串。
- 邮件正文和附件只在处理期间存在，不写入持久化摘要文件。
- OpenAI 请求使用 `store: false`；账号密码和 OAuth 令牌不会发送给模型。
- 项目不包含任何 API 密钥、OAuth 客户端凭据、邮箱账号或应用专用密码；这些信息必须由每位用户在自己的设备上配置。
