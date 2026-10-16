# macOS 代码审查 · 2026-10-16

审查范围：原生重构阶段的 macOS 界面、共用播放器、弹幕绘制、日志和斗鱼取流。
本文保留技术发现，已移除私人开发历史的提交引用和具体观看记录。
审查结合源码与只读日志分析，没有自动操作播放窗口。公开文档不包含原始日志、进程标识或真实观看房间。
以下保留审查时发现的五项问题。它们随后已在 0.3.5 中完成修复与离线回归检查。
其中 1、2、4、5 的底层逻辑已存在于共用 iOS 实现，本次 Mac 复用后同样受影响；3 是新增 Mac 会话逻辑的问题。

## 原始发现（0.3.5 已修复）

### 1. [P1] 取消播放后旧任务仍可能入队并重启播放时钟

位置：`ios_native/App/Player/FLVLivePlayer.swift:267`、`:812`、`:827`、`:838`。

`teardown()` 取消 detached Task 后马上清空解码状态、flush 渲染器；它没有等任务结束或隔离每次连接的上下文。
`waitForRoom()` 会因 `Task.isCancelled` 退出，但调用方 `enqueueVideo/Audio` 返回后没有取消 / generation 检查。
如果此刻渲染器已经因 stop 的 flush 腾出位置，旧 sample 仍会被 enqueue，随后 `startClockIfNeeded()`
还可能把时钟和状态改回 playing。快速停止后重播 / 切线路时，旧任务也会与新任务共用格式和时间戳字段。

影响：停止后又出现旧帧、状态回跳、切流时污染新播放管线。MacRoomSession 的 generation 只保护取流任务，
没有传递到播放器自己的 detached Task，因此不能防住这条路径。

建议：按播放世代隔离解码上下文；统一串行化入队和 reset，并在每个异步恢复点及实际 enqueue 前校验世代。
仅在某一个入口增加取消检查不够。

### 2. [P2] 缺失开播状态会被解释为“已下播”，终止地址刷新

位置：`ios_native/SimpleLiveKit/Sources/SimpleLiveKit/Douyu/DouyuSite.swift:180`、`:203`；
`ios_native/App/Support/Stores.swift:360`。

`fetchRoomInfo()` 只要求 `room` 存在；响应如 `{"room":{}}` 会通过。
`show_status.intValue` 在字段缺失 / 无法解析时回落为 0，`roomBrief.isLiving` 随之为 false。
`refreshStreamURL()` 立即显示“主播已下播”并返回 nil，根本不会尝试取新地址。
新加入的 `statusValid` 日志只是记录，未参与决策。

影响：接口不完整或异常响应可被误报为主播下播，关注状态也会错误变灰。
这仍是用户最初“未开播”反馈的一条候选路径，但不是这次循环重连的已证实原因。

建议：使用 live / offline / unknown 三态，或对缺失状态抛出可恢复错误；确认下播前重查。

### 3. [P2] 手动播放会丢掉用户刚选择的清晰度和线路

位置：`macos_native/App/MacRoomView.swift:66`、`:82`。

触发：默认画质设为最高、关闭自动播放；进房后手选低画质，再点播放。
`chooseQuality()` 能更新当前 store，但播放按钮走 `retry()`，创建全新 `RoomStore`，
随后 `load()` 按默认偏好重新选最高画质，线路也回到 0。
停止后再播放、画中画里恢复播放走相同路径。

影响：用户明确选择被忽略，可能回到更高带宽 / 更高解码负担的画质。

建议：将“恢复播放”和“重载整个房间”分开，重新签名取流时按清晰度名称保留选择，按 CDN 身份保留线路。

### 4. [P2] 修改弹幕设置或改变窗口尺寸会提前释放仍有弹幕的轨道

位置：`ios_native/App/Player/DanmakuOverlay.swift:63`、`:74`。

`apply()` 在字号、速度、区域或间距变化时重建全为 0 的占用表；改变窗口高度导致轨道数变化也会重建。
屏幕上已有的 CALayer 动画仍继续运动。下一条弹幕会被认为可以立即使用这些轨道。
尤其调快速度时，新弹幕会追上仍按旧速度运动的弹幕。

影响：动态调整后暂时重叠，缩小区域后旧弹幕仍可能留在区域外。
这与已经处理的“文字笔画残缺”是不同的问题。

建议：重布局时同时清理现有图层，或根据 presentation layer 的实际位置重新计算占用时间。

### 5. [P2] 切换清晰度失败后，显示的选项与实际播放不一致

位置：`ios_native/App/Support/Stores.swift:323`；`macos_native/App/MacRoomView.swift:92`。

`selectQuality()` 在请求成功前就改写 selectedQualityIndex、currentLineIndex 和记忆偏好。
如果取流请求失败，catch 只设置提示，不回滚这些字段，playURL 仍是上一次结果。
Mac 界面会显示新画质，但播放器继续旧画质；若旧线路不是第 0 条，还可能重新启动旧画质的第 0 条线路。

建议：先获取目标画质的 URL，成功后原子提交所有选择字段；失败保留原选择和原播放状态。

## 本轮已处理

### 画中画偏移与裁切

