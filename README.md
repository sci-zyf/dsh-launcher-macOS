# DSH Launcher (macOS)

[English](README.en.md)

macOS 桌面图形工具，用于启动、停止、重启、更新 DeepSeek Harness（DSH）web 服务，并可禁用问题插件。所有核心逻辑在 `launcher.sh`。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `main.swift` | AppKit 图形界面（状态文字、操作按钮、更新轨道下拉），只做窗口与后台调度 |
| `launcher.sh` | 核心逻辑：启动/停止/重启 DSH、版本轨道查询与更新、插件禁用、启动失败原因分析 |
| `build.sh` | 一键打包脚本，产物输出到 `~/Applications/DSH Launcher.app` |
| `icon.icns` | 应用图标 |

## 构建

```bash
bash build.sh
```

产物固定输出到 `~/Applications/DSH Launcher.app`，构建脚本通过自身所在目录定位源码，仓库文件夹位置与名称不影响构建。

## 安装

在终端依次执行：

```bash
git clone https://github.com/sci-zyf/dsh-launcher-macOS.git
cd dsh-launcher-macOS
bash build.sh
```

安装产物位于 `~/Applications/DSH Launcher.app`，双击即可运行。构建依赖与版本要求见下方「运行依赖」。

## 运行依赖

1. macOS，系统自带 Swift 工具链（`swiftc`），无需额外安装。
2. 通过 nvm 安装 Node.js：

```bash
brew install nvm
nvm install 24
```

3. 全局安装 dsh 包（launcher.sh 依赖 dsh CLI 与实际运行所需的所有依赖）：

```bash
npm install -g @deepseek-ai/dsh
```

launcher.sh 启动时自动探测 `~/.nvm/versions/node` 下已装且含 dsh 命令的版本目录，无需手动配置路径。

## 命令行用法

`launcher.sh` 可脱离界面独立运行：

```bash
launcher.sh status                    查看状态/版本/PID
launcher.sh dist-tags                 列出可用版本轨道
launcher.sh update <tag>              更新到指定轨道
launcher.sh start                     启动 DSH（后台，端口 3080）
launcher.sh stop                      关闭 DSH
launcher.sh restart                   重启 DSH
launcher.sh disable-plugin @scope/name  从启动清单禁用插件（不重装）
```

## 注意事项

- .app 双击运行是非交互 shell 环境，不读取 `~/.zshrc`。launcher.sh 已内置自动探测逻辑：遍历 nvm 已装版本找到含 dsh 命令的目录并前置到 PATH，不依赖用户 shell 配置。
- 正式 .app 从包内 `Contents/Resources/launcher.sh` 读取脚本；未打包的调试场景（如 Xcode 直接运行）按以下顺序定位脚本：设置环境变量 `DSH_LAUNCHER_SH` 指向任意位置 → 依次检查 `~/Desktop/source/dsh-launcher-macOS/launcher.sh` 与 `~/dsh-launcher-macOS/launcher.sh` 两个兜底路径。移动源码目录时优先用环境变量，或更新 `main.swift` 中 `launcherPath()` 的兜底数组。
- 启动失败时会读取 `~/.dsh/launcher.log` 分析原因，输出「问题插件」与「故障原因」。
- 禁用插件走市场语义：优先调用 dsh 的 `/dsh-market/toggle` 接口，dsh 未运行时兜底改写本地状态文件（改动前自动备份）。
- 核心 bundle（`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`）在保护名单中，禁止禁用。
