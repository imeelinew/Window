<p align="center">
  <img src=".github/assets/logo.png" width="128" height="128" alt="Window">
</p>

<h1 align="center">Window</h1>

<p align="center">
  一款只负责窗口管理的轻量原生 macOS 后台工具。<br>
  没有主窗口、Dock 图标或菜单栏图标，用全局快捷键完成最大化、半屏、居中与工作区整理。
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Window/releases">下载</a> ·
  <a href="#快捷键">快捷键</a> ·
  <a href="#安装">安装</a> ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="README.md">简体中文</a>
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <a href="https://github.com/imeelinew/Window/releases/latest"><img src="https://img.shields.io/github/v/release/imeelinew/Window" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-5-orange" alt="Swift 5">
</p>

---

## 简介

Window 是 [Eli New](https://elinew.tech) 开发的原生 macOS 窗口管理工具，只做一件事：用全局快捷键调整当前聚焦窗口。启动后它作为后台进程运行，不出现在 Dock，也没有菜单栏图标或设置窗口。空闲时不轮询，由快捷键和系统事件驱动。

窗口始终落到当前屏幕的**可用区域**内，会避开菜单栏和 Dock。多显示器时，操作作用在窗口所在的那块屏幕上。首次启动会通过系统标准流程请求辅助功能权限，授权后快捷键才会生效。

## 为什么开发 Window

macOS 的 Dock 会随图标数量改变尺寸，屏幕可用工作区也会跟着变。已经最大化的第三方窗口通常不会重新计算高度，于是 Dock 变高或变矮之后，窗口底部就可能留下一块空隙。

Window 要解决的就是这件事：用快捷键把窗口摆到可用区域，并在 Dock 或显示器布局变化后，让已经最大化的窗口继续贴合屏幕边界。如果你后来自己拖动或缩放了这个窗口，Window 会停止跟踪，把控制权交还给你。

- **后台运行**：无主窗口、无 Dock 图标、无菜单栏图标
- **快捷键驱动**：只处理当前聚焦窗口
- **贴合工作区**：最大化与半屏都按菜单栏和 Dock 让出后的可用区域计算
- **最大化保持贴合**：Dock 缩放、显示器插拔或排列变化后，已最大化窗口会重新对齐

## 快捷键

| 快捷键 | 作用 |
| --- | --- |
| `Command + ↑` | 将当前窗口最大化到所在屏幕的可用区域 |
| `Command + ←` | 将当前窗口放到左半屏 |
| `Command + →` | 将当前窗口放到右半屏 |
| `Command + ↓` | 将当前窗口调整为 998 × 836，并在可用区域内水平、垂直居中 |
| `Command + Option + ↓` | 保留当前聚焦窗口，隐藏其他应用，并最小化当前应用的其他窗口 |

左半屏与右半屏会拼满整块可用区域，中间不留缝。

## 工作方式

- 只操作最前方应用的当前聚焦窗口，不会动到 Window 自己。
- 位置和尺寸以屏幕的可见区域为准，因此菜单栏和 Dock 占用的空间会被留出来。
- 窗口落在哪块显示器上，就按那块显示器的可用区域摆放。
- 最大化后的窗口会继续被跟踪：Dock 尺寸变化、屏幕布局变化、应用重新显示或切回当前 Space 时，会重新贴合可用区域。你手动改过的窗口不再跟踪。
- 窗口移动带有短暂动画；系统开启「减弱动态效果」时会直接落到目标位置。
- Electron 应用使用单独的动画路径，避免反复改尺寸造成卡顿。

## 权限与更新

Window 通过辅助功能 API 读取和设置窗口位置，因此需要辅助功能权限。首次启动会弹出系统授权提示；也可稍后在 **系统设置 → 隐私与安全性 → 辅助功能** 中打开。

应用会通过 Sparkle 自动检查 [GitHub Releases](https://github.com/imeelinew/Window/releases) 上的更新。

## 安装

需要 **macOS 14** 或更高版本。

从 [Releases 页面](https://github.com/imeelinew/Window/releases)下载最新版，把 `Window.app` 放到 `/Applications`，然后打开一次并授予辅助功能权限。

## 从源码构建

工程由 Xcode 26 创建，运行目标为 macOS 14 或更高版本。

```bash
git clone https://github.com/imeelinew/Window.git
cd Window
open Window.xcodeproj
```

在 Xcode 中选择 **Window** scheme，然后执行 **Product → Run**。首次使用快捷键前，请按系统提示授予辅助功能权限。

## 许可证

Window 以 [MIT License](LICENSE) 发布。Copyright © 2026 [Eli New](https://elinew.tech)。
