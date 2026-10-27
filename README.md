<div align="center">

# 🐋 WhaleGirl · 鲸鱼娘

住在菜单栏，也陪你在桌面工作的小鲸鱼娘。

![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Universal](https://img.shields.io/badge/Apple_silicon_%2F_Intel-Universal-blue)
[![Release](https://img.shields.io/github/v/release/812147495lz-max/whalegirl)](https://github.com/812147495lz-max/whalegirl/releases/latest)

[下载 2.0.0](https://github.com/812147495lz-max/whalegirl/releases/tag/v2.0.0) · [使用说明](docs/usage/AI_CONNECTORS.md) · [反馈问题](https://github.com/812147495lz-max/whalegirl/issues)

</div>

## 她会做什么

- **菜单栏陪伴**：摇尾巴、悬停探头、眨眼和互动气泡，动画随 CPU 负载调速。
- **桌面养鲸鱼**：向下拖出多只桌宠，自由拖动、缩放、摸头和戳脸；支持经典与赤风 RED 两套外观、丰富动作和散步。
- **Agent 工作搭子**：接入 Codex、DSH 等工具，主任务和子任务化身桌宠，开始工作、完成提醒、自动退场。
- **Token 消耗播报**：显示 DSH / Codex 每轮输入、输出、缓存命中和未命中数量，以及可计算的费用；只由对应主任务和手动桌宠播报。
- **用量与费用报表**：软件内查看记录，按来源和日期筛选，导出 CSV；DeepSeek 按官方模型价格估算费用，悬停可看余额与今日已用。
- **电脑状态一眼看清**：右键拉下绳索信息卡，查看 CPU、GPU、内存、网络、电池、温度及 IP；支持折线图、AI 额度显示和手动网络诊断测速。
- **自动更新与自定义**：从 GitHub 检查并安装新版，保留本地数据；支持开机启动、安静模式，以及编辑 CSV 自定义气泡台词。

## 快速上手

1. 在 [Releases](https://github.com/812147495lz-max/whalegirl/releases/latest) 下载 DMG，把 `WhaleGirl.app` 拖进“应用程序”；也可下载 ZIP 解压使用。
2. 启动后在菜单栏找到鲸鱼娘，向下拖动即可生成桌宠。
3. 需要 Agent 联动或额度显示时，按[接入说明](docs/usage/AI_CONNECTORS.md)启用对应工具。

| 操作 | 效果 |
|---|---|
| 鼠标悬停 | 探头与气泡 |
| 左键点击 | 爱心互动 |
| 右键点击 | 绳索电脑信息卡 |
| 向下拖动 | 拖出桌宠 |
| 中键 / Option + 右键 | 控制菜单 |

**系统要求：macOS 14 或更新版本，支持 Apple silicon 与 Intel。** 当前发行未经过 Apple 公证；校验文件随 Release 提供。

[Token 报表](docs/usage/TOKEN_USAGE_REPORT.md) · [气泡台词](docs/usage/SPEECH_CSV.md) · [网络诊断](docs/usage/NETWORK_DIAGNOSTICS.md) · [软件更新](docs/usage/SOFTWARE_UPDATES.md)

## 致谢

角色与素材来自 [vlln/whale-girl](https://github.com/vlln/whale-girl)、ZipZipPipe、赤风 RED 及社区作者；余额气泡参考 [DeepSeek Balance Whale Widget](https://github.com/MeteorNOX/DeepSeek-Balance-Whale-Widget)。完整来源与许可见 [NOTICE](licenses/NOTICE.md)。应用代码采用 [MIT](LICENSE)，角色素材保留各自权利。
