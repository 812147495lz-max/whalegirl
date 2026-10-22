# ADR-0003: 使用上游 whale-girl 角色图集

- 状态：Accepted
- 日期：2026-10-13

## 背景

V1.2 产品规格将 `https://github.com/vlln/whale-girl` 指定为主要角色美术来源。Phase 01 首次实现时因尚未取得并核对原文件，发布包暂用程序化占位图。用户随后明确确认规格所指角色美术可用于本项目，并要求核查 GitHub 授权后直接采用。

## 核查

- 来源仓库：`https://github.com/vlln/whale-girl`
- 锁定提交：`9c32d7a39a45148076f8ad2fdaad2dc2420eedb3`
- 仓库根许可证：MIT，copyright © 2026 Sam Gao (vlln)
- 许可证文件 SHA-256：`c54724c121bf852962c289ad21462be8148e16d47ded3e39051dcb21c268598d`
- 角色署名：上游 manifest 将角色标注为 ZipZipPipe；README 说明 sprites 基于其 “Whale Girl” sticker character design 生成。

在锁定提交中，使用的 PNG、角色 manifest、安装说明和 MIT LICENSE 一同存在，未发现针对这些 PNG 的单独排除条款。本项目因此依据上游仓库的许可声明使用并再分发这些文件，同时保留上游版权和角色署名。

## 决策

从锁定提交原样复制 `idle.png`、`welcome.png`、`joy.png`、`drag.png` 和 `error.png`。发布应用通过本地 `sprite-manifest.json` 选择帧与裁切，不对源 PNG 像素重绘。

再分发时必须保留：

- `licenses/whale-girl-MIT.txt` 中的完整 MIT 文本；
- Sam Gao (vlln) 的上游版权信息；
- ZipZipPipe 的角色署名；
- 来源仓库、锁定提交和原始文件路径。

`Scripts/generate_placeholder_atlases.py` 仅作为开发故障回退，输出到 `.build/placeholder-atlases`，不得覆盖或冒充正式发布素材。

## 结果

- Phase 01 发布包使用规格指定的鲸鱼娘角色图集。
- 构建不增加网络或运行时依赖；所有发布资源仍随应用离线打包。
- 本记录反映上游公开仓库中的许可声明。若未来商店、发行商或品牌合作要求单独的完整权利链文件，需要再向上游维护者取得补充材料。
