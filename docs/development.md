# SwiftPeek 开发与验证

当前工程名 / scheme 为 `SimpleLive` 和 `SimpleLiveMac`；共享包仍叫 `SimpleLiveKit`。
应用产品名与显示名是 `SwiftPeek`。这些不同名字有意保留，不需要为了构建而批量重命名源码目录。

## 构建配置

- `ios_native/project.yml`：部署目标 iOS 26+，使用 Xcode 27.1+ / iOS 27.1+ SDK 构建 iPhone、iPhone Duo 与 iPad 应用。使用自己的签名团队；无签名编译不会安装设备。
- `macos_native/project.yml`：macOS 27+，默认 ad-hoc 签名。
- 两端都通过 XcodeGen 生成工程，生成目录不纳入版本控制。
- `DEVELOPER_DIR` 可指定完整 Xcode 的 Developer 目录，避免只使用 Command Line Tools。
- 当前共享媒体代码包含 SDK 已标记弃用但仍可编译的 AVFoundation 队列 API；后续迁移需要单独验证播放语义。

## 本地隐私与提交

个人 Apple ID、签名团队、证书、设备标识、私有邮箱及真实播放凭据不得写入公开源码或文档。
签名覆盖配置使用 `*.local.xcconfig`，设备信息和诊断导出统一存放在仓库根目录的 `.local/` 中；
这些文件以及生成的 Xcode 工程、证书、描述文件、日志与诊断报告已加入 `.gitignore`。

`.gitignore` 无法过滤已跟踪文件中的隐私内容。提交前仍需检查暂存区差异，并在工具可用时运行密钥扫描。
`Info.plist` 保持版本控制，不提交仅为本机 Xcode 签名产生的配置迁移；个人签名设置留在生成工程中。
后续自动化开发与提交遵循根目录的 `AGENTS.md`。

## 离线检查

核心库：在 `ios_native/SimpleLiveKit` 下执行 `swift test`。

以下脚本从仓库根目录执行，不启动 App 或设备、不访问真实直播。其中需要 `SimpleLiveKit.o` 的脚本，
先运行 `./macos_native/build.sh`，再显式传入构建产品目录：

```sh
./macos_native/Checks/check-backpressure.sh
./macos_native/Checks/check-generation-gate.sh
./macos_native/Checks/check-playback-recovery.sh
./macos_native/Checks/check-danmaku-text.sh
./macos_native/Checks/check-floating-video.sh

./macos_native/Checks/check-buffered-playback.sh macos_native/build/Build/Products/Release
./macos_native/Checks/check-review-fixes.sh macos_native/build/Build/Products/Release
./macos_native/Checks/check-mobile-playback.sh macos_native/build/Build/Products/Release
./macos_native/Checks/check-follow-sharing.sh macos_native/build/Build/Products/Release
./macos_native/Checks/check-replay.sh macos_native/build/Build/Products/Release
./macos_native/Checks/check-pip-danmaku.sh macos_native/build/Build/Products/Release
```

Mac 的 Xcode 测试目标可通过 `build-for-testing` 仅编译。`xcodebuild test` 会启动宿主 App；
它与上述无窗口检查不同，运行前应留意本机是否有正在使用的实例。

## iPhone Duo 与画中画检查

- [Duo 兼容说明](iphone-duo.md)：折叠 / 展开、横竖屏、折痕避让与离线几何检查命令。
- `SimpleLiveUITests`：页面、真实播放、折叠传感器回读、全屏和弹幕设置检查。需要真实录像时，使用 `TEST_RUNNER_DUO_REPLAY_HASH` 传入当前公开录像的 ID，不提交播放凭据。
- 真正的 Duo 方向矩阵需要 Device Hub 控制姿态，并核对实际窗口尺寸；不能仅用 XCTest 的方向枚举作为通过依据。`TEST_RUNNER_DUO_PRESERVE_POSE=1` 保留外部设置，`TEST_RUNNER_DUO_EXPECT_OUTER_WIDTH` 用于目标宽度断言。
- [小窗弹幕性能说明](pip-danmaku-performance.md)：离线像素 / 调度检查、后台 CPU 合成以及真机诊断字段。
- 截图、xcresult 和设备诊断仅存放在忽略的 `.local/` 中。模拟器不支持系统 PiP 时必须明确跳过。

## 必须区分的验证层次

| 层次 | 能说明什么 | 不能说明什么 |
| --- | --- | --- |
| 编译 | API 可用性、类型和资源配置通过 | 实际能连续播放 |
| 假接口 / 离屏检查 | 队列、取消、合并、时间线和生命周期分支 | 网络与硬件条件下的全部表现 |
| 真机播放 | 某设备、网络、房间和时间段的表现 | 所有房间、CDN 或系统版本都可靠 |
| 双机分享 | 实际隔空投送和文件关联路径 | 所有接收设置与系统版本都一致 |

目前保留的开发记录包含历史版本和特定测试条件，请以其具体说明为准。
新增改动应记录实际做过的验证，不自动继承旧版本的“已实测”结论。

## 兼容性

保留 `com.simplelive.app` / `com.simplelive.mac`、`simplelive://`、`douyu://`、`com.simplelive.follows`、
`.simplelivefollows`、关注文件内部格式标识与原有 UserDefaults key。
本地关注、历史及日志目录也保持原路径。这次品牌更名不迁移或清空用户数据。
