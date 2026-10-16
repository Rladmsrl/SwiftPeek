# SwiftPeek screenshots / 界面截图

Captured on 2026-10-16–17 from SwiftPeek 0.5.0 (13).

| Platform | Capture environment | Screens |
| --- | --- | --- |
| iOS | iPhone 18 Pro Simulator, iOS 27.0, Chinese UI | Discover, categories, settings |
| macOS | Native app on macOS 27.2, Chinese UI | Discover, categories, playback settings in dark mode |

2026-10-17 新增双端直播与录像界面。主 README 每端各展示一张直播图、一张录像图；
推荐、分类和设置移入折叠区。

| Files | 展示内容 / What they show |
| --- | --- |
| `macos-live.png` · `ios-live.png` | 直播画面、实时弹幕与录像入口 / Live playback, chat, and the replay entry |
| `macos-replay.png` · `ios-replay.png` | 按时间轴回放的弹幕、AI 事件标题与摘要；Mac 图还展示热度曲线、章节刻度和悬停预览 / Timed chat and AI event summaries; the Mac image also shows chat density, chapter markers, and a hover preview |

The live and replay screens were added on 2026-10-17. Each platform has one live
image and one replay image in the main README; discovery, categories, and settings
are in collapsed sections.

iOS 使用全新模拟器，macOS 使用独立的截图构建与空白本地库。
Mac 截图构建隔离 Bundle ID 和本地库目录，iOS 使用全新模拟器，界面沿用项目源码。
新增播放截图使用本地启动参数直达指定页面、选择章节页签，并固定显示录像控件与 Mac 时间轴悬停预览；
音频在截图构建中静音。这些辅助设置只在忽略的 `.local/` 副本中，不进入正式 App 源码。
截图为系统直接捕获，未合成或修改界面；状态栏时间统一为 09:41。
新增 PNG 已移除 EXIF 与文本元数据，图像像素保持不变。
Mac 图片只包含应用窗口，不包含桌面、其他应用或通知。

The iOS captures use a fresh simulator. The Mac captures use a separate build with
an isolated bundle ID and empty library. The playback captures use local launch
parameters to open a page and select the chapters tab. Replay controls and the Mac
timeline hover preview are kept visible, and audio is muted in the capture builds.
These helpers exist only in the ignored `.local/` source copy; the production app
source is unchanged.
Images are direct system captures, without compositing or UI retouching. The iOS
status bar is normalized to 09:41. Mac captures contain only the application window.
EXIF and text metadata have been removed from the new PNGs without changing image pixels.

直播封面、主播名称和分类图标来自截图时的公开平台内容，相关权利归各自权利人所有。
未使用维护者的关注、历史或账号信息。截图仅展示界面，不作为播放稳定性或跨设备功能的测试结论。

Stream covers, creator names, and category icons are public platform content at
capture time and belong to their respective rights holders. No maintainer account,
follow list, or viewing history is used. These images illustrate the UI, not playback
reliability or cross-device validation.
