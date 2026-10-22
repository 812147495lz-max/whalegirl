# WhaleGirl：macOS 原生鲸鱼娘桌宠——详细技术设计与实施手册

> **文档版本**：V3.5（七项深度审计缺陷修订）
> **日期**：2026-10-12  
> **需求基线**：《WhaleGirl 总体开发方案 V1.2（按截图比例修订）》  
> **首发平台**：macOS / Apple Silicon，优先 MacBook Air M4；Windows 4K 是显示适配目标与后续移植方向，不代表 Swift 构建可以直接跨平台  
> **交付目标**：能本地构建、能独立常驻、可关闭所有网络能力、无需多套宠物程序同时运行  
> **约束**：桌宠新增的 AI API 费用每天不超过 ¥2；日常动作不调用 LLM；未经授权不控制桌面或改变文件  
> **性质**：架构蓝图 + 接口契约 + 实施步骤 + 测试门槛；代码片段为参考样例，最终须按锁定依赖的实际签名编译调整。

---

## V3.1 历史修订声明与实施边界（以 V3.5 附录为准）（2026-10-12）

**封存范围**：本次修订封存的是产品需求 V1.2 + 技术规范 V3.1 + 可执行的 Swift 协议核心与 SQLite 参考实现及测试；**尚未完成 macOS App**、Codex/DSH 真机端到端接入、Finder 真实互动、邮件读取及素材商业授权。不得将本 ZIP 称为可安装桌宠、完整 Alpha 或已完成全部 P2 的产品实现。

**审计 P1 修复（代码、SQL、测试共同约束）**：

1. 输入边界先执行 16 KiB 上限与嵌套 JSON 重复键检验，再按 `WhaleEventCodec` 验证真正公历日期、合法时分秒及整秒 RFC3339；拒绝无效小时、非闰年 2 月 29 日、小数秒和多余字段。正则仅用于格式初筛。
2. `SecureEventRules` 强制来源/事件类型配对、关键事件 severity 匹配、标识符长度及不含路径；`metadata.client`/`approvalKind` 只接受固定枚举值。`summary` 拒绝明显密钥/本机绝对路径词形；由于自由文本无法保证识别全部秘密，正式落盘应优先采用**由适配器生成的安全状态模板**，不持久化 Agent 回复原文。永不打印原始 NDJSON。
3. `displayTarget.kind` 与参数配对，外部 HTTPS URL 默认只接受有限 host 集合，真正点击必须由用户发起并由 UI 再校验；未经用户显式设置不得访问局域网、回环地址或执行任意文件/命令。
4. `tests/sql/migrate_events_v3.py` 提供离线旧 events 表重建参考实现：显式确认、先 SQLite 备份（权限 0600）、`BEGIN IMMEDIATE`、旧数据校验/敏感投影、仅记录拒绝事件的脱敏 ID 与原因、新表和索引原子切换；迁移前关闭程序。**历史备份可能含敏感数据，须由用户妥善保管/删除**。该参考脚本非正式 App 内迁移器，不得自动替用户库执行。
5. `DSHApprovalResolver` 加入 `(sourceInstance,sessionId,generation,capturedAt)` 一致性与 120 秒默认 TTL；只凭被验证的 MoodBall 或审计源确认等待审批。上游真实 payload 仍需验证。

**审计 P2 修复与未封存项**：

- 新库 SQLite 针对 source/severity/事件族配对、severity 关键取值、非负序号、JSON 类型、metadata 字节数、标识符基本范围、费用与 token 非负数强化 CHECK。SQL 不承担全部业务内容过滤；SQLite 时间完整日历语义与 URL 安全仍以入站 codec 为准。
- `reference/budget_ledger.py` 是 **SQLite 原子预留/确认与并发回归参考实现**，金额单位人民币百万分之一元，单日上限 2,000,000。请求超时必须保留预留；真正调用 DeepSeek 前要预留最坏情况费用并按实际价格模型计算。费用超出预留视为错误，不应允许已经发出的超额外部调用。
- `scripts/doc_check.py` 对 source/severity/privacyClass 的 SQL CHECK **做集合相等**，不再只靠单个非法输入拒绝。新增手动把 `guest` 加到 CHECK 的突变测试。CI 和脚本用稳定路径，不依赖中文文件名。
- 封存不是停止研发：macOS 的 `EventHub → SessionReducer → SQLite → UI` 实体、Socket 服务、真实 Agent Hook、Dock/Finder 系统权限与 72 小时能耗测试仍是**Phase 0/1 必须实机完成**的门槛；不得因为合同测试通过就宣称功能已交付。

本节是 V3 决议，**优先于下文保留的 V2.x 历史审计叙述及仍明确标为“伪代码/目标”的章节**。数据库 Wire `schemaVersion=1` 与产品技术规格版本 V3.5 分属不同维度。数据库 `schema_migrations=3` 为结构迁移版本，不是 Wire v3。

---

## 0. 读者与实施决策

本手册面向负责实现 WhaleGirl 的 Codex / DeepSeek Harness / Swift 开发者、负责素材整理的美术，以及后续 Windows 移植开发者。与需求 V1.2 不一致时，以用户最新确定的交互形态与比例为准；第 4.1 节的尺寸规范以 V1.2 截图比例为基准；不要参考旧版 V1.1 尺寸。

**实施决策：**

1. **Fork AgentPet 为主干**，但保留“审计后替换”的出口。优先复用事件/会话领域逻辑与 **Codex Hook 安装器**，并在源码审计后**重写或加固其 Unix Socket Server**；上游的 Socket 路径抢占/权限行为不能直接照抄。
2. **RunRat 作为系统指标和状态栏实现参考**，按许可与依赖审查后移植需要的 `StatusBarController` / `SystemMetricsMonitor` 能力。WhaleGirl 最终只显示一个菜单栏图标、一个主面板、一组可显隐的宠物透明窗。
3. **DSH Pet 作为 DSH 适配参考**：优先兼容其状态 JSON 与 `moodball.sock` 机制；正式产品决定统一为 WhaleGirl 自己的协议与 Socket 前，要做好兼容层和迁移策略。DSH 插件仅负责发送状态，不承载动画。
4. **whale-girl 作为动作语义与原型图集来源**：它的 15 状态 manifest、每帧 256×256、横向 sheet 等是上游格式，不能不加变更地视为三套屏幕尺寸的最终素材。公开分发前要解决**角色及图集授权**。
5. Aibo 用来参考自主行为；QiuQiu 用来参考多会话汇总；OpenPets 仅是第三方控制接口的参考来源。**这三个项目仅做源码审计，不增加独立常驻进程，也不作为构建依赖。**
6. **先做 macOS MVP，再考虑 Windows**。未来 Windows 采用独立 UI 宿主（例如 Tauri/Rust 或其他平台原生技术），共享事件 JSON/资产规范与测试用例。不要现在为了跨平台而拖入 WebView 或跨平台大运行时。

### 0.1 必须交付的实际体验

- 菜单栏最小头像：待机、眨眼、状态标识；点击打开系统状态和任务面板。
- 菜单栏下沿 Peek：自动或鼠标触发探头、挥手、举信封、举提示牌，角色可缩回。
- 较大的主动鼠标互动：跟随指针、摸头、戳脸、拖拽、抗议；不抢焦点。
- 空闲桌面游荡：跳落、行走、围观 Dock / Finder 图标、踢、抱、假装吃、回到菜单栏。所有“文件变化”都是视觉表现。
- Codex + DSH 的多会话状态与待处理提醒；邮箱新邮件；CPU、内存、网络、电池、磁盘指标；活动监视器入口。
- 本地台词、随机小剧场、必要时低频 DeepSeek API；断网时核心功能依旧工作。

### 0.2 优先级与范围

| 级别 | 能力 | 交付阶段 |
|---|---|---|
| P0 | 菜单栏、基本状态栏图像、系统面板、事件协议、Codex/DSH 通知、去重、设置 | MVP |
| P0 | 安全、点击穿透、退出清理、可控性能与独立素材小头像 | MVP |
| P1 | 探头、大型鼠标互动、复杂动画、场景冷却机制 | 第二阶段 |
| P1 | IMAP 新邮件、独立桌面游荡、Finder 视觉交互 | 第三阶段 |
| P2 | AI 性格、额度监控、跨设备事件、ComfyUI、精细长时统计 | 第四阶段 |
| 排除 | 任意文件的真实删除/移动、未经用户确认直接批准 Agent 高风险命令、持续上传屏幕画面 | 全版本 |

---

### 0.3 P0 缺陷修订与证据状态（V2.1 → V2.2）

本版回应实测审查，**覆盖** V2.0/V2.1 冲突章节，不能只把本段当作补丁而继续照旧代码实施。

| 编号 | V2.0 问题 | 当前延续的决议 | 必测 |
|---|---|---|---|
| P0-01 | `Date` 默认 JSON 解码失败且 `try?` 静默丢事件 | `JSONDecoder.dateDecodingStrategy = .iso8601`；拒绝/计数/诊断并验证 JSON 样例 | `PROTO-DATE-*` |
| P0-02 | Codex 以 `notify` 作为关键事件路径 | `~/.codex/hooks.json` + `PermissionRequest/Stop` 等 Hooks 为主；notify 仅补充回合完成 | `CODEX-HOOK-*` |
| P0-03 | 上游 Socket 存在无条件 `unlink` / 缺少凭据校验等风险 | WhaleGirl 自有路径和实例所有权；权限、`getpeereid`、崩溃恢复 | `IPC-SEC-*` |
| P0-04 | DSH 在 `agent/request-error` 订阅时截断 waterfall，且 `session/event` 少接参数 | 仅读 `emit` 事件；`session/event(session,event)`；不订阅 waterfall | `DSH-EVENT-*` |
| CONSISTENCY | summary、DTO/SQL、动画、帧率、AI 次数、压力测试等不一致 | 单一契约+同名枚举+统一阈值+迁移 SQL；CI 中做静态一致性校验 | `DOC-CHECK-*` |

用户机器上仅找到 V1.0 与本会话已生成 V1.2 **并不矛盾**：V1.2 是本会话生成的文件，不代表它已自动保存到用户的 Downloads/Desktop/Documents。开发时务必将 V1.2 与本 V2.4 两份文件放在仓库的 `docs/` 下，不能只按 V1.0 开工。

### 0.4 V2.3 新增阻断项

| ID | 缺陷 / 结论 | 修订位置 | 可执行验证 |
|---|---|---|---|
| P0-05 | DSH `waiting_approval`/`waiting_input` 缺确定来源 | §8.1–8.2、§3.6、Phase 1 | DSH-APPROVAL-001/002/003；DSH-AUDIT-001 |
| P0-06 | `.iso8601` 不能强制整秒 RFC3339 | §3.2、§3.5 | SwiftPM `testRejectFractionalSeconds` 等 |
| P0-07 | CI 没有实际 XCTest/SQL 负例/文档检查 | §15.1、scripts、tests | `swift test` + `schema_negative_test.py` + `doc_check.py` |
| P1-01 | V1.2 标题、Release 500 次矩阵编号残留 | §4.1、§15.1 | DOC-CHECK-001 |
| P1-02 | Codex Hooks 多来源合并/组织禁用规则遗漏 | §7.1 | CODEX-HOOK-* 真机 PoC |
| P1-03 | DSH 子 Agent 生命周期靠 `session/event` 推断 | §3.6、§8.2 | DSH-PARENT-001 |

**验证等级划分**：本交付包已经执行的为跨平台纯协议 XCTest、SQLite schema CHECK 负例和静态文档检查；MoodBall Socket 原始字段、Codex Hooks 的实际覆盖率、DSH Web/Desktop Profile、macOS UI 均仍需用户设备实测，不会在本文件中伪称已经通过。

### 0.5 V2.3 精准修订范围（不得当成新增已实现的产品功能）

- **P1-01 消灭 fixture 死数据**：三种 `assetVariants` 与六种 `presentationModes` 分离；§10.1 的 Swift 源、交付包的可编译 Swift 源、fixture 三者按完整枚举集合校验，避免注释“提到过就算通过”。
- **P1-02 契约全字段对齐**：`fixtures/wire_contract.json` 显式定义完整的 16 个 Wire 字段及对应 Swift 类型、SQLite 列名、非空性和投影策略；`doc_check.py` 实际解析 §3.2 JSON、WhaleEvent `public let` 属性与 SQLite `PRAGMA table_info(events)`，按集合相等比较。`events.read_at` 明确标为存储专用字段。SQL 附加 `event_id NOT NULL`；错误负例测试覆盖。
- **P2-01 新增 HTTP 读取候选**：MoodBall README 的 `/api/moodball/status` 是现有上游 fallback 描述，**尚未证明 WhaleGirl 在任意目标版本可直接访问**；仅列为 Phase 0 read-only PoC，不承诺生产可用。
- **P2-02 CI 加固**：文档固定为 `docs/technical-spec.md`、通过 `technicalSpecVersion` 核对文档头；GitHub Actions 显式最小权限并将 checkout 固定完整 commit SHA；移除浮动的 `swift-actions/setup-swift`，改用 Swift 6.2.1 容器。该容器仍需 GitHub Actions 首次运行验证，镜像 tag 非不可变 digest。
- **防自欺**：`tests/contract/check_mutations.py` 在临时副本中注入 10 类错误并断言校验器必定失败；这不是纯字符串存在性检查。Swift 协议用例与 SQLite 负例另行执行；以上均不等于 macOS/DSH/Codex 真机测试。

### 0.6 V2.4 协议边界及自动化修复（基于 V2.3）

| 编号 | 已证实风险 | V2.4 可执行防护与验收 |
|---|---|---|
| V24-01 | §3.2 summary 200 可私自改 250 仍通过文档检查 | 固定 `summaryMaxScalars=200`、`summaryMaxUTF8Bytes=800`，比较 §3.2 和 §3.5 的值、Swift 限额常量与边界 XCTest；突变后 doc_check 必须失败 |
| V24-02 | §3.3 删除 `agent.waiting_approval` 仍不被检测 | 全量解析 §3.3 枚举代码块，比较 fixture、Swift `allowedEventTypes` 与 SQLite `event_type` CHECK；删除或添加一项必报错 |
| V24-03 | 未知事件类型可通过 WhaleEventCodec | Codec 在 `decode()` 入站处直接拒绝未知类型，新增 XCTest 和 SQL 负例 |
| V24-04 | metadata 任意键、`file:` URI 可通过解码 | 严格键名白名单与安全 URI 策略；不记录或转发原始 prompt、密码及不可信 URL；新增 XCTest |
| V24-05 | 原测试没有证明 SQL CHECK 删除必被 CI 拦截 | 统一突变测试加入两条删除 CHECK、两条文档破坏、Codec 常量改变及 SQL 事件白名单破坏；同时保留 SQL 负例测试 |

上述属于**本交付包中的可运行协议层与测试修复**，不是已经开发完 EventHub、Finder 或 macOS 桌宠。当前未交付 macOS UI、Codex/DSH 真实端到端接入。时间精度仍为严格整秒 RFC3339。

## 1. 开源项目审计与代码复用清单

### 1.1 版本冻结原则

**不要使用浮动的 `main` 直接做正式构建。** Phase 0 首日必须记录下表字段：

| 仓库 | 职责 | 待记录的信息 | 开工判定 |
|---|---|---|---|
| `ntd4996/agentpet` | 主框架、状态处理、Codex、宠物包 | commit SHA、LICENSE、SwiftPM targets、Hook 安装方式 | 能在本机完整编译并接收模拟事件 |
| `Lolretrorat/runrat` | 状态栏、系统指标 | SHA、原作者依赖/NOTICE、macOS 采样接口 | 能独立采样并释放资源 |
| `sundusk/dsh-pet` | DSH 事件适配 | SHA、Socket JSON 样本、web/desktop 安装流程 | 实机 DSH 能复现 running/wait/done/error |
| `vlln/whale-girl` | 动作命名、sheet、manifest | SHA、素材来源、可重分发许可 | 图集加载成功；发布授权单独确认 |
| `omdsh-dev/dsh-gal` | 动作编排借鉴 | SHA、行为事件、图集权属 | 只参考交互机制 |
| `jc98629/my-cat-desktop-pet` | 状态聚合借鉴 | SHA、去重/并行行为测试 | 能复述和实现其边界条件 |
| `alterhq/openpets` | 第三方控制接口参考，不做依赖 | SHA、协议、授权与暴露面 | 仅形成 ADR，不要求运行 |

审计命令模板（仅用于本地实际拉取后执行）：

```bash
mkdir -p ~/Projects/WhaleGirl/vendor-audit
cd ~/Projects/WhaleGirl/vendor-audit
git clone https://github.com/ntd4996/agentpet.git
git clone https://github.com/Lolretrorat/runrat.git
git clone https://github.com/sundusk/dsh-pet.git
git clone https://github.com/vlln/whale-girl.git
# 下列仅作设计审计，不进入 WhaleGirl 构建依赖
 git clone https://github.com/omdsh-dev/dsh-gal.git
 git clone https://github.com/jc98629/my-cat-desktop-pet.git
 git clone https://github.com/alterhq/openpets.git
for dir in agentpet runrat dsh-pet whale-girl dsh-gal my-cat-desktop-pet openpets; do
  printf '%s\t' "$dir"
  git -C "$dir" rev-parse HEAD
done
```

以上仓库仅用于调查，正式工程应采用明确来源的 Fork、独立版权声明和精确依赖；如直接移植第三方代码，需要保留其许可文本与必要署名。AgentPet 应用代码 MIT 不代表社区宠物素材 MIT。`whale-girl` 原角色外观的权利来源须额外核实。

### 1.2 已核实的事实与未确认项

**已核实的公开信息（截至文档日期）：**

- AgentPet macOS 为 Swift/SwiftUI，SwiftPM `Package.swift` 定义 `AgentPetCore` + `agentpet` 可执行 target，macOS 13+、Swift 6；源码构建工具链要求 Xcode 16。现有宠物格式为 `pet.json` + spritesheet，Agent 状态来自本地 Unix Socket 事件。
- RunRat 的 `macos/` 提供 AppKit/SwiftUI 菜单栏、CPU/GPU/内存等读取和状态面板。
- DSH Pet 的 `dsh-moodball-status` 插件向用户目录下 `moodball.sock` 推送换行分隔状态 JSON；README 展示了“等待你的授权”和“做出你的抉择”两类明确状态，但 Socket 精确字段需采集真实脱敏 fixture 后确定；桌面版应在其独立 Desktop Profile 安装。
- whale-girl 有 15 种状态，图集与 manifest 校验机制明确；原图集规范单帧 256×256，按状态横排。
- Codex 官方 `notify` **当前只支持 `agent-turn-complete`**；审批/工具等事件以 Hooks（`~/.codex/hooks.json`）为首选。Hook 支持哪些客户端必须通过当前安装的 Codex 版本实测，不能把 CLI 的能力自动外推到 Desktop/IDE。`notify` 的 payload 可能含 `input-messages` 与 `last-assistant-message`，辅助程序应在输入边界显式丢弃。

**需要通过 PoC 证明：**

