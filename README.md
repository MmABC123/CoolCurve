# CoolCurve

**Minimal thermal monitor & fan curve control for Apple Silicon Macs** (`by Mm`).

一个极简的原生 macOS 菜单栏温控与状态工具，专注于 **看状态（温度 / 功耗 / 内存压力 / 热源）** 与 **控风扇（4 档策略）**。零第三方依赖，要求 macOS 14+、Apple Silicon。

> [!WARNING]
> **个人项目，风险自负。**
> - 只在 **MacBook Pro 14" M3（Mac15,3，单风扇）** 上测试过。其他机型的 SMC 传感器名可能不同，温度读数和风扇策略可能不准确。
> - 首次开启风扇控制时会以管理员权限安装一个 **setuid root 的辅助程序**（`mm-smc-helper`），之后它可以直接写 SMC 改风扇转速。使用前请先阅读源码。
> - 需要自行从源码编译；不提供签名或公证过的安装包，不保证维护，也不提供支持。
>
> *Personal project, use at your own risk: only tested on an M3 MacBook Pro 14", installs a setuid-root helper that writes to the SMC, build from source, no support.*

---

## 核心特性

- **4 档风扇策略**：
  - **原厂（Auto）**：完全交由 macOS 原生温控自动调节
  - **冷静（Cool）**：以“机身不热、声音平稳”为目标。插电时常驻接管、不停转；主要跟随机内热量（`TH0x`，比机身早 1–2 分钟升温）和慢速平滑后的 CPU 平均温度，掌托/电池超过 `35°C` 时缓慢追加转速；升速 ≤1%/秒、降速 ≤0.5%/秒（升速后先保持 30 秒）；`85°C` 以下静音上限 `60%`
  - **速冷（Turbo）**：比原厂更积极的自动档。`58°C` 或 CPU/GPU 负载 ≥60% 即接管，负载一上来就先提速（不等温度）；`58°C` 20% → `70°C` 50% → `80°C` 80% → `88°C` 满转，升速不限、降速 2%/秒；低于 `50°C` 且空闲满 60 秒后交还系统温控
  - **手动（Manual）**：自由拖动滑块在最低到最大转速间定速
  - 百分比指最低转速到最高转速之间的位置（0% = 最低转速，不会停转）
- **多重安全兜底**：
  - CPU 峰值（含最热核心汇总传感器 `TCMz`）连续约 6 秒 ≥ `95°C`：手动档交还 macOS 原生温控；冷静/速冷保持所选模式但暂停，降到 `85°C` 以下自动恢复
  - 电池供电：手动档在拔电时交还系统；冷静/速冷在电池下暂停（可照常选择），接上电源自动恢复
  - 退出/终止 App 时交还 macOS 原生温控；无风扇机型（如 MacBook Air）自动切换为纯监控模式
- **渐进式信息展示**：
  - 菜单栏常驻读数，支持 **简 / 中 / 全** 三档宽度（适配刘海屏，固定宽度零抖动）
  - 左键弹窗快速查看与调节；右键或点 `↗` 打开可置顶主窗口，含 **近 5 分钟温度/风扇/降频曲线**、**GPU 使用率**与 **整机实时功耗（W）**
  - **可交互发热源**：机器空闲时自动隐藏，发热时显示头号高耗进程，点击展开 Top 3 支持一键切换、退出或强退
- **原生与双语**：Swift + SwiftUI + AppKit + IOKit（AppleSMC）+ Mach/libproc，内置中/英切换与深/浅色 `maxminimalism` 主题

---

## 构建与运行

```bash
zsh scripts/build_app.sh
open CoolCurve.app
```

首次开启风扇控制时，点击「解锁风扇控制」输入一次管理员密码。App 会将 `mm-smc-helper` 安装到 `/Library/PrivilegedHelperTools/`（setuid root），之后所有 SMC 写入均通过该辅助工具完成。

命令行查看传感器与风扇状态：

```bash
./CoolCurve.app/Contents/MacOS/mm-smc-helper status
```

## 打包发布（DMG）

```bash
zsh scripts/package_dmg.sh 1.0.0
```

产物会输出到 `dist/CoolCurve-1.0.0-arm64.dmg` 并打印 SHA-256 校验值（可直接用于 GitHub Releases 或 Homebrew Cask）。

> 若未配置 Apple Developer 公证证书，其他用户下载后首次打开如遇 macOS 提示“无法验证开发者”，可执行：
> ```bash
> xattr -cr /Applications/CoolCurve.app
> ```

---

## 目录结构

```text
Resources/
├── AppIcon.icns          macOS 应用图标（分段仪表旋钮）
├── AppIcon.svg           应用图标矢量源文件
└── MenuBarIcon.svg       菜单栏图标矢量源文件
Sources/
├── CSMCKit/              C：AppleSMC 读写 + IOHID 温度传感器
├── SMCKit/               Swift：SMCClient，温度快照、功耗与风扇控制
├── mm-smc-helper/        root 辅助命令行：status / auto / set / ratio
└── CoolCurve/            菜单栏与主窗口 App
    ├── main.swift        状态栏图标、弹窗与主窗口生命周期
    ├── AppState.swift    采样循环、4 档风扇策略、高温/拔电兜底、偏好持久化
    ├── L10n.swift        中/英文案表
    ├── Services/         SystemMonitorService、FanControlService、ProcessSampler
    └── Views/            MenuBarPopoverView、MainWindowView、Components、MmDesignSystem
scripts/
├── build_app.sh          原生编译并生成 CoolCurve.app
├── generate_icon.swift   生成全尺寸 AppIcon.icns
└── package_dmg.sh        一键打包发布用 DMG
```

> 构建脚本直接调用 Command Line Tools 的 `swiftc`，无 SwiftUI 宏插件依赖，因此视图内不使用 `@State`，界面状态统一由 `AppState` 管理。

---

## 许可证

[MIT](LICENSE)：可自由使用、修改和分发，按原样提供，不附带任何担保。
