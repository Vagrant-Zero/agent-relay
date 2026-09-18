# 发布

目标：macOS 26+ / arm64。需要带 macOS 26 SDK 的 Xcode 26 或更新工具链。

测试需要 Python 3.11+；非默认解释器可通过 `METER_TEST_PYTHON` 指定。

本地构建与打包：

```sh
./scripts/build.sh 0.1.0
./scripts/check.sh
./scripts/package-dmg.sh
```

产物：`dist/Agent-Relay-0.1.0-macos-arm64.dmg` 和对应 `.sha256` 文件。
DMG 包含应用、Applications 快捷方式和安装说明。应用内已包含本项目 CLI 与适配器，不包含官方 Codex。

GitHub Actions 的 `Checks` 检查 main 分支和拉取请求，也可手动运行。
`Release DMG` 由 `vX.Y.Z` 标签触发，在标准 macOS 26 arm64 机器上测试并打包，将 DMG、校验和及签名 appcast 上传到 GitHub 预发布页面，并在 `updates` 分支发布更新订阅。
版本由标签写入应用 Info.plist；不接受任意字符或预发布后缀。

```sh
git tag -a v0.1.0 -m 'Agent Relay 0.1.0 preview'
git push origin v0.1.0
```

每次发布前更新 `docs/release-notes.md`。新的版本使用新标签，不覆盖旧版本。
流程使用仓库自带的 `GITHUB_TOKEN` 发布产物和 `updates/appcast.xml`，并需要 `SPARKLE_PRIVATE_KEY` 仓库 Secret 签署更新包。公钥固定在 Info.plist 的 `SUPublicEDKey`；私钥不得提交源码，需独立安全备份，不可随意重新生成。

Sparkle 固定为 2.10.0，由 SwiftPM 获取。`scripts/build.sh` 将原始框架连同更新辅助程序复制进应用。`scripts/make-appcast.py` 签署 DMG，并以应用内公钥验证签名，再生成订阅；只有 Release 上传成功后才运行 `scripts/publish-appcast.py`，防止发布不可下载的更新。较旧版本不会覆盖较新订阅。

本地签名默认读取 `~/.config/agent-relay/private/sparkle-ed25519.key`（权限 0600），也可通过 `SPARKLE_PRIVATE_KEY` 环境变量提供。不要将私钥写到命令参数、日志或公开制品里。


当前采用 ad-hoc 临时签名，未公证；不能将此版本描述为 Developer ID 签名或已经通过 Gatekeeper。未来接入 Developer ID 时再加入 Hardened Runtime、签名、公证和 stapling。

公开仓库不包含本机账号、会话、生成的设计图或真实账号验收记录。公开源码不等于授予开源许可；尚未选定许可证。
