# Agent Meter

一个简洁的 macOS 菜单栏工具，用来管理 Codex 账号、查看剩余额度，并在切换账号后继续本地会话。

**macOS 26+ · Apple Silicon · 原生 Liquid Glass · 预览版**

[下载 DMG](https://github.com/Vagrant-Zero/agent-meter/releases) · [使用问题与反馈](https://github.com/Vagrant-Zero/agent-meter/issues) · [发布流程](docs/releases.md)

## 可以做什么

- **管理多个账号**：通过官方网页登录，或引用已有 Codex 账号目录。
- **查看额度**：显示官方返回的各周期剩余额度、重置时间和可用重置卡数量。
- **菜单栏快捷切换**：选择仅切换 CLI，或同时切换桌面端与 CLI。
- **恢复本地会话**：跨账号查找历史对话，选择账号后在终端继续。
- **可选菜单栏额度**：显示或隐藏当前 CLI 账号的剩余百分比。
- **原生玻璃界面**：调整背景透明度，保留清晰的文字和标题栏，支持系统深浅色外观。

目前仅支持 Codex，尚未接入 Claude。Agent Meter 是独立项目，与 OpenAI 无隶属关系。

## 下载与安装

1. 打开 [Releases](https://github.com/Vagrant-Zero/agent-meter/releases)，下载 `Agent-Meter-<版本>-macos-arm64.dmg`。
2. 打开 DMG，将 **Agent Meter Preview.app** 拖入 **Applications**。
3. 从 Applications 启动应用，点击菜单栏的环形图标。

当前版本采用临时签名，**尚未进行 Apple Developer ID 签名和公证**。首次打开若被 macOS 阻止，请在“系统设置 → 隐私与安全性”中核对应用来源后选择“仍要打开”，无需关闭系统安全保护。

使用前需要已安装官方 Codex CLI，或安装包含 CLI 的官方 Codex 桌面应用。应用会检查常见安装路径；自定义 CLI 路径可通过 `AGENT_METER_CODEX` 指定。官方客户端不包含在 DMG 中。

升级时退出 Agent Meter，再用新版覆盖应用即可。账号与历史不存储在应用包内，不会因覆盖应用而删除。当前没有应用内自动更新。

## 第一次使用

### 添加账号与查看额度

打开菜单栏 → **管理账号…** → **添加账号**，在官方网页完成登录。可分别添加个人与工作账号。

添加后点击刷新，读取账号的额度信息。菜单栏应用运行期间，所有已添加账号约每 30 秒自动查询一次；查询按账号依次进行，登录或切换中会延后。也可随时手动刷新。超过 5 分钟的缓存会标记为过期，查询失败时保留上次数据。官方数据可能有延迟，百分比也会取整，不是逐 token 实时计数。软件不会自动使用重置卡。

要在菜单栏直接查看额度，勾选 **菜单栏显示剩余额度**。显示内容跟随当前 CLI 默认账号；`*` 表示缓存或查询异常，可打开菜单刷新。取消勾选后只显示图标，选择会自动保存。

### 切换账号

在菜单栏的账号子菜单，或主窗口的 **切换** 菜单中选择：

| 操作 | 行为 |
|---|---|
| 仅切换 CLI | 更改新启动的 Codex 进程所用账号；启用下方 shell 接入后，直接使用 `codex` / `codex resume` 即可 |
| 切换桌面与 CLI | 正常退出并重启受支持的官方桌面端，验证身份后更新 CLI 默认账号 |

已经运行的 CLI 会话继续使用原账号。启用下方 shell 接入后，普通 `codex` 命令会读取软件当前选择；未启用时保持官方原有行为。从 Dock/Finder 直接启动的官方应用也不由本软件接管账号选择。

### 换账号后恢复对话

1. 从菜单栏或主窗口打开 **本地会话**。
2. 搜索会话标题、项目路径或会话 ID。
3. 在 **使用账号** 中选择账号，点击 **恢复会话**。
4. 应用打开 Terminal，在原项目目录中继续这段对话。

默认扫描 `~/.codex`、`~/.codex-profiles/*`、已登记账号及本软件管理的目录。其他位置可通过 **添加目录…** 加入。

恢复时，认证使用所选账号的目录，历史使用原会话数据库；不复制、合并或覆盖历史数据库。某个目录暂时无法读取时，会保留已有列表并显示提示。

### 调整外观

菜单栏 → **外观…**，或点击管理窗口右上角的调节图标。

背景透明度支持 **0% 实色 → 100% 全透明**，实时生效并自动保存。文字和按钮不随背景变淡，标题栏保留底色。系统开启“减少透明度”时，应用遵循系统设置使用实色背景。

## 直接使用 codex / codex resume

如果希望在软件里切换账号后，终端直接运行 `codex resume` 就使用新账号，在 `~/.zshrc` **末尾**加入：

```sh
source "/Applications/Agent Meter Preview.app/Contents/Resources/codex.zsh"
```

若安装在用户目录，将路径改为 `$HOME/Applications/Agent Meter Preview.app/Contents/Resources/codex.zsh`。源码开发也可以直接 source `scripts/codex-resume.zsh`。

首次接入后执行一次 `source ~/.zshrc`，或新开终端。以后在软件中切换账号，已打开的终端也会在下一次运行 `codex` 时读取最新选择，无需再次 source：

```sh
codex
codex resume
codex resume <会话ID>
```

认证使用当前所选账号，恢复会话时仍查找原历史目录。已经运行的 Codex 进程不会被中途换号；先退出该进程，再执行 `codex resume`。

接入只定义 zsh 函数，不替换官方可执行文件、不复制认证文件；`command codex` 可以绕过接入。旧 `cxa` / `cxb` 快捷指令仍可显式使用原 a/b 目录，但普通 `codex` 统一跟随软件中的选择。

## CLI

DMG 安装不会自动修改 shell 配置。可直接使用应用包内的 CLI：

```sh
"/Applications/Agent Meter Preview.app/Contents/MacOS/agent-meter" --help
```

如果经常使用，可在 `~/.zshrc` 加入以下一行，再执行 `source ~/.zshrc`：

```sh
export PATH="/Applications/Agent Meter Preview.app/Contents/MacOS:$PATH"
```

常用命令：

```sh
# 添加和查看账号
agent-meter login personal
agent-meter login work
agent-meter accounts
agent-meter quota

# 引用已有账号目录，不复制凭据
agent-meter import work --profile /path/to/codex-profile

# 切换默认账号，或直接指定账号启动 Codex
agent-meter switch work --cli-only
agent-meter run codex
agent-meter run codex --account personal -- --help

# 同时切换官方桌面端与 CLI
agent-meter switch work
agent-meter status --json

# 查找与恢复会话
agent-meter sessions
agent-meter resume --account work --all
agent-meter resume --account work <会话ID>
agent-meter resume --profile ~/.codex-profiles/a <会话ID>

# 环境检查
agent-meter doctor --json
```

`run` 将 `--` 后的参数传给官方 CLI，不固定模型。更多选项见 `agent-meter --help`。

## 数据保存在哪里

默认数据目录：

```text
~/Library/Application Support/Agent Meter Preview
```

- `accounts.json` 保存账号别名、邮箱、套餐、缓存额度和选择状态。
- 新账号使用独立的 `profiles/<UUID>` 目录，采用官方文件式凭据存储；令牌刷新由官方客户端维护。
- 数据目录权限为 `0700`，账号与凭据文件为 `0600`。当前未实现 Keychain 多账号存储。
- 导入账号只引用原目录；移除账号只删除登记，不删除凭据或会话历史。
- 外观和菜单栏显示偏好保存在 macOS 用户偏好中。

本项目没有独立的遥测或上传服务。登录和额度查询仍通过官方客户端与官方服务通信。不要将自己的账号目录、凭据或会话文件提交到仓库或贴到 Issue 中。

高级配置：

| 环境变量 | 用途 |
|---|---|
| `AGENT_METER_HOME` | 指定独立的应用数据目录 |
| `AGENT_METER_CODEX` | 指定官方 CLI 可执行文件 |
| `AGENT_METER_DESKTOP_APP` | 指定官方桌面应用路径 |

这些变量需要由启动应用或 CLI 的进程传入；Finder 启动的应用不会自动读取 `.zshrc`。

## 当前限制

- **系统与架构**：仅支持 macOS 26+、Apple Silicon，不提供 Intel 版本。
- **桌面切换**：当前适配 `com.openai.codex` **26.908.40834**。其他版本会阻止桌面切换，CLI 功能仍可使用。由 Dock/Finder 启动的桌面端需要先手动退出，再由 Agent Meter 接管启动。
- **会话恢复**：目前适配 Codex CLI **0.154** 的 `state_5.sqlite` 及相关分页历史。其他格式不能保证可恢复，遇到不兼容会报错。
- **运行中的任务**：桌面端存在已观察到的活动任务，或无法可靠判断状态时，会拒绝切换；不会强制杀死官方桌面主进程。
- **预览状态**：尚未完成长时间稳定性验收。官方客户端更新可能影响兼容性。

遇到问题请在 [Issues](https://github.com/Vagrant-Zero/agent-meter/issues) 提供 macOS 版本、Agent Meter 版本、官方 Codex 版本及复现步骤；分享日志前请去除凭据和私人对话。

## 从源码构建

需要 Apple Silicon Mac、macOS 26+，以及 Swift 6.2+ 和 macOS 26 SDK（Xcode 26 或更新工具链）。自动测试另需 Python 3.11+。

```sh
git clone https://github.com/Vagrant-Zero/agent-meter.git
cd agent-meter
./scripts/build.sh
open "dist/Agent Meter Preview.app"
```

可选的本机安装脚本会安装到 `~/Applications`，并在 `~/.local/bin` 创建 CLI 链接：

```sh
./scripts/install.sh
```

检查与打包：

```sh
./scripts/check.sh
./scripts/package-dmg.sh
# 若默认 Python 太旧：
METER_TEST_PYTHON=/path/to/python3.13 ./scripts/check.sh
```

自动测试使用模拟后端与临时数据库，不访问真实账号。真实账号验收记录、生成的界面图片和本机数据不纳入公开仓库。

## 发布

普通提交和拉取请求由 GitHub Actions 构建、测试并检查 DMG 打包。推送 `vX.Y.Z` 标签后，自动生成该版本的 DMG 与 SHA-256 校验文件，上传到 GitHub 预发布页面。详情见 [发布流程](docs/releases.md)。

## 许可

尚未选定开源许可证。公开源码不代表授予额外的使用、修改或分发许可。
