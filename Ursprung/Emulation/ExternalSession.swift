// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// A standalone emulator running as its own process (docs/STANDALONE_PLAN.md).
///
/// Quitting sends SIGTERM once: ARMSX2 then writes its resume state, waits for
/// pending saves and exits. A second SIGTERM would make it exit at once
/// without saving, so the escalation is SIGKILL after a grace period.
final class ExternalSession {
    nonisolated struct Exit: Equatable, Sendable {
        let status: Int32
        /// Ended by a signal (a crash or SIGKILL) rather than by exiting.
        let wasSignaled: Bool
        /// Ursprung asked the process to quit.
        let wasRequested: Bool

        var isClean: Bool { !wasSignaled && status == 0 }
    }

    static let gracePeriod: Duration = .seconds(10)

    private(set) var exit: Exit?
    /// Called once when the process has ended, after `stop` callers resumed.
    var onExit: ((Exit) -> Void)?

    private let process = Process()
    private var isStopRequested = false
    private var waiters: [CheckedContinuation<Exit, Never>] = []

    /// Starts `executable`. Its output goes to `output` (replaced), or nowhere.
    init(executable: URL, arguments: [String], environment: [String: String], output: URL? = nil) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let outputHandle = output.flatMap { url -> FileHandle? in
            FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
            return try? FileHandle(forWritingTo: url)
        }
        defer { try? outputHandle?.close() }
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        process.standardError = outputHandle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            let wasSignaled = ended.terminationReason == .uncaughtSignal
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.didExit(status: status, wasSignaled: wasSignaled) }
            }
        }
        try process.run()
    }

    var processIdentifier: pid_t { process.processIdentifier }

    var isRunning: Bool { exit == nil }

    /// Asks the process to quit and waits until it has; SIGKILL follows
    /// after `gracePeriod`.
    @discardableResult
    func stop(gracePeriod: Duration = ExternalSession.gracePeriod) async -> Exit {
        if let exit { return exit }
        if !isStopRequested {
            isStopRequested = true
            kill(processIdentifier, SIGTERM)
            Task { [weak self] in
                try? await Task.sleep(for: gracePeriod)
                guard let self, self.exit == nil else { return }
                kill(self.processIdentifier, SIGKILL)
            }
        }
        return await waitForExit()
    }

    func waitForExit() async -> Exit {
        if let exit { return exit }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Stops the process while Ursprung quits: the main thread is blocked, so
    /// this polls instead of waiting for the termination handler. Nil when
    /// the process had already ended unnoticed.
    @discardableResult
    func stopAndWait(gracePeriod: TimeInterval = 10) -> Exit? {
        if let exit { return exit }
        guard process.isRunning else { return nil }
        if !isStopRequested {
            isStopRequested = true
            kill(processIdentifier, SIGTERM)
        }
        let deadline = Date.now.addingTimeInterval(gracePeriod)
        while process.isRunning, Date.now < deadline { usleep(50_000) }
        if process.isRunning {
            kill(processIdentifier, SIGKILL)
            while process.isRunning { usleep(10_000) }
        }
        return Exit(status: process.terminationStatus, wasSignaled: process.terminationReason == .uncaughtSignal,
                    wasRequested: true)
    }

    /// Brings the emulator's window to the front.
    func activate() {
        NSRunningApplication(processIdentifier: processIdentifier)?.activate()
    }

    private func didExit(status: Int32, wasSignaled: Bool) {
        guard exit == nil else { return }
        let exit = Exit(status: status, wasSignaled: wasSignaled, wasRequested: isStopRequested)
        self.exit = exit
        let waiters = waiters
        self.waiters = []
        for waiter in waiters { waiter.resume(returning: exit) }
        onExit?(exit)
    }
}
