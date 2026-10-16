<p align="center">
  <img src="shared/Branding.xcassets/BrandIcon.imageset/brand-icon.png" width="112" alt="SwiftPeek 白瓷玻璃图标" />
</p>

<h1 align="center">SwiftPeek</h1>

<p align="center"><strong>Just live. Natively.</strong></p>
<p align="center">用 Swift 打造，在 iPhone、iPad 和 Mac 上看直播，也回看精彩。</p>
<p align="center">Swift · SwiftUI · iOS 26+ · macOS 27+ · GPL-3.0</p>

<p align="center">简体中文 · <a href="README.en.md">English</a></p>

打开，看看谁在播；错过了，就回看录像。SwiftPeek 把直播、录像和弹幕放在一起，用时间轴与 AI 章节帮你找到想看的片段。

> **站在巨人和 AI 的肩膀上。**
>
> SwiftPeek 源自 [xiaoyaocz 的 Simple Live](https://github.com/xiaoyaocz/dart_simple_live)。
> 原项目对直播平台、取流与弹幕的探索，是这个项目能够开始的基础。
> 在此基础上，我借助 AI 深度参与设计、编码、排错与迭代，将客户端逐步重构为 Swift 原生实现。
> 感谢原作者、所有上游贡献者，以及帮助这个项目成形的开源社区与 AI 工具。

**当前原生版本只接入斗鱼。** 仓库中其他平台的 Dart 代码属于迁移参考，不代表已经支持。
`reference/` 不参与原生 App 构建，并通过 `.gitattributes` 标记为第三方代码，不计入 GitHub 语言统计。
项目仍在迭代，持续播放、后台切换与跨设备分享欢迎通过实际使用反馈完善。

## 界面预览

### 看直播 · 画面与弹幕，一起看

清晰度与线路随时切换，滚动弹幕和弹幕列表同步呈现。Mac 使用独立播放窗口，iPhone 支持横屏与触控手势；直播间里的“录像”按钮可直接打开主播的往期内容。

<table>
  <tr><th>macOS · 独立直播窗口</th><th>iOS · 直播与实时弹幕</th></tr>
  <tr>
    <td width="72%" valign="top"><img src="docs/screenshots/macos-live.png" width="680" alt="SwiftPeek macOS 直播窗口：游戏画面、滚动弹幕和右侧实时弹幕列表" /></td>
    <td width="28%" valign="top"><img src="docs/screenshots/ios-live.png" width="260" alt="SwiftPeek iOS 直播页：画质与线路切换、实时弹幕列表和右上角录像入口" /></td>
  </tr>
</table>

### 看录像 · 沿着时间轴，找到精彩

回看时，弹幕按原时间轴重放。进度条用弹幕热度和章节刻度提示精彩位置，AI 章节列出事件标题与摘要，点一下就能跳到对应片段。

<table>
  <tr><th>macOS · 热度时间轴与 AI 章节</th><th>iOS · 录像播放与事件摘要</th></tr>
  <tr>
    <td width="72%" valign="top"><img src="docs/screenshots/macos-replay.png" width="680" alt="SwiftPeek macOS 录像窗口：弹幕回放、热度曲线、章节刻度、悬停章节标题与右侧 AI 事件摘要" /></td>
    <td width="28%" valign="top"><img src="docs/screenshots/ios-replay.png" width="260" alt="SwiftPeek iOS 录像页：同步弹幕、播放进度、当前事件标题和可点击跳转的 AI 章节摘要" /></td>
  </tr>
</table>

- **找片段**：Mac 悬停时间轴可预览时间与章节标题；两端都可点击章节跳转，当前章节会高亮。
- **接着看**：记住每段观看进度，支持 0.5×–2× 倍速，同场录像播完自动接下一段。
- **弹幕跟着走**：暂停时弹幕一起停住，拖动后从新位置继续，也可点弹幕列表的时间跳转。

AI 章节由斗鱼为部分录像提供，包含事件标题与摘要，并非语音字幕。完整功能见[录像回放说明](docs/replay.md)。

<details>
<summary>更多界面 · 推荐与分类浏览</summary>

| macOS | iOS |
| :---: | :---: |
| <img src="docs/screenshots/macos-discover.png" width="680" alt="SwiftPeek macOS 推荐首页" /> | <img src="docs/screenshots/ios-discover.png" width="260" alt="SwiftPeek iOS 推荐首页" /> |
| <img src="docs/screenshots/macos-categories.png" width="680" alt="SwiftPeek macOS 分类浏览" /> | <img src="docs/screenshots/ios-categories.png" width="260" alt="SwiftPeek iOS 分类浏览" /> |

</details>

<details>
<summary>更多界面 · 播放与弹幕设置</summary>

| macOS · 深色外观 | iOS |
| :---: | :---: |
| <img src="docs/screenshots/macos-settings.png" width="620" alt="SwiftPeek macOS 深色播放设置：清晰度、缓冲说明和快捷键" /> | <img src="docs/screenshots/ios-settings.png" width="260" alt="SwiftPeek iOS 播放与弹幕设置" /> |

</details>

以上为 v0.5.0 实际界面截图：iOS 来自模拟器，macOS 来自原生应用窗口。
直播封面与标题为截图时的公开内容，会随平台更新；截图不代表持续播放稳定性验证。
[截图环境与说明](docs/screenshots/README.md)。

## 能做什么

- **浏览直播**：推荐、分类、直播间与主播搜索，支持房间号和链接打开。
- **专注播放**：H.264 / AAC 的 HTTP-FLV 播放，清晰度与线路切换，音量、静音和全屏。
- **缓冲与后台换流**：目标约 4 秒内存缓冲，提前准备新凭据与连接，在新流就绪后交接。
- **弹幕**：滚动弹幕与列表，支持字号、速度、透明度、显示区域和屏蔽词。
- **录像回放**：按场次浏览主播录像，弹幕按原时间轴重放；进度条带弹幕热度与 AI 章节，记住观看进度。[说明](docs/replay.md)
- **关注与历史**：本地保存；分享关注文件（含观看历史），通过隔空投送在 Mac 和 iPhone 间手动合并。
- **原生体验**：SwiftUI 界面、Liquid Glass 控件、深浅色外观，以及各平台适合的窗口和交互。

| | iOS / iPadOS | macOS |
| --- | --- | --- |
| 界面 | 标签导航、自适应分栏、横屏播放 | 侧边栏、自适应卡片、独立直播窗口 |
| 交互 | 触控手势、音量与亮度调节 | 鼠标、键盘快捷键、可缩放窗口 |
| 小窗播放 | 系统画中画 | AppKit 悬浮播放窗口 |
| 后台 | 按后台音频与画中画设置处理 | 浏览主窗口时直播窗口继续播放 |
| 关注分享 | 系统分享面板、文件导入 | 系统分享面板、文件导入 |
| 录像回放 | 列表页与播放页、横屏全屏手势 | 独立录像窗口、键盘快捷键 |

缓冲会增加少量起播等待与直播延迟。后台换流旨在减少可见中断，并不保证网络中断、平台接口变化或跨 CDN 切换时完全无感。
关注分享是手动合并，不是 iCloud 实时同步；重复导入不会重复添加，也不会删除已有关注或历史。

## 从哪里来，又改了什么

[Simple Live](https://github.com/xiaoyaocz/dart_simple_live) 是这个项目最重要的上游。
SwiftPeek 保留它“简单看直播”的方向，并参考、迁移了站点接入、签名、取流及弹幕实现。

本项目主要推进的是 Apple 平台的原生重构：Swift / SwiftUI 界面、AppKit / UIKit 适配、
HTTP-FLV 解复用与 Apple 媒体框架播放、缓冲和换流、双端关注分享，以及相应的检查与文档。
这部分重构建立在上游工作的基础上，不能抹去原实现和社区探索的贡献。

本公开仓库以经过隐私清理的源码快照建立独立历史，不包含私人开发分支与旧提交。
原 Flutter 实现可在[上游仓库](https://github.com/xiaoyaocz/dart_simple_live)查阅；`reference/` 保留迁移参考，当前构建不需要 Flutter。
本项目独立维护，与上游及直播平台没有官方隶属关系。

## 关于 AI

AI 是实际参与开发的协作者。包括 Codex 在内的工具参与了方案讨论、代码实现、UI 迭代、
日志排查、代码审查、测试和文档；当前应用图标也来自 AI 生成的候选方案，经维护者选择后适配双端。

项目方向、功能取舍和实际使用反馈由维护者推动，后续维护与发布责任也由维护者承担。
我们会区分“源码已实现”“编译和离线检查通过”与“真机实测通过”，不把 AI 给出的结论或一次绿色构建当作完整验证。

## 从源码运行

### 环境

- macOS 开发环境、Xcode 27 或更新版本，包含 iOS 26+ / macOS 27+ SDK。
- Swift 6.2 或更新工具链；当前源码使用 Swift 5 语言模式。
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)，用于从 `project.yml` 生成 Xcode 工程。

如果使用 Homebrew，可以执行 `brew install xcodegen`。以下命令从仓库根目录运行。

### macOS

```sh
./macos_native/build.sh
```

构建产物：`macos_native/build/Build/Products/Release/SwiftPeek.app`。
脚本只构建，不自动启动 App。默认使用本机 ad-hoc 签名，不等同于 Developer ID 公证或公开发行包。

### iOS / iPadOS

```sh
xcodegen generate --spec ios_native/project.yml
open ios_native/SimpleLive.xcodeproj
```

在 Xcode 中选择 `SimpleLive` scheme 和你的设备，在 **Signing & Capabilities** 中选择自己的开发团队，构建运行。
工程不预设维护者的签名团队。

只检查设备目标能否编译、不安装到手机：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ios_native/SimpleLive.xcodeproj \
  -scheme SimpleLive -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios_native/build \
  CODE_SIGNING_ALLOWED=NO build
```

无签名产物不能直接安装到 iPhone。平台说明见 [iOS](ios_native/README.md) 与 [macOS](macos_native/README.md)。

### 测试

```sh
cd ios_native/SimpleLiveKit
swift test
```

另有不联网、不打开 App 窗口的回归检查，用于缓冲、取消、后台换流、关注导入和移动端会话生命周期。
入口与所需构建目录见 [开发与验证](docs/development.md)。编译或离线检查通过，不代表所有机型、网络和画中画行为均已实测。

## 项目结构

```text
SwiftPeek/
├── ios_native/
│   ├── App/                 iOS 界面、共用播放器和本地数据逻辑
│   ├── SimpleLiveKit/       站点接口、斗鱼签名与弹幕、数据模型
│   └── project.yml          iOS 工程配置
├── macos_native/
│   ├── App/                 Mac 界面与窗口会话
│   ├── Checks/              离线回归检查
│   └── project.yml          macOS 工程配置
├── shared/                  双端共用品牌资源
├── design/                  图标原图、提示词与导出记录
├── reference/               上游 Dart / Flutter 迁移参考
└── docs/                    设计、审查与使用说明
```

`SimpleLiveKit`、现有 Xcode target / scheme、Bundle ID、数据目录和 `.simplelivefollows` 文件格式保留原名，
用于兼容已有安装与数据。面向用户的应用名称为 **SwiftPeek**。

## 当前边界

- 原生站点目前只有斗鱼；虎牙、哔哩哔哩、抖音尚未完成原生迁移。
- 播放器目前覆盖 H.264 + AAC，HEVC 流尚不支持。
- 关注分享需要两端都安装支持该文件格式的版本；不自动同步变更或删除。
- Mac 小窗使用公开 AppKit API，是应用内实现的悬浮窗口，不是系统 AVKit PiP 面板。
- 本项目不是直播源服务，不托管或分发直播内容。

## 参与

欢迎提交 Issue 或 PR，尤其是实际播放、后台切换和跨设备导入的反馈。
报告问题时请提供系统版本、App 版本、房间号、发生时间及复现步骤；日志请先检查并去除不希望公开的信息。

愿意参与其他站点迁移的话，可以从 `reference/` 与 `SimpleLiveKit` 的 `LiveSite` 协议开始。

## 声明

以下沿用 [Simple Live 上游 README 的声明](https://github.com/xiaoyaocz/dart_simple_live#声明)：

> 本项目的所有功能都是基于互联网上公开的资料开发，无任何破解、逆向工程等行为。
>
> 本项目仅用于学习交流编程技术，严禁将本项目用于商业目的。如有任何商业行为，均与本项目无关。
>
> 如果本项目存在侵犯您的合法权益的情况，请及时与开发者联系，开发者将会及时删除有关内容。

可通过本仓库的 [Issues](https://github.com/Rladmsrl/SwiftPeek/issues) 联系维护者；请勿在公开 Issue 中上传个人敏感信息。

**许可证说明：** 上述文字保留上游的项目用途与维护立场；代码的使用、修改和分发权利以 [GPL-3.0](LICENSE) 为准。
GPL-3.0 允许商业使用，上述用途声明不构成对 GPL 授权的额外限制，参见 [GNU GPL FAQ](https://www.gnu.org/licenses/gpl-faq.html#NoMilitary)。

## 许可与致谢

沿用上游 **GPL-3.0**，许可证全文见 [LICENSE](LICENSE)。
第三方组件保留各自的许可证与版权声明，详见 [来源与致谢](THIRD_PARTY_NOTICES.md)。

特别感谢 **[xiaoyaocz](https://github.com/xiaoyaocz)**、**[Simple Live](https://github.com/xiaoyaocz/dart_simple_live)**
及所有贡献者。也感谢 CryptoJS、Tars 等相关开源项目，以及协助这个项目迭代的 AI 工具。

感谢 **[LINUX DO](https://linux.do/) 社区** 的交流与分享。

**站在巨人和 AI 的肩膀上，把看直播这件小事做好。**
