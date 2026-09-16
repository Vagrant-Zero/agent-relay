import Foundation
import AppKit
import AgentMeterCore
import Darwin

let cancellation = Cancellation()
signal(SIGPIPE, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
interrupt.setEventHandler { cancellation.cancel() }; interrupt.resume()
termination.setEventHandler { cancellation.cancel() }; termination.resume()

let help = """
Agent Relay 0.2.4

  agent-relay accounts [--json]                 列出账号与缓存额度
  agent-relay login <别名> [--no-open]           在官方网页添加账号
  agent-relay import <别名> --profile <目录>    引用已有 Codex 登录目录
  agent-relay quota [别名] [--cached] [--json]  查询一个或所有账号额度
  agent-relay switch <别名> [--cli-only]        切换 CLI 默认账号和官方桌面端
  agent-relay run [codex] [--account <别名>] [-- <Codex 参数>]
  agent-relay sessions [--json] [--source <目录>]  列出各账号的本地会话
  agent-relay resume [--account <别名>] [ID | --last] [--all]
  agent-relay status [--json]                  查看默认账号与桌面实际状态
  agent-relay desktop stop                    正常退出本软件启动的桌面端
  agent-relay remove <别名>                    移除登记，保留凭据与历史
  agent-relay doctor [--json]                  检查本机环境

默认切换会启动/重启官方桌面端并验证身份。已有 CLI 会话不受影响。
普通 codex 命令不受本软件接管；使用 agent-relay run 启动所选账号。
AGENT_METER_HOME 可指定独立的数据目录。
"""

func output<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value)); print("")
}
func message(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
func render(_ account: Account, selected: Bool = false) {
    print("\(selected ? "●" : "○") \(account.alias)  \(account.email)  \(account.plan.capitalized)")
    if let quota = account.quota {
        for window in [quota.primary, quota.secondary].compactMap({ $0 }) {
            print("  \(window.label)剩余 \(window.remainingPercent)% · \(Format.reset(window.resetsAt)) 重置")
        }
        print("  重置卡 \(quota.resetCards.map(String.init) ?? "未知") · \(Format.updated(quota.fetchedAt))\(quota.isStale ? "（缓存已过期）" : "")")
    } else { print("  尚无额度数据") }
    if let error = account.lastError { print("  \(error)") }
}
func option(_ key: String, in args: inout [String]) throws -> String? {
    guard let index = args.firstIndex(of: key) else { return nil }
    guard index + 1 < args.count else { throw MeterError.message("\(key) 缺少参数。") }
    let value = args.remove(at: index + 1); args.remove(at: index); return value
}
func flag(_ key: String, in args: inout [String]) -> Bool {
    guard let index = args.firstIndex(of: key) else { return false }; args.remove(at: index); return true
}
func exactly(_ count: Int, _ args: [String]) throws {
    guard args.count == count else { throw MeterError.message("参数不正确，使用 agent-relay --help 查看用法。") }
}

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? "help" : args.removeFirst()
let json = command == "run" ? false : flag("--json", in: &args)

func resumeArguments(_ original: [String], store: Store, profile: String, additional: [String]) throws -> [String] {
    guard original.first == "resume", !original.contains("--help"), !original.contains("-h") else { return original }
    // Remote sessions belong to the remote server and are not local history.
    if original.contains(where: { $0 == "--remote" || $0.hasPrefix("--remote=") }) { return original }
    var forwarded = Array(original.dropFirst())
    let last = flag("--last", in: &forwarded)
    let all = flag("--all", in: &forwarded)
    var workingDirectory = FileManager.default.currentDirectoryPath
    let valueOptions: Set<String> = ["-c", "--config", "--enable", "--disable", "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval", "--remote-auth-token-env"]
    var positional: Int?
    var index = 0
    while index < forwarded.count {
        let item = forwarded[index]
        if item == "--" { positional = index + 1 < forwarded.count ? index + 1 : nil; break }
        if valueOptions.contains(item) {
            guard index + 1 < forwarded.count else { throw MeterError.message("\(item) 缺少参数。") }
            if item == "-C" || item == "--cd" { workingDirectory = forwarded[index + 1] }
            if (item == "-c" || item == "--config"), forwarded[index + 1].hasPrefix("sqlite_home") {
                throw MeterError.message("恢复入口会自动选择会话数据库，请移除 sqlite_home 覆盖。")
            }
            index += 2; continue
        }
        if item.hasPrefix("--cd=") { workingDirectory = String(item.dropFirst(5)) }
        if !item.hasPrefix("-") { positional = index; break }
        index += 1
    }
    let scan = LocalSessions.scan(roots: try LocalSessions.roots(store: store, additional: additional + [profile]))
    scan.warnings.forEach { message("部分会话暂时不可读：\($0)") }
    if last && !scan.warnings.isEmpty { throw MeterError.message("部分会话目录暂时不可读，无法可靠判断最近会话。请稍后重试，或直接指定会话 ID。") }
    var sessions = scan.sessions
    let chosen: LocalSession
    if let position = positional, !last {
        let key = forwarded.remove(at: position)
        let matches = sessions.filter { $0.id == key || $0.title == key }
        if matches.isEmpty && !scan.failedRoots.isEmpty {
            throw MeterError.message("部分会话索引暂时不可读，无法确认会话是否存在：\(key)。请稍后重试。")
        }
        guard matches.count == 1, let session = matches.first else { throw MeterError.message("会话不存在或名称不唯一：\(key)。使用 agent-relay sessions 查看 ID。") }
        chosen = session
    } else {
        if !all {
            let cwd = URL(fileURLWithPath: workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path
            sessions = sessions.filter { URL(fileURLWithPath: $0.cwd).standardizedFileURL.resolvingSymlinksInPath().path == cwd }
        }
        if !forwarded.contains("--include-non-interactive") { sessions = sessions.filter { $0.source == "cli" || $0.source == "vscode" } }
        guard !sessions.isEmpty else { throw MeterError.message("没有匹配的本地会话。使用 resume --all 查看其他目录的会话。") }
        if last { chosen = sessions[0] }
        else {
            guard isatty(STDIN_FILENO) != 0 else { throw MeterError.message("请在终端选择会话，或指定会话 ID / --last。") }
            signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL)
            for (i, session) in sessions.enumerated() {
                let title = session.title.components(separatedBy: .controlCharacters).joined(separator: " ")
                print("\(i + 1). \(title.prefix(100))\n   \(session.cwd) · \(session.id)")
            }
            print("选择要恢复的会话（输入序号，回车取消）：", terminator: " "); fflush(stdout)
            guard let line = readLine(), let number = Int(line), sessions.indices.contains(number - 1) else { throw MeterError.message("已取消恢复。") }
            chosen = sessions[number - 1]
        }
    }
    return try chosen.resumeArguments(extra: forwarded)
}
do {
    if ["help", "--help", "-h"].contains(command) { print(help); exit(0) }
    if ["--version", "version"].contains(command) { print("0.2.4"); exit(0) }
    let store = try Store()
    let service = AccountService(store: store, cancellation: cancellation)
    switch command {
    case "accounts", "list":
        try exactly(0, args)
        let registry = try store.read()
        if json { try output(registry) }
        else if registry.accounts.isEmpty { print("尚无账号。使用 agent-relay login <别名> 添加。") }
        else { registry.accounts.forEach { render($0, selected: registry.selectedID == $0.id) } }
    case "login":
        let noOpen = flag("--no-open", in: &args)
        try exactly(1, args)
        let account = try service.login(alias: args[0]) { url in
            if noOpen { message(url.absoluteString) }
            else {
                let opener = Process(); opener.executableURL = URL(fileURLWithPath: "/usr/bin/open"); opener.arguments = [url.absoluteString]
                try opener.run(); opener.waitUntilExit()
                guard opener.terminationStatus == 0 else { throw MeterError.message("无法打开系统浏览器。请使用 --no-open 重试。") }
                message("请在浏览器完成官方登录。Ctrl+C 可取消，5 分钟后自动超时。")
            }
        }
        if json { try output(account) } else { print("已添加 \(account.alias)"); render(account) }
    case "import":
        guard let path = try option("--profile", in: &args) else { throw MeterError.message("请使用 --profile 指定已有登录目录。") }
        try exactly(1, args)
        let account = try service.importProfile(alias: args[0], path: path)
        if json { try output(account) } else { print("已添加 \(account.alias)，使用原目录中的最新凭据。"); render(account) }
    case "quota", "refresh":
        let cached = flag("--cached", in: &args)
        _ = flag("--all", in: &args)
        guard args.count <= 1 else { throw MeterError.message("一次指定一个别名，或省略别名查询所有账号。") }
        let accounts: [Account]
        if cached {
            let registry = try store.read()
            accounts = try args.first.map { [try registry.account($0)] } ?? registry.accounts
        } else { accounts = try service.refresh(args.first) }
        if json { try output(accounts) } else { accounts.forEach { render($0) } }
        if !cached && accounts.contains(where: { $0.lastError != nil }) { exit(2) }
    case "switch":
        let cliOnly = flag("--cli-only", in: &args)
        try exactly(1, args)
        if cliOnly { try service.selectCLI(args[0]) }
        else { try DesktopController(store: store, cancellation: cancellation).switchAccount(args[0]) }
        if json { try output(try store.read()) }
        else { print(cliOnly ? "CLI 默认账号已切换为 \(args[0])。" : "桌面端身份已验证，CLI 默认账号已切换为 \(args[0])。") }
    case "status":
        try exactly(0, args)
        let registry = try store.read()
        let verified = registry.desktop.map { DesktopController.isVerified($0) } ?? false
        let running = registry.desktop.map { DesktopController.isAlive($0.processID) } ?? false
        if json {
            struct Status: Encodable { let selected: String?; let desktopAccount: String?; let desktopRunning: Bool; let desktopVerified: Bool; let activeTurns: Int? }
            try output(Status(selected: registry.selected?.alias,
                              desktopAccount: registry.accounts.first { $0.id == registry.desktop?.accountID }?.alias,
                              desktopRunning: running, desktopVerified: verified,
                              activeTurns: registry.desktop.flatMap { DesktopController.state($0)?.activeTurns }))
        } else {
            print("CLI 默认：\(registry.selected?.alias ?? "未选择")")
            print("桌面端：\(verified ? "已验证 · " + (registry.accounts.first { $0.id == registry.desktop?.accountID }?.alias ?? "未知") : (running ? "运行中，身份未确认" : "未由本软件运行"))")
        }
    case "desktop":
        guard args == ["stop"] else { throw MeterError.message("用法：agent-relay desktop stop") }
        try DesktopController(store: store, cancellation: cancellation).stop()
        if json { try output(["stopped": true]) } else { print("桌面端已正常退出。") }
    case "remove":
        try exactly(1, args); try service.remove(args[0])
        if json { try output(["removed": true]) } else { print("已移除账号登记，凭据与历史保留在原目录。") }
    case "sessions":
        let source = try option("--source", in: &args)
        try exactly(0, args)
        let scan = LocalSessions.scan(roots: try LocalSessions.roots(store: store, additional: source.map { [$0] } ?? []))
        scan.warnings.forEach { message("部分会话暂时不可读：\($0)") }
        let sessions = scan.sessions
        if json { try output(sessions) }
        else { for session in sessions { print("\(session.id)  \(session.title.components(separatedBy: .controlCharacters).joined(separator: " ").prefix(100))\n  \(session.cwd)") } }
    case "run", "resume":
        let plan = command == "resume" && flag("--plan", in: &args)
        if args.first == "codex" { args.removeFirst() }
        var prefix = Array(args.prefix(while: { $0 != "--" }))
        let requested = try option("--account", in: &prefix)
        let profileOverride = try option("--profile", in: &prefix)
        let source = try option("--source", in: &prefix)
        let forwarded: [String]
        if let separator = args.firstIndex(of: "--") {
            guard prefix.isEmpty else { throw MeterError.message("Codex 参数请放在 -- 之后。") }
            forwarded = Array(args.dropFirst(separator + 1))
        } else { forwarded = prefix }
        let registry = try store.read()
        let profile: String
        guard requested == nil || profileOverride == nil else { throw MeterError.message("账号和 profile 请只指定一个。") }
        if let profileOverride { profile = (profileOverride as NSString).expandingTildeInPath }
        else if let requested { profile = try registry.account(requested).profilePath }
        else if let selected = registry.selected { profile = selected.profilePath }
        else { throw MeterError.message("尚未选择账号，请先添加账号。") }
        let invocation = try resumeArguments(command == "resume" ? ["resume"] + forwarded : forwarded, store: store, profile: profile, additional: source.map { [$0] } ?? [])
        let executable = try CodexEnvironment.executable()
        if plan {
            struct Plan: Encodable { let executable: String; let profile: String; let arguments: [String] }
            try output(Plan(executable: executable.path, profile: profile, arguments: invocation)); break
        }
        for key in ["CODEX_ACCESS_TOKEN", "CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_APP_SERVER_WS_URL", "CODEX_CLI_PATH", "CODEX_ELECTRON_USER_DATA_PATH", "CODEX_APP_SERVER_FORCE_CLI"] { unsetenv(key) }
        unsetenv("ELECTRON_RUN_AS_NODE")
        setenv("CODEX_HOME", profile, 1)
        signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGPIPE, SIG_DFL)
        var pointers = ([executable.path] + invocation).map { strdup($0) }
        pointers.append(nil)
        execv(executable.path, &pointers)
        pointers.forEach { free($0) }
        throw MeterError.message("无法启动官方 Codex CLI。")
    case "doctor":
        try exactly(0, args)
        let executable = try? CodexEnvironment.executable()
        let application = try? DesktopController.application()
        let version = application.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        let result = ["version": "0.2.4", "codex": executable?.path ?? "未安装", "desktop": application?.path ?? "未安装", "desktopVersion": version ?? "未知", "desktopSupported": version == "26.908.40834" ? "yes" : "no", "dataDirectory": store.root.path, "desktopAdapter": (try? DesktopController.bridgeExecutable().path) ?? "缺失"]
        if json { try output(result) } else { for key in result.keys.sorted() { print("\(key): \(result[key]!)") } }
    default: throw MeterError.message("未知命令：\(command)。使用 agent-relay --help 查看用法。")
    }
} catch {
    if json { try? output(["error": error.localizedDescription]) }
    else { message("错误：\(error.localizedDescription)") }
    exit(cancellation.isCancelled ? 130 : 1)
}
