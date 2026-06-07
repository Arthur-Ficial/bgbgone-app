import Foundation
import os

/// Production `BgBgOneRunning` — spawns the resolved binary as a `Process`, reads the
/// single JSON line on stdout, captures the stderr tail for error messaging.
///
/// One Process per call. Concurrency is enforced by `QueueRunner`, not this type.
struct BgBgOneRunner: BgBgOneRunning {
    let binary: URL
    let timeout: Duration
    /// Optional env to *add* on top of the inherited parent environment. Used by tests
    /// to drive the process-behavior harness (exit code / stderr / delay) deterministically
    /// without setenv races.
    let extraEnvironment: [String: String]
    private let logger: Logger

    init(binary: URL, timeout: Duration = .seconds(60), extraEnvironment: [String: String] = [:]) {
        self.binary = binary
        self.timeout = timeout
        self.extraEnvironment = extraEnvironment
        self.logger = Logger(subsystem: BuildInfo.osLogSubsystem, category: "runner")
    }

    func run(arguments: [String]) async throws -> RunResult {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw RunnerError.binaryNotExecutable(binary)
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.qualityOfService = .userInitiated
        if !extraEnvironment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnvironment { env[k] = v }
            process.environment = env
        }

        let cmdLine = "\(binary.path) \(arguments.joined(separator: " "))"
        logger.debug("spawn: \(cmdLine, privacy: .public)")
        Task { @MainActor in DebugLog.shared.append(category: "spawn", message: cmdLine) }

        let clock = ContinuousClock()
        let start = clock.now

        // Set the instant cancellation is requested. The terminationHandler honors it
        // regardless of how the (just-terminated) process happened to exit — a cancelled
        // run must surface `.cancelled`, never a stale result or `malformedJSON` parsed
        // from whatever the dying process left on stdout.
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RunResult, Error>) in
                process.terminationHandler = { proc in
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: RunnerError.cancelled)
                        return
                    }
                    let elapsed = clock.now - start
                    let stdoutData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
                    let stderrTail = Self.tail(of: stderrData, lines: 8)

                    self.logger.debug("exit: \(proc.terminationStatus) stderr: \(stderrTail, privacy: .public)")
                    let exitCode = proc.terminationStatus
                    Task { @MainActor in
                        DebugLog.shared.append(category: "exit", message: "code=\(exitCode) stderr=\(stderrTail)")
                    }

                    switch proc.terminationStatus {
                    case 0:
                        guard let jsonLine = Self.lastJSONLine(in: stdoutData) else {
                            continuation.resume(throwing: RunnerError.malformedJSON)
                            return
                        }
                        do {
                            let decoded = try JSONDecoder().decode(RunResult.self, from: jsonLine)
                            continuation.resume(returning: decoded.withDuration(millis: Self.millis(from: elapsed)))
                        } catch {
                            continuation.resume(throwing: RunnerError.malformedJSON)
                        }
                    case 1:
                        continuation.resume(throwing: RunnerError.userError(stderrTail: stderrTail))
                    case 2:
                        continuation.resume(throwing: RunnerError.noSubject)
                    case 3:
                        continuation.resume(throwing: RunnerError.framework(stderrTail: stderrTail))
                    default:
                        // SIGTERM (15) from cancellation surfaces as 143; anything else is framework.
                        if proc.terminationStatus == 143 || proc.terminationReason == .uncaughtSignal {
                            continuation.resume(throwing: RunnerError.cancelled)
                        } else {
                            continuation.resume(throwing: RunnerError.framework(stderrTail: stderrTail))
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: RunnerError.framework(stderrTail: error.localizedDescription))
                }
            }
        } onCancel: {
            // Cooperatively terminate. The flag makes the handler report `.cancelled`
            // regardless of the resulting exit code (avoids a cancel/exit race).
            cancelled.withLock { $0 = true }
            if process.isRunning {
                process.terminate()
            }
        }
    }

    /// Find the last JSON object in stdout. bgbgone normally emits a single line but
    /// could in theory print log noise before it on misconfigured installs.
    private static func lastJSONLine(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let lastObjectLine = text
            .split(whereSeparator: \.isNewline)
            .reversed()
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") })
        return lastObjectLine.flatMap { String($0).data(using: .utf8) }
    }

    private static func tail(of data: Data, lines: Int) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let split = text.split(whereSeparator: \.isNewline)
        return split.suffix(lines).joined(separator: "\n")
    }

    /// `Duration` → integer milliseconds. `Duration.components` is `(seconds, attoseconds)`.
    private static func millis(from duration: Duration) -> Int {
        let comps = duration.components
        return Int(comps.seconds) * 1000 + Int(comps.attoseconds / 1_000_000_000_000_000)
    }
}
