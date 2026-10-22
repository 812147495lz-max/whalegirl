# ADR-0001: 独立 AppKit 宿主与本地 WhaleCore

- 状态：Accepted
- 日期：2026-10-13

## 背景

开发包要求先建立真正可运行的 macOS 桌宠，并提到 AgentPet 等候选项目。随包内容没有这些候选项目的源码、固定提交或许可证，不能据此假定可复用或获得授权。角色美术另按 `ADR-0003-whale-girl-assets.md` 的 GitHub 来源与许可审计处理。

## 决策

创建独立的 macOS 14+ Xcode App target。应用生命周期、`NSStatusItem`、透明 `NSPanel` 与动画使用 AppKit/Core Animation。状态机、manifest 解析和显示几何放在本地 Swift package `WhaleCore`，应用通过本地 package dependency 引用。

Phase 00/01 不引入任何第三方运行时依赖，不联网拉取 AgentPet，不创建第二个常驻桌宠宿主。单实例由应用自己的文件锁负责，因此只有一个 status item 所有者。

## 结果

- 工程可以完全离线构建和运行。
- 核心逻辑可以独立单测，AppKit 代码保留在应用 target。
- AgentPet/RunRat/DSH Pet 的复用仍需以后取得真实 upstream、revision 与许可证后重新评估。
- 当前发布包只生成 arm64，Intel 通用包不在 Phase 01 范围。
