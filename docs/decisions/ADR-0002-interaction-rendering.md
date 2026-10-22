# ADR-0002: 紧凑透明面板、标准化 hitbox 与 CALayer 图集

- 状态：Accepted
- 日期：2026-10-13

## 背景

Phase 01 要求低频动画、角色区域交互和屏幕内拖动。透明窗口若覆盖过大，即使视图返回 nil，也不能据此证明窗口层面的点击穿透正确。NSImage 直接作为 layer contents 还会受表示层和缩放影响，导致图集帧重复或裁切错误。

## 决策

- Peek 与 Full 面板尺寸贴合角色视觉区域，并限制在目标 `NSScreen.visibleFrame` 内。
- manifest 使用标准化的视觉边界和 hitbox；`HitRegionView` 只让角色区域参与点击。
- 图集加载为固定 `CGImage`，`CALayer.contentsRect` 选择当前帧，`contentsGravity = .resize`，避免 NSImage 多表示层造成的帧采样错误。
- 动画根据 manifest 的逐帧 duration 用一次性 timer 调度，不运行全屏 60 FPS 循环；系统睡眠时停止 timer，唤醒后按当前可见状态恢复。
- Peek 下拉 28 pt 才进入 Full；Full 拖动始终经过屏幕边界收敛，松手播放 return clip 后回到 Peek。

## 结果与限制

角色外透明区域已由紧凑窗口和 hitbox 缩小，但 Chrome/Finder 上的窗口层点击穿透仍需单独人工验收。多显示器和刘海菜单栏也保留为人工验收项。
