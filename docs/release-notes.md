Agent Relay 0.2.0 · macOS 26+ · Apple Silicon

项目由 Agent Meter 更名为 Agent Relay，定位为 coding agent 账号切换与本地会话管理工具。目前已支持 Codex，其他平台尚未接入。

应用、CLI、仓库及 DMG 统一使用新名称。原有账号、登录凭据、本地会话、外观和菜单栏设置继续保留；内部数据目录与应用标识保持兼容。CLI 改为 `agent-relay`，不再提供旧命令和旧应用路径的兼容入口。

从旧版升级请先退出 Agent Meter，再启动 Agent Relay。若 shell 配置直接引用旧应用路径，请更新为 `Agent Relay.app/Contents/Resources/codex.zsh`。

下载 DMG 后将应用拖入 Applications。此版本采用临时签名，未进行 Apple 公证；首次打开被阻止时，在系统设置的隐私与安全性中选择“仍要打开”。无需关闭系统安全保护。
