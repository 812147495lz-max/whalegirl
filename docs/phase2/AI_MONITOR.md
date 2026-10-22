# AI 额度与子 Agent 桌宠

## 调研结论与获取方式

参考 [CodexBar](https://github.com/steipete/CodexBar) 与 [QuotaBar](https://github.com/QuotaBar/QuotaBar)。成熟工具主要复用本机 OAuth、浏览器会话、官方 CLI 的状态接口；不同产品/账号的配额不能混用，也不能从本地 token 消耗推算订阅剩余额度。

本版内置 CodexBarCLI，锁定 `9093308f0b79645f6794c2f28f020d87fe06386b`，MIT。仅包含命令行后端、SwiftPM 资源及许可；剥除本地符号后约 26 MB，不安装另一个菜单栏 App。

| 服务 | 本版读取方式 | 实际显示 |
|---|---|---|
| Codex | 本机 Codex `app-server --stdio` → `account/rateLimits/read` | 实际限额窗口和恢复时间；本机实读成功 |
| DSH | 原有平台账号 grant → 原 issuer 的固定用户余额接口 | 普通与奖励钱包总余额，保留精确十进制；本机实读成功 |
| Claude Code | CodexBar OAuth 路径 | 本机已有账号的实际窗口；此机器暂无可用登录 |
| Gemini 桌面版 | macOS公开Accessibility API，仅明确的用量窗口 | 系统授权后读取页面真实数字；不复用浏览器或CLI登录 |
| Grok Bot | macOS公开Accessibility API，仅明确的用量窗口 | 未暴露可读窗口/数字时明确受限；独立于Grok Build CLI |
| Cursor / Copilot | CodexBar兼容额度后端，官方事件Hook | 兼容额度可能依赖内部接口，不称为全部公开API |
| OpenCode Go | 本机已存Go密钥 → 官方Go usage接口 | 5小时/周/月，401明确认证失败；其他连接的账号分别计算 |
| 其他 | 添加工具时填 CodexBar provider 标识，或自定义快照 | 按提供方实际返回的周期显示 |

参考主源：[Claude](https://github.com/steipete/CodexBar/blob/9093308f0b79645f6794c2f28f020d87fe06386b/docs/claude.md)、[Gemini](https://github.com/steipete/CodexBar/blob/9093308f0b79645f6794c2f28f020d87fe06386b/docs/gemini.md)、[Grok](https://github.com/steipete/CodexBar/blob/9093308f0b79645f6794c2f28f020d87fe06386b/docs/grok.md)。网站私有额度接口可能随上游变化，失败时显示不可用，不造出满额数值。

## 使用

中键点击图标，选择“选择 AI 工具…”。可逐项显示、全部隐藏/显示，以及关闭整个 AI 额度区域。设置也在展开信息栏的“选择”入口。原有 CPU/内存采集继续后台运行。

配置文件：`~/Library/Application Support/WhaleGirl/UserData/AI工具设置.json`。每分钟后台刷新，单次最多 3 路并发，提供方超时各自处理，总读取有上限。新增或关闭开关后保存，无需重启。配置只保存显示偏好及 adapter/provider 标识，不保存账号 token。

“连接浏览器”是显式交互操作，复用 CodexBar cookie 导入，可能出现 macOS 钥匙串授权。普通后台刷新不申请交互式钥匙串授权、不清除拒绝冷却。Claude Code 使用原 CLI 登录状态。没有登录、接口不可用、无相应周期均不估算。旧数据超过 5 分钟会注明过期。

自定义快照放在 `AI额度/<provider-id>.json`，provider 的 adapter 选 `snapshot`。示例：

```json
{"providerId":"custom-demo","state":"ready","fetchedAt":"2026-10-21T03:00:00Z","windows":[{"durationSeconds":18000,"remainingPercent":75},{"durationSeconds":604800,"remainingPercent":90}],"balances":[]}
```

时间未知的真实窗口使用 `durationSeconds:0` 与 `periodLabel`；不能因恢复时间看起来像某天就假定为周额度。过滤 CodexBar 的 synthetic placeholder 和 usageKnown=false 窗口。其他供应商的历史、账户标识、调试错误、消费明细均不进入面板或事件。

## 子 Agent 桌宠

打开“子 Agent 自动生成鲸鱼娘”后，按 `(source, sourceInstance, child session ID)` 去重，每个真实子代理一只；生成中心点在当前显示器可用桌面的中央 50% 宽 × 50% 高范围内独立随机选择，不按序号排成网格。父会话与普通 fork 不计。出生气泡显示真实子代理标识及可用的公开任务标签；出生满2秒后后台预载首次不同动作，准备完成才播放，不阻塞界面。活动结束后每只随机10–20秒离开，重复结束不会延长期限；期间重新运行取消退场。结束气泡最多10字，依据任务标签说明该项结束，不把标签当成成功证明；无标签则说“这轮工作结束了”。经典素材已有“点击回应-元气挥手”，退出前统一播放并播完再消失；其余皮肤不强塞经典动作。自动生成的角色使用既有共享素材与全局调度，手动拖出的角色独立。关闭自动开关只关它生成的角色。

DSH 桥：`Integrations/WhaleGirlDSH`，只观察身份、所有权、活动状态和公开任务标签，不读取对话。已安装到当前桌面 profile，先备份原 patch，再通过唯一 `insert` 注册稳定文件。观察桥 v4 已在原 DSH 进程热加载生效，健康文件确认当前活动数量；没有重启或运行模型任务。idle 表示本次活动停止，不宣称成功；disposed 未有正常停止时标记断联。2 秒校正心跳用于 WhaleGirl 后启动时恢复；15 分钟失联后提示断联，再随机等10–20秒退场。

Codex 桥：原插件更新为 0.2.0，原生插件命令安装完成，新增 SubagentStart/Stop。`agent_id` 为子代理、`session_id` 为父会话。没有心跳的 Codex 子代理不会因运行超过 15 分钟被错误关闭。改变 Hook 定义仍遵守 Codex 原生信任审查，必要时在新会话 `/hooks` 查看并审核，未修改信任 hash。Claude Code 桥也提供于 `Integrations/WhaleGirlClaude`，本机未安装 Claude CLI，未替用户安装该插件。

通用接入沿用 WhaleEvent v1 本地 Unix socket。发送 start/working/end 并附真实 parentSessionId 即可；仅统计接入的工具，不声称能从任意进程或任意聊天软件自动识别子代理。不创建付费推理任务测试，不采集 prompt、模型回答或工具命令。

## 验证与限制

9项纯逻辑测试覆盖去重、根排除、恢复、随机10–20秒退场、短句与标签清理、跨服务身份、失联、长任务与额度周期。12项 Python 测试覆盖最小元数据投影、敏感字段排除、精确金额、占位窗口过滤。Node 测试通过真实临时 Unix socket 验证 DSH 桥。原生 AppKit 测试覆盖开关持久化、额度卡片渲染、回调数量与关闭边界；0 runtime warnings。

实际 Codex 与 DSH 账户只读查询成功，其他服务尚无可用登录，不能声称真实额度全验证。原生测试不等于物理鼠标/真实模型子代理/多屏/全屏性能验收。电脑端 UI 自动化选择 App 超时，未以其作为成功证据。尾巴、角色素材、已有探头/下落几何均未修改。


## 2026-10-21 恢复修复

- 实际故障证据：旧进程仅收到三条 DSH 子代理结束事件，未收到对应开始；旧 roster 忽略未知结束，20 秒恢复间隔也会错过短任务。
- 桥每 2 秒按当前 runtime running/idle/live 列表校正，丢失 idle/disposed 事件也能恢复。串行 socket 每批最多 64 帧，低于服务端 120 帧限制；失败 300ms 后重试，最长 60 秒，合并待发心跳并限制队列。此为尽力投递，没有伪称服务端 ACK。
- 仅本地 DSH 桥标记且仍在本次随机退场期限内的新结束事件可补建桌宠并立即说话，退出期限使用原始结束时刻加10–20秒；历史完成列表不回放。序号挡住同秒迟到的旧 start。显示器选择增加 screens.first 回退。
- 安装器使用内容哈希文件名和 v2 条目，备份后只替换原观察桥；已通过健康文件验证热加载。健康文件 `Application Support/WhaleGirl/integrations/dsh-observer-health.json` 仅包含版本、PID、活动数量、时间，无对话内容。
- 真实运行 App 的本地 IPC 回放生成两只可见窗口（并非仅回调 mock）；不调用任何模型。50 个真实模型任务已在此前完成，因此当前活动数为 0，不复活旧任务。50 只桌宠并发渲染性能未测试。


## Finder 启动的 CLI 环境

后台 helper 为子进程补齐 Homebrew 与用户 local bin 路径，保留已有环境优先级；不执行 shell 配置文件。npm 安装的 Codex 启动器需要 Node.js，精简的 Finder PATH 原先会让它直接退出，被误标为超时。现在 EOF 直接标记不可用，真正超过查询时限才标记超时，并完整关闭进程管道。最终应用包中的脚本已在精简 PATH 下实读成功。Codex 显示提供方实际的 5 小时/周剩余百分比，DSH 显示钱包余额。


回复完成气泡与各工具的实际接入状态见 [REPLY_NOTIFICATIONS.md](REPLY_NOTIFICATIONS.md)。额度可读不代表该工具的完成事件已接入。

默认设置和快照目录随用户文案移至 Application Support/WhaleGirl/UserData；应用启动不探测或迁移旧 Documents 目录。此次本机升级已无覆盖复制并校验旧配置；其它安装需主动复制旧配置和 AI额度 子目录。显式自定义 snapshotPath 若指向受保护目录，仍受系统文件授权控制。


## 20:00更新的边界

挥手使用原有经典素材 full.community.b5987c85ef9d（120帧、10秒），是实际挥手动作。正常提前准备并在退场期限前播放；若加载或播放较迟，允许播完再退出，最多15秒保护等待。恢复工作会取消旧倒计时与挥手，手动桌宠不受影响。一键关闭及关闭自动生成功能会直接清理其管理的角色。公开任务标签缺失时仅展示真实ID与中性结束提示，无法据此证明具体成果。

UI参考与验证见 [晚间设计约定](../design/AGENT_COMPANIONS_UI.md)。系统减少透明度/增强对比度采用不透明浅蓝底；说明文字不透明，网络速率与容量分行，设置为原生双列选项。


## 2026-10-22 桌面软件接入口

旧内置Gemini/Grok/OpenCode数据来源自动迁移并保留开关，迁移前保留 `.before-native-sources.bak`；自定义快照不迁移。Gemini CLI、Grok Build CLI改为单独的默认关闭项目。完整使用步骤、各官方来源、需手动授权/重载及未公开接口的限制见 [软件接入说明](../usage/AI_CONNECTORS.md)。原来的“登录后自动读取”不适用于尚未开放外部接口的桌面版。


## Agent stage lifecycle (2026-10-22)

Automatic desktop pets now include active main sessions as well as delegated children. A fresh working/tool-start event is required for an unknown main session; an explicitly identified DSH running heartbeat can recover a missed start. Opening an idle application is insufficient. Main and child identities use separate keys, share animation resources, and preserve manual pets. A main pet shows occasional generic thinking lines about every 12–25 seconds while observed working, never real chain-of-thought; existing visible bubbles, paused/hidden/fullscreen pets are left alone. Waiting for input/approval stops these lines.

Child completion does not send a system notification or menu-head completion reminder. Its existing local farewell lifecycle remains: a stable random 10–20-second countdown, the verified classic wave where available, then a 3.6-second rise with a soft golden halo and a large-radius downward-bulging, feathered circular wipe over halo and body. Resumed work cancels the departure and restores position/opacity. Rise and wipe travel equal distances at constant speed; halo and body share the same curved mask. Reduced motion fades in place. No dedicated entrance clip was identified in the current catalog; automatic pets use a brief fade-in rather than substituting unrelated artwork. The taskbar tail is unchanged.

Ordinary main completion also avoids Notification Center duplication; the existing ten-second root reply peek remains. Failures, waiting input and approval notifications retain their existing switches. Native Gemini/Grok desktop apps without a supported activity source still cannot be inferred as working from login or process presence. All providers require their real event connector; no invented API or model test is used.
