# GT 音量助手(GTVolume)

<img src="docs/icon-128.png" width="96" alt="GT 音量助手图标" align="right">

简体中文 | [English](README.en.md)

菜单栏音量控制工具,为**华为 MateView GT 27 显示器**(QSN-CBB / HWV)打造,兼容其他显示器与音频设备。直接控制显示器喇叭的实际音量(DDC/CI 协议,与显示器物理按钮等效),并可与 macOS 本地音量管理打通(键盘音量键接管),附带智能风扇管理。

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
- **智能风扇管理**(可选,首次开启需管理员授权):温度曲线调速、手动 RPM 调速、高温保护;模式跨重启记忆
- **本地模型运行时监测**(Ollama / LM Studio / MLX / llama.cpp):自动发现本机在跑的推理服务,显示已加载模型、显存占用、参数量化、保活倒计时与进程 CPU/内存,附 GPU 利用率与统一内存压力;Ollama 支持一键卸载/批量卸载/续期保活
- **局域网远程模型监测**(Windows / Linux):手动添加 IP:端口或一键扫描 /24 网段,自动识别 Windows 机器上跑的 Ollama / LM Studio / llama.cpp / vLLM,远程 Ollama 同样支持卸载与保活
- **音频假死自动修复**(可选,启用需一次管理员授权):常驻守护在每次显示器唤醒后静默探测,假死自动重启音频服务,全程无感
- **一键修复系统音频**:显示器睡眠唤醒后 DP 音频假死(播放报 `AudioQueueStart failed`)导致系统级无声时,菜单里点一下即可重启音频服务
- 显示器插拔、默认输出切换实时响应;锁定的设备被拔出时自动回退
- 登录时自动启动(SMAppService)
- 无需麦克风等其他权限

## 智能风扇管理

macOS 自带的风扇策略偏保守,本 App 通过 SMC 直读温度与转速,提供三种模式:

- **系统自动**:完全交给 macOS(默认)
- **智能温控**:按「全系统最高温」驱动自定义曲线,三档预设——安静(62°C 起转)/ 均衡(55°C 起转)/ 性能(48°C 起转),升速平滑(每步限速 800 RPM)、带迟滞
- **手动调速**:按风扇滑杆直接设定转速

安全设计:

- 风扇控制键(F0Md/F0Tg)写入需要 root,App 内嵌微型特权助手 `gt-fanctl`,**首次开启时弹一次管理员密码**;助手只接受白名单的风扇命令,本地 socket 权限 0600
- 转速永远钳制在 SMC 上报的 [最小, 最大] 区间;温度 ≥90°C 智能模式强制满速,≥95°C 任何非自动模式强制满速
- App 退出自动恢复系统自动;助手连接断开立即恢复系统自动;助手启动时清理上次异常残留的强制状态

## 音频假死自动修复

显示器睡眠唤醒后,macOS 的 DP 音频驱动偶发假死——设备在、功放正常,但**任何 App 都无法启动音频流**(报 `AudioQueueStart failed ('stop')`),表现为系统级无声,只能 `sudo killall coreaudiod` 修。本功能把它彻底自动化:

- 菜单里点「音频自动修复」→ 助手安装为常驻 LaunchDaemon(`com.sounds.gtfanctl`,开机自启、崩溃自动拉起),**一次性管理员授权,之后不再弹窗**
- 每次显示器重配置(含睡眠唤醒)后,守护在默认输出上静默启动一个**无声测试流**:失败即判定假死 → 自动重启音频服务 → 复测,最多 3 次
- 探测流零音量、毫秒级,健康时完全无感;睡眠中不探测;内置 45 秒冷却防抖
- 再点一次同一菜单项即完全卸载守护

## 本地模型运行时监测

菜单里新增「本地模型」区,自动发现本机正在运行的推理服务并给出可操作的管理入口,不用再开终端敲命令。

**监测的运行时**(探测各自本地 API,请求显式绕过系统代理,避免被 127.0.0.1 上的科学上网代理拦截):

| 运行时 | 探测方式 | 展示内容 |
| --- | --- | --- |
| Ollama | `11434/api/ps` + `/api/tags` | 已加载模型、显存占用、参数量·量化·上下文、保活倒计时、已安装模型总数 |
| LM Studio | `1234/api/v0/models`(回退 `/v1/models`) | 已加载模型、量化、上下文长度 |
| MLX / oMLX / MTPLX | `8088` 等端口的 `/v1/models` | 已提供服务的模型 |
| llama.cpp | `8080/8010/8011` 的 `/props` | 模型别名与权重文件名 |

每个运行时会附带该进程组的 CPU 占用与常驻内存;菜单顶部还有整机 **GPU 利用率**(Apple Silicon 的 IOAccelerator Device Utilization)、统一内存用量与内存压力等级。

**管理动作**:

- **卸载模型**:Ollama / LM Studio 支持按模型卸载。Ollama 走 `keep_alive=0` 立即释放显存;向量模型(bge 等)不接受 generate 请求,会自动回退到 `/api/embed` 完成卸载。
- **卸载全部 / 续期保活**:Ollama 支持一次清空全部已加载模型,或把保活时间延长 30 分钟避免反复冷启动。
- **结束进程**:MLX、llama.cpp 等没有卸载接口的运行时,提供「结束进程(释放内存)」——先发 SIGTERM,宽限期后仍未退出则 SIGKILL(会二次确认)。
- **启动服务**:列出本机已安装但没在跑的运行时,一键拉起(Ollama 走 App 或 `ollama serve`;LM Studio 先起 App 再 `lms server start`;MLX 打开桌面端)。
- **打开控制台**:跳转到对应运行时的管理界面或本地网页控制台。

