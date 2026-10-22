# Phase 2 角色动作素材接口

本轮先完成互动控件和动作调用接口，暂用仓库现有角色图集做开发预览；没有重绘或修改 PNG。收到新动作素材后，可以在不改交互行为代码的情况下替换对应图集，或只调整本文件所述 manifest。

## 资源入口

- 图集和清单目录：`Apps/macOS/Resources/Sprites/`
- 动作清单：`sprite-manifest.json`
- 运行时加载：`SpriteRepository` 根据 manifest 中的 atlas `resource` 名称读取 PNG，再按 clip 的 frame rect 播放。
- 菜单栏循环动画独立放在 `Apps/macOS/Resources/MenuBarFrames/`；Peek/Full 不读取该目录，也不使用菜单栏的 `png_1`–`png_20` 帧。

## 社区全量动作库

`Apps/macOS/Resources/CommunityActions/` 含 `PC2005-cloud/dsh-pet@2dc2dfe7796c2ab77edb6f093c5886642d6870f4` 的全部 106 个动作，12,659 帧。`catalog.json` 定义显示名称、分类和默认动作映射，`sprite-manifest.json` 使用相同的 schemaVersion 1，`provenance.json` 锁定源文件与转换图集校验值，`LICENSE.txt` 保留 MIT 原文。

大鲸鱼娘全身状态使用这套动作：待机期间预读下一动作，随机打乱全部动作后依次播放，轮完再重新打乱。中键菜单「桌面动作」可手工点播。悬停探出与菜单栏尾巴素材保持独立。

`SpriteRepository.prepareClip` 在后台解码下一动作，社区图集缓存最多两个；图集不在启动时全部解码。`SpriteAnimator` 在后台准备好后切换图集，旧画面保留到新动作就绪。隐藏角色后随机调度暂停。

重新导入：使用带 Pillow 的 Python 运行 `Scripts/import_community_actions.py --download`，并安装 ffmpeg。导入工具枚举已锁定上游的全部 WebM，校验 Git blob，保留透明通道，共享 384×216 画布，以 12 fps 输出 WebP 图集；不运行上游程序。

## 稳定动作槽位

界面通过下列 clip ID 请求动作。替换素材时优先保留这些 ID；如果动作帧数或排布改变，只需更新对应 atlas 和 frame 定义。

| 状态 | Clip ID | 用途 |
| --- | --- | --- |
| Peek | `peek.idle` | 探头待机 |
| Peek | `peek.wave` | 鼠标进入时的招呼 |
| Peek | `peek.happy` | 摸头反馈 |
| Peek | `peek.poke` | 戳脸反馈 |
| Full | `full.idle` | 全身待机 |
| Full | `full.dragged` | 拖出/移动时 |
| Full | `full.happy` | 摸头反馈 |
| Full | `full.poke` | 戳脸反馈 |
| Full | `full.return` | 返回探头状态 |

菜单栏状态保留 `mini.idle`、`mini.blink`、`mini.hover`。

## 帧约定

- 每个帧使用透明 PNG；atlas 的 `pixelWidth` / `pixelHeight` 和每帧 `rect` 使用像素坐标。
- `duration` 用秒表示，单帧范围为 0.03–10 秒。
- `anchor`、`visualBounds` 和 `hitbox` 使用 0–1 归一化坐标。每个动作的可见边界应保持在画布内，身体比例和底部锚点应在同一展示形态的各帧间保持稳定。
- Atlas 可以重新排版；只要更新 manifest 中对应的 atlas 尺寸和 frame rect，动作槽位与交互控件不需要改动。
- 若新素材分成独立 PNG 帧，可先打包为水平 atlas；或者后续扩展 repository 的逐帧资源读取，但保持上述 clip ID 不变。

## 交互控件

Peek/Full 面板底部的控件条是独立 AppKit UI，不属于图集：摸头、戳脸、Peek/Full 切换和收起始终可用。角色点击区域由每帧的 `hitbox` 决定；控制条按钮保留独立的可访问名称和工具提示。