- AgentPet 每种 Codex 客户端事件的准确覆盖率：CLI、桌面 App、VS Code/IDE；是否可共存已有 notify/hook。
- DSH Pet Socket 状态格式、并发多个实例、重连、断线与泄漏敏感内容的可能性。
- macOS 状态栏按钮坐标、Peek 透明覆盖层可否在用户系统设置下保持稳定，是否影响菜单点击。
- Finder 可见桌面图标的 AX 坐标可靠性；多显示器/桌面隐藏/Stage Manager 条件下是否稳定。
- 所有美术图集的发布授权及重新绘制方案。

### 1.3 代码整合策略

- **Fork 后保留/借鉴 AgentPet 的 CodexHookConfig 安装逻辑**，但安装 Hook 必须做非破坏性合并、原子写入、用户批准、卸载回滚。
- **不能直接复用上游 EventSocketServer 作为安全边界**；源代码审计如确认其无条件 `unlink(path)` 且未执行权限与对端身份校验，则必须换成独立的 WhaleGirl SocketServer，不能碰 AgentPet 自有路径。
- 整合前先提交一次“纯上游可编译”提交，之后每个功能一个分支，以免把上游问题和新问题混合。
- RunRat 的指标采样模块做成适配接口，不在 WhaleGirl 中引入第二条 StatusBar 循环。
- DSH 的上游 JSON 在 **DSHAdapter** 内转换为 **WhaleEvent**，其他模块不得依赖 `moodball` 字段名。
- whale-girl 资产先通过工具脚本离线转换到 WhaleAsset 格式；不在运行时加载其 Node/DOM/CSS 代码。

---

## 2. 详细技术栈与系统依赖

| 领域 | 优先方案 | 具体用途与边界 |
|---|---|---|
| 语言 | Swift 6 | macOS 应用、业务状态、动画调度、系统桥接 |
| UI | AppKit + SwiftUI | AppKit：状态栏/透明 `NSPanel`/坐标/鼠标；SwiftUI：设置、任务卡片、仪表盘 |
| 动画 | Core Animation + `CALayer` + 图集离线切片 | Mini/Peek 少帧低负载动画；必要时 Full 可使用 SpriteKit，但先以 CA 实测 |
| 构建 | Swift Package Manager，Xcode 16+ | 以 AgentPet 包结构为起点；测试与依赖锁定 |
| 并发 | Swift `actor` / `async` / `Task` | 事件中心、采样调度、存储队列、AI 任务；UI 在 `MainActor` |
| 本地事件接收 | Unix Domain Socket（AF_UNIX）+ NDJSON | DSH/Codex Helper → Event Hub；仅本机、无需 HTTP 端口 |
| 兼容传输 | DSH 原状态 Socket/HTTP（仅适配） | 作为 DSHAdapter 输入；不默认暴露监听所有网卡的服务器 |
| 数据存储 | SQLite3（系统 SQLite）+ 可选轻量数据访问封装 | 事件去重、未读、历史、台词及消费流水 |
| 设置 | `UserDefaults` | 非敏感开关、尺寸、动效与通知规则 |
| 凭据 | Keychain / Security.framework | DeepSeek API key、邮箱 OAuth/IMAP 凭据 |
| 网络 | `URLSession` | 低频模型 API、邮件 OAuth 请求（按授权）、更新检查 |
| 本地通知 | UserNotifications | 关键 Agent 完成/审批、新邮件；尊重系统通知权限 |
| 启动登录 | `SMAppService` | 用户主动开启开机自启，不自行安装未授权后台服务 |
| 系统应用 | `NSWorkspace` | 前台应用识别、打开活动监视器、打开文件与邮件客户端 |
| 桌面结构 | Accessibility `AXUIElement`（可选） | 获授权后尝试获取 Finder 图标信息/坐标，失败退化 |
| 用户闲置 | CoreGraphics 的系统空闲时间接口 | 不需要记录按键内容；超时决定桌面游荡 |
| 多显示器/DPI | `NSScreen`、`backingScaleFactor`、显示配置事件 | 每个显示器独立尺寸与锚点；Mac 的 pt 与 Windows 的 DIP 不混用 |
| 邮件 | IMAP + IDLE（优先）、按提供商 OAuth2；其它路径可选 | 监听未读，密码不进代码仓库、日志或 UserDefaults |
| 日志 | `Logger`（os.log） | 默认隐去邮件正文、工作目录、Token、会话内部内容 |
| 性能分析 | Instruments（Time Profiler、Allocations、Energy Log）、活动监视器 | 监测真实机型待机与唤醒的 CPU/内存/能耗 |

### 2.1 App 沙盒与发布策略

首个个人使用的开发版本优先非 Mac App Store 分发方式，保持权限、Hook 和本地 Socket 的调试可控；签名、公证、自动更新作为独立发布工作。**非沙盒并不等于无需隐私授权**：Finder AX、桌面文件、录屏等仍须明确按需向系统请求权限。若以后目标改为 Mac App Store，需要另做 sandbox entitlements、Socket 和插件路径的全面可行性评估。

推荐 `LSUIElement=true`（纯菜单栏模式、隐藏 Dock 图标）作为实验方案，不把它当作可随意切换而无副作用的设置：正式 UI 调试窗口、设置激活、全屏空间适配需验证。`SMAppService.mainApp.register()` 只能在用户同意后启用。

### 2.2 代码拆分：不要堆出巨型 AppDelegate

采用 3 层模型：

- **Presentation**：状态栏、透明窗、Dashboard、设置，仅消费 ViewModel，不处理原始外部 JSON。
- **Domain**：EventHub、SessionRegistry、PetBehavior、AnimationTimeline、DialoguePolicy、NotificationPolicy。纯逻辑，尽可能可在 SwiftPM Tests 下无图形运行。
- **Infrastructure**：AgentPet/DSH/Codex 适配、Socket、邮件、系统指标、Finder AX、SQLite、Keychain、AI API。

数据单向流：`输入适配器 → 原始事件校验 → 标准事件 → SessionRegistry → Policy/Behavior → UI`。UI 产生的用户动作经 `AppCoordinator` 路由到 Domain；不允许 SwiftUI View 直接写 Socket 或访问 Finder。

### 2.3 推荐工程目录（目标目录，不是上游现有文件布局）

```text
WhaleGirl/
├── Package.swift
├── Sources/
│   ├── App/
│   │   ├── WhaleGirlApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── AppCoordinator.swift
│   │   └── Resources/
│   ├── WhaleCore/
│   │   ├── Models/{WhaleEvent,SessionState,PetState}.swift
│   │   ├── Events/{EventHub,SessionRegistry,EventReducer}.swift
│   │   ├── Behavior/{PetBrain,BehaviorScheduler,CooldownPolicy}.swift
│   │   ├── Dialogue/{DialogueEngine,BudgetLedger}.swift
│   │   ├── Protocol/{TransportEnvelope,EventCodec}.swift
│   │   └── Ports/{AgentEventSource,MetricsProvider,DesktopTargetProvider}.swift
│   ├── WhaleUI/
│   │   ├── MenuBar/{MenuBarController,MiniRenderer}.swift
│   │   ├── Overlay/{PetPanel,PanelCoordinator,HitTestView}.swift
│   │   ├── Sprite/{SpriteLoader,SpriteAnimator,AnimationTimeline}.swift
│   │   ├── Dashboard/{DashboardView,TaskListView,SystemStatsView}.swift
│   │   └── Settings/{General,Animation,Integration,Privacy}.swift
│   └── WhaleInfra/
│       ├── Ipc/{UnixSocketServer,FramedJSONReader}.swift
│       ├── Agents/{AgentPetAdapter,CodexAdapter,DSHAdapter}.swift
│       ├── Email/{IMAPService,OAuthCredentialStore}.swift
│       ├── System/{MetricsMonitor,IdleDetector,DisplayResolver}.swift
│       ├── Desktop/{FinderAXProvider,DesktopScene,RoamPlanner}.swift
│       ├── Storage/{SQLiteStore,DatabaseMigration}.swift
│       ├── Notifications/NotificationService.swift
│       └── API/{DeepSeekClient,APIUsageCounter}.swift
├── Helpers/
│   ├── whale-hook/               # Codex Hooks (主路径)，只上报白名单状态
│   ├── whale-notify/             # Codex notify (仅 turn-complete 可选补充)
│   └── dsh-whale-status/         # DSH Cordis 插件：TypeScript + 构建脚本
├── Assets/
│   ├── Source/                   # 原始素材（有授权后才可打包）
│   ├── Processed/{Mini,Peek,Full}/
│   ├── manifest.json
│   └── attribution.json
├── Scripts/
│   ├── convert_sprites.py
│   ├── verify_assets.py
│   ├── inject_mock_event.py
│   └── performance_smoke.sh
├── Tests/
│   ├── WhaleCoreTests/
│   ├── ProtocolTests/
│   ├── BehaviorTests/
│   ├── AdapterContractTests/
│   ├── PerformanceTests/
│   └── Fixtures/{codex,dsh,mail,system}/
└── docs/
    ├── decisions/
    ├── contracts/
    ├── test-matrix.md
    └── third-party-notices.md
```

**迁移策略：**不要求第一个提交就重排所有上游目录。先在 AgentPet 的 `Sources/App` 与 `Sources/AgentPetCore` 下实现并以 facade 适配；跑通功能后再拆成模块，避免首阶段大量无功能的目录重构。

---

## 3. 统一事件协议与传输设计（核心系统）

### 3.1 为什么先定协议

DSH、Codex、邮件及系统监控使用的事件格式完全不同。UI、动画、通知**只能依赖统一事件格式**，否则后期加 Windows 或接入其他 Agent 必定不断改 View。

所有消息统一为 UTF-8 JSON 一行一条（NDJSON），以 `\n` 结束；协议版本与业务事件版本必须明确。主应用是**事件的唯一可信决策节点**；外部插件仅报告事实，不能直接驱使角色删除文件或执行任意 shell 命令。

### 3.2 WhaleEvent v1 契约（**唯一规范**）

下面是 WhaleGirl 自定义的跨应用协议，并非 Codex/DSH 原生协议。**此 JSON、§3.5 的 Swift DTO、§11.2 的 SQLite 列必须互相对应。**

```json
{
  "schemaVersion": 1,
  "eventId": "0199e3f3-6c3e-7e0a-96dc-604a4e4187df",
  "source": "codex",
  "sourceInstance": "local-mac",
  "sessionId": "codex-thread-123",
  "parentSessionId": null,
  "projectKey": "project-key",
  "eventType": "agent.waiting_approval",
  "occurredAt": "2026-10-10T15:00:00+08:00",
  "receivedAt": null,
  "sequence": 42,
  "severity": "action_required",
  "summary": "Codex 正在等待操作授权",
  "displayTarget": {"kind":"app", "bundleId":"com.example.codex", "uri":null},
  "metadata": {"client":"codex-cli", "approvalKind":"shell_command"},
  "privacyClass": "metadata_only"
}
```

- `schemaVersion`：必填 `1`，未知版本拒绝并计数。
- `eventId`：必填 UUID，接收端按 `(source, sourceInstance, eventId)` 复合主键去重，不得跨来源吞事件。
- `source`：必填，固定枚举 `codex/dsh/mail/system/whale/remote`；`sourceInstance` 必填，用于区分进程、Profile 或机器。
- `sessionId`：Agent 事件必须；`parentSessionId` 和 `projectKey` 可缺省，但绝对路径不能直接上传或持久化。
- `eventType`：受限事件白名单，见 §3.3；`severity`：`info/success/warning/error/action_required`。 **v1 唯一允许集合取自 `fixtures/contract_constants.json:eventTypes`，Swift Codec 和 SQLite CHECK 必须一致，不允许任何未知值。**
- `occurredAt`：**必填严格日历有效且 ISO 8601 RFC3339 风格带时区字符串**，如 `2026-10-10T15:00:00+08:00`。协议 v1 **严格拒绝小数秒**（包含 `.000`），发送方必须规范化为整秒。**仅设置** `JSONDecoder.dateDecodingStrategy = .iso8601` **并不能保证拒绝小数秒**。所有线路必须经过带有时间字符串预校验的 `WhaleEventCodec.decode(_ data: Data)`，并将失败上报诊断计数；不得直接暴露 `JSONDecoder` 供生产调用。
- `receivedAt`：发送方可省略或为 `null`，由接收端覆盖写入服务端本机时间。
- `sequence`：推荐每会话递增，允许 `null`，来源缺失时按接收顺序处理并标记精度。Wire DTO 采用 `UInt64?`，SQLite 列采用有符号 `INTEGER`，因此**协议 v1 实际接收上限为 `Int64.max`**；`WhaleEventCodec` 必须拒绝超过此范围的序号，禁止数据库写入时整数溢出。
- `summary`：可空，**最多 200 个 Unicode scalar，且 UTF-8 编码最多 800 字节**；二者都要验证。超过限额拒绝/或在适配器安全截断，不能出现文档与代码的 200/800 相互矛盾。（注：单个 Unicode scalar 的 UTF-8 编码最多 4 字节，因此 200 scalar 的限制在数学上已蕴含 ≤800 字节；两个数仍须分别进入契约，防止后续独立调整时漂移。）
- `displayTarget`：仅允许 `app/session/none`；v1 的 Codec 暂只允许空 `uri` 或 HTTPS 且具有 host 的 `uri`；最终打开时仍需应用级 host allowlist 和用户动作验证。拒绝 `file:`, `javascript:`, `http:` 等协议，绝不执行 shell。
- `metadata`：v1 只允许 `client` 与 `approvalKind` 两种键；**总 JSON 编码最大 2048 字节**；任何 `input-messages`、`last-assistant-message`、`password`、原始邮件正文或命令输出一律丢弃/拒绝，不可进入持久化。
- `privacyClass`：必填 `metadata_only/local_sensitive`；`local_sensitive` **不得写敏感正文入历史表**，仅用于本地限制展示与转发。

编解码失败要成为可观测事件：最小诊断记录包括来源、失败字段类别、时间、总字节数（不记录原文）；累计 `decodeFailureCount`，并在诊断页显示。**不得使用 `try?` 静默丢弃。**

**V2.4 规范同步说明（强制检查）**：`fixtures/wire_contract.json` 是 Wire → Swift DTO → SQLite `events` 表的字段映射清单；§3.2 的示例 JSON 必须含有相同**完整字段集合**（包括可空字段），而非只包含必填字段。每个映射必须明确 Swift 类型、SQLite 列名、SQLite 类型和可空性；`receivedAt` 是“Wire 可空 / 入库服务端填充非空”的特殊列，`summary → summary_redacted` 为脱敏投影，均由 `wire_contract.json` 显式声明。`events.read_at` 属于数据库管理专用字段，必须在 `storageOnlyColumns` 白名单中声明。**新增、删除或更名字段不经契约同步应使 CI 失败**，不允许通过把字段名塞进注释来绕过。协议编码器与存储模型是两个边界，数据库衍生字段不自动成为 Wire 属性。实际比对程序为 `scripts/doc_check.py`，其 `contract-mutation` 测试必须证明三种漂移能被检测。

JSON、Swift、SQLite 的字段映射固定为：`eventId → event_id`、`receivedAt → received_at`、`displayTarget → display_target_json`、`metadata → metadata_json`、`privacyClass → privacy_class`、`sequence → sequence_no`。`unreadCount` 是会话衍生/缓存字段，SQLite 列名 `unread_count`；`lastSequence` 对应 `last_sequence_no`。

### 3.3 事件枚举与状态映射

**唯一事件值集合**：以下 `text` 代码块逐行列出全部允许的 v1 事件名；`doc_check.py` 解析整个列表并与 `contract_constants.json:eventTypes`、Swift `WhaleEventContract.allowedEventTypes`、SQL `events.event_type` CHECK 进行**无缺项、无多项、无重复**的集合比较；仅在其他章节出现事件名称不能使验证通过。

```text
agent.session_started
agent.working
agent.tool_started
agent.tool_finished
agent.waiting_input
agent.waiting_approval
agent.turn_completed
agent.session_completed
agent.failed
agent.interrupted
agent.disconnected
agent.heartbeat

mail.new
mail.read
mail.connection_lost

system.load_high
system.battery_low
system.woke
system.slept
system.idle_started
system.user_returned

pet.clicked
pet.hovered
pet.drag_started
pet.drag_finished
pet.roam_finished
```

**关键区别：** `turn_completed` 不必然等于整个会话结束；`tool_finished` 不代表问题已解决；`disconnected` 不代表 Agent 失败；`waiting_approval` 的结束要由同 session 的新事件明确恢复。对于不能确认的客户端适配器显示“完成一轮回复”或“状态未知”，不误称“整个任务完成”。

### 3.4 传输层安全设计（上游 Socket **必须重写/加固**）

WhaleGirl 的事件 Socket 为自己所有，不复用、也不抢占 AgentPet、DSH Pet 的监听路径：

```text
~/Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock
```

**启动与恢复顺序**：

1. `Application Support/WhaleGirl/ipc` 目录要求当前用户所有，`0700`；防止 symlink 路径注入，严查 `lstat`、owner 和目录权限；`umask(0077)` 创建 Socket，随后检查 `chmod(0600)` 结果。
2. 主程序获取本应用**独立实例锁**，以避免第二个 WhaleGirl 进程同时绑定；锁失败只做客户端或提示用户，不删除 socket。
3. 路径已存在时**禁止直接 `unlink(path)`**。验证节点类型/owner，并尝试连接：有服务则报告“实例已运行”；连接失败且有确凿证据属本应用遗留的 stale socket，才可清理。若无法确定归属就拒绝启动服务端并提示。
4. 每次 `accept` 后使用 Darwin `getpeereid()` 验证对端 uid == 本用户 uid（注意：**同一 uid 内恶意程序仍可伪造事件**，不能把 uid 当成细粒度 App 身份），对外部桥接仅开放“状态上报”而非命令执行权限。
5. 服务端只处理 NDJSON、16 KiB 单消息上限、速率限流、版本及字段白名单；Hook/Plugin 用短超时与退避重试，不阻塞 Codex/DSH 业务执行。
6. 收到不完整 JSON、未知枚举、无效时间戳时：记录脱敏解码失败计数与来源，返回可诊断的错误/断开（按协议），**绝不静默忽略**。
7. 退出时只清理由当前实例拥有且仍指向当前服务的 Socket；必须考虑进程崩溃与启动并发。绝不触碰 `moodball.sock` 或 AgentPet 的 Socket 文件。

**NDJSON 接收示例（架构代码，网络收包细节需实装）**：

```swift
// 只允许调用严格编解码边界，不在连接处理层构造自己的 JSONDecoder。

func handleFramedLine(_ line: Data, source: String) async {
    guard line.count <= 16 * 1024 else {
        diagnostics.increment(.oversizedFrame, source: source)
        return
    }
    do {
        let event = try WhaleEventCodec.decode(line)
        try await eventHub.ingest(event)
    } catch {
        diagnostics.increment(.invalidEvent, source: source)
        logger.warning("WhaleEvent rejected from \(source, privacy: .public): \(String(describing: type(of: error)), privacy: .public)")
        // 不记录 line、prompt、邮件正文、错误上下文 payload
    }
}
```

