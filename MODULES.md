# 功能模块导航

先根据需求选下面一行，读取对应文件与直接依赖。不要默认读取整个源码、所有测试或HANDOFF_HISTORY。原生模块文件由Xcode Sources一起编译链接，主入口按原有时序调用；不是运行时下载插件，也没有动态热加载。

## 主入口与功能小文件

`Apps/macOS/App/AppCoordinator.swift`仅管理实例与连线；启动入口仍为`WhaleGirlMain.swift`→`AppDelegate.swift`→`AppCoordinator.make()/start()`。`Apps/macOS/App/Modules/`使用同一MainActor协调器的extension共享状态，不重复持有服务，不新增一层公共插件API。

|要改什么|先读哪个文件（相对Apps/macOS）|直接依赖/约束|
|---|---|---|
|启动/退出、服务启停、命令行演示|App/Modules/AppCoordinator+Lifecycle.swift|AppCoordinator、已有服务；保持启动/停止顺序|
|设置、安静模式、缩放迁移|App/Modules/AppCoordinator+Preferences.swift|UserDefaults；不改变键或格式版本|
|主/子Agent出生、思考、退场、DSH状态|App/Modules/AppCoordinator+Agents.swift|Events/AgentCompanionController、Overlay/RoamPanelController|
|Token自动播报对象/队列|App/Modules/AppCoordinator+Usage.swift|System/UsageReportStore；仅对应主任务和手动桌宠|
|桌宠创建、关闭、清空|App/Modules/AppCoordinator+DesktopPets.swift|Overlay/RoamPanelController|
|摸头、戳脸、拖拽、回收、休眠唤醒|App/Modules/AppCoordinator+Interaction.swift|WhaleCore交互状态机、Interaction/PetView|
|概览窗口、通知和登录项|App/Modules/AppCoordinator+Dashboard.swift|Dashboard/、Notifications/、Settings/|
|Socket事件接收、去重、持久化、完成提醒|App/Modules/AppCoordinator+Events.swift|WhaleCore事件模型、Events/EventStateStore|
|菜单到应用的功能路由|App/Modules/AppCoordinator+MenuActions.swift|MenuBarControllerDelegate；不把业务重新塞回菜单|

`MenuBar/MenuBarController.swift`保留菜单实例、依赖、安装/卸载和输入连接；功能实现位于`MenuBar/Modules/`：

|要改什么|对应模块|直接依赖/约束|
|---|---|---|
|右键菜单、功能入口、菜单内缩放控件|MenuBarController+Actions.swift|原有各功能服务|
|悬停、探头、眨眼、冷却、手动展开|MenuBarController+Hover.swift|HoverCharacterPanel、MenuBarInformationController|
|完成提醒、网络结果和探头气泡调度|MenuBarController+Speech.swift|HoverCharacterPanel；保持Token不主动探头|
|菜单点击爱心特效|MenuBarController+HeartEffects.swift|CoreAnimation；和余额气泡无关|
|帧加载、缩放、CPU调速及播放|MenuBarController+Animation.swift|MenuBarFramePipeline、ActivityFrameMorpher、WhaleCore|

## 已有独立模块

- 气泡外观/定位：`MenuBar/HoverCharacterPanel.swift`；全身桌宠气泡同时看`Interaction/PetView.swift`。
- Token账本、采集与费用：`System/UsageReportStore.swift`、`Resources/AIMonitor/whale_usage_report.py`；报表/CSV界面：`Dashboard/UsageReportWindowController.swift`。规则见`docs/usage/TOKEN_USAGE_REPORT.md`。
- 自动更新：`System/SoftwareUpdateController.swift`、`SoftwareUpdateInstaller.swift`、WhaleCore的`SoftwareUpdate.swift`/`GitHubUpdateCommand.swift`。见`docs/usage/SOFTWARE_UPDATES.md`。
- 网络诊断：`System/NetworkDiagnosticsController.swift`；系统指标：`System/LiveMetrics.swift`/`SystemMetricsSampler.swift`。
- 额度/余额：`System/AIMonitorStore.swift`与`MenuBar/AIMonitorViews.swift`。
- 素材/动画：`Sprite/`、`Overlay/`、WhaleCore模型；资源保留原出处、哈希和许可。

## 修改约定

新增功能优先放入对应模块，主入口仅补充必要的初始化/路由。新增Swift文件必须同时加入Xcode文件引用和app Sources，否则不会编译。扩展跨文件用应用target内的internal访问，不能升级为public或复制状态绕开依赖。需要真正独立生命周期/复用时再提取独立类型或Swift Package，避免只为拆分而增加加载器。

测试先按`Tests/WhaleGirlTests/WhaleGirlAppTests+主题.swift`选择相关项，WhaleCore逻辑用对应包测试。不要为排版移动增加镜像实现测试，也不要删除已有断言。模块化不代表全量功能已端到端验收；验证范围见`docs/releases/v2.0.0-validation.md`。