监测每 5 秒刷新一次;菜单打开时数值就地更新,只有"运行时/已加载模型集合"发生增删才重建菜单,不会打断鼠标操作。

## 远程模型监测(Windows / 局域网)

「远程模型」区可以监测**局域网里其他电脑**上跑的模型服务——典型场景是 Windows 游戏机上装的 Ollama / LM Studio,Mac 菜单栏直接看它加载了什么模型、占了多少显存,还能远程卸载。

**添加方式**:

- **添加远程主机…**:输入 `IP[:端口]`(如 `192.168.1.23:11434`,端口缺省按 Ollama 的 11434),支持主机名
- **扫描局域网**:并发探测主网卡所在 /24 网段的常见推理端口(11434 / 1234 / 8080 / 5001 / 8000 / 5000,约 3~10 秒),发现的服务列在菜单里一键添加
- 已添加的主机持久化保存,离线时显示「离线」,上线自动恢复;可随时「移除」

**自动识别**(按 API 特征依次探测):Ollama(`/api/version`)→ llama.cpp(`/props`)→ LM Studio(`/api/v0/models`)→ 通用 OpenAI 兼容服务(`/v1/models`,覆盖 vLLM、KoboldCpp 等)。

**远程管理能力**:

| 运行时 | 展示 | 管理 |
| --- | --- | --- |
| Ollama | 已加载模型、显存、量化、保活倒计时、已安装总数 | 卸载单个 / 卸载全部 / 续期保活(与本地一致) |
| LM Studio | 已加载模型、量化、上下文 | 仅监测(HTTP 无卸载接口) |
| llama.cpp | 加载的 gguf 模型 | 仅监测,可打开其内置网页界面 |
| OpenAI 兼容 | 提供的模型列表 | 仅监测 |

**Windows 端配置**(服务默认只监听 127.0.0.1,需手动放开):

- Ollama:设置里打开「Expose Ollama to the network」,或设置环境变量 `OLLAMA_HOST=0.0.0.0`
- LM Studio:Developer 页打开「Serve on Local Network」
- llama.cpp:启动参数加 `--host 0.0.0.0`
- 并在 Windows 防火墙放行对应端口(入站规则)

远程探测与本地共用同一套请求通道(显式禁用系统代理),探测结果 12 秒节流,不会拖慢本地刷新。

## 构建与运行

```bash
./build.sh          # 生成 GTVolume.app
open GTVolume.app
```

要求:Xcode Command Line Tools(未安装时先 `xcode-select --install`)。链接了私有框架 CoreDisplay(SDK 内有 tbd 存根,运行时由 dyld 共享缓存解析)。

打包分发 DMG:`./build-dmg.sh`。

建议把 `GTVolume.app` 拖入「应用程序」文件夹后再开启「登录时自动启动」;移动位置后需把该选项关掉再开一次。

## 使用

![菜单截图](docs/screenshot-menu.png)

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
Sources/SMCLite.swift            # SMC 底层:键读写、风扇转速、温度键发现(App 与助手共用)
Sources/FanController.swift      # 智能风扇管理:温度曲线、模式切换、特权助手通信
Sources/ModelMonitor.swift       # 本地模型监测:运行时探测、模型/显存/保活、GPU 与内存压力、卸载与启停
Sources/FanHelperMain.swift      # gt-fanctl 特权助手(root):常驻守护、白名单命令、唤醒探测自动修复、断连恢复
Sources/MediaKeyTap.swift        # CGEventTap 键盘音量键接管(需辅助功能权限)
Sources/MenuBarController.swift  # 菜单栏 UI:滑杆、设备列表、风扇区、状态图标、开机自启
Sources/main.swift               # 入口
tools/main.swift                 # CLI 自检工具(音量通路)
tools/smc_probe.swift            # CLI 自检工具(SMC 风扇/温度键)
Info.plist / build.sh / build-dmg.sh
```

## 常见问题

- **滑杆拖动没声音**:确认菜单里当前目标是目标显示器(勾选状态);显示器端物理音量是否被调为 0。
- **键盘音量键无反应**:需开启「接管键盘音量键」并授予辅助功能权限;开启后系统 OSD 不再弹出,以菜单栏图标为反馈。
- **改了音量但显示器没响**:DP 音量走显示器功放,检查显示器当前输出源与喇叭开关。
- **开启风扇控制没弹密码 / 取消了授权**:菜单底部会显示提示,重新点「智能温控」或「手动调速」即可再次授权;授权只在开启时需要,系统自动模式完全无需权限。
- **显示器唤醒后系统级无声**:DP 音频假死(播放报 `AudioQueueStart failed`)。启用「音频自动修复」后每次唤醒会自动修;也可点「修复系统音频」手动重启音频服务,或手动 `sudo killall coreaudiod`。
- **异常退出后风扇停在固定转速**:重新打开 App,菜单里会出现「恢复自动」入口,点击即可(助手启动时也会主动清理残留)。
- **m1ddc 参考**:本实现与 [waydabber/m1ddc](https://github.com/waydabber/m1ddc) 协议一致,可用 `m1ddc display 1 get volume` 交叉验证。

## 许可证

MIT — 见 [LICENSE](LICENSE)。
