# Lecture Player

原生 macOS 课程播放器：双视频同步、可移动画中画、中英字幕、转写搜索、章节与课程播放列表。

A native macOS lecture player with synchronized dual video, movable picture-in-picture, bilingual captions, searchable transcripts, chapters, and course playlists.

**推荐下载：[0.8.9.1 预发布版](https://github.com/Schinsm/LecturePlayer/releases/tag/v0.8.9.1)** · [全部版本](https://github.com/Schinsm/LecturePlayer/releases)

本源码快照：**0.8.7.2**。历史版本，不建议日常使用。尚未完成全部实际界面和长时间播放验收，偶发黑屏不能视为已彻底解决。

## 安装

需要 **Apple Silicon Mac、macOS 14 或更新版本**。从对应 Release 下载 `LecturePlayer-0.8.7.2-macOS-arm64.zip`，解压后将应用拖入 Applications；打开新版前退出旧版。

应用使用本地临时签名，**没有 Apple Developer ID 签名或公证**。macOS 可能阻止首次启动；核验下载来源及 SHA-256 后，可在系统设置的隐私与安全性中按系统提示允许打开。不需要关闭系统安全保护。

旧版可能不支持新版资料库格式。测试旧版本时使用独立资料库，勿用历史应用覆盖当前资料。

## 使用

1. 选择包含视频与原始带时间字幕的课程目录，确认导入。
2. 播放时使用转写搜索、字幕校准、章节和播放列表；双视频可调整布局或画中画。
3. 翻译与总结是可选功能。按应用设置配置自己的服务凭据，确认任务配置和估算后开始。

仓库不包含课程材料或服务密钥。字幕、译文、学习进度默认保存在本机；启用外部翻译或总结服务时，相关文本会发送到所选服务。模型可用性与价格以服务商当时信息为准。

## 构建与测试

需要 Swift 6 工具链与 SwiftData 编译插件；推荐安装完整 Xcode。现有脚本也支持本机 Swift Playground 提供的宏插件。目标为 arm64。

```sh
LP_WORK=/private/tmp/LecturePlayer-public-build ./Scripts/swift.sh test -c release --no-parallel
LP_WORK=/private/tmp/LecturePlayer-public-build LP_DEST=/private/tmp/LecturePlayer-public-app/LecturePlayer.app ./Scripts/build-app.sh
```

默认测试使用临时资料和 mock，不发送付费服务请求。需要原生窗口、专用隔离资料或手动指定环境的测试可能跳过；跳过不能算作通过。请勿把测试数据路径指向正式资料库。

示例视频是色彩图及 440 Hz 测试音，原字幕是人工编写的合成文本。安装 FFmpeg 后可用 `Scripts/generate-public-samples.sh` 重新生成视频。

## 版本记录

分栏代理、重复导出写入及保存错误处理修复。

参见 [CHANGELOG](CHANGELOG.md)、[公开整理说明](PUBLICATION.md) 和 [验证范围](VALIDATION.md)。欢迎通过 Issues 报告复现步骤、应用版本和系统版本；提交前移除密钥和课程私人内容。

## License

[MIT](LICENSE) © 2026 Schinsm。仓库代码、程序生成的图标与合成样本按此许可发布；用户自行导入的课程材料不属于本仓库许可范围。
