# 发布流程

## 版本

两端只从 `shared/version.yml` 读取版本。当前双端版本为 0.8.4 (18)。每次发布递增版本和 build：

```sh
python3 scripts/bump-version.py          # 0.8.4 -> 0.8.5，同时 build +1
python3 scripts/bump-version.py 0.9.0    # 显式指定更高版本
```

不要复用已发布 tag。版本脚本不提交、不打 tag、不上传。

0.8.4 起，同一版本按平台分别创建 `v<version>-ios`、`v<version>-macos` 两个 Release，标签指向同一发布提交，各自附带平台安装包、匹配源码 ZIP 和 SHA256SUMS.txt。打包目录分别为 `.local/releases/<version>/ios/` 和 `.local/releases/<version>/macos/`，可从同一干净快照依次或并行执行两端脚本。

## macOS

需要 Xcode 27.1、XcodeGen、Python 3。先验证两端编译与受影响检查，再检查 staged diff 和隐私，将本次发布提交为独立快照。保持工作区干净：

```sh
bash scripts/release-macos.sh
```

脚本为 arm64 和 x86_64 构建 Universal 应用，将分发副本的调试路径符号移除后重新 ad-hoc 签名，扫描最终 app，生成应用 ZIP、对应提交的源码 ZIP 和 SHA-256 校验文件。构建日志、原始产物和 staging 都不上传。

输出在忽略的 `.local/releases/<version>/macos/`。发布前解压应用 ZIP，再运行 `scripts/audit-release.py` 检查版本、两种架构、签名、个人路径、凭据特征和许可资源；检查源码 ZIP 不含私人数据。该扫描是发布防线，不是任意秘密或漏洞的完整检测。

只上传 `SwiftPeek-<version>-macOS-universal.zip`、`SwiftPeek-<version>-source.zip` 和 `SHA256SUMS.txt`，并将 release tag 指向生成源码包的同一个提交。

最低系统为 macOS 26。x86_64 交叉编译成功不能代替 Intel 真机兼容性、图形及播放验证。不要把下载名称写成“适用于所有 Intel Mac”。

当前采用不包含开发者身份的 ad-hoc 签名，未做 Developer ID 公证。Gatekeeper 可能阻止运行；核对仓库来源和 SHA-256 后，可按系统提示在“系统设置 → 隐私与安全性”允许该应用。不要要求用户全局关闭 Gatekeeper。将来若改用 Developer ID，必须先明确证书身份会向下载者公开，并调整审计规则。

## iOS 自用与侧载

两端使用同一版本与源码，但本流程不会公开个人签名 IPA。个人签名会把团队、证书以及可能的注册设备信息写入产物。

自用：从源码生成工程，由安装者在本机选择自己的开发团队构建。团队覆盖配置仅存在忽略的 `*.local.xcconfig` 或本机 Xcode 工程中。

Release 共享配置关闭 ENABLE_CODE_COVERAGE；构建时也应显式传入 ENABLE_CODE_COVERAGE=NO，避免本机 scheme 覆盖设置。覆盖率插桩会嵌入源码路径，单独剥离调试符号不足以去除。

0.8.1 已在同一 Release 补充公开无签名 IPA，源码版本和二进制版本保持一致。后续打包应从无签名 Release 的设备构建开始，创建只包含 `Payload/SwiftPeek.app` 的 IPA，清理符号路径并检查整个包，不携带维护者的 provisioning profile、签名身份、测试 target 或诊断文件。使用者需要自己的签名和相应安装工具；无签名 IPA 本身不能直接安装。不得为分发提供个人私钥或企业证书。

iOS IPA 上传后应下载回验，并将其摘要加入同一版本的 SHA256SUMS.txt。当前 0.8.1 尚未验证重签后的真机安装、启动、网络播放、后台和 PiP，发布说明已明确这一限制；macOS 发布通过不代表 iOS 已完成验收。

## iOS 0.8.2 打包

从已提交且干净的快照运行 `bash scripts/release-ios.sh`。脚本以关闭签名和覆盖率的 Release 配置构建设备 arm64 产物，剥离调试路径后调用 `scripts/audit-release.py --platform ios`，生成无签名 IPA、同提交源码 ZIP 和 SHA256SUMS.txt。发布前解压 IPA 再审计，上传后下载回验摘要。只上传这三份文件，不能上传 staging、构建目录、签名开发包或私人日志。

0.8.2 的代码已在维护者 Duo 上安装并验证小窗流畅度改善；公开无签名 IPA 重签后的安装验证仍需由使用者完成。本次仅发布 iOS 安装包，不替换 macOS 0.8.1 附件。

## iOS 0.8.3 发布

沿用上述无签名打包、解包审计、源码匹配及下载回验流程，仅发布 iOS / iPadOS arm64 安装包。更新说明见 [0.8.3：多画面直播与三档弹幕](release-notes/0.8.3.md)。

## 双端 0.8.4 发布

两端从同一提交构建，分别发布 [iOS 全屏返回与直播状态修复](release-notes/0.8.4-ios.md) 和 [macOS 直播状态修复](release-notes/0.8.4-macos.md)。每个平台都应解包审计并下载回验，不能以一端通过替代另一端的检查。