上例中 `diagnostics/logger/eventHub` 均为工程对象。必须另写 `FramedJSONReader` 负责断包、粘包、连续换行、CRLF、单行过长，以及并发连接相互隔离。**不要把该示例与可直接编译的完整服务器混为一谈。**

**强制契约测试**：正常 `+08:00`/`Z`；**拒绝小数秒**（例如 `.123`）、缺少时区以及 `receivedAt` 错误时间；非法 JSON；无效 UUID；`summary` 超限；粘包/断包；第二实例抢占；符号链接；已有 AgentPet Socket 不受影响；错误计数可查询。

### 3.5 Swift DTO 与解码配置（协议 v1 代码契约）

```swift
import Foundation

enum EventSource: String, Codable, Sendable {
    case codex, dsh, mail, system, whale, remote
}
enum EventSeverity: String, Codable, Sendable {
    case info, success, warning, error, action_required
}
enum PrivacyClass: String, Codable, Sendable {
    case metadata_only, local_sensitive
}
enum DisplayKind: String, Codable, Sendable { case app, session, none }
struct DisplayTarget: Codable, Sendable {
    let kind: DisplayKind
    let bundleId: String?
    let uri: String?
}
struct WhaleEvent: Codable, Sendable, Identifiable {
    let schemaVersion: Int
    let eventId: UUID
    let source: EventSource
    let sourceInstance: String
    let sessionId: String?
    let parentSessionId: String?
    let projectKey: String?
    let eventType: String
    let occurredAt: Date
    let receivedAt: Date?
    let sequence: UInt64?
    let severity: EventSeverity
    let summary: String?
    let displayTarget: DisplayTarget?
    let metadata: [String: String]?
    let privacyClass: PrivacyClass
    var id: String { source.rawValue + ":" + sourceInstance + ":" + eventId.uuidString }
}

// 以下仅示范生产边界 API；完整的已测试实现位于：
// tests/SwiftContractPackage/Sources/WhaleProtocol/WhaleEvent.swift
// 必须在 JSONDecoder 前验证 occurredAt / receivedAt 的秒级 RFC3339 形式。
// JSONDecoder.dateDecodingStrategy = .iso8601 本身不等于严格校验。
func strictRoundtrip(_ frameData: Data) throws -> Data {
    let event = try WhaleEventCodec.decode(frameData)
    return try WhaleEventCodec.encode(event)
}
```

**时间精度真值**：`fixtures/contract_constants.json` 中 `timestampPrecision = "seconds"`，必须被 `doc_check.py` 读取，并与 Swift `WhaleEventCodec.v1SecondsPattern`、XCTest 的秒级带时区有效样例及“`.123` 小数秒拒绝”测试同时核对。若将来允许毫秒，必须升级 Wire 协议版本并同步更新 codec、fixture 和测试；不能只改字符串常量。

`WhaleEventCodec.decode(_ data: Data)` 是唯一的生产网络入口：先用 JSON 对象校验 `occurredAt`/`receivedAt` 的**严格 RFC3339 整秒字符串格式**，再以 `.iso8601` 将时间转为 `Date`，最后校验协议字段。完整 SwiftPM 源码和 XCTest 见 `tests/SwiftContractPackage/`。若未来支持小数秒，采用明确的协议 v2 或版本协商，不得悄悄改变 v1 接受范围。`decode()` 发生错误时，IPC 调用层仍须增加**脱敏失败计数**，测试工程中的纯解码函数不负责数据库日志。

`WhaleEventCodec.decode` **必须在入站阶段** 验证事件白名单、metadata 键白名单、URI 策略及 summary 的 **≤200 Unicode scalar 且 ≤800 UTF-8 bytes**，metadata ≤2048 UTF-8 bytes；EventHub 在入库前对来源可信性、业务状态转换和安全跳转进行第二次验证。`EventStore` 的 PRIMARY KEY/UNIQUE 决定持久幂等，内存仅用有界 LRU。`receivedAt` 在入库时被接收端实际时间覆盖，不能信任外部填值。

**错误处理**：捕捉 `DecodingError`、协议校验错误、SQLite 写入错误，分别计数与报告；任何一类都不允许 `try?`。对上游 Hook 的回调不把异常抛回 Codex：助手业务继续运行，但 WhaleGirl 诊断能显示事件未送达。

### 3.6 会话聚合器：必须做对的边界情况

主键：`(source, sourceInstance, sessionId)`。每个会话可有 `parentId`、`state`、`updatedAt`、`lastSequence`、`unreadCount`、`needsAttention`、`stateEvidence`、`approvalCoverage` 等字段。聚合遵循：

1. 只更新该主键的会话状态，不用一个 Agent 的 `done` 覆盖另一个的 `working`。
2. 多个子 Agent 结束不能直接把父会话变成 `done`，除非有父会话明确终态事件。DSH 的父子关系优先使用 `subagent/start`/`subagent/end`（`emit`，带对应运行身份，按锁定接口解析）以及 `session/created` / `session/disposed` 生命周期事件；`session/event` 仅用于补全审计与会话事实。防止同一个子任务结束被视为父会话完成。
3. `waiting_approval` 需要用户动作；除非有同会话 `resumed/completed/interrupted` 事件，不能被全局普通 idle 消息清除。
4. 相同 `eventId` 重发不能重复弹窗；不同 ID 但 `source + session + type + action` 相同且短时间内重复，应用节流策略。
5. 旧序号的非终态不能覆写新终态；断线重连后要标记 `stale`，不要假装任务已完成。**DSH 待审批必须附来源可信度**：已验证 MoodBall 或版本锁定的 `approval/asked` 审计事件才可置 `waiting_approval`；仅 agent running/idle 不可推断。缺少来源时显示“审批监控暂不可用”。
6. `turn_completed` 后如 session 继续运行，要允许回到 working；需检测事件来源是否属于当前活动 turn。
7. 30 秒未见心跳 ≠ 30 秒失败。给等待状态设服务特定 TTL，展示“状态可能过期”，避免未经证实的卡死结论。


**V3.2 序号权威水位线**：无序号事件不得覆盖已有序号的会话状态；当已有状态没有序号而新事件具有序号时，**先提升序号权威，跳过旧的无序号时间守卫**，所以 `working@08:00（无序号） → waiting_approval@07:59（有序号）` 必须变为待审批。两个状态同为有序号时，严格递增的序号优先，即使源时钟回拨也不得丢弃更高序号的审批事件；仅同为无序号时要求时间递增。首次 `heartbeat` **不建立会话快照和 updatedAt 水位线**。权威从无序号升为有序号时，`updatedAt` 表示新权威事件的 occurredAt，允许相对旧低权威观察值暂时后移到较早时间；不要把两种权威的时间水位线混用。

实现建议：`SessionReducer.reduce(current: SessionState?, event: WhaleEvent) -> SessionState` 采用**纯函数**，配上固定 Fixture 做 Table-driven 单元测试。

### 3.7 通知去重与优先级

业务优先级由 `NotificationPolicy` 计算，不能让任何桥接插件直接指定 `priority=9999`。

| 事件 | 优先级 | 建议反馈 |
|---|---:|---|
| 等待输入/审批 | 100 | 菜单栏提醒 + 提示牌 + 可选系统通知；不得自动批准 |
| 未读失败 | 90 | 短暂惊讶/委屈 + 任务卡片 |
| 未读完成 | 75 | 欢呼一次 + 可选系统通知 |
| 重要邮件 | 65 | 信封 + 未读数；邮件隐私设置有效 |
| 普通邮件 | 40 | 累计角标，默认不弹大窗 |
| 工作中 | 20 | 小动作与状态面板，不弹窗 |
| 随机吐槽/游荡 | 0 | 只能在不存在更高优先任务时触发 |

限制：全屏应用、屏幕共享、会议和勿扰状态下，不主动显示遮挡性 Overlay；系统通知由用户显式设置决定。高优先级事件应进未处理队列而不是被丢弃。

---

## 4. 角色素材：三套尺寸、格式、帧与动画引擎

### 4.1 正式尺寸定义（遵循 V1.2 截图比例）

以用户提供的标记截图视觉比例为基准：小红框 2.5% 屏高、中红框 8.2%、黄框 15.0%。截图中的尺寸是**视觉意图**，并不是系统菜单栏物理大小测量值。因此只对 Peek/Full 使用百分比，Mini 应服从系统菜单栏/托盘容器高度。

| 形态 | 默认外观 | Mac 逻辑尺寸规则 | Windows 未来移植的逻辑尺寸规则 |
|---|---|---|---|
| Mini | 头部 / 上半身清晰简化版 | 状态栏内约 20–24 pt 上限，由实际 status item 高度减内边距得到 | 根据托盘容器实际像素/DPI 决定，使用单独小图标 |
| Peek | 约屏高 8.2% | `NSScreen.frame.height × 0.082` | `MonitorLogicalHeightDIP × 0.082` |
| Full Roam | 约屏高 15% | `NSScreen.frame.height × 0.15` | `MonitorLogicalHeightDIP × 0.15` |
| Full Active | Roam 放大 10%–20% | `RoamHeight × 1.15` 默认 | 同样倍率 |

用户总缩放 `0.8...1.3`；宽度跟原图有效内容纵横比变化；任何状态禁止 x/y 非等比拉伸。角色 Full 的高度约为 Mac 13 英寸常见逻辑画面 143 pt、Windows 4K 150% 时 216 DIP，仅用于设计参考，**运行时永远读取当前显示器实际参数**。

`NSScreen.frame.height` 适合计算“占屏幕视觉比例”；`NSScreen.visibleFrame` 更适合最终的位置合法性与活动区域裁剪：两个概念不能混淆。若菜单栏自动隐藏、Dock 改位置、切换 Space，须重新求锚点与可达区域。

### 4.2 素材规范与运行时资产结构

建议建立 `WhaleAssetManifest v1`（不要求与 whale-girl 或 AgentPet 原 `pet.json` 二进制格式相同），用离线工具转换原素材。结构示例：

```json
{
  "formatVersion": 1,
  "characterId": "whale-girl",
  "credit": "artist-and-license-record-required",
  "assets": {
    "mini": { "atlas": "mini@2x.png", "scale": 2 },
    "peek": { "atlas": "peek@2x.png", "scale": 2 },
    "full": { "atlas": "full@2x.png", "scale": 2 }
  },
  "animations": {
    "mini.idle": {
      "atlas": "mini",
      "frames": [[0, 0, 48, 48], [48, 0, 48, 48]],
      "durationsMs": [650, 110],
      "repeat": "loop",
      "anchor": [0.5, 0.9],
      "hitbox": [0.18, 0.1, 0.64, 0.8]
    },
    "peek.wave": {
      "atlas": "peek",
      "frames": [[0, 0, 256, 256], [256, 0, 256, 256]],
      "durationsMs": [180, 220],
      "repeat": "once",
      "anchor": [0.5, 0.0],
      "hitbox": [0.22, 0.08, 0.56, 0.86]
    }
  }
}
```

示例中的 `frames` 数值仅用于说明切片元数据，不代表已经存在的实际图集。制作工具必须自动从图片与 manifest 验证帧坐标、PNG 透明通道、纹理尺寸和对齐点。不要依赖运行时 AI 生成或裁图。

**关键元数据：**

- `visualBounds`：透明边去除后的视觉轮廓范围，计算角色真实大小与比例。
- `pivot/anchor`：Mini 居中；Peek 顶部扒边；Full 足底位置（跳落/坐下/行走时不“漂移”）。
- `hitbox`：可交互区，不等于整张图；建议使用多个矩形或低分辨率 alpha mask。
- `rootMotion`：角色每帧在窗口坐标中的位移，或独立行为曲线；素材绘制与角色真实移动分离。
- `loop/reverse/pingpong/once`：与对应 fps/duration；优先采用逐帧离散而非 CSS 运动。
- `frameEvent`：第 N 帧播放视觉特效/音效，不能在源图片里硬编码“被吃掉的文件”。

### 4.3 三套资源必须分开设计

**Mini**：专门重绘高辨识度小头像，约 24–48 物理像素级图像，输出 1×/2×/3× 适配（按当前实际系统需求），1–3 帧为主。用简化头发、眼睛、尾鳍轮廓与情绪色；不把完整全身大图压缩至 20 pt。

**Peek**：半身图集，探出菜单栏、抓住顶部、说话、挥手、举信封、等待审批、收起。建议至少 512 px 高质量原画母版，以适应 Retina 和放大。原始 `whale-girl` 256×256 的帧可先供 PoC 使用，观察大图精细度后决定是否重绘。

**Full**：全身完整动作，跳、跑、趴、坐、睡、抱、踢、咬、回爬；建议准备 768–1024 px 高质量母版以容纳放大，但运行时导出适当图集以降低内存，不是所有帧都以 1024 px 常驻显存。保持素材的原本像素风或插画风一致，不在一段动画中混用不一致的绘制比例。

### 4.4 动作制作优先序（工程建议，不是上游固定帧数）

| 层 | 首批动作 | 建议帧数区间 | 默认播放策略 |
|---|---|---:|---|
| Mini | idle、blink、working、waiting、done、error、mail | 1–4/动作 | idle 约 1–2 fps；事件动作 3–4 fps |
| Peek | peek_out、hold_edge、wave、look_mouse、show_card、peek_back | 3–8/动作 | once + hold；一轮结束退场 |
| Full | jump_down、land、walk、turn、sit、sleep、kick、bite、hug、climb_back | 3–12/动作 | 4–10 fps；可以复用镜像方向但需检查镜像文字 |

动作 ID **唯一命名**：`mini.idle`、`mini.blink`、`mini.working`、`mini.waiting`、`mini.done`、`mini.error`、`mini.mail`；`peek.peek_out`、`peek.hold_edge`、`peek.wave`、`peek.look_mouse`、`peek.show_card`、`peek.peek_back`，并补 `peek.working`（可用 `peek.hold_edge` 暂代）；Full 使用 `full.idle/jump_down/land/walk/turn/sit/sleep/kick/bite/hug/climb_back/drag`。上游 `working` 映射 `mini.working/peek.working`，不再出现未定义的 `mini.work/peek.work`。资产缺失时按 `mini.idle`、`peek.hold_edge`、`full.idle` 明确回退；构建时 `verify_assets.py` 校验必选 ID。

### 4.5 动画渲染器实现

MVP 优先 `CALayer` + 预加载的 CGImage/NSImage 图集，降低依赖与运行成本。角色动画播放器只负责 `animationId + elapsed` → `frameIndex`，每次只切换图层内容/子区域，不负责业务事件与窗口坐标。

伪接口：

```swift
protocol AnimationRendering: AnyObject {
    func load(_ manifest: WhaleAssetManifest) throws
    func play(_ id: String, looping: Bool)
    func pause()
    func setScale(_ scale: CGFloat)
    func currentHitRegions() -> [CGRect]
}

struct AnimationKeyframe {
    let frameRect: CGRect
    let duration: TimeInterval
    let opacity: CGFloat
    let offset: CGPoint
}
```

独立使用 `SpriteKit/SKView` 仅在 Full 的物理/粒子互动实测有显著开发效率优势时考虑；不能先装一个 60fps 游戏循环，再说要“低功耗”。NSImage 解码/裁切在资源加载线程做，UI 主线程不进行每帧大量像素计算。隐藏和系统休眠时必须暂停所有动画计时器。

### 4.6 素材校验流水线

1. 整理上游 manifest，建立原图与角色信用档案 `attribution.json`。
2. 离线脚本生成透明背景 PNG（如来源仍是绿底，使用上游切图工具或 Pillow 抠除背景）。
3. 根据有效角色边界做缩放和底部锚点对齐；头发与尾巴超出范围时保留安全内边距。
4. 按 Mini/Peek/Full 分别组装 atlas，自动输出 frame rectangles 与动画时长。
5. 校验所有动画引用的图集存在、帧范围合法、alpha 通道正确、帧宽高/原始比例不异常。
6. 生成可点击/可查看的动作预览清单；审核轮廓、人物一致性、动作流畅度；再随 App 打包。

不能因为运行时有 Sprite Atlas，就假定所有素材的再使用许可已经成立。

---

## 5. 菜单栏、透明窗口、鼠标命中与显示器适配

### 5.1 结构：三个独立的 UI 宿主

1. **MenuBar Host**：AppKit `NSStatusBar.system.statusItem(withLength:)`，使用 `NSStatusItem.button`。Mini 动画在该按钮内显示，其图像由 MiniRenderer 管理。
2. **Peek / Interaction Host**：一只小型无边框透明 `NSPanel`，锚在对应 `NSStatusBarButton` 的屏幕坐标下方。执行探身、鼠标互动、气泡、收回。关闭后释放或复用，平时完全不显示。
3. **Roam Host**：透明宠物窗，在工作区内以坐标动画移动全身角色，完全不覆盖整个屏幕；可与 Peek Host 复用底层渲染引擎，但窗口控制不同。

**关键取舍：**不创建一个永远覆盖整个屏幕、`ignoresMouseEvents=false` 的透明大窗口。透明不代表能点击穿透；这样的窗口可能截获大量正常桌面点击。优先使用随角色移动的小窗口、严格限制窗口外接范围，必要时在非互动状态设置 `ignoresMouseEvents=true`。高级逐像素点击命中在后续迭代验证。

### 5.2 菜单栏宿主示意

```swift
import AppKit

@MainActor
final class WhaleMenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength
    )

    func configure() {
        guard let button = item.button else { return }
        button.image = NSImage(named: "WhaleMiniIdle")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(didClick)
    }

    @objc private func didClick() {
        // AppCoordinator 决定打开 Dashboard 或互动窗
    }

    func anchorFrameOnScreen() -> CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let local = button.convert(button.bounds, to: nil)
        return window.convertToScreen(local)
    }
}
```

这是简化样例。正式工程中必须处理状态栏图标因刘海、空间不足、菜单栏自动隐藏而不可见或窗口为空的情况。苹果 `NSStatusBar` 通常把第三方状态项排在菜单栏右侧，不提供将它放到左侧苹果菜单区的常规接口；若以后实现“左上角常驻”，应当作为独立可关闭的模拟组件，不作为第一版默认路径。

### 5.3 Peek / Full 透明窗

建议初步配置（真实表现需实机验证）：

```swift
let panel = NSPanel(
    contentRect: CGRect(x: 0, y: 0, width: 180, height: 180),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.ignoresMouseEvents = true   // 默认“只看不摸”，等待显式进入交互状态
```

建议有两种模式：

- **被动动画态**：角色只是探头/走动，无点击需求，`ignoresMouseEvents=true`，所有鼠标事件继续交给原应用。
- **主动互动态**：用户明确点击、拖拽、悬停触发交互窗口时，启用局部的鼠标接受；缩小窗体的边界或采用可验证的命中策略，使角色外的大面积透明区域不拦截桌面。

不要简单声称给 `NSView.hitTest` 返回 `nil` 就能自动让事件穿过整个 `NSWindow` 到下面的 Finder；窗口命中和 view 命中是两层机制。若像素级穿透在具体系统版本做不到可靠且低功耗，产品退化为“小范围角色窗口 + 默认穿透 + 鼠标悬停时显式互动区”。

