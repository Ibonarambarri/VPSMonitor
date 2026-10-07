import Foundation

struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var standardOutput: String { String(decoding: stdout, as: UTF8.self) }
    var standardError: String { String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct ProcessTimeoutError: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "El comando no respondió en \(Int(seconds)) s." }
}

/// Runs a process without blocking on full pipes and with a hard timeout, so a hung
/// remote command can never freeze periodic refreshes.
enum ProcessRunner {
    static func run(executable: String, arguments: [String], input: Data? = nil, timeout: TimeInterval) async throws -> ProcessOutput {
        let state = RunState()
        let process = Process()
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                state.continuation = continuation
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    state.append(handle.availableData, toStandardError: false)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    state.append(handle.availableData, toStandardError: true)
                }
                process.terminationHandler = { process in
                    state.terminated(status: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    state.fail(error)
                    return
                }
                state.onFinish = {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                }
                if let input {
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .utility).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if state.fail(ProcessTimeoutError(seconds: timeout)), process.isRunning { process.terminate() }
                }
            }
        } onCancel: {
            if state.fail(CancellationError()), process.isRunning { process.terminate() }
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var stdoutClosed = false, stderrClosed = false
    private var status: Int32?
    private var finished = false
    var continuation: CheckedContinuation<ProcessOutput, Error>?
    var onFinish: (() -> Void)?

    func append(_ data: Data, toStandardError: Bool) {
        lock.lock()
        if data.isEmpty {
            if toStandardError { stderrClosed = true } else { stdoutClosed = true }
        } else if toStandardError {
            stderr.append(data)
        } else {
            stdout.append(data)
        }
        let ready = status != nil && stdoutClosed && stderrClosed
        lock.unlock()
        if ready { complete() }
    }

    func terminated(status: Int32) {
        lock.lock()
        self.status = status
        let ready = stdoutClosed && stderrClosed
        lock.unlock()
        if ready {
            complete()
        } else {
            // A detached child (such as an SSH ControlMaster) may keep a pipe open; don't wait for it.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { self.complete() }
        }
    }

    @discardableResult
    func fail(_ error: Error) -> Bool {
        guard let continuation = take() else { return false }
        continuation.resume(throwing: error)
        return true
    }

    private func complete() {
        lock.lock()
        let output = status.map { ProcessOutput(status: $0, stdout: stdout, stderr: stderr) }
        lock.unlock()
        guard let output, let continuation = take() else { return }
        continuation.resume(returning: output)
    }

    private func take() -> CheckedContinuation<ProcessOutput, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let continuation else { return nil }
        finished = true
        self.continuation = nil
        let onFinish = onFinish
        DispatchQueue.global().async { onFinish?() }
        return continuation
    }
}
