import Foundation
import Darwin

/// A bounded, synchronous stdio client. Call it from a worker, never the UI thread.
public final class RPCClient {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var pending = Data()
    private var sequence = 0
    private var notifications: [[String: Any]] = []
    private let cancellation: Cancellation
    private var stopped = false
    public init(profile: String, cancellation: Cancellation = Cancellation(), executable: URL? = nil) throws {
        self.cancellation = cancellation
        process.executableURL = try executable ?? CodexEnvironment.executable()
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = CodexEnvironment.clean(profile: profile)
        process.currentDirectoryURL = URL(fileURLWithPath: profile, isDirectory: true)
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The parent only owns the write end of stdin and read end of stdout.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let fd = output.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        do {
            _ = try request("initialize", params: ["clientInfo": ["name": "agent_meter", "title": "Agent Relay", "version": "0.3.1"]])
            try send(["method": "initialized"])
        } catch { stop(); throw error }
    }
    deinit { stop() }
    public func stop() {
        guard !stopped else { return }; stopped = true
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        let finalDeadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < finalDeadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? output.fileHandleForReading.close()
        pending.removeAll(); notifications.removeAll()
    }
    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    private func next(deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            try cancellation.check()
            if let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let value = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw MeterError.message("官方客户端返回了无效响应。")
                }
                return value
            }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&fd, 1, 100)
            if result < 0 { if errno == EINTR { continue }; throw MeterError.message("读取官方客户端失败。") }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16384)
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            if count > 0 {
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 1_048_576 else { throw MeterError.message("官方客户端响应超出大小限制。") }
            } else if count == 0 { throw MeterError.message("官方客户端提前退出。") }
            else if errno != EAGAIN && errno != EINTR { throw MeterError.message("读取官方客户端失败。") }
        }
        throw MeterError.message("官方客户端响应超时，请检查网络后重试。")
    }
    public func request(_ method: String, params: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> [String: Any] {
        sequence += 1
        let id = sequence
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let value = try next(deadline: deadline)
            if let responseID = value["id"] as? Int, responseID == id {
                if let error = value["error"] as? [String: Any] {
                    // Avoid persisting raw provider errors, which can contain private context.
                    let code = error["code"] as? Int ?? -1
                    throw MeterError.message("官方客户端请求失败（\(method)，代码 \(code)）。可重新登录后重试。")
                }
                guard let result = value["result"] as? [String: Any] else { throw MeterError.message("官方客户端未返回有效结果。") }
                return result
            }
            if value["method"] != nil {
                notifications.append(value)
                if notifications.count > 32 { notifications.removeFirst() }
            }
        }
    }
    public func waitForLogin(_ loginID: String, timeout: TimeInterval = 300) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancellation.check()
            let value = notifications.isEmpty ? try next(deadline: deadline) : notifications.removeFirst()
            guard value["method"] as? String == "account/login/completed",
                  let params = value["params"] as? [String: Any], params["loginId"] as? String == loginID else { continue }
            guard params["success"] as? Bool == true else { throw MeterError.message("官方登录未完成，请重新尝试。") }
            return
        }
        throw MeterError.message("登录已超时，请重新添加账号。")
    }
}