### 5.4 锚点与坐标转换

- 菜单栏 button 坐标由 `convertToScreen` 获取，Peek 面板根据 button 底边、当前屏幕可见区域计算位置。
- AppKit 屏幕与窗口坐标以 pt 计；物理像素来自 `backingScaleFactor`。不要把 Retina 2× 再手动重复应用到 Window Frame。
- Peek 的实际角色高度计算为 `targetScreen.frame.height * 0.082 * userScale`；Full 为 `* 0.15 * userScale`；主动互动为 `full * 1.15`。
- Full 碰到窗口边界时优先调整位置，不轻易缩放；越界或空间不足时降级动作。
- 同时保存**菜单栏锚点、角色视觉包围盒与窗口坐标**，使“从头像跳下”和“返回菜单栏”的位置连续，不用固定 x/y magic number。

几何伪代码：

```swift
// PresentationMode 唯一显示状态；行为状态单独为 BehaviorState
func targetHeight(mode: PresentationMode, screen: NSScreen, scale: CGFloat) -> CGFloat {
    let h = screen.frame.height
    switch mode {
    case .mini: return 22                   // 实际服从系统状态栏容器
    case .peeking: return h * 0.082 * scale
    case .roaming, .returning: return h * 0.150 * scale
    case .interacting: return h * 0.150 * 1.15 * scale
    case .hidden: return 0
    }
}

func clampToWorkArea(_ requested: CGRect, visible: CGRect) -> CGRect {
    let x = min(max(requested.minX, visible.minX), visible.maxX - requested.width)
    let y = min(max(requested.minY, visible.minY), visible.maxY - requested.height)
    return CGRect(x: x, y: y, width: requested.width, height: requested.height)
}
```

`clampToWorkArea` 样例前提是窗口小于可用区域；如果窗口更大，需先处理缩放或减小特效范围，否则 maxX-width 会落到非法位置。多屏使用目标 `NSScreen` 而非总是 `NSScreen.main`。

### 5.5 多显示器 / 刘海 / Dock / 全屏场景

下列事件必须触发 `DisplayResolver.recalculate()`：

- 显示器连接/拔出、分辨率变化、缩放比例变化。
- 菜单栏出现/隐藏、Dock 改边与自动隐藏。
- 系统睡眠/唤醒、用户切换 Space、显示器位置排列变化。
- 菜单栏 item 因第三方图标太多而被遮挡或移动。

**窗口层级策略**：菜单栏悬浮物不保证在所有原生全屏 App 上永远可见。全屏默认禁用桌面 roaming，在不受支持的 Space 中不创建奇怪的覆盖窗口；如果需要关键提醒，让系统通知/菜单栏角标承担，避免靠设置极高窗口 level 硬压其他软件。

### 5.6 用户输入事件与“无焦点”要求

- 菜单栏点击、Peek 鼠标事件采用 AppKit 本地事件或跟踪区域 `NSTrackingArea`；鼠标高频跟踪只在互动模式启用。
- 不记录全局按键内容；不安装键盘监听器。闲置检测可使用系统最近输入时间，而不是逐个截取鼠标键盘事件。
- 角色拖动不能修改系统指针位置，只更新窗口位置。一次拖动完成后自动决定返回菜单栏或暂时停留。
- 如果检测用户开始打字、鼠标快速持续操作，Roam 应进入“避让/返回”流程，不产生遮挡关键点击的动画。

### 5.7 动画过渡的具体时间线

以 `mini → peek → roam → mini` 为例：

| 时间 | 动作 | Window 行为 |
|---:|---|---|
| 0 ms | Mini 眨眼、抬头 | 状态栏状态切换 |
| 80–220 ms | Peek 扒住菜单栏，露出头肩 | Peek Panel 出现；角色上缘与 status item 锚点对齐 |
| 220–650 ms | Peek 半身伸出、挥手或说话 | UI 根据事件选择气泡与动作 |
| 后续 | Peek 可持续停留，也可启动 Full 跳落 | Roam Host 预加载，全身从同一锚点进入 |
| 300–900 ms | Full 落地、站稳 | 窗口随 Root Motion 位移；不真的移动 Finder |
| 空闲 | 巡逻、小剧场、互动 | 限制每次时长与活动区域 |
| 结束 | 跳起/攀爬收回 | 以屏幕坐标对齐菜单栏位置，Full 与 Peek 交接 |

上表时间只是动画制作参考，不是系统性能保证。所有动作都能被新来的高优先级事件中断，并能够安全恢复到 Mini 状态。

---

## 6. 桌面游荡、Finder 图标与 Dock 互动

### 6.1 本质是“宠物表演”，不是桌面自动化

最小可实现方案不需要 Finder 图标的位置：只在安全的可见工作区域内让角色走动和跟随鼠标，经过屏幕边缘或 Dock 附近播放动作。**这一阶段即可完整实现“跳下来”“踢空气”“追鼠标”的视觉效果。**

高级版本在获得用户许可后，才尝试枚举 Finder 桌面可见元素及其坐标，并做有目标的“踢/吃/抱”动作。不得要求 Accessibility 成功才能启动主程序。

### 6.2 可行性分级

| 级别 | 实现 | 对权限的依赖 | 说明 |
|---|---|---|---|
| L0：纯视觉 | 根据安全区域随机游走、跳跃、坐下、面向 Dock | 无额外权限 | MVP 之后优先交付，最稳定 |
| L1：读桌面项目名称 | 用户授权访问 Desktop 文件夹，只读名称和类型 | 文件夹权限 / TCC | **只有文件名，不知道它在屏幕上哪个位置** |
| L2：读可见坐标 | 使用 `AXUIElement` 枚举 Finder 可访问的 UI 元素及位置 | 辅助功能权限、Finder 层级稳定性 | 可能因 macOS 版本/视图模式失效，必须有回退 |
| L3：视觉精确对齐 | 结合 AX 坐标与图形场景，精确趴坐/踢图标 | L2 + 定期校正 | 只可做视觉交互，不改 Finder 文件 |
| L4：真实操作文件 | 拖走或删除文件等 | 更多权限/高风险 | **不做** |

仅依赖 `FileManager.contentsOfDirectory` 绝不可能获得桌面图标精确坐标。必须通过 Finder 的 UI 可访问性结构或用户主动指定位置。若 AX 失败，产品不能“猜一个位置并假装它是真的 Finder 文件”。

### 6.3 FinderDesktopProvider 接口

```swift
struct DesktopTarget: Sendable {
    let id: String
    let displayId: UInt32
    let title: String?        // 可根据隐私设置不保存
    let kind: TargetKind     // file / folder / app / dock / unknown
    let frameOnScreen: CGRect
    let confidence: Double   // 0...1，低于阈值则不执行精确交互
}

protocol DesktopTargetProvider: Sendable {
    func visibleTargets() async -> [DesktopTarget]
}
```

实现建议在 AX 请求中加超时/节流，监听 Finder 状态变化进行失效，而不是每帧重新扫描全部控件。对桌面坐标的持久缓存也应设置短 TTL，尤其是图标手动拖动之后。

### 6.4 RoamPlanner 行为模型

每次游荡生成一个 15–45 秒的**本地场景计划**，不调用大模型：

1. 取当前显示器 `visibleFrame` 和边界安全余量。
2. 找可行停靠区域，避开菜单栏、Dock 和用户设置的禁入区。
3. 如有高置信度的可见 Finder 图标，在距离适中的目标中按随机权重挑选一项；否则随机选择地面/角落坐标。
4. 生成一段轻量动作序列：`jumpDown → walk → look → kick(x2) → sit → climbBack`。
5. 如果用户返回、任务需要审批或前台进入全屏，在可中断点退出；重要事件可以即时切换为短通知。

简化场景数据示例：

```json
{
  "sceneId": "roam-kick-icon-v1",
  "maxDurationMs": 28000,
  "requiresDesktopTarget": true,
  "steps": [
    { "action": "jump_down", "durationMs": 750 },
    { "action": "walk_to_target", "maxDurationMs": 9000 },
    { "action": "look", "durationMs": 1200 },
    { "action": "kick", "repeat": 2 },
    { "action": "speech", "textKey": "kick_icon_joke" },
    { "action": "climb_back", "maxDurationMs": 5000 }
  ]
}
```

### 6.5 “吃掉文件”效果怎么做

**不做真正的“图标消失”承诺**。推荐先做三个视觉层级：

- **普通版**：人物靠近图标、张嘴、咀嚼、满足/嫌弃；原图标一直保留。
- **增强版**：临时绘制纸片/像素碎屑/图标剪影，被鲸鱼娘吃掉；这是独立特效，不能遮挡或篡改真实图标。
- **高精度版**：AX 稳定、目标坐标可信时，用轻量遮挡/特效与原图标对齐，但用户随时能点击原始图标；无法稳定达到不挡点击就不启用。

### 6.6 与鼠标互动的有限规则

只获取角色附近的鼠标位置，不用把鼠标历史记录写盘：

- 指针进入角色近场 → 角色眼睛跟踪。
- 指针停在头部 Hitbox 超过阈值 → 播放蹭头/害羞。
- 连续短点 3 次 → 短暂嫌弃，进入 5–10 秒冷却；不能不断弹气泡。
- 长按角色 → 进入拖拽态，若用户释放则落地或回菜单栏。
- 用户快速恢复正常操作 → 宠物退到屏幕边缘或返回菜单栏。

### 6.7 空闲检测与触发限额

**产品默认值，必须可调整：**

- 无输入约 3 分钟：允许 Peek 偶发探头。
- 无输入约 10 分钟：允许触发一次桌面 roaming，且只在用户允许游荡时。
- 任何一次游荡最多 45 秒；至少间隔 10–15 分钟；每小时次数上限例如 3 次。
- 新发生键鼠输入时立即暂停新动作、视情况收起；不需读取按键文本。
- 全屏、会议、屏幕共享状态不精确时，默认宁可少游荡也不强行覆盖（可提供手动静默开关）。

`IdleDetector` 通过 macOS 提供的最近输入时间 API 获得时间差；`NSWorkspace.frontmostApplication` / Workspace 通知判断前台应用。不要用每秒数百次的全局 Event Tap 收集所有鼠标事件。

---

## 7. Codex 事件接入：真实支持范围与实施方案

### 7.1 主路径：AgentPet 的 Codex Hooks 安装器，而非 `notify`

**当前官方契约**：`notify` 目前**仅支持** `agent-turn-complete`，不得用于等待审批等 P0 能力。Codex 生命周期 Hooks 可提供 `PermissionRequest`、`Stop`、`PreToolUse`、`PostToolUse`、`SessionStart`、`SessionEnd` 等；以用户实际安装版本的 `~/.codex/hooks.json` 为准，`[features] hooks = true` 需与该版本核对（新版本可能默认开启）。来源：

- https://developers.openai.com/codex/hooks/
- https://developers.openai.com/codex/config-advanced
- AgentPet 源代码 `CodexHookConfig.swift`（**开工时锁定 SHA 后核对实际路径和配置逻辑**）

实施顺序：

1. 在锁定的 AgentPet 版本中审计 **CodexHookConfig.swift**，Fork 后保留其**增量合并 Hooks** 的能力，不写第二套会清空其它 Hook 的安装器。
2. 检查 `~/.codex/hooks.json` 和相关 `~/.codex/config.toml`，读取用户已有 Hooks 并备份；只追加 WhaleGirl 自有 handler，保留其他工具注册与用户配置；仅在用户确认后原子写入。
3. 优先监听 `PermissionRequest`（等待授权）、`Stop`（回合停止）、`SessionStart/SessionEnd`（生命周期），若已验证可用再监听工具事件。Hook 必须**永不自动批准/拒绝**用户命令；返回码、标准输出和耗时不能改变正常 Codex 决策。
4. 注明 Codex 安全审核可能需要用户在 `/hooks` 中信任新增 Hook；未被信任则显示“未启用/待批准”，不是虚报“已监控”。
5. `notify` **仅作为回合完成可选补充**，若既有 `notify`，不能替换成 WhaleGirl 数组；除非经过用户确认和兼容方案验证，否则不安装；若与 `Stop` 双发，用 `source + session + turn + type` 进行跨入口去重。
6. **隐私白名单**：Hooks 与 `notify` 的原始 payload 可能包含 `input-messages`、`last-assistant-message`、`cwd`、命令参数/命令输出。Helper 只提取受支持的事件类型、匿名化会话 ID、时间、审批类别等少数字段；上述原文**不落盘、不发 Socket、不进入日志、不发 DeepSeek API**。

只以标准字段归一化后的安全对象进入 EventHub。CLI、Codex Desktop 和 IDE 插件三类客户端的 Hook 覆盖范围分别测试；缺少审批事件的客户端必须显式显示“审批监控暂不可用”。

**Codex Hooks 发现与管理策略（V2.3 精确约束）：** `~/.codex/hooks.json`、用户级 `config.toml` 内联 `[hooks]`、信任的仓库级 `.codex/hooks.json` / `.codex/config.toml`、启用并确认信任的插件捆绑 Hooks 都可能提供事件；所有匹配来源是**合并执行**，不是按优先级覆盖。WhaleGirl 安装器**仅写用户级 `~/.codex/hooks.json`**，保留未知键和其他来源，并记录回滚备份。由于同一事件可能来自多份 Hook，必须按会话+事件身份去重。项目级 Hook 仅在项目受信任后可用，非 managed Hook 可能需在 `/hooks` 人工信任；设置界面应显示“待信任/启用状态未知”。

