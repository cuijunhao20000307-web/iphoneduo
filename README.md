# Force Duo 简体中文版构建

本仓库基于 [34306/ForceDuoApp](https://github.com/34306/ForceDuoApp) 固定提交 `5b65200015f7ed0a0fdf34708bd857e4a34e1f80`，叠加简体中文界面与游戏兼容性恢复入口。

GitHub Actions 在 Xcode 27 环境编译未签名 IPA，产物位于 Actions 页面。下载后用 Sideloadly 等工具签名安装，务必保留原应用的 App Groups 权限。

Force Duo 只修改 LaunchServices 的 SDK 记录，无法改写游戏内的音频或画面代码。游戏黑屏、静音时可恢复该游戏的原始 SDK，应用修改并重启设备。此功能是否能处理特定游戏仍需真机验证。

## 替换应用图标

将原图以 `ForceDuoIcon.png` 的文件名上传到仓库的 `assets/` 目录。每次上传会自动重新构建 IPA；构建时只按苹果图标要求缩放到 1024×1024，不重绘图案。上传后到 Actions 页面下载最新构建产物。
