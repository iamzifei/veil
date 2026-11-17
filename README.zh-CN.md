<p align="center"><img src="docs/assets/icon.png" width="128" alt="Veil 图标"></p>

<h1 align="center">Veil</h1>

<p align="center">
  你正在用的窗口保持清晰，后面的一切柔和地模糊掉。<br>
  免费、开源的 macOS 菜单栏小工具。
</p>

<p align="center">
  <a href="https://github.com/iamzifei/veil/releases/latest/download/Veil.dmg"><b>下载 Veil.dmg</b></a> ·
  <a href="https://jamesai.dev/veil/"><b>在浏览器里直接试</b></a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <a href="https://jamesai.dev/veil/"><img src="docs/assets/veil-demo.gif" width="800" alt="Veil 演示"></a><br>
  <sub>▶ <a href="docs/assets/veil-demo.mp4">高清视频（MP4）</a> · 或到 <a href="https://jamesai.dev/veil/">官网</a> 上直接动手试</sub>
</p>

## 它做什么

Mac 上每个窗口都在抢你的注意力。Veil 把背景调低：手上这个窗口清清楚楚，后面的全部变成柔和的模糊，眼睛就不会到处乱跑。

- **Ambient / Deep 两种模式**：轻一点的模糊，或者更暗更重、专心干活用的。
- **外观随你调**：模糊半径（调到 0 就是只调暗、不模糊）、色调（预设色、跟随系统强调色、任意颜色，强度可调）、胶片颗粒、黑白。
- **焦点规则**：*App Groups* 让几个 App 共用一个焦点（比如编辑器 + 浏览器）；*整个 App* 模式让前台 App 的所有窗口都保持清晰；*忽略名单* 里的 App（比如视频播放器）不会被盖住。
- **多显示器**：*Per screen* 每块屏各自保留最前面的窗口；*Global* 只保留你正在用的那个。
- **手势**：晃动鼠标开关；按住 ⇧ 晃动 = 临时看一眼（至少 2 秒，按住 ⇧ 就一直保持）；把指针推进屏幕角落也能临时看一眼；拖文件时自动让开。
- **过渡效果**：淡入淡出、从指针位置展开的圆形、或者直接切换。
- **桌面更干净**：开着 Veil 时可以自动隐藏菜单栏和 Dock；台前调度的侧边窗口条保持可见（也可以一起模糊）。
- **自动化**：`veil://` 地址，Shell、AppleScript、快捷指令都能调。

## 快捷键

| 操作 | 默认 |
|---|---|
| 开关 Veil | ⌃⌥⌘F |
| 切换模式（Ambient ↔ Deep） | ⌃⌥⌘M |
| 忽略当前 App | ⌃⌥⌘E |
| 打开设置面板 | ⌃⌥⌘C |

四个都能在设置面板里重新录。左键点菜单栏图标 = 开关（也可改成打开设置），右键出菜单。

## 自动化

```sh
open -g veil://toggle            # 还有 on, off, peek, settings, ignore
open -g veil://mode/deep         # ambient | deep | toggle
open -g "veil://set?blur=30&tint=blue&tintAmount=0.3&grain=0.4&monochrome=1&transition=cursor"
```

参数说明见 [英文 README](README.md#automation)。用 `open -g` 可以不抢焦点。

## 安装

1. 下载 [Veil.dmg](https://github.com/iamzifei/veil/releases/latest/download/Veil.dmg)，打开后把 **Veil** 拖进「应用程序」。
2. 打开它。Veil 只在菜单栏里，没有 Dock 图标。

需要 macOS 14 或更新版本，Apple 芯片和 Intel 都支持。

**权限**：模糊本身不需要任何权限。Veil 只读取窗口位置，不录屏。只有第一次打开「自动隐藏菜单栏和 Dock」时，会请求「自动化 → System Events」权限。

已用 Developer ID 签名，并通过 Apple 公证。

## 从源码构建

```sh
git clone https://github.com/iamzifei/veil && cd veil
scripts/build.sh
```

Swift 5.9+，没有第三方依赖。

## 许可

[MIT](LICENSE) © 2026 Zifei Gong · 作者 [James](https://jamesai.dev)
