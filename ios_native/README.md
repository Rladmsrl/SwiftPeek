# SwiftPeek · iOS / iPadOS

用 SwiftUI 与 UIKit 构建的原生直播客户端，目前接入斗鱼。
共享的播放器、站点接口、弹幕和关注文件格式与 macOS 版保持一致。
已兼容 iPhone Duo 折叠屏，覆盖内外屏、横竖屏和半折叠姿态。
项目来源、AI 协作说明和许可证见 [项目首页](../README.md) 与 [来源与致谢](../THIRD_PARTY_NOTICES.md)。

## 环境与构建

- iOS / iPadOS 26 或更新版本。
- Xcode 27.1 或更新版本（使用 iOS 27.1 SDK，部署目标仍为 iOS 26）。
- XcodeGen；可通过 `brew install xcodegen` 安装。

从仓库根目录运行：

```sh
xcodegen generate --spec ios_native/project.yml
open ios_native/SimpleLive.xcodeproj
```

选择 `SimpleLive` scheme 和目标设备，在 **Signing & Capabilities** 中选择自己的开发团队。
工程不预设维护者的账号、证书或团队。构建后的产品名为 `SwiftPeek.app`。

无签名编译检查：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project ios_native/SimpleLive.xcodeproj \
  -scheme SimpleLive -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath ios_native/build \
  CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build
```

产物位于 `build/Build/Products/Release-iphoneos/SwiftPeek.app`。无签名产物不能直接安装到手机。

## 播放与弹幕

- 推荐、分类、搜索、直播间、关注、历史和设置。
- 按容器尺寸上下排列或左右分栏；Duo 半折叠时视频与弹幕 / 选集避开折痕。
- 全屏由按钮控制，横竖屏旋转保留当前页面；详情见 [Duo 适配与验收](../docs/iphone-duo.md)。
- HTTP-FLV 解复用，H.264 / AAC 经 Apple 媒体框架渲染；HEVC 暂不支持。
- 目标约 4 秒压缩媒体内存缓冲，后台准备新凭据与连接，媒体就绪后交接。
- EOF、401、403、410 会触发新地址准备；缓冲耗尽时才显示重连。
- 字幕式滚动弹幕与列表，支持字号、速度、透明度、区域与屏蔽词。
- 弹幕文字分开绘制描边和填色；重布局前移除旧动画，避免轨道冲突。

缓冲会增加直播延迟与起播等待，不能保证长时间断网或跨 CDN 切换完全无感。
后台换流保留播放时钟与已排队媒体；用户停止、退出或切换播放时取消旧连接。

## 后台与画中画

iOS 使用系统 `AVPictureInPictureController`。进入画中画时继续播放；关闭后台音频且未进入画中画时，
退到后台会停止拉流，回到前台按之前的播放意图恢复。
暂停、手动恢复、画质切换及后台交接由 `MobileRoomPlaybackSession` 统一协调。

在直播或录像播放页，点“弹幕”可快速开关，点旁边的下拉箭头打开弹幕设置。
紧凑布局使用可展开的底部面板，其余布局使用浮层；面板高度随可用空间调整，打开设置时控制栏保持显示。
面板提供实时预览、字体（标准 / 圆体 / 衬线）、字号、可见度与“画中画显示弹幕”开关（默认关闭）。
调整立即生效并自动保存，直播、录像与小窗共用样式。
沿用播放器的弹幕开关、显示样式和屏蔽词；录像弹幕跟随进度，暂停冻结，拖动清屏。
开启后只在画中画期间额外生成带弹幕的视频帧，会增加耗电；退出小窗后停止合成。
直播需要等待可解码的视频关键帧，准备期间保留普通画中画画面。

小窗弹幕使用独立串行队列，以 60 fps 为动画调度目标；取帧/状态采样最多 30 fps。
缩放与合成通过 CPU/vImage 完成，避免依赖后台受限制的应用 GPU 工作；迟到帧直接丢弃，不累积延迟。
这不代表源视频被提升到 60 fps，也不保证所有设备始终达到目标值。修复依据与验证结果见 [小窗弹幕性能](../docs/pip-danmaku-performance.md)。

系统画中画、音频路由、设备亮度与后台行为需要真机验证，编译或离线检查不能代替这些验证。

## 关注分享

在关注页点击“分享关注”，通过系统分享面板选择隔空投送。另一端打开关注文件、预览后手动合并。
0.8.0 起分享默认不含历史，只有显式勾选后，观看历史才随文件一并合并（同一房间保留最近一次观看）。重复导入会去重，不删除本机已有关注或历史。见 [关注分享说明](../docs/follow-sharing.md)。

## 录像回放

直播间右上角的“录像”进入主播的录像列表；主播未开播时，画面中央也有“看录像”按钮。
关注行长按或左滑也可以进入，搜索页可直接粘贴录像链接。
播放页的控制层提供 10 秒快退 / 快进、倍速、清晰度、弹幕开关与画中画，横屏全屏沿用直播的手势（单击显隐、双击暂停、竖滑调亮度和音量）。
下方在弹幕回放、AI 章节和选集之间切换。见 [录像说明](../docs/replay.md)。

## 验证

核心库：

```sh
cd ios_native/SimpleLiveKit
swift test
```

移动端会话的假接口检查在 Mac 上运行，不启动 App 或真实直播：

```sh
# 先构建 macOS 版，提供共享库链接产物
./macos_native/build.sh
./macos_native/Checks/check-mobile-playback.sh macos_native/build/Build/Products/Release
```

覆盖自动播放、后台交接、切 Tab、手动停止、后台音频/PiP 状态、取消和退出后的迟到响应。
更多检查见 [开发与验证](../docs/development.md)。

## 目录与兼容性

- `App/Views/`：iOS 页面与手势。
- `App/Player/`：共用播放、缓冲、换流与弹幕绘制，以及按平台区分的视图宿主。
- `App/Support/`：本地存储、设置、路由、移动端播放会话与关注导入。
- `SimpleLiveKit/`：站点协议、斗鱼实现、数据模型和离线测试。

保留 `com.simplelive.app`、`simplelive://`、原数据目录和关注文件格式，用于兼容既有安装。
图标为选定的“白瓷玻璃”方案，来源与导出记录见 [图标资源](../design/app-icons/selected/README.md)。