`[features] hooks = false`（用户可设）及组织 `requirements.toml` 中强制关闭 Hooks 或设置 `allow_managed_hooks_only = true` 的策略不可绕过；发现管理策略禁用或只有 managed hooks 时，不得自行重新启用、修改策略文件或偷偷改用侵入式监听，必须显示“Codex 审批监控暂不可用”，并允许保留可用的完成通知。具体以安装的 Codex 版本与官方文档为准：[Codex Hooks](https://developers.openai.com/codex/hooks)。

### 7.2 Codex Hook 适配器、去重与测试

Hook Helper 在接收 Codex 原生 JSON 后先做**字段白名单投影**，不把原始 JSON 保存在内存中的长期队列；再生成 `WhaleEvent`（不含输入消息/完整回复）发到独立 WhaleGirl Socket，短超时失败只记录脱敏诊断。不能为获得“等待审批”去修改 Codex 的批准策略。

**状态覆盖表（版本敏感，功能上线前必实测）**：

| 客户端 | working/start | turn 完成 | 等待审批 | 失败 | 打开会话 |
|---|---|---|---|---|---|
| Codex CLI | Hooks `SessionStart/PreToolUse` 等事件按版本测试 | `Stop` 为主；notify 可补充 | Hooks `PermissionRequest` 优先 | Hook 与 CLI 状态事实确认 | 终端定位需另测 |
| Codex Desktop | 待实测，不外推 CLI | 待实测 | 待实测 | 待实测 | 优先打开 App |
| Codex IDE | 待实测 | 待实测 | 待实测 | 待实测 | 依插件版本 |

**Fixture**：`PermissionRequest`、`Stop`、`SessionStart`、重复 `agent-turn-complete`、未知事件/拒绝 Hook 信任，以及包含 `input-messages/last-assistant-message/cwd` 的隐私攻击样例。断言这些字段在 WhaleEvent JSON、SQLite、日志中都不存在。

### 7.3 与额度/模型切换的联动

- 若 AgentPet 有稳定的 Codex 额度状态来源，读取后提供阈值告警；遇到不支持或来源失效时显示“数据不可用”，不猜测剩余额度。
- 第一版只做“提醒可以转 DSH”和“一键打开 DSH”，不自动篡改进行中会话配置。
- 真正跨 Agent 接续需要导出当前任务摘要、修改差异、工作树状态、未完成清单，且得到用户确认；由单独的 handoff workflow 开发，不能只切换一个按钮就叫无缝转移。

---

## 8. DeepSeek Harness 状态桥接

### 8.1 P0 状态 → 来源矩阵与降级策略（必须实施）

本节是 Phase 1 等待状态唯一业务契约。**不允许“支持 DSH 的 running/idle”被 UI 展示成“支持等待审批”。**

| 规范状态 | 第一来源（已知可用路径） | 第二来源（按版本验证后可用） | 无确定性来源时 | 展示行为 |
|---|---|---|---|---|
| `agent.waiting_approval` | DSH Pet/MoodBall 状态桥接的“等待你的授权”分类 | `session/event(session,event)` 中锁定版本的 `approval/asked` + `approval/decided` 配对 | 启发式最多标注“疑似等待”，不升级为确定状态 | 已确认才显示“等待授权”；否则显示“审批监控暂不可用” |
| `agent.waiting_input` | DSH Pet/MoodBall 的“做出你的抉择”分类 | 只有验证过确切且可关联的只读状态/持久事件时启用，不得假定存在 `user-questions/*` emit | 未知 | 已确认才显示“等待输入”；否则显示“输入监控暂不可用” |
| `agent.working` | `agent/status`、MoodBall 工具/思考状态 | `api-session/status` 或 session 运行事件 | 连接断开提示状态过期 | 仅证明运行，不证明审批或等待 |
| `agent.turn_completed` | MoodBall 完成状态 | 已验证 session `turn/end` 类型与结束语义 | 无 | 标为“本轮完成”，不冒充整个会话完成 |
| 子 Agent 开始/结束 | `subagent/start`、`subagent/end` emit | `session/created`、`session/disposed` emit 的会话生命周期 | 无 | 只有子任务状态变化，不擅自改父任务终态 |

MoodBall 优先的前提是**本机真实状态帧已验证且未过期**；此处“等待你的授权/做出你的抉择”是上游 README 的显示分类，**不等于 Socket JSON 的实际字段和值已经核定**。Phase 0 要用真实运行中的 MoodBall JSON fixture 锁定原始字段、版本和状态清除规则，在 `DSHAdapter` 内归一化；不能直接照 README 的中文标签作为协议枚举。

> 注意：官方 DSH 的用户审批模块把 `approval/asked`、`approval/decided` 作为 Session 的持久**审计事件**，而 `session/event` 是 `emit` 只读通知。因此在**对应的已验证版本**中，可用它们准确记录审批开始/结束而不触碰 waterfall；但要核实实际 `event.type`、请求 ID、session ID 与版本兼容。如果某版本缺失审计事件或无法配对，该路径必须自动禁用。`user-questions/request` 仍是 waterfall；不能因推测输入等待而拦截它。

**来源优先级**：同一 `sourceInstance+sessionId+generation` 下，**先比较已验证证据的最新时间**，若时间相同且无冲突，再按来源优先级 MoodBall 明确状态 > 已验证的 `approval/asked`/`approval/decided` 配对 > 带“推测”标签的非权威状态 > 监控不可用。不能以过期 MoodBall 状态覆盖较新的、已确定的生命周期终止事实；比较时间戳、序号和连接 generation，并对不同来源做幂等与 TTL。

**审批准入/清除**：仅在有同一会话、同一审批请求身份的确认事件时清除等待；`agent/status: idle/running` 不能单凭状态变化强行清除审批。连接断开时保留最近状态但标注 stale，不声称当前仍在审批。没有真实审批状态来源的环境，必须显示覆盖率警告，**不能通过 Phase 1 验收**。

**V2.3 新增传输候选：MoodBall 只读 HTTP fallback（优先做 Phase 0 可行性验证）**。上游 DSH Pet README 说明：状态 Socket 不可用时，它可向配置中的 HTTP Host 查询 `/api/moodball/status`。这只证明**上游 App 具有 fallback 行为**，不证明此端点在用户实际 DSH 版本、Profile 或端口下允许 WhaleGirl 直接读取。新增 `MoodBallHTTPProbe`：交付包提供 `scripts/probe_moodball_http.py`（**只报告脱敏 JSON 字段名与类型，不输出响应值**；可由用户手动对已知端口运行），只向用户明确选择的本机 Host (`127.0.0.1`/`::1`) 发起最小 GET，短超时、低频退避、禁止自动跟随非 loopback 重定向；验证响应状态码、认证需求、字段 schema、会话身份、等待审批/输入覆盖、时效/序列号、是否能同时连接。必要时允许用户配置经验证的本机地址，**不得**扫描端口或直接假定 3080 永远正确。HTTP 可以作为 moodball 的**另一种传输**，不是自动更高可信度的新审批来源；证据等级与 freshness 必须以响应内容和版本锁定为准。若只返回全局状态而无会话 ID，只能显示“DSH 整体等待”且**不得**虚构到具体 session。严禁把访问令牌、邮箱正文或任何模型消息写入探测日志。验证条目为 `DSH-HTTP-001`、`DSH-HTTP-002`、`DSH-HTTP-003`，未测试前标记**可行性未确认**。

**Socket 所有权修订**：上游插件把状态推送到 `~/Library/Application Support/MoodBall/moodball.sock`；这个 Socket 通常由 DSH Pet **作为接收端监听**，WhaleGirl 不可能同时把自己挂上同一个独占 socket 路径“旁听”消息。优先派生经许可的轻量插件，改向 WhaleGirl 独有的 Socket 发送；或者让已有 DSH Pet 提供经确认的转发能力。无故不得 `unlink`、抢占 MoodBall 自有监听路径，更不能让两个应用互抢。

**待审批三种技术落地路径**：A）MoodBall 派生状态插件发送至 WhaleGirl 自有 Socket；B）经版本核实的 DSH Pet 明确转发；C）经 Phase 0 验证的只读 HTTP `/api/moodball/status`。优先选**无需抢占 Socket、能精确覆盖会话且维护成本最低**的路径，而非先验断言某路径必须为主。三者只属于传输层差异；状态优先级仍由 MoodBall 明确证据、经验证的 Session 审计、启发式推测、不可用组成。

### 8.2 Cordis 只读事件：emit / Session 审计与子任务生命周期

- `session/event(session,event)`：`emit`，**两个参数**；只有 `event` 是 SessionEvent。对已验证版本识别 `approval/asked` 与 `approval/decided`（审批 audit pair）；正常 `turn/*`、`step/*`、`tool/*` 只做对应事实映射。
- `agent/status`：`emit`，只呈现 `idle/running` 等实际提供的状态。不能生成确定的待审批状态。
- `agent/error`、`api-session/status`、`api-session/error`：`emit`；仅转换必要元数据，不序列化完整错误和 prompt。
- `session/created` / `session/disposed`：`emit`；记录 Session 实际生命周期、父子关联的可验证事实。
- `subagent/start` / `subagent/end`：`emit`；记录子任务开始与结束。`subagent/end` 不会强制父 Session 完成；跨 Provider 的 runId 与 SessionId 要单独处理。
- **绝不为只读监听器注册** `agent/request-error`、`approval/request`、`user-questions/request`：这些 waterfall 事件的返回值/`next()` 会参与 DSH 执行决策，非观察型接入容易改变重试和审批链。

概念性 TypeScript 事件投影（只有签名展示，仍需依版本适配类型；不是可直接打包的插件）：

```ts
export function apply(ctx: Context) {
  ctx.on('session/event', (session, event) => {
    // 不抓取 event 的任意原文，先按锁定版 schema 映射白名单字段。
    // approval/asked 与 approval/decided 要使用稳定 requestId 配对。
    queueSanitizedSessionFact(session, event)
  })
  ctx.on('agent/status', payload => queueStatusOnly(payload))
  ctx.on('session/created', session => queueSessionCreated(session))
  ctx.on('session/disposed', session => queueSessionDisposed(session))
  ctx.on('subagent/start', function (info) { queueSubagentStarted(this, info) })
  ctx.on('subagent/end', function (info) { queueSubagentEnded(this, info) })
  // NO approval/request, user-questions/request, agent/request-error
}
```

`queue*` 是必须自行实现的脱敏、有界、非阻塞投递函数。`this` 的 scoped carrier 和 `info` 类型在锁定 SHA 下验证；严禁把全部 Session、Agent 或 Error 原始对象直接序列化到 Socket。

**HTTP 专项 PoC（不上 CI，以真实 DSH 实机验收）**：`DSH-HTTP-001`：Socket 不存在时，尝试已配置回环 HTTP endpoint，记录 HTTP 状态码/响应 schema 的脱敏摘要与重连延迟；`DSH-HTTP-002`：进入权限等待及输入等待，核对响应字段能否区分且能关联 sessionId，不能时明确显示“只提供全局状态/审批监控暂不可用”；`DSH-HTTP-003`：验证无认证/有认证、重定向至非 loopback、连接拒绝、超时、不同 Web/Desktop Profile 时均安全降级，绝不影响原有 DSH 重试/审批。

**PoC 测试**：`DSH-APPROVAL-001` MoodBall 权限等待→批准/拒绝→恢复；`DSH-APPROVAL-002` 问题等待→回答→恢复；`DSH-APPROVAL-003` 没有可靠来源→明确不可用；`DSH-AUDIT-001` 审计 asked/decided 精确配对；`DSH-PARENT-001` 子 Agent lifecycle 不错误结束父 Session；`DSH-EVENT-002` DSH 重试链安装前后无变化。每条 PoC 都记录 profile、DSH SHA/版本、原始数据**的脱敏类型摘要**及验收证据，不上传内容全文。

DSH 官方参考：[approval subsystem](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/approval.md)、[session subsystem](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/session.md)、[subagent lifecycle](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/subagent.md)；[MoodBall 状态说明](https://github.com/sundusk/dsh-pet#小雨动作帧)。

### 8.3 Web 与 Desktop 两种 Profile

- **Web/CLI Profile**：安装器从用户已启动的 Harness 实例/配置确定目标，展示将在哪个 profile 安装插件，确认后执行兼容命令。
- **Desktop Profile**：按 DSH 桌面版提供的插件管理 UI 安装；**不要**把 `dsh plugin --profile web add ...` 当成安装桌面版的替代品。
- 插件安装失败时，WhaleGirl 应可运行，状态显示“未连接”，支持重新检查、诊断信息复制。
- 多个 Harness 实例同时打开，`sourceInstance` 必须包含实例标识与 profile，避免状态互相覆盖。

### 8.4 精确跳转会话的边界

DSH Pet 已说明其某些版本中缺乏稳定的“打开指定会话”的官方外部深链。WhaleGirl 第一版采用“打开 Harness + 复制会话 ID”；只有在官方接口明确可用、通过版本适配测试后，才提供一键跳到该精确会话。不要擅自拼造不受支持的 URL。

---

## 9. 邮件、系统监控、通知与面板

### 9.1 邮件模块

初期优先实现**只读新邮件提醒**，不默认具备发件、删件或自动回复能力。

推荐多提供商策略：

- 支持 IMAP IDLE 的账号：使用只读 IMAP 客户端监听；断开时指数退避重连，遵守服务提供商对 IDLE 的超时与限流。
- 支持 OAuth2 的邮箱：优先 OAuth2，凭据放 Keychain；不要要求用户将主账号密码直接写入配置文件。
- 无 IDLE / 连接不稳定时：低频回退轮询（例如 5–15 分钟），而不是 1 秒刷新。
- 系统已有 Apple Mail 的用户：可以提供“打开 Mail / 显示徽标”能力，但不假设 Apple Mail 提供一个所有版本通用的实时新邮件事件 API。

新邮件去重键推荐 `accountId + mailbox + UIDVALIDITY + UID`（IMAP 语义），若 UIDVALIDITY 变化需重新处理初始同步基线，避免把历史邮件全部标为新邮件。默认读取：是否未读、到达时间、发送人显示名（可关闭）、主题（可关闭）；不读取正文。

默认不通知营销订阅和低优先级邮件；联系人白名单、关键词和时间段可以作为后续过滤项，但不允许默认将邮件标题发送给第三方 AI。

### 9.2 系统监控实现

| 指标 | macOS 技术方向 | 采样和局限 |
|---|---|---|
| CPU 总占用 | Mach `host_processor_info` / RunRat 的采样器 | 通过两次累计 tick 差值计算，不用单时刻瞬时 tick 直接作为百分比 |
| 内存 | Mach `host_statistics64` 或系统 API | 区分物理已用、内存压力、App 进程内存；不能把缓存全算“占用” |
| 电池 | IOKit Power Sources | 台式机无电池时显示不支持，检测是否充电 |
| 网络上下行 | `getifaddrs` + 接口字节计数，或系统网络 API | 两次采样求速度；切换 Wi-Fi/网卡时处理计数器归零 |
| 磁盘空间 | `URLResourceValues` / FileManager volume 属性 | 默认只展示可用空间；磁盘 I/O 另做 |
| 温度 / GPU | RunRat 的可能采样实现和可用公共接口 | 不保证每个 M 系列芯片都有同样开放指标，拿不到就隐藏 |
| 前台 App | `NSWorkspace.frontmostApplication` | 获取应用名称，不默认获取窗口内容 |
| 活动监视器 | `NSWorkspace.openApplication` 等受支持方式 | 用户点击时打开系统 Activity Monitor |

指标采样一般 2–5 秒足够；打开 Dashboard 时可改为 1 秒，收起后降频。不得为刷新系统数据而每帧遍历进程列表。程序级网络流量精确计量远比总流量复杂，**不属于基础版本承诺**。

### 9.3 Dashboard 界面结构

顶层分为 `Overview | Agents | Mail | History | Settings`，但菜单栏小面板首屏尽量简洁：

```text
┌ WhaleGirl ────────────────────────────┐
│ CPU  12%  MEM 9.2G  NET ↓1.4MB/s    │
│                                      │
│ Codex · AIShortFilm     等待审批 [查看]│
│ DSH   · 项目 A          运行中       │
│                                      │
│ 邮箱    新邮件 2 封      [打开邮箱]   │
│                                      │
│ [活动监视器] [静音] [游荡开关] [设置]│
└──────────────────────────────────────┘
```

点击一条消息时只允许打开白名单对应的应用或可信 URL；不能把来自不可信事件源的任意 `openTarget` 当成 shell 命令执行。邮件标题默认不直接浮现在屏幕共享画面上，需用户开启“显示邮件预览”。

### 9.4 系统通知规则

用 `UNUserNotificationCenter` 发送可关闭的完成、等待和邮件通知。用户禁用通知权限时，菜单栏角标与历史记录仍可用；通知与 Overlay 不能同时无节制重复播报。未读以 EventHub 数据为准，通知送达不是“已读”，点击面板或用户确认才更新。

---

## 10. PetBrain 状态机、随机行为与优先级仲裁

### 10.1 两个正交状态机

不要把“窗口形态”和“角色心情”合并成 70 个状态：

**显示状态（PresentationMode）**和**语义状态（PetMood）**是两套明确、独立的枚举（与 §5.4 完全同名）：

```swift
enum PresentationMode: Sendable {
    case mini, peeking, interacting, roaming, returning, hidden
}
enum PetMood: Sendable {
    case idle, working, waiting, celebrating, error, curious, sleepy, annoyed
}
```

**契约源文件**：`tests/SwiftContractPackage/Sources/WhaleProtocol/PresentationMode.swift` 提供可编译的 `PresentationMode` 和 `PetMood` 枚举；`fixtures/contract_constants.json` 分别声明 `presentationModes`（六种窗口状态）与 `assetVariants`（`mini/peek/full` 三套素材）。`doc_check.py` 必须解析 §10.1 代码块、Swift 源码与 fixture 三方，逐个集合相等，不得混用“窗口显示模式”和“素材类型”。

组合产生已定义的素材键：`mode=mini,mood=waiting → mini.waiting`；`mode=peeking,mood=waiting → peek.show_card`；`mode=mini,mood=working → mini.working`。素材缺失走 manifest 显式 `fallbackAnimation`，最后退至 `mini.idle / peek.hold_edge / full.idle`；不可直接崩溃或黑屏。旧式枚举及 `mini.work`、`mini.wait` 都不作为合法标识。

### 10.2 调度器输入与输出

输入：`UserIdleSeconds`、`MouseProximity`、`ForegroundApplication`、`AgentSummary`、`UnreadMailCount`、`SystemLoad`、`VisibleDisplay`、`QuietMode`、`PowerState`、`UserPreferences`。

输出：

```swift
struct PetDecision {
    let mode: PresentationMode
    let animationId: String
    let speechText: String?
    let target: CGPoint?
    let interruptPriority: Int
    let maxDuration: TimeInterval
}
```

模型只负责可选 `speechText`，不要把精确位置和动作时间线交给 LLM 决定。

### 10.3 仲裁规则

优先级：用户显式命令 > 待审批/待输入 > 未读错误 > 未读完成 > 邮件 > 用户鼠标互动 > 自主行为。用户交互触发的“去睡觉 / 禁止游荡”必须持续生效，不可被模型文本覆盖。

按如下流程选择：

```text
接收到事件
    ↓
EventHub 验证/存储/去重
    ↓
SessionReducer 更新事实状态
    ↓
NotificationPolicy 确定是否应该提醒
    ↓
PetBrain 查当前显示状态与冷却时间
    ↓
若高优先级事件 → 中断低优先级 Roam，切换到必要提示
否则若空闲且满足条件 → 随机触发一个有上限的小剧场
否则 → 保持 Mini 低频动作
    ↓
AnimationController 播放 + OverlayController 定位
```

### 10.4 随机行为设计

使用**权重 + 冷却 + 互斥条件**。例如：

```json
{
  "behavior": "peek_and_wave",
  "weight": 15,
  "requiredModes": ["mini"],
  "minimumIdleSeconds": 180,
  "cooldownSeconds": 900,
  "durationMs": 4500,
  "disallowWhen": ["fullscreen", "quiet", "screen_share", "awaiting_approval"]
}
```

随机行为不能因为连续失败不断重试或连续生成台词。维护一份 `recentActions` 环形数组，避免 5 分钟内重复同一动作；每小时最多触发几次，确保低打扰。

### 10.5 鼠标交互中断与位置稳定

- 鼠标主动接近时，视线追踪可以 15–30 Hz 更新**目标眼睛方向**，但人物贴图仍可以 4–8 fps；不必触发逐帧图片重载。
- 角色足底锚点保持固定；被拖动时只改变 `root transform`。
- 互动开关关闭时，不再要求系统级鼠标权限；关闭“桌面游荡”后应立即停止不必要的定时器。
- 鼠标拖拽有明确阈值和退出条件，用户可以按 Esc（只在宠物窗口获得必要输入时）或点击菜单栏“回家”强制收起。

---

## 11. 本地数据层、迁移与日志

### 11.1 SQLite 优先存事实，不存私密正文

建议使用 SQLite 的 `WAL` 日志模式和数据库串行写队列/actor；不跨线程共享同一未经保护的连接。数据目录放在：

```text
~/Library/Application Support/WhaleGirl/
  whalegirl.sqlite
  settings.json              # 非敏感或仅临时迁移用途，正常优先 UserDefaults
  assets/                    # 用户导入的授权角色包
  diagnostics/               # 经过脱敏、可手动导出的诊断日志
```

尽量不要默认缓存实际用户消息、邮件正文、命令输出、磁盘完整绝对路径。

### 11.2 SQLite Wire v1 / 数据库 Schema V3 完整定义（与 WhaleEvent DTO 一致）

**`tests/sql/schema_v1.sql` 是唯一可执行 SQL 源，本节代码块必须与其逐字相同并由 CI 验证。该初始化脚本只允许用于空数据库；既有库必须调用迁移器，禁止在旧库上直接运行本脚本。** 对已创建旧库采用带版本号 migration，不做破坏性 DROP。时间使用 UTC ISO8601 文本，`received_at` 总由主程序提供；`privacy_class` 必须存在。

```sql
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    event_id TEXT NOT NULL CHECK(length(CAST(event_id AS BLOB)) BETWEEN 1 AND 128 AND instr(event_id,char(0))=0),
    schema_version INTEGER NOT NULL CHECK(schema_version = 1),
    source TEXT NOT NULL CHECK(source IN ('codex','dsh','mail','system','whale','remote')),
    source_instance TEXT NOT NULL CHECK(length(CAST(source_instance AS BLOB)) BETWEEN 1 AND 64 AND instr(source_instance,char(0))=0 AND source_instance GLOB '[A-Za-z0-9]*' AND source_instance NOT GLOB '*[^A-Za-z0-9._:-]*'),
    session_id TEXT CHECK(session_id IS NULL OR (length(CAST(session_id AS BLOB)) BETWEEN 1 AND 256 AND instr(session_id,char(0))=0 AND session_id GLOB '[A-Za-z0-9]*' AND session_id NOT GLOB '*[^A-Za-z0-9._:-]*')),
    parent_session_id TEXT CHECK(parent_session_id IS NULL OR (length(CAST(parent_session_id AS BLOB)) BETWEEN 1 AND 256 AND instr(parent_session_id,char(0))=0 AND parent_session_id GLOB '[A-Za-z0-9]*' AND parent_session_id NOT GLOB '*[^A-Za-z0-9._:-]*')),
    project_key TEXT CHECK(project_key IS NULL OR (length(CAST(project_key AS BLOB)) BETWEEN 1 AND 256 AND instr(project_key,char(0))=0 AND project_key GLOB '[A-Za-z0-9]*' AND project_key NOT GLOB '*[^A-Za-z0-9._:-]*')),
    event_type TEXT NOT NULL CHECK(event_type IN (
        'agent.session_started',
        'agent.working',
        'agent.tool_started',
        'agent.tool_finished',
        'agent.waiting_input',
        'agent.waiting_approval',
        'agent.turn_completed',
        'agent.session_completed',
        'agent.failed',
        'agent.interrupted',
        'agent.disconnected',
        'agent.heartbeat',
        'mail.new',
        'mail.read',
        'mail.connection_lost',
        'system.load_high',
        'system.battery_low',
        'system.woke',
        'system.slept',
        'system.idle_started',
        'system.user_returned',
        'pet.clicked',
        'pet.hovered',
        'pet.drag_started',
        'pet.drag_finished',
        'pet.roam_finished'
    )),
    severity TEXT NOT NULL CHECK(severity IN ('info','success','warning','error','action_required')),
    privacy_class TEXT NOT NULL
      CHECK (privacy_class IN ('metadata_only', 'local_sensitive')),
    summary_redacted TEXT CHECK(summary_redacted IS NULL OR (length(summary_redacted) <= 200 AND length(CAST(summary_redacted AS BLOB)) <= 800 AND instr(summary_redacted,char(0))=0)),
    display_target_json TEXT CHECK(display_target_json IS NULL OR (json_valid(display_target_json) AND json_type(display_target_json)='object' AND instr(display_target_json,char(0))=0)), -- caller must sanitize/allowlist
    metadata_json TEXT CHECK(metadata_json IS NULL OR (json_valid(metadata_json) AND json_type(metadata_json)='object' AND instr(metadata_json,char(0))=0)), -- caller must sanitize values
    occurred_at TEXT NOT NULL CHECK(length(CAST(occurred_at AS BLOB)) BETWEEN 20 AND 25 AND instr(occurred_at,char(0))=0),
    received_at TEXT NOT NULL CHECK(length(CAST(received_at AS BLOB)) BETWEEN 20 AND 25 AND instr(received_at,char(0))=0),
    sequence_no INTEGER CHECK(sequence_no IS NULL OR sequence_no >= 0),
    read_at TEXT,
    CHECK (metadata_json IS NULL OR length(CAST(metadata_json AS BLOB)) <= 2048),
    CHECK (privacy_class != 'local_sensitive' OR (summary_redacted IS NULL AND metadata_json IS NULL AND display_target_json IS NULL)),
    CHECK (
      (event_type LIKE 'agent.%' AND source IN ('codex','dsh','remote')) OR
      (event_type LIKE 'mail.%' AND source = 'mail') OR
      (event_type LIKE 'system.%' AND source = 'system') OR
      (event_type LIKE 'pet.%' AND source = 'whale')
    ),
    CHECK (event_type NOT IN ('agent.waiting_approval','agent.waiting_input') OR severity = 'action_required'),
    CHECK (event_type != 'agent.failed' OR severity = 'error'),
    CHECK (event_type NOT IN ('agent.turn_completed','agent.session_completed') OR severity = 'success'),
    CHECK (source NOT IN ('codex','dsh','remote') OR session_id IS NOT NULL),
    PRIMARY KEY (source, source_instance, event_id)
);
CREATE INDEX IF NOT EXISTS events_recent_idx ON events(received_at DESC);
CREATE INDEX IF NOT EXISTS events_session_idx
  ON events(source, source_instance, session_id, received_at);

CREATE TABLE IF NOT EXISTS sessions (
    source TEXT NOT NULL,
    source_instance TEXT NOT NULL,
    session_id TEXT NOT NULL,
    parent_session_id TEXT,
    project_key TEXT,
    state TEXT NOT NULL,
    state_evidence TEXT CHECK(state_evidence IN ('moodball','session_audit','heuristic','none')),
    approval_coverage TEXT NOT NULL DEFAULT 'unavailable'
      CHECK(approval_coverage IN ('supported','unavailable','unknown')),
    needs_attention INTEGER NOT NULL DEFAULT 0 CHECK(needs_attention IN (0,1)),
    unread_count INTEGER NOT NULL DEFAULT 0 CHECK(unread_count >= 0),
    last_sequence_no INTEGER,
    updated_at TEXT NOT NULL,
    stale_since TEXT,
    PRIMARY KEY(source, source_instance, session_id)
);

CREATE TABLE IF NOT EXISTS mail_seen (
    account_key TEXT NOT NULL, mailbox TEXT NOT NULL,
    uidvalidity TEXT NOT NULL, uid TEXT NOT NULL,
    seen_at TEXT NOT NULL,
    PRIMARY KEY(account_key, mailbox, uidvalidity, uid)
);

CREATE TABLE IF NOT EXISTS dialogue_cache (
    cache_key TEXT PRIMARY KEY, text TEXT NOT NULL,
    topic TEXT NOT NULL, generated_at TEXT NOT NULL,
    expires_at TEXT, api_generated INTEGER NOT NULL DEFAULT 0
);

-- 同一表表达每笔调用的预留费用与最终确认费用。
-- 单位：人民币百万分之一元；2 元上限 = 2,000,000。
CREATE TABLE IF NOT EXISTS api_requests (
    request_id TEXT NOT NULL PRIMARY KEY CHECK(length(CAST(request_id AS BLOB)) BETWEEN 1 AND 128 AND instr(request_id,char(0))=0),
    local_day TEXT NOT NULL CHECK(
      length(CAST(local_day AS BLOB))=10 AND instr(local_day,char(0))=0 AND
      local_day GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND
      CAST(substr(local_day,1,4) AS INTEGER) BETWEEN 1 AND 9999 AND
      CAST(substr(local_day,6,2) AS INTEGER) BETWEEN 1 AND 12 AND
      CAST(substr(local_day,9,2) AS INTEGER) BETWEEN 1 AND
      CASE CAST(substr(local_day,6,2) AS INTEGER)
       WHEN 2 THEN CASE WHEN (CAST(substr(local_day,1,4) AS INTEGER)%4=0 AND
          (CAST(substr(local_day,1,4) AS INTEGER)%100!=0 OR CAST(substr(local_day,1,4) AS INTEGER)%400=0)) THEN 29 ELSE 28 END
       WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END
    ),
    provider TEXT NOT NULL,
    model TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('reserved','confirmed','unknown')),
    reserved_cny_micros INTEGER NOT NULL DEFAULT 0 CHECK(reserved_cny_micros >= 0),
    actual_cny_micros INTEGER NOT NULL DEFAULT 0 CHECK(actual_cny_micros >= 0),
    input_tokens INTEGER NOT NULL DEFAULT 0 CHECK(input_tokens >= 0),
    output_tokens INTEGER NOT NULL DEFAULT 0 CHECK(output_tokens >= 0),
    created_at TEXT NOT NULL,
    settled_at TEXT,
    CHECK (state NOT IN ('reserved','unknown') OR reserved_cny_micros > 0),
    CHECK (state != 'confirmed' OR actual_cny_micros <= reserved_cny_micros),
    CHECK (reserved_cny_micros <= 2000000),
    CHECK (length(CAST(local_day AS BLOB)) = 10 AND instr(local_day,char(0)) = 0)
);
CREATE INDEX IF NOT EXISTS api_requests_day_idx ON api_requests(local_day, state);

-- Defense in depth. Both direct SQL writes and BudgetLedger reservations obey the same daily cap.
-- Unknown/unsettled charges hold their full reservation until explicitly reconciled.
CREATE TRIGGER IF NOT EXISTS api_requests_daily_cap_insert
AFTER INSERT ON api_requests BEGIN
  SELECT RAISE(ABORT,'daily CNY cap exceeded') WHERE
    (SELECT COALESCE(SUM(CASE WHEN state='confirmed' THEN actual_cny_micros
       ELSE reserved_cny_micros END),0) FROM api_requests WHERE local_day=NEW.local_day) > 2000000;
END;
CREATE TRIGGER IF NOT EXISTS api_requests_daily_cap_update
AFTER UPDATE OF local_day,state,reserved_cny_micros,actual_cny_micros ON api_requests BEGIN
  SELECT RAISE(ABORT,'daily CNY cap exceeded') WHERE
    (SELECT COALESCE(SUM(CASE WHEN state='confirmed' THEN actual_cny_micros
       ELSE reserved_cny_micros END),0) FROM api_requests WHERE local_day=NEW.local_day) > 2000000;
END;
-- Only run this schema initializer on an empty database. Existing users MUST run the guarded migrator.
PRAGMA user_version = 4;

-- V3.3 ledger immutability: daily spending history may not be erased to reset the cap.
-- Retention/archival requires a separate audited accounting migration.
CREATE TRIGGER IF NOT EXISTS api_requests_no_delete
BEFORE DELETE ON api_requests BEGIN
  SELECT RAISE(ABORT,'budget ledger deletion prohibited');
END;
CREATE TRIGGER IF NOT EXISTS api_requests_guard_transition
BEFORE UPDATE ON api_requests BEGIN
  SELECT RAISE(ABORT,'budget day and reservation immutable') WHERE
    OLD.local_day != NEW.local_day OR
    OLD.request_id != NEW.request_id OR
    OLD.reserved_cny_micros != NEW.reserved_cny_micros OR
    OLD.provider != NEW.provider OR OLD.model != NEW.model OR
    OLD.created_at != NEW.created_at OR
    (OLD.state = 'confirmed' AND
      (NEW.state != 'confirmed' OR NEW.actual_cny_micros != OLD.actual_cny_micros OR
       NEW.input_tokens != OLD.input_tokens OR NEW.output_tokens != OLD.output_tokens OR
       NEW.settled_at IS NOT OLD.settled_at)) OR
    (OLD.state = 'unknown' AND NEW.state = 'reserved') OR
    (OLD.state = 'reserved' AND NEW.state NOT IN ('reserved','unknown','confirmed')) OR
    (OLD.state = 'unknown' AND NEW.state NOT IN ('unknown','confirmed'));
END;

-- SQLite INSERT OR REPLACE can silently delete a conflicting row without firing
-- DELETE triggers unless recursive_triggers is enabled. Guard at BEFORE INSERT.
CREATE TRIGGER IF NOT EXISTS api_requests_no_replace
BEFORE INSERT ON api_requests BEGIN
  SELECT RAISE(ABORT,'budget request ID replacement prohibited') WHERE
    EXISTS(SELECT 1 FROM api_requests WHERE request_id=NEW.request_id);
END;
```

**字段同步策略**：events 为事实日志，`sessions.unread_count` 是缓存计数，必须在事件入库/标已读的**同一事务**调整；避免并发更新丢失。`sessions.last_sequence_no` 是 `SessionState.lastSequence` 的持久化。 `sessions.state_evidence` 持久化审批/输入状态的已验证来源；`sessions.approval_coverage` 用于设置面板准确显示功能覆盖情况，默认为 `unavailable`，新建连接时必须重新核验，不能从上次启动的“supported”永久沿用。针对已有 V2.1 数据库，先备份并通过 schema migration `ALTER TABLE` 增列；交付包 `tests/sql/migrate_existing_database.py` 是迁移算法的独立验证样例，不是自动操作用户数据库的命令。 `api_requests` 的 `reserved_cny_micros` 才是 §12.3 预留额来源，不依赖一个不存在的 `reserved` 表。

**一致性校验要求**：CI 读取当前 `WhaleEvent` CodableKeys/JSON fixture、SQLite PRAGMA table_info(schema) 和迁移结果，断言 §3.2 每个可持久字段均有明确表列或显式声明“不存储”的理由。`metadata` 与 `displayTarget` 即便存为 JSON 也只能保存白名单投影。

### 11.3 数据保留期限与删除

默认：详细事件 7–30 天；汇总计数 90 天；脱敏日志最短必要时间；API 费用账本可保留较长时间但不存 prompt。用户可在设置里导出 JSON/CSV 或“一键清除个人数据”，删除成功前需要关闭数据库并确保不会立刻由其他连接重新写回。

关键调试信息至少包括：进程是否运行、Socket 连接状态、各适配器最近事件时间、是否允许系统通知、当前 FPS、当前窗口数量、内存峰值、当前日 API 消费，但不得默认包含隐私原文。

---

## 12. DeepSeek AI 台词、预算和隐私保护

### 12.1 运行方式：90% 规则 + 低频云端

- 内置 200–400 条分类中文台词，按 `coding`、`approval`、`mail`、`idle`、`load`、`desktop`、`mouse` 等分类。
- 用户可在设置中编辑、禁用敏感话题与自定义角色性格。台词与场景采用可本地审核的 JSON/SQLite 数据。
- DeepSeek API 只在“刚发生可解释的新鲜事件”或极低概率随机触发时调用，默认每天最多 20 次（可调）。
- 角色每一秒的动作、目的地、颜色、碰撞都不走 AI 模型。AI 不决定是否批准工具命令，不具有直接调用 shell 或 Finder 修改操作的能力。

### 12.2 输入模板与生成约束

模型输入只包含白名单摘要，例如：

```json
{
  "persona": "蓝发鲸鱼娘，嘴毒但克制，幽默抽象，不人身攻击",
  "context": {
    "localTimeBucket": "afternoon",
    "foregroundApp": "Visual Studio Code",
    "agent": "Codex",
    "agentState": "turn_completed",
    "elapsedBucket": "10-20min"
  },
  "instruction": "只输出一句中文吐槽，20-40字，无解释、不包含敏感信息"
}
```

默认**禁止输入**：邮件正文、浏览器具体网页内容、用户当前聊天全文、命令输出、环境变量、密钥、工作目录绝对路径、屏幕截图。用户可以单独主动授权“针对选定错误摘要解释”，且该功能显示要发送的内容预览。

### 12.3 费用预留、结算与 ¥2 每日预算硬限制

**单一配置**：每天最多 **20 次**独立模型调用；主动台词 **两次开始时间至少相隔 60 分钟**（有事件但在冷却时用本地台词，不是每天固定发 24 次）；每日软预算 ¥0.50、主程序硬预算 ¥2.00。

数据表：§11.2 的 `api_requests`，金额整数 `cny_micros`（百万分之一元）。由**一个** `BudgetLedger actor` 对 SQLite 写事务串行执行，预留及请求计数须在**同一 `BEGIN IMMEDIATE` 事务**完成。

1. 收到候选调用，检查总次数与上次主动调用的冷却时间。
2. 估算本次上界费用 `required`，查询 `confirmed` 行 `actual_cny_micros` 之和，加 `reserved/unknown` 行 `reserved_cny_micros` 之和；若加 `required > 2_000_000`，不创建请求。
3. 条件满足则先插 `state='reserved'`、`reserved_cny_micros=required`，**成功提交事务后**才发送网络请求；取消/明确未发出的请求才能释放预留额。
4. API 成功返回 usage，更新 `state='confirmed'`，写入 token 与实际费用。供应商超时或无法确认是否实际扣款时置为 `unknown` 并继续占用 `reserved`，不能因重试立即释放额度；每个新请求有新预算预留。
5. **严禁单次确认金额超出已预留上界而仍继续新请求**：更新本地价格配置、暂停后续请求并提示用户对账。程序预算只约束后续调用，并非供应商最终账单保证。

定价、模型和汇率仅从版本化配置读取，记录生效时间；用户更改时重新计算保守上界。使用固定配置的本地日（用户选定时区）归集金额；切换时区不能导致同一天计数清零。

### 12.4 API 请求排队与缓存

- `APIUsageCounter` 采用 actor 串行锁；并发十个事件最多触发一个台词请求。
- 主动生成冷却 **至少 60 分钟**，同时受 **每日最多 20 次** 和 ¥2 预算限制；同类事件优先使用缓存、短句变体和模板。
- 超时如 5–10 秒，最多一次退避重试，失败不阻塞事件通知与动画。
- 台词生成结果可按场景复用，移除可能输出的原始提示内容、Markdown、网址和过长文本。
- 遵循用户禁止骚话/成人化内容的设置，保证在办公和共享屏幕场景不会突然显示不合适文字。

---

## 13. 资源占用、功耗与性能验收

以下指标都是**建议验收目标，不是已经测得的实际表现**，必须在 MacBook Air M4 上测试；操作系统后台本身存在采样噪声，需要多次测试取中位数和尾部峰值。

| 指标 | 建议目标 | 测试条件 |
|---|---|---|
| 静态待机 CPU | 尽量 <=0.5%（长期均值） | 主应用启动 10 分钟后，静置 30 分钟 |
| 有动效 CPU | 尽量 <=1%–2% 持续平均 | Mini + Peek 交替，正常 Dashboard 关闭 |
| 常驻内存 | 优先 <=100 MB，不以此牺牲稳定性 | 使用 3 套图集、10 个会话，不展开大窗口 |
| 帧率 | Mini 待机 1–2 fps、事件动作 3–4 fps；Peek/Full 4–10 fps | 动态按需播放；休眠/隐藏完全暂停 |
| 系统采样 | 默认 2–5 s | Dashboard 展开可变为 1 s |
| 任务响应 | 本地事件到菜单栏变化多数 <=500 ms | Socket 连接正常、主线程不忙 |
| 主动提醒 | 用户配置后不遗漏、不无限重复 | 单源断线/重连，10 个会话混合负载 |
| 空闲功耗 | 与完全禁用动画基线比增量尽可能小 | 电池模式、长时间锁屏与休眠唤醒 |
| 本地长期可靠性 | 连续 24–72 小时无异常累积 | 压测事件和切换 Space/显示器 |

### 13.1 省电机制优先序

1. 隐藏窗口时暂停帧计时器、AI 计时器与鼠标跟踪。
2. 状态栏仍可显示事件角标，不必持续跑 Animator。
3. 只在 Dashboard 可见时高频更新资源数据；不可见时降频。
4. 鼠标进入角色区域才启用相应 Tracking 逻辑，禁止全屏高频事件监听。
5. Sprite Atlas 预解码后复用图层、贴图和布局，避免每帧从磁盘读 PNG。
6. 远程 API 调用不可阻塞 UI 线程；超时和断网自动降级。
7. 按需创建 Overlay，不使用全屏透明常驻窗口；不用每帧扫描 Finder AX 树。

### 13.2 Instruments 与排查

- **Time Profiler**：记录状态栏空闲、Panel 弹出、Full 走动各 10 分钟热点。
- **Allocations / Leaks**：检查每次弹出 Panel、切换素材和取消动画后对象是否释放。
- **Energy Log**：比较 Wi-Fi 开启和离线状态的能耗；设置电池省电选项。
- **Activity Monitor**：观察常驻 CPU、实际内存、唤醒次数，注意不同采样窗口结果不可直接比较。
- **Network 模拟**：断网、DNS 超时、DSH 中断、邮件 IDLE 断连、睡眠唤醒，确认不会无限重试。
- **UI 压测统一标准**：流水线 smoke 运行 200 次 Panel 开合；Release 回归压力测试运行 **500 次** Panel 开合（同一场景加严）；另外 1000 条事件、跨显示器拖拽 100 次、切换 Space 后仍可恢复。

---

## 14. 权限、安全、签名、公证和更新

### 14.1 最小权限矩阵

| 功能 | 是否默认开启 | 需要的权限或用户动作 |
|---|---|---|
| 菜单栏头像、动画、系统总指标 | 是 | 正常应用权限 |
| Codex/DSH Hook | 用户显式连接 | 修改各自配置/安装插件，必须有恢复机制 |
| 通知中心提醒 | 用户选择 | 系统通知授权 |
| 登录自启动 | 默认关闭 | `SMAppService` 注册并按系统审批 |
| 邮箱新邮件 | 默认关闭 | 邮箱 OAuth/IMAP 登录与授权，Keychain 保存凭据 |
| 桌面文件名 | 默认关闭 | Desktop 文件夹访问授权；不能擅自递归读取其他目录 |
| Finder 图标精确坐标 | 默认关闭 | Accessibility 权限，且受系统/视图模式限制 |
| 屏幕截图或读取私密窗口内容 | 默认不做 | 如未来需求新增，再做专项 TCC/透明提示与本地处理 |
| 发送数据到 DeepSeek API | 默认关闭 | 明确选择启用、展示数据项、设置预算 |

### 14.2 重要安全边界

- Hook 只把状态 JSON 发到本地 Socket，不处理/修改 Agent 的工具调用内容。
- 无“自动审批危险命令”选项；等待审批由用户到 Codex/DSH 原应用处理。
- 角色“吃文件”不真实删除文件，Finder 只读来源与渲染特效数据必须单向流动。
- `displayTarget` 只支持少量可信类型：`bundleId`、经验证的内部会话 ID、用户确认的 URL；不允许任意 shell 命令。
- API key/邮箱授权令牌只在 Keychain，日志与 UI 截图隐藏敏感值。
- 外部附件/邮件标题/原始 Agent 文本属于不可信内容，不能改变角色的工具权限、API 预算和行为规则；台词生成输入也必须经过白名单过滤。
- 安装 Hook、删除 Hook、重置数据库、导出个人数据均需用户明确操作，安装器可撤回/卸载。

### 14.3 Release 构建与第三方许可

MVP 首先保证 Debug/Release 在本机运行；准备公开发布时再完成：bundle ID、签名证书、Apple Notary Service、公证包/DMG、自动更新签名、版本迁移与第三方 notices。Sparkle 作为 AgentPet 现有依赖可审查后复用。不能把第三方鲸鱼娘生成素材与 MIT 应用代码不经核实就打包公开分发；若权利不明，发布版使用有明确授权的原创素材，并保留 whale-girl 图集转换工具供个人导入。

---

## 15. 开发阶段、任务拆分、验收条件与交付物

### Phase 0——仓库审计与高风险 PoC（先做，避免后期推倒重写）

**具体任务：**

- [ ] 拉取并锁定 AgentPet、RunRat、DSH Pet、whale-girl 的固定 commit 与许可档案。
- [ ] AgentPet 可在 M4 + Xcode 16+ 环境完整构建、运行、收到模拟事件。
- [ ] 做 Mini 头像：`NSStatusItem` 内 2–3 帧眨眼，获取真实 button frame。
- [ ] 做透明 Peek `NSPanel`：从菜单栏下边出现/消失，点击穿透不干扰 Chrome 标签和菜单。
- [ ] Codex CLI 通过 AgentPet **`~/.codex/hooks.json` Hooks 主路径**触发 `PermissionRequest/Stop`；未信任 Hook 能诊断。`notify` 仅完成补充；保留用户配置并证明可无损卸载。
- [ ] 验证 `notify` 输入里含 `input-messages` / `last-assistant-message` 时，Helper 从不传出或存储原文。
- [ ] 验证 `JSONDecoder.iso8601` 可解析契约时区字符串；反例解码报错可计数。
- [ ] 独立 Socket 的 `0700/0600` 权限、`getpeereid`、第二实例、已存在 AgentPet Socket 不被 `unlink`。
- [ ] 安装并实测 DSH Web、Desktop Profile 任意一个；获得**真实**状态 NDJSON 样本，检验 `session/event(session,event)`；不使用 `agent/request-error` 监听，安装前后重试链行为一致。
- [ ] 选定图集许可路径：私人原型与可公开发布版分别说明。
- [ ] 记录至少一次每项 PoC 的录屏、日志和“失败回退”行为。

**交付物**：`docs/decisions/ADR-0001-base.md`、PoC demo、协议 fixture、锁定的 SHA 清单。**退出标准**：能展示从菜单栏位置探出人物，同时 Codex 或 DSH 完成事件可使 Mini 改表情。

**Phase 0 保留的验证门槛（源自 V2.3）**：完成 `DSH-HTTP-001/002/003` 的真实设备探测记录，并与 MoodBall 独立 Socket / 插件转发路径比较；只要本地 HTTP 不可用，应书面标记“不支持”，不把它当作已实现主路径。新增契约突变测试三项必须能让 CI 如预期失败（Swift DTO 缺失或额外字段、SQLite 列漂移、PresentationMode/时间精度漂移）；正式仓库引入后不得回退为文本存在性检查。

### Phase 1——日常可用 MVP

**任务：**

- [ ] 统一 WhaleEvent/SessionRegistry、持久去重和错误处理。
- [ ] Codex 与 DSH Adapter 能各自运行、重连、识别完成/等待/异常；不能覆盖另一会话状态。
- [ ] Mini 清晰、Peek 可收起、通知角标与 Dashboard 正常。
- [ ] 系统指标 CPU、内存、网络、电池及活动监视器入口。
- [ ] 重点设置：开机启动、静音、禁用动画、禁用游荡、缩放、通知类型。
- [ ] 所有关键通知都可显示来源、项目别名和更新时间；不暴露原始工作目录。
- [ ] 完成低功耗/基本无障碍和无权限降级。

**退出标准（不能弱化）**：两个 Agent 同时工作、一个完成、**DSH 或 Codex 的另一个有真实审批等待事件**时 UI 各自正确；必须使用由 Hook/MoodBall 或已核实审计事件提供的**确认状态**完成现场演示；若只拿到 `running/idle` 或无 MoodBall 状态源，标注“审批监控暂不可用”，**Phase 1 不能验收通过**，不能把模拟事件或“疑似”等同于真实审批支持。禁止网络后仍能运行、收本地事件并展示系统指标；实测 CPU/内存有性能报告。

### Phase 2——半身与大姿态互动

- [ ] Mini/Peek/Full 正式格式图集与转化工具。
- [ ] Peek 扒边、收缩、挥手、气泡、举牌；Active 鼠标追踪、戳脸、拖动与回家。
- [ ] 添加 `PetBrain` / `BehaviorScheduler` 与测试用例；支持优先级中断、冷却与静音。
- [ ] 多显示器、刘海、任务栏变化与屏幕缩放时保证角色不飞出屏幕。

**退出标准**：桌面常规操作不被角色透明窗口拦截；200 次 smoke + 500 次 Release 回归开合均不产生持续内存增长。

### Phase 3——桌面游荡 / Finder / 邮箱

- [ ] L0 无需 AX 的纯视觉游荡，按空闲时间概率触发，打断/回菜单栏正常。
- [ ] L1 读取 Desktop 文件名（用户授权）；L2 AX 桌面图标坐标实验、失败回退和隐私提示。
- [ ] 实现至少 3 个短小剧场：巡逻、踢图标、假装吃文件；不实际改文件。
- [ ] IMAP 新邮件（只读、OAuth/Keychain、UID 去重）、断线重连与邮件隐私设置。
- [ ] 全屏/会议/屏幕共享时默认静默；在无法准确检测的场景使用可见手动开关。

**退出标准**：关闭 AX 权限仍可游荡，磁盘上文件完整一致；离线/邮件网络断开不影响 Agent 监控。

### Phase 4——个性化、预算与扩展

- [ ] 本地台词库和分类随机词条，用户可改写/静音。
- [ ] 可选 DeepSeek API、Token 成本预算流水、软硬上限、缓存与超支降级。
- [ ] Codex 额度监控与转 DSH 提醒，数据不可用时如实提示。
- [ ] 通知历史与每日任务摘要，项目别名、长期趋势。
- [ ] 远程 Windows/ComfyUI 结构化事件可选适配器；先安全配对再接局域网。
- [ ] Windows 4K 显示比例与托盘 Mini 适配单独 PoC。

**退出标准**：模拟 24 小时满额请求，不能突破程序内硬预算；角色仍可离线行动；可重放一组跨设备事件 Fixture 得到稳定一致的状态。

### 15.1 全局自动化测试矩阵

| 测试 | 输入 | 期待 |
|---|---|---|
| E-001 幂等 | 相同 eventId 发 100 次 | 只存 1 条，只提醒一次 |
| E-002 并发 | Codex 工作中、DSH 完成 | 仍显示 Codex 工作中，DSH 单独完成 |
| E-003 子任务 | 子 Agent 结束，父 Agent 在跑 | 父状态保持工作中 |
| E-004 乱序 | 完成 seq=20 后到工作 seq=19 | 不回退到旧工作状态 |
| E-005 断线 | DSH Socket 断开并重连 | 显示失联/过期，重连后恢复，不误报失败 |
| E-006 格式错误 | 截断 JSON、超长 payload、未知枚举 | 显式诊断计数，主程序不崩溃，不静默 | 
| PROTO-DATE-001 | ISO 时区 `+08:00`、UTC `Z` | `.iso8601` 解码成功，往返一致 |
| PROTO-DATE-002 | 缺失/畸形 `occurredAt`、小数秒协议 v1 不支持 | 解码失败计数+脱敏诊断，未误入库 |
| CODEX-HOOK-001 | `PermissionRequest` + `Stop` | 审批与完成分离，Hook 主路径可达 |
| CODEX-HOOK-002 | `notify` 回合完成重复 + 私密字段 | 去重；原始 prompt、回复全文不入库/Socket/日志 |
| IPC-SEC-001 | 两个实例争用、已有 AgentPet Socket、symlink | 不抢占、不删别的 App Socket；权限校验 |
| DSH-HTTP-001 | MoodBall HTTP fallback 可访问性 | 仅本机回环、确定实际端口/Profile、验证 schema 与响应时效（实机） |
| DSH-HTTP-002 | HTTP 等待授权/输入能力 | 真实等待事件区别、会话关联证据；没有就如实降级（实机） |
| DSH-HTTP-003 | HTTP 错误/权限/重定向 | 无越界访问、无 token 泄露、无 DSH 行为副作用（实机） |
| DSH-EVENT-001 | `session/event(session,event)` | 第二参数 event.type 正确映射 |
| DSH-EVENT-002 | 模型请求重试 / WhaleGirl Socket 中断 | 无 waterfall 干预；原重试行为不变 |
| DSH-APPROVAL-001 | MoodBall 进入权限等待后审批结束 | 显示已确认审批、恰当清除，并记入来源 |
| DSH-APPROVAL-002 | MoodBall 等待回答后用户回复 | 显示已确认输入等待、匹配会话清除 |
| DSH-APPROVAL-003 | 无 MoodBall 及版本锁定审计源 | 显示“审批监控暂不可用”，绝不从 idle/running 瞎猜 |
| DSH-AUDIT-001 | `approval/asked` + `approval/decided` | 在锁定版通过 requestId 配对；失配禁用，不碰 waterfall |
| DSH-PARENT-001 | `subagent/start`、`subagent/end` | 只改子任务，不错误完成父 Session |
| SCHEMA-001 | DTO/JSON/SQLite 各字段 | 映射全覆盖，privacy/metadata/target/预算预留存在 |
| ASSET-001 | 所有引用的动作 ID | manifest 存在或有显式回退 |
| DOC-CHECK-001 | Mini FPS/预算限制/Panel 次数/模式枚举 | 文档、配置、测试唯一规范；`python3 scripts/doc_check.py` 必须通过 |
| CONTRACT-SET-001 | Wire JSON、Swift DTO、SQLite events | 集合完全相等（明确映射与 DB-only 白名单），类型/非空一致；新增字段不声明即失败 |
| CONTRACT-ENUM-001 | `presentationModes` / Swift / §10.1 | 枚举六个状态集合完全相等；`assetVariants` 与模式严格区分 |
| CONTRACT-TIME-001 | `timestampPrecision` / Swift Codec / XCTest | 秒级时间含时区通过，小数秒拒绝，配置项必须被校验器读取 |
| CONTRACT-MUT-001 | 契约突变注入 | 改动枚举、增删 Wire/DTO/SQL 字段、时间精度均如预期失败 |
| SCHEMA-NEG-001 | SQLite 的 CHECK / 主键空值非法值 | `python3 tests/sql/schema_negative_test.py` 逐项拒绝 |
| SCHEMA-MIG-001 | 历史库增加状态来源与能力字段 | `python3 tests/sql/migrate_existing_database.py` 幂等、保留旧行 |
| PROTO-XCTEST-001 | SwiftPM 协议单测 | `swift test --package-path tests/SwiftContractPackage` 退出码为 0 |
| UI-001 漂浮窗 Smoke | 反复 Peek 200 次 | 不持续增长内存，不拦截透明区域点击 |
| UI-004 漂浮窗 Release | 反复 Peek 500 次（Release 构建） | 无窗口泄漏、锚点漂移与持续内存增长 |
| UI-002 显示器 | 跨主副屏、切换 DPI/分辨率 | 人物比例与锚点正确、可回家 |
| UI-003 前台/全屏 | 全屏游戏或演示 | 不强行漂在全屏最上方 |
| PET-001 空闲触发 | 模拟无键鼠输入 10 分钟 | 根据配置概率触发、次数受限 |
| PET-002 中断 | 角色正踢图标，Codex 等审批 | 立即转入高优先级提醒并安全回收场景 |
| FINDER-001 无 AX | 用户拒绝辅助功能权限 | L0 视觉游荡工作，文件内容不变 |
| MAIL-001 去重 | IMAP reconnect，重复 UID | 只新提醒一次 |
| AI-001 预算 | 请求费估算超过剩余额度 | 不发请求，改用本地台词 |
| AI-002 网络 | 供应商 API 超时 | Agent 提醒与动画不被阻塞 |
| P-001 长时 | 72h 稳定性测试 | 无异常内存/进程/Socket 泄漏 |

**CI 可以执行的真实命令（交付包已包含脚本与测试工程）：**

```bash
swift test --package-path tests/SwiftContractPackage
python3 tests/sql/schema_negative_test.py
python3 tests/sql/migrate_existing_database.py
python3 scripts/doc_check.py
python3 tests/contract/check_mutations.py
python3 tests/contract/test_http_probe.py
```

`tests/SwiftContractPackage/` 是供 Phase 0 合并的独立 SwiftPM 测试工程；正式加入主应用后，必须把 `WhaleProtocol` 源码与 `Tests/ProtocolTests` 合并到产品 Package.swift 的测试 Target，**不能在产品中复制两套 WhaleEventCodec**。CI 不应只运行 `swift file.swift` 形式的 smoke。上述 XCTest 已覆盖秒级时区、小数秒拒绝、缺时区、超长摘要、无效 UUID、MoodBall 来源选择和不可用退化；macOS AppKit UI/Hook/DSH 真机测试仍须独立运行。

### 15.2 开发者每次提交必须提供的证据

- 修改文件列表、相关 ADR/协议版本（如有变化）。
- 本地构建命令与结果（SwiftPM/Xcode）。
- 自动化测试命令及统计，新增功能至少有对应 Fixture。
- UI 行为的短录屏或截图（菜单栏、Peek、透明点击测试）。
- 新权限请求为什么需要，拒绝时如何降级。
- 性能相关改动至少给前后测试对照，防止“流畅但高耗电”。

---

## 16. 建议的任务切片：直接给 Codex / DSH 执行

按“可审查、可回滚、一次只做一件事”原则交付：

**Task 00：基线调查**  
读取本手册、需求 V1.2、各仓库源代码与 LICENSE；输出代码目录与许可证矩阵，锁定依赖，不在此阶段重写 UI。

**Task 01：AgentPet 骨架**  
在单独 Fork 分支实现 WhaleGirl 命名/菜单栏 Mini 原型，保留原始 AgentPet 功能，测试程序可正常启动退出。

**Task 02：协议与测试（阻断条件）**  
实现 WhaleEvent、`WhaleEventCodec.decode(_:)`、SessionReducer、SQLite 完整表迁移及 `PROTO-DATE/SCHEMA` 测试。**未通过合法时区事件从 socket → 解码 → 入库 → UI 的纵向测试，不允许开始动画集成。**

**Task 03：两个 Agent 适配**  
优先复用/加固 AgentPet `hooks.json` 安装器（不能以 `notify` 代替审批），DSH 仅读 `emit` 事件；使用真实 CLI 与 Harness 样本测试 `working/waiting/completed/failed`，并实现隐私投影、跨入口去重、配置回滚。

**Task 04：MenuBar + Dashboard**  
接入系统资源指标和最近任务卡片；界面不阻塞正常 macOS 菜单操作。

**Task 05：Peek PoC**  
实现菜单栏锚点、透明面板、角色实际 hitbox、鼠标追踪、动画中断。逐个测 Chrome、Finder、VS Code 点击穿透。

**Task 06：素材流水线**  
转换已授权的 whale-girl 原型资源，生成三种 atlas 与 manifest、运行 verify_assets；新增缺少的过渡动作。

**Task 07：Roam L0**  
无 AX 条件下全身走动、闲置触发和自动回家，验证 Spaces 与全屏兼容。

**Task 08：Roam L2**  
用户可选 Finder AX 读图标，加入踢/抱/咬视觉效果和拒绝授权回退。

**Task 09：Mail**  
实现只读 IDLE/轮询及 UID 幂等，不读取/上传默认正文。

**Task 10：AI 对话与预算**  
本地台词 → API 可选 → RMB 费用账本 → 限额强制 → AI 故障退化。完成测试后才允许默认使用 API。

**Task 11：稳定性/发布**  
72 小时长测、签名、公证、迁移脚本、Hook 清理和脱敏日志，再准备安装包。

### 16.1 给执行 Agent 的通用指令模板

```text
你是 WhaleGirl 项目的资深 Swift/AppKit 工程师。
先完整阅读《WhaleGirl 技术设计与开发实施手册 V2.4》及 V1.2 总体需求；禁止仅凭 V1.0 开发。
严格按当前任务切片工作，不并行引入无关新功能。
开始编码前：检查实际仓库、锁定 commit、列出要改的文件、接口/许可证/权限风险。
新增代码必须配对应单元测试/Fixture；不确定的外部 API 以实际源码和官方文档验证。
不得把伪代码直接当作可编译代码；不要猜 Codex/DSH 的 JSON 字段或构造不存在的深链。
不得修改、删除真实桌面文件，不安装未经授权的全局输入监听器或自动审批工具命令。
先验证时间戳解码、Hooks 审批、Socket 所有权和 DSH emit 签名四个 P0 阻断项，再实现可运行纵向功能切片；提交前编译、测试并记录 UI 效果与 CPU/内存数据。
若遇到需用户确认的产品决策，先汇报备选方案，不擅自改变原需求。
```

---

## 17. 风险清单与可执行回退

| 风险 | 严重程度 | 发生条件 | 回退策略 |
|---|---|---|---|
| 透明窗口截获点击 | 高 | 窗口碰撞外接过大、无穿透 | 默认 ignoresMouseEvents / 缩小窗口 / 禁用主动互动 |
| macOS 菜单栏无法固定左上 | 高 | 原生 `NSStatusItem` 受系统约束 | 右侧常规菜单栏；左侧仅可选独立 Overlay 实验 |
| DSH Desktop Profile 安装不一致 | 高 | 用户在 Web Profile 装错插件 | UI 引导 Desktop 内安装，不自动改其他 Profile |
| Codex 客户端事件不统一 | 高 | CLI、IDE、Desktop Hook 不同 | 使用支持矩阵和“仅完成通知”降级，不虚报审批 |
| Finder 图标位置读取失败 | 中高 | Accessibility API 不稳定 | L0 无目标游荡/随机位置剧场 |
| 角色美术许可不明确 | 高 | 发布或商业化 | 只在私人本地实验使用；公开版取得授权或原创替代 |
| 图集太大导致耗电/内存 | 中 | Full 母版过大、每帧解码 | 离线 atlas 优化，按需加载，不用固定 60 FPS |
| 预算误算 | 中高 | API 单价变化或并发预约竞态 | 保守预留、低次限额、超额拒绝新请求 |
| 旧 Hook 被覆盖 | 高 | 安装器未备份配置 | 先探测、备份、预览、用户确认和可恢复卸载 |
| 用户工作时被打扰 | 中高 | 频繁吐槽/漂浮窗覆盖 | 安静模式、冷却、全屏禁用、用户一键回家 |
| Windows 与 Swift 不能直接共享窗口代码 | 中 | 需求提前要求跨平台 | 共享 JSON/资产/测试，另建 Windows UI Adapter |

---

## 18. 官方资料与上游链接（可供开发者复查）

> 这些链接用于验证实际 API 与上游能力。访问日期：2026-10-10。真实开发时重新核对仓库 commit、发布版本、API 接口和许可证；以下链接不是软件包已经完成整合的证明。

1. AgentPet 仓库：https://github.com/ntd4996/agentpet
2. AgentPet Swift Package 定义：https://github.com/ntd4996/agentpet/blob/main/Package.swift
3. RunRat 仓库与目录：https://github.com/Lolretrorat/runrat
4. DSH Pet 桥接与 Desktop Profile 说明：https://github.com/sundusk/dsh-pet
5. DeepSeek Harness 官方 Cordis 事件：https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/framework/events.zh.md
6. DeepSeek Harness 架构：https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md
7. whale-girl 仓库：https://github.com/vlln/whale-girl
8. whale-girl 角色和动作规格：https://github.com/vlln/whale-girl/blob/main/docs/sprites-spec.md
9. whale-girl 增加角色指南：https://github.com/vlln/whale-girl/blob/main/docs/adding-a-character.md
10. Aibo：https://github.com/omdsh-dev/dsh-gal
11. QiuQiu：https://github.com/jc98629/my-cat-desktop-pet
12. OpenPets：https://github.com/alterhq/openpets
13. Apple NSStatusBar：https://developer.apple.com/documentation/appkit/nsstatusbar
14. Apple NSStatusItem：https://developer.apple.com/documentation/appkit/nsstatusitem
15. Apple NSWindow.ignoreMouseEvents：https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents
16. Apple SMAppService：https://developer.apple.com/documentation/servicemanagement/smappservice
17. Codex 官方配置参考：https://developers.openai.com/codex/config-reference
18. Codex 官方 Hooks 说明：https://developers.openai.com/codex/hooks/
19. Codex notify 限制与 payload：https://developers.openai.com/codex/config-advanced
20. DeepSeek Harness Core 事件精确签名：https://deepseek-harness.github.io/deepseek-harness/en/reference/subsystems/core
21. DeepSeek Harness Cordis 事件模式：https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/framework/events.md

---

## 19. 最终实施结论

**主框架**：AgentPet（Swift 6 + SwiftPM + AppKit/SwiftUI），按审计结果抽取其 Agent/Event/通知能力。  
**系统指标**：RunRat 的已验证采样方案或公共系统 API。  
**DSH**：Cordis/DSH Pet 状态插件 → 本地只读事件 → 统一 WhaleEvent。  
**Codex**：AgentPet 现有 **`hooks.json` Hook 安装器为主**，`notify` 仅作为 `agent-turn-complete` 补充；须剔除 prompt、回复全文等敏感字段，客户端覆盖按实测。  
**角色**：whale-girl 的原型图集和动作契约，离线转换成 Mini/Peek/Full 三套新图集，发布前确认美术授权。  
**窗口**：Mini = `NSStatusItem`；Peek = 小型 `NSPanel`；Roam = 按需出现的透明角色窗；所有窗口通过 AppCoordinator 统一生命周期。  
**角色行为**：Swift 本地状态机 + 可配置场景与冷却，空闲只做视觉文件交互；AI 只为少量台词服务。  
**资源限制**：常驻低帧率、系统指标低频采样、后台休眠停动画、严格 AI RMB 日预算。  
**第一步**：不要马上追求 3D 互动和复杂自主 AI；先完成“菜单栏清晰头像 → 探出半身 → 收到 Codex/DSH 事件 → UI 正确显示”这一完整纵向切片，证明最关键的窗口与事件技术均可行。

> **V2.4 与 V1.2 的关系**：V1.2 定义角色比例、最终体验与产品范围；V2.4 定义具备明确安全/时间/事件契约的技术方案。V2.0 的冲突实现样例自本版本起作废。后续更改契约应通过 ADR、迁移和测试落地。

---

## 20. V2.4 交付包运行与合入说明

- 规范文档使用**稳定路径** `docs/technical-spec.md`，文件头 `文档版本：V2.4` 为实际版本来源。版本升级时应修改文档头与 `fixtures/contract_constants.json` 中的 `technicalSpecVersion` 并通过校验，**不要重命名文件来改变检查器寻找目标的方式**。
- **SQLite 迁移限制**：`CREATE TABLE IF NOT EXISTS` 不会给既有 `events` 表补加新的 `event_type CHECK`；本交付包不包含正式生产数据库升级器。未来落地到真实用户数据库时，必须先脱敏审计旧事件、备份、事务化重建表/迁移，不能只运行更新后的 `schema_v1.sql`。
- `fixtures/wire_contract.json` 是 DTO/持久化字段映射规范；`fixtures/contract_constants.json` 是 UI/预算/时间精度/summary 长度/事件白名单参数。新增字段前先更新契约，且要通过集合等价检查及突变测试。
- CI 使用显式 `permissions: contents: read`；协议测试运行于 Swift 6.2.1 容器，避免未固定 SHA 的第三方 `setup-swift` Action。`actions/checkout` 固定审查过的 SHA。Swift 容器 tag 仍属于可变引用，若进入对外发布 CI 需进一步固定镜像 digest 并实施依赖更新流程。
- `MoodBallHTTPProbe` 目前是 Phase 0 **待验证方案**，不应被 UI 宣称为已实现。


1. 将 `docs/product-spec-V1.2.md` 与本文件置于主仓库 `docs/`。
2. 将 `tests/SwiftContractPackage/Sources/WhaleProtocol/WhaleEvent.swift` 作为协议唯一实现原型，不把旧 V2.1 `WhaleEventContractSmoke.swift` 作为生产源码。
3. 执行六条 CI 命令：`swift test --package-path tests/SwiftContractPackage`、`python3 tests/sql/schema_negative_test.py`、`python3 tests/sql/migrate_existing_database.py`、`python3 scripts/doc_check.py`、`python3 tests/contract/check_mutations.py`、`python3 tests/contract/test_http_probe.py`。
4. 将上述命令加入 CI workflow，Linux 可跑协议/数据库；macOS runner 再增加 Apple 原生窗口/Unix Socket、Agent 真机集成。
5. **目前已验证的是样例协议与校验逻辑**，不是用户 Mac 的真实 DSH Socket 事件或 Codex Hook；必须先采集 MoodBall 的等待审批/输入前后状态 fixture，再锁定真实字段和值。
6. 正式实现 `WhaleEventCodec`、`SessionReducer`、SQLite 访问层前，先明确一套单一代码源；避免测试代码和产品代码分叉。

以本版 §8.1 的“状态来源确认”作为 `waiting_approval/waiting_input` 功能开关和 UI 验收的必要前置条件。


## 附录：V3.1 纠错与不可变数据约束（替换原 V3.0 的危险实现）

1. `migrate_events_v3.py`：迁移前按列名（不使用 `raw[0]`）读取 `event_id`；检查未知列、触发器、外部索引、视图及外键依赖。存在不符合 V3 合同的历史记录时**整体中止，不进行重命名或 DROP**，原库行数及 `user_version` 不变。日志只能输出 `event_id` 的脱敏哈希引用，不含原始正文。正常迁移中校验旧新 `(source, source_instance, event_id)` 集合及行数守恒。CLI 需要备份；直接调用 `migrate()` 时发现不兼容数据也不会丢行。
2. `schema_v1.sql`：新建空数据库末尾设置 `PRAGMA user_version = 4`。禁止把这一 initializer 当作已有库升级脚本。检查版本时还需比对实际 events 表 DDL，不可只看 `user_version`。不支持未知数据扩展时必须人工审查，不准自动删除。
3. `SessionReducer`：状态更新先比较序号权威；旧状态有序号时无序号不具覆盖权；双序号严格递增，允许时间回拨；无序号到有序号不受旧时间守卫阻挡；`agent.tool_finished` 不能结束待审批；终态会话在没有新的会话身份／代数时不可自动复活。`ingest` 返回 `true` 仅表示新事件 ID 被接收，不保证状态发生更新。
4. `SecureEventRules`：敏感摘要启发式识别必须先 NFKC、去零宽与空白归一；对有限长度的 base64 片段进行一次解码检验；时间戳只允许 ASCII 数字。**这一启发式不是密钥检测安全保证**：安全默认应由上游字段投影、禁止原始自由文本传输和敏感级别下不存摘要提供。
5. SQLite CHECK 及日累计约束覆盖 NUL、实际 UTF-8 字节长度、`local_sensitive` 的 `summary_redacted/metadata_json/display_target_json` 全部为 NULL、`local_day` 公历格式；`api_requests` 使用 INSERT/UPDATE 触发器限制每天已确认实际金额与仍预留金额的合计不超过 2,000,000 微元（人民币 ¥2）。请注意旧版 `api_requests` 表不会因 events 迁移自动获得新的 CHECK 与累计触发器。交付包已增加独立的 `migrate_budget_v31.py` 参考迁移器（自检、备份、事务重建、历史日累计审查）；如历史金额超限或日期非法，迁移会中止并保留全量旧表。**生产系统必须执行并验证这个独立迁移，完成之前不得启用 AI 付费请求**。
6. §11.2 代码块与 `tests/sql/schema_v1.sql` 要求字节内容在规范化换行后相同，任意 CHECK 或 TRIGGER 漂移都使 CI 失败。

**封存范围**：V3.2 是跨平台协议、SQLite 迁移参考、文档及自动化测试的更正包，尚未完成 macOS App；不能称 DSH/Codex IPC、Finder 交互或能耗实测已通过。


## 附录 V3.2：审计回归与故障恢复门槛

1. **有序号优先**：权威由无序号提升到有序号时不让旧时间水位线挡住审批事件；同为有序号的事件按序号判定更新，不再以源时间回拨为拒绝依据。首次 heartbeat 不建立快照。B1/B2/B3 及回归逆序用例列入 SwiftPM。注意 `updatedAt` 记录当前权威事件时间，在升级权威那一瞬间允许早于先前无序号观察时间。
2. **迁移可定位但不自动删改**：执行 `python3 tests/sql/migrate_events_v3.py --database /path/to/old.sqlite --inspect-only --report-json /private/diagnostics.json`，生成权限 0600 的只读报告，包含 `table`、SQLite `rowid`、不兼容的 `columns` 和脱敏 `event_ref`，不含字段值和完整 ID；诊断不自动纠正、隔离或删行。未知 DDL 扩展仍整体中止，需人工审查。真正迁移必须备份并显式 `--confirm`，仍坚持任意不兼容记录便整批回滚。诊断中的列名是定位线索，不是直接修改旧数据的授权。
3. **HTTP 畸形响应安全降级**：超深 JSON 可能触发 Python `RecursionError`，探测器统一转换成不泄露响应内容的 `ValueError`；不追随重定向、不扫描端口、不打印正文。此测试仅使用本地模拟响应，真实 DSH 仍需 Phase 0。
4. **八项语义反转必失败**：`scripts/doc_check.py` 按指定章节核对审批来源优先顺序、metadata 键全集、waterfall 只读禁止、Codex 用户级 Hook 写入范围、v1 拒绝小数秒、会话序号权威、HTTP 本机回环范围、UInt64→SQLite Int64 上限投影。`tests/contract/check_mutations.py` 对每一种方向性改错都独立注入并要求 CI 失败。此类静态语义锚点与真实行为测试相互补充，不等同于已经存在正式的 Codex 安装器或 DSH 插件。
5. **封存范围**：当前交付包仍是参考协议、数据迁移与验证测试，不是可安装 macOS UI；必须真实连接 Codex/DSH 并完成审批状态端到端验收后才可声明产品级 P0 通过。


## V3.3 对抗性复验与冻结说明

本版本是 V3.2 参考实现的安全修订，不是安装包，也没有完成 macOS/DSH/Codex 真机验收。

- **数据库 P0**：`api_requests_daily_cap_insert` 只同名而内容变成 `SELECT 1` 时，旧 `migrate_budget_v31.py` 误判 `already_current`，可累计超出每天 ¥2；新版逐字义核验规范触发器的真实 SQL，遇见伪造定义直接中止；即使 DDL 与触发器都匹配，也重算历史每天费用并运行 `PRAGMA integrity_check`，防止修复触发器后将既有超额账本误判为安全。
- **数据库 P0**：SQLite 默认不开启递归触发器；`INSERT OR REPLACE` 会隐式替换已有主键并绕过 `BEFORE DELETE`。新版 `api_requests_no_replace` 在 `BEFORE INSERT` 阶段拒绝原有 `request_id`；`api_requests_no_delete` 阻止删除已扣费记录；`api_requests_guard_transition` 阻止挪日期、降低预留及篡改已确认费用/令牌统计。仅靠约束不能对抗具有 DROP TRIGGER 权限的同一数据库写入者，因此在执行任何付费请求前必须校验 schema/触发器指纹与迁移状态。
- **审批 P1**：`DSHApprovalResolver` 原先在多个有效 MoodBall 证据中取数组第一条，最新的 `state=nil`（退出等待）不能取消旧的 `waiting_approval`。新版按每一权威层中最新 `capturedAt` 选择，确认清除具有同时间戳的优先权，不降级为旧的审计审批状态。需要 DSH 适配器正确上报非等待状态与连接代数，才能在实机兑现。
- **迁移**：`tests/sql/migrate_budget_v31.py` 可以将真正的 V3.2 账本升级至五条触发器；同名触发器内容异常则 **不自动覆盖或修复**，保持数据库原样并要求人工审查。对历史账本先备份、停用付费请求，再执行离线迁移。`PRAGMA user_version = 4` 表示新 events 复合主键布局；预算触发器强化是该布局的防护升级，真实完整性由内容校验而不是单靠版本整数判断。
- **验收**：`test_adversarial_v33.py` 需要验证 REPLACE、DELETE、UPDATE、同名空触发器和 V3.2 升级；Swift `testFreshMoodballClearSuppressesOldApproval`、`testVerifiedClearBeatsSameTimePending` 等覆盖时间乱序；CI 运行这两组实测，不能只靠文档断言。

仍未完成：真正 SQLite 持久化 `EventHub`、macOS Socket 服务与可安装 App、DSH/Codex 真实 Hook/等待审批覆盖率、对账数据不可删除的归档/保留策略、跨进程锁和端到端注入测试。


## V3.5 安全修订附录：七项深度对抗复现修复（2026-10-12）

本附录优先于文内旧版本描述。外部 WhaleEvent Wire 协议仍为 v1，数据库 `PRAGMA user_version=4`，不以更新文档版本替代协议迁移。

1. **RT-01 事务排他**：`migrate_events_v3.migrate()` 在读取任意 DDL、事件或 `user_version` 前执行 `BEGIN IMMEDIATE`，所有预检、红线清洗、双表复制、索引创建与完整性检查共用该事务。预算迁移器也采用同样顺序。若获取锁失败，则中止并保留原库，不得复用预先读取的快照。
2. **RT-02 高权威审批**：`SessionReducer` 明确允许首次带序号事件纠正此前无序号终态，包括需要处理的审批状态；已有序号的真正终态仍对同一会话身份不可逆。首次 heartbeat 不创建状态。当前模型尚无完整 session generation（代数），正式客户端需补充并验证实例重启隔离。
3. **RT-03 / RT-04 跨表依赖**：迁移之前扫描全库 `sqlite_master` 中其他表、外部触发器、视图及索引对被替换表的引用，并检查外键。任何无法安全重写的依赖均 **fail-closed**，明确告知需要人工离线迁移；不允许把外部触发器改写成引用 `events_pre_v3` / `api_requests_pre_v31` 后删除旧表。扫描策略刻意保守，可能将注释或 SQL 字面量提及也阻断。
4. **RT-05 当前版本健康**：即使 `PRAGMA user_version` 和 DDL 一致，也需同一事务内执行 `PRAGMA integrity_check` 和所有事件的清洗/规范性校验。发现无效行不返回 `already_current`，也不静默清除。
5. **RT-06 请求 ID 约束**：`api_requests.request_id` 显式采用 `TEXT NOT NULL PRIMARY KEY` 和 UTF-8 字节长度、NUL 检查；旧库含 NULL 时升级中止且不删行。
6. **RT-07 同时刻证据冲突**：同权威、同 session、同 generation、同最新时间戳的 `waiting_approval` 与 `waiting_input` 并存，结果是 `unavailable`，不依赖数组顺序。若同刻存在明确清除证据，清除优先。正式 DSH 适配器应尽量提供真实的单调序号。
7. **验收约束**：测试应覆盖跨进程并发写锁、其他表上的触发器、旧库 NULL 请求 ID、历史无效记录、状态终态权威提升、同刻冲突与数组排列不变性；旧基线 V3.3 的报告不能代替 V3.5 的实际测试。

以上为参考协议、测试及迁移代码的 V3.5 修订，不代表 macOS App、正式 IPC 服务或 DSH/Codex 实机端到端链路已经交付。


### V3.5 对抗修订说明（覆盖旧版本中的冲突表述）

- SQLite `PRAGMA user_version=4`：新事件表主键为 `(source,source_instance,event_id)`，保留 Wire v1。升级器在写锁内重建旧版 events 表；已存在的旧 event_id 可无损迁入，重复 UUID 在不同来源不再互相冲突。新旧索引必须核对实际 SQL 定义，不只检查名称；未知生成列通过 `table_xinfo` 检测后阻断升级。
- DSH 审批：限相同来源实例、会话及连接代数；**先比较经过验证的证据时间**，最新明确的 audit cleared 可以清除较旧 MoodBall waiting。相同时间戳冲突按不可用降级；同时间无冲突时 MoodBall 具有来源优先权。
- SessionReducer：同为有序号的事件只按严格递增序号决定新旧，容忍系统时钟回拨；`updatedAt` 保存两次有序号观察中的最大值。无序号不能覆盖有序号；未序列化事件只按自身时间水位线判断。
- Remote Agent 属于 Agent 事件来源，必须具有 `sessionId`；解码器提前拒绝，不得留待 SQLite 报错。
- 内存去重按 `(source,sourceInstance,eventId)` 隔离并设 4096 条上限；**它不是重启后幂等保证**，正式 App 仍须通过 SQLite 复合主键持久去重。
- V3.5 仍属于协议与数据库参考工程，不代表 macOS / Codex / DSH 实机集成已经完成。
