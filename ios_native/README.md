# SwiftPeek · iOS / iPadOS

用 SwiftUI 与 UIKit 构建的原生直播客户端，目前接入斗鱼。
共享的播放器、站点接口、弹幕和关注文件格式与 macOS 版保持一致。
项目来源、AI 协作说明和许可证见 [项目首页](../README.md) 与 [来源与致谢](../THIRD_PARTY_NOTICES.md)。

## 环境与构建

- iOS / iPadOS 26 或更新版本。
- Xcode 27 或更新版本，Swift 6.2+ 工具链。
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
  CODE_SIGNING_ALLOWED=NO build
```

产物位于 `build/Build/Products/Release-iphoneos/SwiftPeek.app`。无签名产物不能直接安装到手机。

## 播放与弹幕

- 推荐、分类、搜索、直播间、关注、历史和设置。
- iPhone 紧凑布局，iPad 自适应分栏；横屏播放与触控手势。
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

系统画中画、音频路由、设备亮度与后台行为需要真机验证，编译或离线检查不能代替这些验证。

## 关注分享

在关注页点击“分享关注”，通过系统分享面板选择隔空投送。另一端打开关注文件、预览后手动合并。
观看历史随文件一并合并（同一房间保留最近一次观看）。重复导入会去重，不删除本机已有关注或历史。见 [关注分享说明](../docs/follow-sharing.md)。

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
