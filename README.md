<p align="center"><img src="docs/assets/icon.png" width="128" alt="Veil icon"></p>

<h1 align="center">Veil</h1>

<p align="center">
  Keep the window you're working in sharp. Softly blur everything behind it.<br>
  A free, open-source macOS menu-bar app.
</p>

<p align="center">
  <a href="https://github.com/iamzifei/veil/releases/latest/download/Veil.dmg"><b>Download Veil.dmg</b></a> ·
  <a href="https://jamesai.dev/veil/"><b>Try it in your browser</b></a> ·
  <a href="README.zh-CN.md">中文</a>
</p>

<p align="center">
  <a href="https://jamesai.dev/veil/"><img src="docs/assets/veil-demo.gif" width="800" alt="Veil demo: switching windows, the settings panel, tint, Ambient mode, monochrome, fading off and on"></a><br>
  <sub>▶ <a href="docs/assets/veil-demo.mp4">Full-quality video (MP4)</a> · or <a href="https://jamesai.dev/veil/">play with it live</a> on the website</sub>
</p>

## What it does

Your Mac shows every window at full volume. Veil turns the background down: the window you're using stays crisp, and everything behind it fades into a soft blur, so your eyes stop wandering.

- **Deep and Ambient modes.** Deep blurs everything behind your window evenly. Ambient keeps the top of the screen clear and lets the blur build towards the middle.
- **A Control Center-style panel.** Click the menu-bar icon and a frosted panel appears at the right edge of the screen: ignore the current app, power, mode, and blur, tint and grain sliders up top; *More settings* for everything else.
- **Your look.** Blur strength (0 = blur-free: tint, grain or monochrome only), tint (as system, nine presets, or any colour) with opacity, film grain, monochrome.
- **Focus rules.** *App Groups* treat several apps as one focus (say, an editor plus a browser). *App-wide focus* keeps every window of the front app sharp. An *ignore list* switches Veil off for apps like video players.
- **Multiple displays.** *Per screen* keeps the frontmost window on each display sharp; *Global* only the one you're using.
- **Gestures.** Shake the mouse to toggle. Hold ⇧ and shake to peek behind the veil (it stays at least 2 s and holds while you keep ⇧ down). Push the pointer into a screen corner to peek. Veil steps aside while you drag a file.
- **Transitions.** The veil fades in and out (0–1.5 s, 0.75 s by default) or grows as a soft circle from your pointer. When you switch windows, the new one is sharp at once and the old one blurs back in.
- **Tidy desktop.** Optionally auto-hide the menu bar, the Dock, or both while Veil is on. The Stage Manager strip stays visible (or blur it too).
- **Automation.** A `veil://` URL scheme for Shell, AppleScript and Shortcuts; the panel lists every command, click one to copy it.

## Shortcuts

| Action | Default |
|---|---|
| Toggle Veil | ⌃⌥⌘F |
| Switch mode (Ambient ↔ Deep) | ⌃⌥⌘M |
| Ignore the current app | ⌃⌥⌘E |
| Open the settings panel | ⌃⌥⌘C |

All four can be re-recorded in the panel (More settings → Shortcuts). Left-click the menu-bar icon to open the panel (or to toggle Veil, your choice). Right-click it for the menu. The icon shows the state: a glowing dot for Deep, a soft dot for Ambient, a ring when the front app is ignored, a faint dot when Veil is off.

## Automation

```sh
open -g veil://toggle                 # also: on, off, peek, settings, check-updates, quit
open -g veil://mode/ambient           # ambient | deep | toggle
open -g veil://blur/60                # 0–100
open -g veil://tint/color/blue        # system, blue, purple, pink, red, orange, yellow, green, graphite, black, or RRGGBB
open -g veil://tint/opacity/30        # 0–100
open -g veil://grain/50               # 0–100
open -g veil://grayscale/toggle       # on | off | toggle | 0–100
open -g veil://display/global         # perScreen | global
open -g veil://reveal-all/toggle      # app-wide focus: on | off | toggle
open -g veil://ignore/toggle          # ignore / include the front app; ignore/<bundle id>, unignore/<bundle id>
```

The older `veil://set?blur=…&tint=…` form still works. Use `open -g` so Veil doesn't steal focus.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask iamzifei/tap/veil
```

Or by hand:

1. Download [Veil.dmg](https://github.com/iamzifei/veil/releases/latest/download/Veil.dmg), open it, and drag **Veil** to Applications.
2. Launch it. Veil lives in the menu bar; there is no Dock icon.

Requires macOS 14 Sonoma or later. Universal binary (Apple Silicon + Intel).

**Permissions.** None for blurring: Veil reads window positions, which needs no permission, and it never records your screen. Auto-hiding the menu bar and Dock asks for *Automation → System Events* the first time you turn it on.

Signed with a Developer ID and notarized by Apple. Updates install automatically (Sparkle).

## Build from source

```sh
git clone https://github.com/iamzifei/veil && cd veil
scripts/build.sh            # builds, ad-hoc signs, installs to /Applications
scripts/build.sh release    # Developer ID signing + DMG (maintainers)
```

Swift 5.9+. The only dependency is [Sparkle](https://sparkle-project.org) for automatic updates.

## How it works

Each display gets a borderless overlay window that is ordered **directly below the focused window**, so everything above it stays sharp and everything below it is blurred by the window server itself (a `CABackdropLayer` with a Gaussian-blur filter, a tint layer and a grain layer; Ambient adds a vertical gradient mask). Windows that must stay sharp but sit lower in the stack (App Groups, App-wide focus, the Stage Manager strip) are cut out of the overlay with a mask. Focus is tracked by polling `CGWindowListCopyWindowInfo` twenty times a second; that needs no permission and catches window switches no notification reports.

## License

[MIT](LICENSE) © 2026 Zifei Gong · made by [James](https://jamesai.dev)

## More Mac apps by James

| App | What it does | GitHub |
|---|---|---|
| [Candela](https://getcandela.app) | Every display control macOS hides | [iamzifei/Candela](https://github.com/iamzifei/Candela) |
| [ClipStack](https://getclipstack.app) | Clipboard history in the menu bar | [iamzifei/clipstack](https://github.com/iamzifei/clipstack) |
| [AudioSwitch](https://audioswitch.dev) | Audio device switching from the menu bar | [iamzifei/audioswitch](https://github.com/iamzifei/audioswitch) |
| [Inkstone](https://inkslab.app) | Notes that stay your own files | [iamzifei/inkstone](https://github.com/iamzifei/inkstone) |
| [Tapper](https://jamesai.dev/tapper/) | Turns your pointer into a cartoon glove on a long stick, for demos and screen recordings. Free, MIT. | [iamzifei/tapper](https://github.com/iamzifei/tapper) |