用户截图显示视频向右上方偏移、左侧和底部大块白色空白。
原 Mac 使用 AVPictureInPictureController 的 sample-buffer 镜像路径。
[Apple 开发者论坛的同类报告](https://developer.apple.com/forums/thread/821582) 提到 macOS 下该路径的缩放异常；
这是其他开发者的报告，不作为本机系统根因已确证的依据。

Mac 改用公开 AppKit NSPanel 实现悬浮播放，直接移动原 AVSampleBufferDisplayLayer，不复制解码链路。
只允许当前拥有该视频图层的宿主更新 frame；旧主窗口的 layout 不再改写小窗尺寸。
窗口采用 point 坐标，视频像素尺寸仅用于纵横比，resizeAspect 保证画面完整。
提供置顶、跨桌面、缩放、播放 / 停止、关闭与返回直播间。iOS 仍使用系统画中画。
这不是系统 AVKit PiP 面板，不依赖私有 PIP.framework 或系统内部视图名称。

### 持续“第 1 次重连”

一份已匿名化的诊断记录显示：起播约 304 秒后发生首次正常 EOF。
随后同一个播放器记录了 30 次 EOF，29 次进入 attempt 1，1 次进入 attempt 2；没有 room.refreshStream。
反复连接返回 HTTP 200，往往只有几秒钟媒体。期间 heartbeat 显示 rendering、rate=1、resync=0。

代码把第一帧视为恢复成功，清除重试预算，因此短连接也让计数回到第 1 次。
已提取 PlaybackRecoveryPolicy：短于 30 秒的起播不重置失败预算；同址最多重试 2 次，
然后由房间层重新签名、取地址、轮换线路；换址仍保留 3 轮上限。
只有稳定播放 30 秒后再发生断流，才把后续恢复作为一次新事件。

上述证据可以确定“重连循环被错误重置”这一客户端问题；不能仅据此断定首次 EOF 就是 CDN 票据过期。
本轮没有操纵正在播放的旧进程，新策略要在用户自行打开新版后生效。

## 验证

- macOS Release 与 iOS 无签名构建通过。
- `Checks/check-floating-video.sh`：1,000 次离屏图层换宿主 / 缩放；宽屏、竖屏、Retina 像素尺寸换算检查通过。
- `Checks/check-playback-recovery.sh`：日志中的短连接序列、换址预算上限、稳定播放后恢复预算、无首帧连接四组检查通过。
- 本轮没有启动 GUI、真实直播或执行画中画交互。实际小窗表现和长时间播放仍需用户验证。

审查结论更新：上述 5 项已修复并复核。验证覆盖源码、编译、假接口与离屏图层；没有将这些结果等同于真实网络下的持续播放或物理窗口交互验证。


## 0.3.5 修复与复核

1. **旧播放任务**：每条连接独立持有格式、时间戳、音频基准和首帧状态。`PlaybackGenerationGate` 将世代撤销与实际 enqueue/flush 串行化；停止返回后旧世代不能再入队。状态、时钟、字节数、尺寸及取新地址回调均校验世代。`PlaybackFlushQueue` 串行等待异步视频 flush，新连接等待清空完成后才拉流；旧 resync 完成后再次检查世代。解复用和常规逐帧入队仍在后台，不逐帧跳主线程。
2. **开播判定**：`parseRoomState` 拒绝缺失、非法、布尔冒充数字等状态；详情、简要状态与 liveStatus 使用同一解析器。重连遇到未知状态继续尝试取流；仅两次有效查询均确认未直播时才停止，取消任务不会变成下播提示。
3. **选择保留**：`LivePlayURL` 新增与 URL 对应的 CDN 身份，避免地址签名和列表顺序变化导致选错线路。Mac 的恢复播放与整房重载分开；前者保留当前 store，后者传递清晰度名称和 CDN 身份。失效选择有明确回退，不沿用越界索引。
4. **弹幕轨道**：速度、字号、区域、间距或画布尺寸变化时，先移除旧动画与图层，再释放并重建轨道；宽度变化也会触发重布局。
5. **清晰度事务**：获取新地址成功后才提交画质、线路、地址和记忆偏好；失败保留原播放信息。每次取流请求拥有序号，过期、被取消、stop 后才返回的结果均不得覆盖最新选择。

对应检查：

- 核心库 `swift test`：25 项通过，含未知状态、有效直播/轮播/下播、CDN 重排匹配。
- `Checks/check-generation-gate.sh`：停止与入队互斥；1,000 次切换中拒绝 4,000 次旧世代写入；新连接的 flush 等待旧 flush 完成。
- `Checks/check-review-fixes.sh`：编译并调用实际 RoomStore 与 DanmakuHostView，使用内存假接口验证失败回滚、恢复/重载保留选择、未知与暂时下播、确认下播、并发乱序/取消/stop 后返回，以及离屏弹幕图层清理。该脚本禁用生产诊断日志写入。
- macOS Release 与 iOS 无签名构建通过；复核未发现上述五项修复中的新增阻断问题。
- 最终 0.3.5 产物使用 `macos_native/build/review-fixes/`，与原 App 路径分开；没有操作窗口或试播。
