# 右侧信息面板

展示动画的手旁沿用窄幅 236pt 面板，点击、收回、全屏避让及动画时序保持原有行为。

- 顶部为运行概览，系统版本/核心数为次要信息，小爱心保留陪伴感。
- CPU、内存使用率为并列重点，内存用量/总量在小字中保留；网速、电池降为辅助信息。
- AI 余量独立分组，以数字和周期分列展示；超过两个周期继续换行，不丢弃额外额度。金额与周期可同时显示。恢复时间放到周期提示中，更新时间降为辅助信息。
- 未连接、未登录、未安装等状态明确区分，不绘制猜测百分比。管理入口保留原有工具选择、总开关与连接功能。
- 背景采用 AppKit NSVisualEffectView 加淡蓝渐变，文字不透明；这是玻璃风格实现，不声称使用 macOS26 原生 Liquid Glass API。没有增加渲染计时器或动态背景。
- AI 区域按实际数据估算高度、上限286pt，更多内容在区内滚动；关闭全部额度时只显示原有224pt系统卡。

设计参考：

- [Apple 2025 软件设计 / Liquid Glass](https://www.apple.com/ca/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/)：半透明材质、内容优先。
- [Apple MacBook Pro](https://www.apple.com/macbook-pro/)：大数字、清晰标题与留白。
- [DJI Mavic 4 Pro](https://www.dji.com/cn/mavic-4-pro)：主视觉/主参数优先，次要说明弱化，操作入口克制。

以上为本项目的设计取舍，不使用上述网站的图片、商标或组件。原生渲染证据在 evidence/glass-information，额度截图使用测试快照，并非当前账号额度。

后续硬件信息版本增加了八项独立显示开关和整卡滚动，基础卡高度随选择变化；以[电脑指标说明](SYSTEM_METRICS.md)为准，原固定224pt描述仅适用于先前版本。
