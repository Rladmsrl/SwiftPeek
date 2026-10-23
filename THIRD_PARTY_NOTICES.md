# 来源与致谢 / Third-party notices

SwiftPeek 是基于开源项目经验与代码、在 AI 深度协助下开发的 Swift 原生直播客户端。
改名和 Swift 重构不改变原有代码与资源的来源归属。以下区分直接参考的上游、实际随包组件，以及保留的迁移参考。

## Simple Live

- 原项目：[xiaoyaocz/dart_simple_live](https://github.com/xiaoyaocz/dart_simple_live)
- 作者：[xiaoyaocz](https://github.com/xiaoyaocz) 及上游贡献者
- 上游许可证：[GPL-3.0](https://github.com/xiaoyaocz/dart_simple_live/blob/master/LICENSE)
- 本仓库继续保留该许可证全文：[LICENSE](LICENSE)

本仓库从 Simple Live 工程演进而来。直播站点接入、取流和签名流程、弹幕协议与产品思路，
均受益于原项目。现有 Swift 斗鱼实现参考并迁移了上游 Dart 实现，Apple 平台界面和播放链路进行了原生重构。
`reference/` 保留的 Dart/Flutter 文件来自原工程，只用于迁移参考，不参与 Swift App 构建。
本公开仓库使用独立的源码快照历史；原 Flutter 工程及其历史可在上游仓库查阅。
这些内容不因项目改名或建立新历史而成为本项目独立原创。

SwiftPeek 是独立维护的衍生项目，不代表上游官方发布，也不暗示上游作者为本项目背书。
上游 README 中的[参考及引用](https://github.com/xiaoyaocz/dart_simple_live#参考及引用)记录了其进一步的来源。
这些项目的贡献同样值得尊重，但不在这里将每一项都声称为 SwiftPeek 当前原生程序的直接依赖。

## CryptoJS

- 项目：[brix/crypto-js](https://github.com/brix/crypto-js)
- 用途：斗鱼签名脚本所需的 JavaScript 密码学工具，由 JavaScriptCore 执行。
- 随包文件：`ios_native/SimpleLiveKit/Sources/SimpleLiveKit/Resources/crypto-js.js`
- 许可证：MIT；完整文本保存在同目录的 `crypto-js.LICENSE`，并随 Swift Package 资源一起打包。
- 原版权声明：Copyright (c) 2009-2013 Jeff Mott；Copyright (c) 2013-2016 Evan Vosberg。

当前 minified 文件没有可确认的版本标记，此处不推测其版本号。

## Tars Dart 参考代码

`reference/simple_live_core/packages/tars_dart/` 保留自身的 BSD 3-Clause 许可证和
THE TARS FOUNDATION 版权声明，见该目录的 `LICENSE`。该目录不参与当前原生 App 的构建。

## Appium WebDriverAgent（仅 UI 测试）

- 项目：[appium/WebDriverAgent](https://github.com/appium/WebDriverAgent)
- 来源：[iPhone Duo hinge control 实现](https://github.com/appium/WebDriverAgent/pull/1287)中的 `XCUIDevice+FBHinge.m`。
- 用途：`ios_native/UITests/DuoHingeControl.m` 的模拟器折叠驱动和角度回读。
- 许可证：BSD 3-Clause；完整许可与 Copyright (c) 2015-present, Facebook, Inc. 声明保留在该测试文件头部。
- 只编入 UI 测试 target，模拟事件仅在 simulator 分支执行，不包含在 SwiftPeek App 产物中。

## 图标与 AI 协作

当前“白瓷玻璃”应用图标由 AI 图像生成工具产出候选，经维护者选择后进行 iOS / macOS 资源导出。
生成提示词和原图记录在 `design/app-icons/`。它替换了早期迁移阶段沿用的图标；历史资源仍保留各自来源。

AI（包括 Codex）参与了方案讨论、Swift 实现、界面迭代、日志分析、审查、测试和文档编写。
这是开发过程说明，不是对代码正确性、独创性或第三方权利的保证。维护与发布责任仍由项目维护者承担。

直播平台名称、主播头像及直播内容属于相应权利人；出现在运行时界面中不表示与本项目存在合作或授权关系。


## 社区致谢

感谢 [LINUX DO](https://linux.do/) 社区的交流与分享。这项致谢不表示社区为本项目提供官方背书。
