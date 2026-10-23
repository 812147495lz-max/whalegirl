# whalegirl

macOS 菜单栏鲸鱼娘与桌宠，支持系统信息展示、AI 工具额度面板，以及基于真实工作事件的 Agent 陪伴。

**当前版本：v1.5 · macOS 14+ · Apple silicon / Intel Universal**

## 下载与安装

在 [Releases](https://github.com/812147495lz-max/whalegirl/releases/latest) 下载 `WhaleGirl-v1.5-Universal.dmg`，打开后把 `WhaleGirl.app` 拖入 Applications。也提供 ZIP，解压后移动到 Applications。

当前发行使用本地 ad-hoc 签名，未经过 Apple 公证；macOS 可能显示来源或安全提示。安装包的 SHA-256 见 Release 附件 `SHA256SUMS-v1.5.txt`。

## v1.5 更新

- 紧凑统一的信息卡；CPU、GPU、内存、网络、电池、温度折线图可分别开关，时间范围只显示一次。
- 网络测速支持常用站点或自定义网址/IP、逐跳 IP/延迟与详情设置；仅主动点击后测试。内外网 IPv4/IPv6 完整显示并统一右对齐。
- 可切换两列小型双环额度仪表：内圈/上方为小时剩余，外圈/下方为周剩余；文字模式同样右对齐，有真实重置时间才显示倒计时。
- DSH 主 Agent 在右下角保持工作，优先工作/表情与偷吃 Token 动作；气泡显示余额、今日已观测消费和转峰/转谷时间。DSH 余额环默认满量程50元，可修改。
- Codex 实际额度恢复后提醒一次；主 Agent 回复/会话完成提醒附带可读取的剩余额度。
- 菜单栏尾巴改用连续时间调速，保留25%负载约15FPS、99%约45FPS的目标范围，减少变速滞后和计时延迟积累。

DSH 今日已用基于独立余额观察，首次成功读取才建立基线，部分当日数据和充值调整会标记；不是完整官方账单。Gemini/Grok 桌面版的额度限制不因本次更新改变。详见 [实时指标](docs/usage/LIVE_METRICS.md)、[网络诊断](docs/usage/NETWORK_DIAGNOSTICS.md) 与 [DSH 余额桌宠](docs/usage/DSH_BALANCE_COMPANION.md)。

## 功能

- 菜单栏角色动画随 CPU 负载调速，可通过滑杆缩放；左击冒出漂浮爱心，悬停探头、眨眼和随机气泡。
- 右键进入绳索下落和电脑信息展示；展示时左键打开菜单、右键收回，收回后有 1 秒悬停冷却。
- 从菜单栏拖出多只桌宠，分别拖动、缩放、换素材系列、指定动作或关闭；支持全部关闭。
- 动作间回到默认状态，经典系列随机动作后横向溜达；动画资源共享并后台准备，共用移动时钟。
- 系统信息可独立选择型号、CPU、GPU、内存、电池、存储、网络、温度等；无法获取时显示不可用。
- AI 额度项目可独立开关；额度查询和 Agent 工作事件分别接入。
- 主 Agent 与子代理收到真实工作事件后生成桌宠；主 Agent 工作时显示通用思考文案，DSH 主 Agent 显示余额气泡；不读取模型推理内容。
- 主 Agent 一轮完成后，菜单栏探头气泡提醒 10 秒；子代理完成不触发系统通知或探头提醒。
- 自动桌宠完成后等待 10–20 秒退场，带挥手、柔光光环、上升和圆弧羽化擦除；恢复工作会取消退场。手动桌宠不受自动回收影响。
- 气泡文案使用外部 CSV，可编辑后即时用于下一条气泡。

## AI 接入状态

| 项目 | 当前状态 |
|---|---|
| Codex | 本机 app-server 额度读取；原生 Hook 事件桥 |
| DSH | 既有账号余额读取；主代理心跳、子代理和重连事件桥 |
| OpenCode | Go 额度适配器；官方插件事件桥 |
| Cursor、Gemini CLI、Copilot 等 | 按工具提供额度兼容后端或事件桥；部分事件需在工具中重载并授权 |
| Gemini 桌面版 | macOS 辅助功能读取用量页，需打开“设置 → 用量限额”；这不是内部额度 API 接通 |
| Grok Bot 桌面版 | 当前自动额度读取未接通，明确显示不可读取；不会用登录状态或截图数字伪造额度 |

完整安装、权限和能力边界见 [AI 接入说明](docs/usage/AI_CONNECTORS.md)。后台兼容接口并非全部是公开稳定 API。存在适配器或单元测试不等于所有提供方都已完成真实模型端到端验收。

## 使用

1. 启动后在菜单栏找到鲸鱼娘；中键或 Option+右键可打开控制菜单。
2. 左击产生爱心，悬停显示探头，右键展示电脑信息；从菜单栏向下拖动可生成桌宠。
3. 在“选择 AI 工具”里启用需要的项目，再按对应工具说明接入。
4. 用“编辑气泡文案 CSV”调整台词。用户数据独立保存在 `~/Library/Application Support/WhaleGirl/UserData/`，不随仓库发布。

更多说明：[气泡 CSV](docs/usage/SPEECH_CSV.md) · [系统指标](docs/usage/SYSTEM_METRICS.md) · [完成提醒](docs/phase2/REPLY_NOTIFICATIONS.md)

## 从源码构建

需要支持 Swift 6 的 Xcode。当前所有运行资源及额度辅助程序均包含在仓库中，不需要导入工作目录或开发者账号。

```bash
git clone https://github.com/812147495lz-max/whalegirl.git
cd whalegirl
xcodebuild -project WhaleGirl.xcodeproj -scheme WhaleGirl \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$PWD/.build/xcode" -jobs 2 build
```

产物位于 `.build/xcode/Build/Products/Release/WhaleGirl.app`。配置目标为 macOS 14+，Release 包含 arm64 与 x86_64。

```bash
swift test --package-path Packages/WhaleCore --scratch-path "$PWD/.build/core"
python3 -m unittest discover -s Tests/Integration -p 'test_*.py'
node Tests/Integration/test_dsh_bridge.mjs
node Tests/Integration/test_opencode_bridge.mjs
```

构建不会自动安装工具 Hook，也不会替用户接受原生工具的信任和系统权限提示。

## 已验证与限制

- 实际构建和运行验证在 Apple silicon/macOS 26.6.2 上完成；Universal 架构、macOS 14 部署目标、归档完整性及签名另行校验。
- 既有原生动画、Agent 生命周期、协议、额度解析和面板有回归检查；近期8个动画计时与4个余额观察用例通过。v1.5 仅改版本/发布资料并重新构建、检查安装包，未重新运行全套测试。
- Intel 实机、所有 AI 软件的真实模型运行、多显示器切换和大量桌宠长期性能尚未全面验收。
- 保留全屏避让；“支持”的代码路径不代表所有 Spaces/全屏/硬件组合均完成实机验收。

版本说明见 [v1.5](docs/releases/v1.5.md)（[首版 v1.0](docs/releases/v1.0.md)），开发边界与验证说明见 [HANDOFF.md](HANDOFF.md)。

## 素材与许可

应用自有代码按 [MIT License](LICENSE) 发布。**第三方素材按各自许可使用，不因仓库代码采用 MIT 而自动获得相同许可。**

- 经典鲸鱼娘素材来自 `vlln/whale-girl`、`PC2005-cloud/dsh-pet`、`yanzwzz/dsh-whale-girl-pet`，保留锁定版本、MIT 全文和 ZipZipPipe 角色署名。
- 赤风RED系列及提供的动画保留作者、来源和独立许可说明；发布方已确认本次公开分发许可，不代表授予第三方任意复用权。
- 内置 CodexBarCLI 与相关依赖保留各自许可证和致谢。

详见 [总声明](licenses/NOTICE.md)、[素材归属](Assets/attribution.json)、[赤风RED素材说明](Apps/macOS/Resources/CommunityActions/red-ART-NOTICE.md) 和 [额度后端声明](Apps/macOS/Resources/AIMonitor/NOTICE.md)。本项目不声称与 DeepSeek 或其他 AI 提供方存在官方关联。

现有 CI 配置保留为 [`docs/ci/ci.yml.example`](docs/ci/ci.yml.example)，首版发布使用上述本地验证结果；尚未启用 GitHub Actions。
