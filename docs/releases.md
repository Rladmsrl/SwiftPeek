# 发布流程

## 版本

两端只从 `shared/version.yml` 读取版本。当前 0.8.0 (14)。每次发布递增版本和 build：

```sh
python3 scripts/bump-version.py          # 0.8.0 -> 0.8.1，同时 build +1
python3 scripts/bump-version.py 0.9.0    # 显式指定更高版本
```

不要复用已发布 tag。版本脚本不提交、不打 tag、不上传。

## macOS

需要 Xcode 27.1、XcodeGen、Python 3。先验证两端编译与受影响检查，再检查 staged diff 和隐私，将本次发布提交为独立快照。保持工作区干净：

```sh
bash scripts/release-macos.sh
```

脚本为 arm64 和 x86_64 构建 Universal 应用，将分发副本的调试路径符号移除后重新 ad-hoc 签名，扫描最终 app，生成应用 ZIP、对应提交的源码 ZIP 和 SHA-256 校验文件。构建日志、原始产物和 staging 都不上传。

输出在忽略的 `.local/releases/<version>/`。发布前解压应用 ZIP，再运行 `scripts/audit-release.py` 检查版本、两种架构、签名、个人路径、凭据特征和许可资源；检查源码 ZIP 不含私人数据。该扫描是发布防线，不是任意秘密或漏洞的完整检测。

只上传 `SwiftPeek-<version>-macOS-universal.zip`、`SwiftPeek-<version>-source.zip` 和 `SHA256SUMS.txt`，并将 release tag 指向生成源码包的同一个提交。

最低系统为 macOS 27。x86_64 交叉编译成功不能代替 Intel 真机兼容性、图形及播放验证。不要把下载名称写成“适用于所有 Intel Mac”。

当前采用不包含开发者身份的 ad-hoc 签名，未做 Developer ID 公证。Gatekeeper 可能阻止运行；核对仓库来源和 SHA-256 后，可按系统提示在“系统设置 → 隐私与安全性”允许该应用。不要要求用户全局关闭 Gatekeeper。将来若改用 Developer ID，必须先明确证书身份会向下载者公开，并调整审计规则。

## iOS 自用与侧载

两端使用同一版本与源码，但本流程不会公开个人签名 IPA。个人签名会把团队、证书以及可能的注册设备信息写入产物。

自用：从源码生成工程，由安装者在本机选择自己的开发团队构建。团队覆盖配置仅存在忽略的 `*.local.xcconfig` 或本机 Xcode 工程中。

若之后公开侧载产物，应从无签名 Release 的设备构建开始，创建只包含 `Payload/SwiftPeek.app` 的 IPA，清理符号路径并检查整个包，不携带维护者的 provisioning profile、签名身份、测试 target 或诊断文件。使用者需要自己的签名和相应安装工具；无签名 IPA 本身不能直接安装。不得为分发提供个人私钥或企业证书。

实际发布 iOS 之前，还需验证重签后真机安装、启动、网络播放、后台和 PiP；macOS 发布通过不代表 iOS 已完成验收。
