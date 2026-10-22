# AI 软件接入

在鲸鱼娘图标中键菜单选择“选择 AI 工具”，可逐项显示、全部显示/隐藏、立即刷新，以及安装/修复官方事件接入。每个项目标明真实数据来源。额度、软件登录和回复完成事件是三件独立的事。

## Gemini 桌面版 / Grok Bot

这两项对应已安装的桌面软件，不再默认读取浏览器或另一套 CLI 登录。

点“授权读取软件用量页面”，由系统决定是否授予鲸鱼娘辅助功能权限。只通过 macOS 公开 Accessibility API 读取明确命名的用量窗口；不会提取应用密钥或读取聊天、不会自行点击、切换设置或发送消息。随后点“打开软件”，在软件里打开用量页面：

- Gemini：账号和设置 → 设置 → 用量限额。
- Grok Bot：Settings → Usage & Billing（用量与账单）。

回到鲸鱼娘点“立即刷新”。Gemini 的原生用量限额页已在当前机器实测读到“已更新”；软件未运行或未打开该页面时无法进行新的读取。只显示页面明确提供的百分比，不从重置时刻猜测窗口长度。页面关闭后保留原时间戳最多5分钟，之后显示需打开页面；不会把缓存重新标成刚更新。

**Grok Bot 0.75.0 当前仍无法自动读取。** 其“用量与账单”嵌在主窗口内；即使用量数字在屏幕上可见，辅助功能树仍只有空容器。已实测 Electron 官方 `AXManualAccessibility` 请求返回成功，但未恢复可读取内容；最终版本不保留这个无效的试验请求，也不扫描聊天。鲸鱼娘会显示“软件未提供可读取数据”，避免反复要求打开已经打开的页面。截图上的数字不写成自动额度快照；需要软件方提供可访问界面或确认可用的外部接口后才能继续接通。

Electron 辅助功能机制参考：https://www.electronjs.org/docs/latest/tutorial/accessibility 。它说明了启用请求方式，并不保证 Grok Bot 的具体版本会暴露完整界面。

目前未确认这两个桌面版有供外部助手订阅既有回复的公开完成事件接口，因此本版不会伪造自动完成提醒。Gemini CLI、Grok Build CLI是单独的可选项目，其钩子不能代表桌面版。

## OpenCode

“OpenCode Go”使用 OpenCode 桌面版/CLI 共用的 auth.json 内 opencode-go API 密钥，直接只读查询 opencode.ai 的 Go usage API。无需浏览器、无需单独安装CLI。密钥只在内存中使用并发给原服务，不复制到鲸鱼娘设置或日志。5小时、周、月按真实返回值显示，0.5%已用就是99.5%剩余；缺少的窗口不补零，月周期不假定为30天。

401/403会明确显示登录凭据未通过验证：请在 OpenCode 的提供商设置更新对应密钥。界面显示“已连接”可能只表示保存过密钥，不保证服务端仍接受它。OpenCode 连接的 OpenAI、DeepSeek 等账户额度分别属于对应服务，不合并成 Go 剩余，不用本地Token历史推算订阅余额。

“安装/修复官方事件接入”安装 OpenCode 官方插件事件观察器，合并保留现有配置。重载 OpenCode 服务后生效。使用官方注入 SDK确认会话父子关系，busy/idle通知运行与结束，子会话可生成关联桌宠；错误不报成功，重复idle只提醒一次。已启动的模型任务不因安装器被终止。新运行中的任务才验证真实事件；本版不为测试调用付费模型。

## 其他既有项目

| 项目 | 额度来源 | 回复/子代理事件 |
|---|---|---|
| Codex | 本机 app-server 的 account/rateLimits/read | 已有原生插件，保留信任审核 |
| DeepSeek Harness | 原有账号钱包接口 | 已有元数据观察桥，保留 |
| Claude Code | CodexBar OAuth兼容后端 | 官方 UserPromptSubmit/Stop，SubagentStart/Stop |
| Cursor | CodexBar兼容后端 | 官方 beforeSubmitPrompt/stop，提供明确身份的 subagent 事件 |
| Copilot CLI | CodexBar兼容后端 | 官方 userPromptSubmitted/agentStop，提供明确身份的 subagent 事件 |
| Gemini CLI | 本机CLI OAuth配额，与桌面版分开 | 官方 BeforeAgent/AfterAgent |
| Grok Build CLI | 官方CLI billing扩展，强制CLI来源 | 官方兼容Hook，与Grok Bot分开 |
| 自定义 | 用户主动提供的本地快照/指定兼容后端 | 本机WhaleEvent协议 |

兼容额度后端可能调用提供方网页内部接口，不承诺都是公开稳定API；这点不会因封装成适配器而改变。官方API可用的连接优先使用官方接口；尚无已确认公开接口的功能保持受限状态。Cursor/Copilot/Claude等CLI Stop钩子可能在其他阻断钩子继续模型之前触发，不能保证所有外部重试组合都准确。子代理缺少真实唯一ID时不会按名字虚构角色数。

安装器只给本机存在的工具配置监听，备份后幂等合并。不更改工作区信任、禁用钩子或系统权限开关。关闭通知或受企业策略限制时依原工具规则运行。一次配置并不等于收到过事件；面板只有收到真实、有效、未过期事件后才显示运行/完成状态，5分钟无更新标记过期。

## 官方参考

- macOS Accessibility：https://developer.apple.com/documentation/applicationservices/axuielement
- Gemini CLI：https://geminicli.com/docs/hooks/reference/
- Grok Bot 用量页面：https://docs.x.ai/grok-bot/settings-and-notifications
- OpenCode 插件与SDK：https://opencode.ai/docs/plugins/ 、https://opencode.ai/docs/sdk/
- OpenCode Go：https://opencode.ai/docs/go/
- Claude Code：https://code.claude.com/docs/en/hooks
- Cursor：https://cursor.com/docs/hooks
- Copilot：https://docs.github.com/en/copilot/reference/hooks-reference

手动回退时可打开保留的旧鲸鱼娘。AI设置迁移前会保存 before-native-sources.bak；各工具Hook配置旁保留带时间戳的备份。回退只恢复对应文件，避免覆盖其他新改动。

本机WhaleEvent连接空闲2秒关闭（非总时长限制），外部监听桥应按批次重连。最终共享接收端已修复macOS非阻塞标记继承导致的连接后稍晚写入丢帧，并覆盖立即发送关闭的Python与Node方式。实际模型端到端仍需各软件正常使用后验证。
