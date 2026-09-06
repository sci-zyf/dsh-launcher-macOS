# DSH Launcher (macOS)

macOS 桌面图形工具，用于启动、停止、重启、更新 DeepSeek Harness（DSH）web 服务，并可禁用问题插件。所有核心逻辑在 `launcher.sh`，本仓库文件仅供个人使用与备份。

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

## 运行依赖

- macOS，系统自带 Swift 工具链（`swiftc`）。
- 通过 nvm 安装的 Node.js，当前路径写死在 `launcher.sh` 中（`~/.nvm/versions/node/v24.16.0/bin`）。若 nvm 的 node 版本目录变化，需同步更新 `launcher.sh` 内两处路径，否则 .app 双击启动会找不到 node。
- 全局安装的 `@deepseek-ai/dsh` 包。

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

- .app 双击运行是非交互 shell 环境，不读取 `~/.zshrc`，因此 `launcher.sh` 必须显式写入 nvm node 路径，不能依赖用户 shell 配置。
- 正式 .app 从包内 `Contents/Resources/launcher.sh` 读取脚本；Xcode 直接调试等未打包场景会回退到 `~/dsh-launcher-macOS/launcher.sh`，本仓库文件夹名变更时需同步修改 `main.swift` 中的回退路径。
- 启动失败时会读取 `~/.dsh/launcher.log` 分析原因，输出「问题插件」与「故障原因」。
- 禁用插件走市场语义：优先调用 dsh 的 `/dsh-market/toggle` 接口，dsh 未运行时兜底改写本地状态文件（改动前自动备份）。
- 核心 bundle（`@deepseek-ai/dsh-base`、`@deepseek-ai/dsh-web-app`）在保护名单中，禁止禁用。
