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

        // The deadline runs independently of the process callbacks.
        let deadline = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if state.fail(ProcessTimeoutError(seconds: timeout)) { stop(process) }
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                guard state.install(continuation, onFinish: {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                }) else { return }
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
                    state.fail(error)
                    return
                }
                if let input {
                    let writer = stdin.fileHandleForWriting
                    DispatchQueue.global(qos: .utility).async {
                        try? writer.write(contentsOf: input)
                        try? writer.close()
                    }
                }
            }
        } onCancel: {
            if state.fail(CancellationError()) { stop(process) }
        }
    }

    /// Asks the process to exit and kills it if it ignores the request.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data(), stderr = Data()
    private var stdoutClosed = false, stderrClosed = false
    private var status: Int32?
    private var finished = false
    private var pendingError: Error?
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var onFinish: (() -> Void)?

    /// Returns false when the run already failed (timed out or cancelled) before starting.
    func install(_ continuation: CheckedContinuation<ProcessOutput, Error>, onFinish: @escaping () -> Void) -> Bool {
        lock.lock()
        if let pendingError {
            finished = true
            lock.unlock()
            continuation.resume(throwing: pendingError)
            return false
        }
        self.continuation = continuation
        self.onFinish = onFinish
        lock.unlock()
        return true
    }

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
        lock.lock()
        if continuation == nil && !finished && pendingError == nil {
            // Not started yet: fail as soon as the continuation is installed.
            pendingError = error
            lock.unlock()
            return true
        }
        lock.unlock()
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
