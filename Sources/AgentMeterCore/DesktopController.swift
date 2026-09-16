import Foundation
import AppKit
import Darwin

public final class DesktopController {
    public let store: Store
    public let cancellation: Cancellation
    public init(store: Store, cancellation: Cancellation = Cancellation()) { self.store = store; self.cancellation = cancellation }
    public static func isAlive(_ pid: Int32) -> Bool { pid > 1 && (kill(pid, 0) == 0 || errno == EPERM) }
    public static func state(_ session: DesktopSession) -> BridgeState? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: session.statePath)), data.count < 16384,
              let state = try? JSONDecoder().decode(BridgeState.self, from: data), state.nonce == session.nonce else { return nil }
        return state
    }
    public static func isVerified(_ session: DesktopSession) -> Bool {
        guard isAlive(session.processID), let state = state(session), isAlive(state.bridgePID), isAlive(state.childPID) else { return false }
        return state.accountVerified
    }
    public static func application() throws -> URL {
        let paths = [ProcessInfo.processInfo.environment["AGENT_METER_DESKTOP_APP"], "/Applications/Codex.app", "/Applications/ChatGPT.app"].compactMap { $0 }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.openai.codex" { return url }
        }
        throw MeterError.message("未找到 Codex 官方桌面应用。可先使用「仅切换 CLI」。")
    }
    public static func bridgeExecutable() throws -> URL {
        let current = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL.resolvingSymlinksInPath()
        let candidates = [
            current.deletingLastPathComponent().appendingPathComponent("agent-relay-bridge"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-relay-bridge")
        ]
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MeterError.message("缺少桌面适配器，请重新运行构建脚本。")
        }
        return url
    }
    private func quit(_ session: DesktopSession) throws {
        guard Self.isAlive(session.processID) else { return }
        guard let app = NSRunningApplication(processIdentifier: session.processID),
              app.bundleIdentifier == "com.openai.codex",
              app.bundleURL?.standardizedFileURL == URL(fileURLWithPath: session.appPath).standardizedFileURL else {
            throw MeterError.message("桌面进程身份无法确认，请手动退出官方桌面端后重试。")
        }
        guard let state = Self.state(session), Self.isAlive(state.bridgePID), state.trackingReliable else {
            throw MeterError.message("无法可靠确认桌面任务状态，请手动退出官方桌面端后重试。")
        }
        guard state.activeTurns == 0 else { throw MeterError.message("桌面端有任务正在运行，请完成或取消任务后切换。") }
        guard app.terminate() else { throw MeterError.message("官方桌面端未接受退出请求。") }
        let deadline = Date().addingTimeInterval(15)
        while Self.isAlive(session.processID) && Date() < deadline { usleep(100_000) }
        guard !Self.isAlive(session.processID) else { throw MeterError.message("桌面端尚未退出，切换已停止；请处理桌面端提示后重试。") }
        let childDeadline = Date().addingTimeInterval(5)
        while (Self.isAlive(state.bridgePID) || Self.isAlive(state.childPID)) && Date() < childDeadline { usleep(100_000) }
        guard !Self.isAlive(state.bridgePID), !Self.isAlive(state.childPID) else {
            throw MeterError.message("官方认证进程尚未结束，切换已停止。")
        }
        try? FileManager.default.removeItem(atPath: session.statePath)
    }
    private func launch(_ account: Account, appURL: URL) throws -> DesktopSession {
        guard let bundle = Bundle(url: appURL), let executable = bundle.executableURL else { throw MeterError.message("官方桌面应用包不完整。") }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        // Internal desktop integration is version-gated rather than silently assuming future compatibility.
        guard version == "26.908.40834" else {
            throw MeterError.message("官方桌面端版本 \(version) 尚未验证。此预览版支持 26.908.40834，可先仅切换 CLI。")
        }
        let bridge = try Self.bridgeExecutable()
        let bundledCLI = appURL.appendingPathComponent("Contents/Resources/codex")
        guard FileManager.default.isExecutableFile(atPath: bundledCLI.path) else { throw MeterError.message("官方桌面包中没有 Codex 可执行文件。") }
        let stateDirectory = store.root.appendingPathComponent("desktop", isDirectory: true)
        try Store.privateDirectory(stateDirectory)
        let uiDirectory = stateDirectory.appendingPathComponent("ui", isDirectory: true)
        try Store.privateDirectory(uiDirectory)
        let nonce = UUID().uuidString.lowercased()
        let stateURL = stateDirectory.appendingPathComponent("\(nonce).json")
        var environment = CodexEnvironment.clean(profile: account.profilePath)
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = uiDirectory.path
        environment["CODEX_CLI_PATH"] = bridge.path
        environment["CODEX_APP_SERVER_FORCE_CLI"] = "1"
        environment["AGENT_METER_REAL_CODEX"] = bundledCLI.path
        environment["AGENT_METER_EXPECTED_EMAIL"] = account.email
        environment["AGENT_METER_SESSION"] = nonce
        environment["AGENT_METER_STATE_PATH"] = stateURL.path
        let process = Process()
        process.executableURL = executable; process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        return DesktopSession(accountID: account.id, processID: process.processIdentifier, nonce: nonce,
                              statePath: stateURL.path, appPath: appURL.path, startedAt: Date())
    }
    private func verify(_ session: DesktopSession) throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            try cancellation.check()
            guard Self.isAlive(session.processID) else { throw MeterError.message("官方桌面端启动后提前退出。") }
            if Self.isVerified(session) {
                // Do not accept a fleeting read immediately followed by account/updated.
                usleep(400_000)
                if Self.isVerified(session) { return }
            }
            usleep(100_000)
        }
        throw MeterError.message("桌面端未在 30 秒内确认目标身份；CLI 默认账号未提交更改。")
    }
    public func switchAccount(_ name: String) throws {
        try store.locked {
            var registry = try store.read()
            let account = try registry.account(name)
            let appURL = try Self.application()
            _ = try Self.bridgeExecutable()
            // Check version before closing a working desktop instance.
            guard Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String == "26.908.40834" else {
                throw MeterError.message("当前官方桌面版本未通过此预览版的兼容性验证，可先仅切换 CLI。")
            }
            try AccountService(store: store, cancellation: cancellation).validate(account)
            let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter {
                !$0.isTerminated && $0.processIdentifier != registry.desktop?.processID
            }
            guard otherApps.isEmpty else {
                throw MeterError.message("官方桌面端由其他入口启动，无法确认其任务状态。请先手动退出，再点击切换；后续由本软件启动的桌面端可直接切换。")
            }
            let previous = registry.desktop
            let previousAccount = registry.accounts.first { $0.id == previous?.accountID }
            if let previous, previous.accountID == account.id, Self.isVerified(previous) {
                registry.selectedID = account.id; try store.write(registry)
                NSRunningApplication(processIdentifier: previous.processID)?.activate()
                return
            }
            if let previous { try quit(previous) }
            registry.desktop = nil
            try store.write(registry)
            try cancellation.check()
            do {
                let session = try launch(account, appURL: appURL)
                registry.desktop = session
                try store.write(registry)
                try verify(session)
                registry.selectedID = account.id
                try store.write(registry)
            } catch {
                let originalError = error.localizedDescription
                if let failed = registry.desktop, Self.isAlive(failed.processID) {
                    // Only request a graceful exit. If it refuses, keep its exact session record.
                    do { try quit(failed); registry.desktop = nil }
                    catch { try? store.write(registry); throw MeterError.message("\(originalError) 新桌面端未能安全退出，请手动处理；账号状态未标为切换成功。") }
                } else { registry.desktop = nil }
                if let previousAccount, !cancellation.isCancelled {
                    do {
                        let restored = try launch(previousAccount, appURL: appURL)
                        registry.desktop = restored; try store.write(registry)
                        try verify(restored)
                        try store.write(registry)
                        throw MeterError.message("\(originalError) 已恢复之前的桌面账号。")
                    } catch {
                        try? store.write(registry)
                        if let session = registry.desktop, Self.isVerified(session) {
                            throw MeterError.message("\(originalError) 已恢复之前的桌面账号。")
                        }
                    }
                }
                try? store.write(registry)
                throw MeterError.message("\(originalError) 切换未完成，请重试。")
            }
        }
    }
    public func stop() throws {
        try store.locked {
            var registry = try store.read()
            if let session = registry.desktop { try quit(session); registry.desktop = nil; try store.write(registry) }
        }
    }
}
