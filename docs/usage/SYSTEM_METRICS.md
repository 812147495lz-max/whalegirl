# 自选电脑信息

右侧展示面板右上角的滑杆按钮，或图标控制菜单“选择电脑信息…”，打开八项开关。支持单独选择、全部显示/隐藏，立即重排并通过 UserDefaults 记住选择；AI 额度仍由原有设置独立管理。小屏幕可在整张卡内部滚动，避免字段裁切。

| 指标 | 数据与限制 |
| --- | --- |
| 型号 | IOKit product-name，缺失时显示 hw.model 型号代码；处理器来自 sysctl，不读取序列号或设备名 |
| CPU | Mach 累计 tick 差值，首次采样显示待取值 |
| GPU | IOAccelerator PerformanceStatistics，多个可读 GPU 取最忙者，不把多个百分比相加；驱动不提供则明确显示不可用 |
| 内存 | internal−purgeable+wired+compressed，排除可回收文件缓存；失败显示缺失值 |
| 电池 | IOPowerSources 内置电池，充电状态使用 IsCharging；台式机显示无内置电池 |
| 储存 | 启动 Data 卷容量减可用容量，APFS 共享空间占用，不等于系统设置按文件类型分类的数字 |
| 网络 | en 系列物理接口上传/下载差值，避免重复累计 VPN 隧道；首次/接口重置显示待取值 |
| 温度 | 只读 SMC，按芯片匹配已知 CPU/GPU 传感器白名单，取有效最高值；无传感器时仅显示系统热状态，热状态不伪装为摄氏温度 |

CPU/内存/电池/网速在展示时每秒更新；GPU/容量/温度在后台 actor 最快每5秒更新，不派生 shell、不调用 sudo、不安装特权助手、不写 SMC 或风扇。隐藏 GPU/容量/温度后不再发起对应的新硬件查询。超过30秒的缓存不作为新数据展示。未完成的首轮读取显示“正在读取”，与已读取但不支持区分。

兼容目标为 macOS14+ Intel x86_64 与 Apple 芯片 arm64。主程序和随附 CodexBarCLI 均为 Universal；这不表示所有机型/显卡/系统版本都已实测。现有本机实测为 MacBook Air M4/macOS26.6.2；Intel 仅编译与架构校验，未在实体 Intel Mac 验收。更旧系统不能运行此包。程序仍为本地 ad-hoc 签名，尚未 Apple 公证。

SMC 只读 ABI、GPU 字段、传感器白名单参考并改编自 [exelban/Stats](https://github.com/exelban/stats/tree/b796af44541a6e1802e58918d301aa8c7c07572d)，MIT，Serhiy Mytrovtsiy。完整许可随包 AIMonitor/Stats-LICENSE.txt。只使用读取协议与键表，不包含风扇控制、特权助手或 Stats 的后台常驻服务。接口与传感器映射非 Apple 保证的跨版本契约，读不到即降级。

原生渲染证据 evidence/hardware-metrics；其中 AI 数字为测试快照，硬件数字为采样时的瞬时值，并非性能基准。Universal 会增加主程序和额度后端的二进制体积，素材没有复制第二份。
