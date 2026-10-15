# Lecture Player

原生 macOS 课程播放器。把视频、字幕、转写和章节放在同一个学习窗口中。

A native macOS lecture player with synchronized dual video, bilingual captions, searchable transcripts, and chapters.

**0.9.1（构建 34）** · [已发布版本](https://github.com/Schinsm/LecturePlayer/releases)

本版稳定章节跟随位置、精简主页和课程页，翻译与章节生成提速，已完成实际界面验收。

## 功能

- 双视频同步播放，可切换布局、拖动和缩放画中画。
- 中英字幕、按句阅读、全文搜索和时间校准。
- 按周浏览全部课程，可按课程、类型和学习状态筛选；同一系列的多段视频叠成一项。
- 视频、章节、转写三栏并排，可分别收起和调整宽度；章节与转写独立跟随播放，共用一个搜索框。
- 课程播放列表，以及跨视频记忆的字幕设置。

## 安装

需要 **Apple Silicon Mac、macOS 14 或更新版本**。

打开 `LecturePlayer-0.9.1.zip`，解压后将应用拖入 Applications。更新时先退出正在运行的旧版。

应用尚未完成 Apple 公证。首次打开如被系统拦截，可在“系统设置 → 隐私与安全性”中允许打开。同名 `.sha256` 文件用于核对下载完整性。

## 开始使用

1. 选择课程视频和字幕所在的目录，确认导入。
2. 打开课件，使用字幕、转写搜索、章节和播放列表。
3. 需要翻译或章节生成时，在设置中配置服务，再确认任务。

学习记录保存在本机。启用外部翻译或章节生成服务时，相关文本会发送到所选服务，费用取决于所选服务。

## 构建与测试

需要 Swift 6 工具链与 SwiftData 编译插件，推荐使用完整 Xcode。构建目标为 arm64。

```sh
LP_WORK=/private/tmp/LecturePlayer-public-build ./Scripts/swift.sh test -c release --no-parallel
LP_WORK=/private/tmp/LecturePlayer-public-build LP_DEST=/private/tmp/LecturePlayer-public-app/LecturePlayer.app ./Scripts/build-app.sh
```

测试默认使用临时目录和模拟服务。示例视频为色彩图与 440 Hz 测试音，可用 `Scripts/generate-public-samples.sh` 重新生成（需要 FFmpeg）。

## 版本与反馈

[更新记录](CHANGELOG.md) · [已知问题与测试记录](VALIDATION.md) · [报告问题](https://github.com/Schinsm/LecturePlayer/issues)

历史安装包位于 Releases；旧版可能不支持新版资料库格式。

## License

[MIT](LICENSE) © 2026 Schinsm
