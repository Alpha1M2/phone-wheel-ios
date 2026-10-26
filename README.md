# 手机方向盘 iPhone 原生版

基于 yahyio/phone-wheel 的中文定制界面，添加原生 Core Haptics、Core Motion 和局域网 WebSocket 桥接。

## 当前状态

此包是待云端编译的源码，尚未经过 Xcode 编译或 iPhone 真机验证。Windows 上的网页和服务端已可使用。

不需要付费 Apple 开发者会员；免费账号签名通常需要每 7 天续签。构建不需要任何 Apple 密码、签名证书或 GitHub Secrets。

## 云端构建

1. 创建自己的 GitHub 仓库，把本目录内容放在仓库根目录。必须保留 `.github/workflows/build-ios.yml`。
2. 仓库 Actions 中选择 **Build iPhone app**，点击 **Run workflow**。
3. 等待成功后，从该运行的 Artifacts 下载 **PhoneWheel-unsigned**，解压得到 `PhoneWheel-unsigned.ipa`。
4. 编译失败则下载 build-log。不要把未成功构建的源码当作可安装应用。

GitHub 公共仓库标准 macOS runner 免费；私人仓库按账号额度计算。项目只手动构建，不设置定时任务。

## Windows 安装

从 https://sideloadly.io/ 下载 Windows 版 Sideloadly，按其要求准备 Apple 设备驱动。

连接 iPhone，由用户在手机上确认信任电脑。把 IPA 放入 Sideloadly，通过用户自己的免费 Apple 账号签名安装。账号、密码和验证码由用户在本机操作，不要放进仓库。

按手机提示启用开发者模式、信任开发者；约每 7 天需要重新签名。第三方安装工具的实际兼容性需现场确认。

## 使用

1. 电脑启动 Phone Wheel 服务，手机和电脑在同一个可信局域网，代理应绕过局域网。
2. 打开 App，输入电脑 IPv4 和端口，例如 `192.168.1.10:8080`。
3. 首次连接将展示电脑证书 SHA-256。与电脑证书指纹核对一致后再信任；证书改变会重新提示。
4. 点击开始驾驶，横屏握稳后校准中心。
5. 方向盘设置内的 **电脑连接 / 震动设置** 可以测试震动、开启/关闭震动、修改电脑地址。

震动包括按键轻触、换挡、转速阈值和 DRS 提示。游戏遥测需正常运行，才能触发相应游戏状态反馈。未实现轮胎路面、碰撞等持续力反馈。

页面在 App 内本地加载；原生层连接局域网电脑。无外部账号、分析或数据上传。App 只允许连接私人 IPv4 地址，不开放网页对任意外部服务器的原生通信。

## 界面版本

使用最新中文网页：左右踏板均 60% 高度、十字方向键靠左、矩形功能键含彩色圆形 ABXY 图标、肩键标注、转向显示条。已删除满油锁定；左侧刹车上方为全刹车按钮，右侧油门上方为满油按钮，按住生效、松手归零。

## 来源与许可

网页上游：https://github.com/yahyio/phone-wheel ，MIT，原许可位于 LICENSE-upstream。
本包新增代码也按 MIT 许可发布，见 LICENSE。
