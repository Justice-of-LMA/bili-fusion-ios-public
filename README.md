# 二路随行 iOS

iPhone / iPad 的二路融合观看工具，GPL-3.0。普通版与独立本机 AI 去人声版共用工程。

当前修复目标：普通版0.2.5/build16、AI版0.3.2/build3。正在修复7777／6连续播放中断；第一轮实播未通过，后续修正尚待重新编译和实播，不能把此源码状态称为已通过验收的发布版。

## 功能与边界

B站、虎牙、斗鱼主副组合，两路音量与0–20秒额外延迟；统一弹幕/SC、专属表情、用户与关键词屏蔽、合并/不重叠模式。画中画需用户主动开启；iOS没有Android式透明跨App弹幕层。平台登录、验证、画质权限与开播状态仍受平台约束。

不自动刷新、重新取源、切换线路或跳回直播点。正常缓冲恢复使用原播放项，保留用户暂停和延迟选择。独立AI版在本机估计并减去人声，不是专门训练的LOL分离模型，可能损伤游戏音效，只处理支持的TS/AAC路径。

## 构建与测试

macOS + Xcode + XcodeGen。先运行 bash scripts/build-voice.sh，再运行 xcodegen generate。AI版另运行 bash scripts/prepare-ai-voice.sh，并使用 xcodegen generate --spec project-ai.yml。

Actions只接受手动触发。run_tests启用原生回归；live_soak启用7777／6真实原生连续五分钟测试（先双画面，再B仅音频），不登录、不发送消息。失败不能当作通过，模拟器也不替代所有真机与网络验收。构建不使用签名证书，IPA需用户自行签名；不需要把密码、Cookie或私钥交给开发者。

本公开仓库只发布审核后的当前源码快照及随包资源，不复制原私有仓库历史，不包含账号、签名、缓存或本机测试产物。随包支付宝/微信资源只用于用户自愿支持，不影响功能，不自动付款。

## 来源与许可

应用见LICENSE；各组件保留原许可和署名。FFmpeg精简构建及固定来源在scripts/build-voice.sh，AI模型和ONNX Runtime来源/校验见AIAssets/PROVENANCE.md，Web第三方许可见Fusion/Web/NOTICES.txt和vendor。公开测试语音归因见Tests/Fixtures/VOICES-ATTRIBUTION.md。分发安装包时应同时提供完整对应源码与第三方材料。

开发者：B站 @夙潮夜汐
