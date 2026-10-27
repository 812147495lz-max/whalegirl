# WhaleGirl 开发守则

## 真实状态

- 规格和测试夹具不等于生产功能。只有实际写入仓库并在目标环境构建或运行的内容才能标记为已实现。
- 一次只推进当前 Phase。未实测的权限、性能、点击穿透、多显示器和外部系统行为必须明确写成未测。
- XCTest 通过不等于端到端验收通过。

## 代码边界

- 使用 Swift 6、AppKit 和 Core Animation；UI 类型标注 `@MainActor`，可测试的纯逻辑放在 Swift Package。
- Phase 03 前不引入网络或数据库。Phase 01 不接入 Agent、Finder、邮箱、系统指标或 AI。
- 模式与情绪分离；六种 `PresentationMode` 只表达位置/展示状态。
- Sprite manifest 保持 `schemaVersion = 1`，必须验证帧、持续时间、锚点、视觉边界和 hitbox。
- 透明窗口只在角色 hitbox 内接受主动交互，不得仅凭 `NSView.hitTest = nil` 声称整个窗口点击穿透。
- 美术素材必须记录来源、锁定提交、许可文本和角色署名。当前发布素材来自 `vlln/whale-girl@9c32d7a`，MIT 全文与 ZipZipPipe 署名不得删除。

## 每期移交

`HANDOFF.md` 必须记录可验证功能、构建/测试命令和退出码、环境、证据路径、通过/失败/跳过项、权限和性能的真实状态、可复用接口、风险、ADR 与最小回滚步骤。

提交和日志不得包含真实用户名、邮箱、token、prompt 原文或机器专属绝对路径。

## 按模块开发

先读根目录`MODULES.md`，根据需求仅读取对应模块及直接依赖；查旧决定才读历史文档。主入口负责初始化和连接，业务写入对应功能文件。新增源码必须注册Xcode Sources，不增加没有实际需要的插件加载层。
