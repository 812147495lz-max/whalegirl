# 探头式 AI 回复完成提醒

主会话正常完成一轮回复后，鲸鱼娘从图标下探头，复用日常探头的玻璃对话框显示“Codex 回复完成啦”。气泡在探头动画约2/3时出现，顶部有指向角色的小箭头。显示10秒后，角色播放原 disappear 动画收回，气泡同步向下漂移淡出。没有另一套独立蓝色横条。

连续完成事件合并软件名，并从最新一条提醒重新计时10秒；鼠标移出不提前收回，眨眼不会替换完成文案。用户明确固定探头时保留固定状态。若正在查看下落展示的电脑面板，提醒暂存，收回面板并经过既有1秒冷却后再探头提醒。手动进入信息展示可结束当前提示，卸载/退出取消提醒任务。安静模式、全屏避让、软件完成事件的身份/去重规则保持。

日常悬停气泡也使用同一顶部箭头；短文案自动收窄，长文案换行。入场采用淡入和轻微位移，避免缩小原生窗口时裁掉文字。探头素材优先于独立尾巴插帧准备，冷启动无需等尾巴计算完成。

## 接入状态

| 工具 | 完成事件 | 当前机器状态 |
|---|---|---|
| Codex | 既有本地插件 Stop → agent.turn_completed | 保留已安装插件；原生 Hook 未加载时需新会话/原生审核 |
| DSH | session/event 的 turn/end，reason.kind=completed，且该 turn 观察到 step/start | 观察桥 v4 已热加载；排除子代理、取消、错误及空输入 |
| Cursor | beforeSubmitPrompt / stop(status=completed) | 已写入用户 hooks.json，原工具重载后生效 |
| OpenCode | session.status busy → session.idle | 已安装自动加载插件；已观察失败和子会话不报成功，重开 OpenCode 后生效 |
| Gemini CLI（独立项目） | BeforeAgent / AfterAgent | 已配置用户 settings.json；CLI 使用时加载，不是 Gemini 网页版或原生 Gemini.app |
| Copilot CLI | userPromptSubmitted / agentStop | 已配置独立用户 hooks 文件；不是云端 agent 或 VS Code Copilot 聊天 |
| Claude Code | UserPromptSubmit / Stop | 当前未安装，通用安装器与原生插件源码已备好 |
| Grok Build CLI（独立项目） | UserPromptSubmit / Stop(reason=end_turn) | 当前未安装，通用安装器已备好；识别 Grok 导入的 Cursor/Claude 兼容 hook 来源 |
| 其他工具 | 本地 WhaleEvent agent.turn_completed + metadata.provider | 接口可接入，不推测网页或任意应用进程的回复状态 |

本机 hook 安装器位于 `WhaleGirl.app/Contents/Resources/AIMonitor/ReplyHooks/install.py`，以后新增工具后可用 `/usr/bin/python3` 执行。只对存在相应用户目录/应用的工具配置监听，备份并合并设置；不改原生信任开关，不触发推理。原生工具禁用 Hook、工作区未信任或要求审核时，遵守其原有流程；不绕过。未重启其他用户应用或会话。

Grok/Claude 等 Stop 钩子可能在其他阻断钩子继续模型之前触发；上游没有一致的跨工具最终确认，不能保证所有阻断/重试组合都能完美判断。网页和云端工具没有本地完成事件时，本版不以额度、CPU 或进程存活伪装回复完成。

## 隐私与去重

气泡只展示软件名和完成状态，不展示模型回答。适配器不转发或保存 prompt、回复内容、工具参数、邮箱或 transcript 路径；原生 hook 的 stdin 可能自带这些字段，脚本只投影允许的身份/状态字段，原始输入不落盘。

WhaleEvent v1 元数据白名单增加 provider（其余边界保持），用于 Gemini/Grok/Cursor/Copilot/OpenCode/Claude 名称。按来源、实例、主会话去重；历史超过 60 秒的事件不提醒，旧序号不能覆盖新一轮。sessionEnd、工具结束、错误、子代理结束不当作主回复完成；新一轮 working/start 重新允许提醒，独立于自动生成桌宠开关。

## 验证

- 纯逻辑：2 项 ReplyCompletionTests，覆盖软件名称、根/子区分、去重、下一轮恢复、过期/乱序、工具/退出/错误过滤；与 8 项 AIMonitor、5 项事件协议测试一起通过。
- Python：12 项集成测试通过，包含多厂商身份格式、Cursor/Grok 失败/退出过滤、敏感字段丢弃、Grok 兼容来源识别。
- Node：真实临时 Unix socket fixture 验证 DSH root 成功、重复 turn、取消/错误、无 step/无 agent 排除，原 40 子代理与重连/失联回归保持通过。
- 原生：气泡合并、文字宽度、屏幕边界、点击穿透、全屏抑制与自动消失测试通过。首轮暴露 NSAnimationContext 异步重载，已修正；随后测试环境全屏抑制造成无 panel，改用显式策略注入，抑制分支也独立验证。视觉检查发现末字换行裁切，增加内边距后完整渲染，见 evidence/reply-bubble-final。
- 运行版收到两条本地模拟主完成事件（Codex/Gemini），成功解码且新增 provider 字段被接受；这不是实际调用各家模型或网页端端到端验收。未消耗模型额度测试，未做多屏/Spaces/高并发性能重测。

## 回滚

退出 ReplyNotify，打开保留的 QuotaFix。各厂商 hook 恢复对应 `.whalegirl-backup-*.bak` 或删除独立的 whalegirl-replies 文件即可；DSH 恢复修复前 patch 备份。保留额度、用户 CSV 与素材。

主要接口来源：[Gemini CLI Hooks](https://geminicli.com/docs/hooks/reference/)、[Cursor Hooks](https://cursor.com/docs/hooks)、[OpenCode Plugins](https://opencode.ai/docs/plugins/)、[Copilot Hooks](https://docs.github.com/en/copilot/reference/hooks-reference)、[Claude Code Hooks](https://code.claude.com/docs/en/hooks)、[Grok Build Hooks](https://github.com/xai-org/grok-build/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/10-hooks.md)。

后续原生测试覆盖实际10秒停留、鼠标移出仍保持、合并完成文案、眨眼后文案保留、带箭头的气泡路径、结束收回及卸载清理；证据见 evidence/reply-peek。此前 evidence/reply-bubble* 为已替换的独立提示框，仅作历史记录。


2026-10-22：增加原生桌面软件额度入口、逐来源说明及一键安装/修复官方事件接入。OpenCode插件通过注入SDK补查未知会话父子关系，处理status.idle和旧session.idle、排除重复/失败，真实子会话活动可生成桌宠；未获父子关系则不报完成。Claude/Cursor/Copilot钩子仅在提供真实父子ID时生成子代理角色；Copilot某些start事件没有唯一ID，不用名称伪造。Gemini/Grok CLI的完成名与桌面版区分。软件运行状态只由有效新事件更新，5分钟无更新注明过期。Gemini.app/Grok Bot目前未接通官方既有回复完成接口，不能凭读到额度就称提醒生效。详见 [AI_CONNECTORS](../usage/AI_CONNECTORS.md)。


2026-10-22: routine turn/session completions are explicitly excluded from macOS Notification Center in both coordinator policy and delivery service. Only main turn completion drives the existing hanging peek; delegated completion stays in the child pet lifecycle. Failure/input/approval notifications remain enabled according to user settings. Previously delivered notifications are not new events and may remain until dismissed.
