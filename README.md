# GT 音量助手(GTVolume)

简体中文 | [English](README.en.md)

![GT 音量助手菜单截图](docs/screenshot-menu.png)

菜单栏音量控制工具,为**华为 MateView GT 27 显示器**(QSN-CBB / HWV)打造,兼容其他显示器与音频设备。直接控制显示器喇叭的实际音量(DDC/CI 协议,与显示器物理按钮等效),并可与 macOS 本地音量管理打通(键盘音量键接管)。

纯 Swift + Command Line Tools 构建,无需 Xcode 工程;使用 [waydabber/m1ddc](https://github.com/waydabber/m1ddc) 验证过的 DDC 通路。MIT 许可证。

## 为什么需要它

这台显示器通过 DisplayPort 输出音频时,macOS **不提供任何系统音量控制**:

- CoreAudio 设备(QSN-CBB)无 VolumeScalar/Mute 属性,`osascript get volume settings` 的输出音量为 `missing value`;
- 键盘音量键只会弹系统 OSD,实际不改变显示器喇叭音量。

唯一通路是显示器的 DDC/CI 接口(VCP 0x62 音量 / 0x8D 静音),本 App 通过 Apple Silicon 的 IOAVService 私有 API 直连(与 MonitorControl、m1ddc 同源),已在 Mac Studio + DP 连接下实测读写可用。

## 功能

- 菜单栏喇叭图标 + 滑杆,实时控制显示器喇叭音量(百分比显示,图标随音量/静音变化)
- 静音切换(VCP 0x8D;显示器不支持时以音量 0 模拟)
- **显示器物理按键改音量 → App 3 秒内同步**(DDC 轮询)
- 自动识别华为显示器(厂商 HWV / 名称匹配),也可在设备列表锁定任意 DDC 显示器或 CoreAudio 设备(蓝牙、内建扬声器等)
- 「跟随系统默认输出」:默认输出是普通设备时直接控制它;是无音量控制的 DP 显示器时自动映射到同名显示器喇叭
- **接管键盘音量键**(可选,需辅助功能权限):拦截 F1/F2/F3 音量键,±5% 步进控制显示器音量——把 mac 本地音量键真正"打通"到显示器
- 显示器插拔、默认输出切换实时响应;锁定的设备被拔出时自动回退
- 登录时自动启动(SMAppService)
- 无需麦克风等其他权限

## 构建与运行

```bash
./build.sh          # 生成 GTVolume.app
open GTVolume.app
```

要求:Xcode Command Line Tools(未安装时先 `xcode-select --install`)。链接了私有框架 CoreDisplay(SDK 内有 tbd 存根,运行时由 dyld 共享缓存解析)。

打包分发 DMG:`./build-dmg.sh`。

建议把 `GTVolume.app` 拖入「应用程序」文件夹后再开启「登录时自动启动」;移动位置后需把该选项关掉再开一次。

## 使用

- 点击菜单栏喇叭图标,拖动滑杆调节音量
- 「显示器喇叭(DDC)」区:勾选任意一台显示器锁定控制
- 「输出设备」区:蓝牙耳机、内建扬声器等 CoreAudio 设备(走系统音量属性,与音量键天然同步)
- 「接管键盘音量键」:开启后按音量键即调节当前目标音量;首次开启会弹出辅助功能授权,在 系统设置 → 隐私与安全性 → 辅助功能 中勾选本 App

## 与系统音量打通的原理

App 通过 CoreAudio 直接读写输出设备的 `kAudioDevicePropertyVolumeScalar` / `kAudioDevicePropertyMute`——与按下键盘音量键修改的是**同一份系统状态**:

- **App → 系统**:调节滑杆即写入目标设备音量,系统层面(控制中心、音量键)立即一致
- **系统 → App**:注册 `AudioObjectAddPropertyListenerBlock` 监听音量、静音、默认设备切换、设备插拔,任何外部改动实时刷新 UI

当默认输出无音量控制(DP 显示器音频)时,App 把「跟随系统默认输出」映射到同名显示器并走 DDC;开启键盘音量键接管后,音量键也会路由到那里。

## 自检工具

```bash
# 列出输出设备与 DDC 显示器,验证音量读写(原值回写,不改变当前音量)
swiftc -O -swift-version 5 Sources/AudioController.swift Sources/DDCController.swift tools/main.swift \
  -o /tmp/gt-audio-check -framework IOKit \
  -F "$(xcrun --show-sdk-path)/System/Library/PrivateFrameworks" -framework CoreDisplay
/tmp/gt-audio-check
```

## 目录结构

```
Sources/AudioController.swift    # CoreAudio 封装:设备枚举、音量/静音读写、属性监听
Sources/DDCController.swift      # DDC/CI 封装:显示器发现、IOAVService I2C、VCP 0x62/0x8D
Sources/VolumeManager.swift      # 统一目标模型:跟随默认输出 / 锁定音频设备 / 锁定 DDC 显示器
Sources/MediaKeyTap.swift        # CGEventTap 键盘音量键接管(需辅助功能权限)
Sources/MenuBarController.swift  # 菜单栏 UI:滑杆、设备列表、状态图标、开机自启
Sources/main.swift               # 入口
tools/main.swift                 # CLI 自检工具
Info.plist / build.sh / build-dmg.sh
```

## 常见问题

- **滑杆拖动没声音**:确认菜单里当前目标是目标显示器(勾选状态);显示器端物理音量是否被调为 0。
- **键盘音量键无反应**:需开启「接管键盘音量键」并授予辅助功能权限;开启后系统 OSD 不再弹出,以菜单栏图标为反馈。
- **改了音量但显示器没响**:DP 音量走显示器功放,检查显示器当前输出源与喇叭开关。
- **m1ddc 参考**:本实现与 [waydabber/m1ddc](https://github.com/waydabber/m1ddc) 协议一致,可用 `m1ddc display 1 get volume` 交叉验证。

## 许可证

MIT — 见 [LICENSE](LICENSE)。
