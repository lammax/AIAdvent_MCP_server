import Darwin
import Foundation

/// Owns only a process identifier across isolation boundaries. `Process` itself never
/// leaves the task that created it.
actor RemoteProcessCancellation {
    private var processID: pid_t?
    private var cancellationRequested = false

    func register(processID: pid_t) {
        self.processID = processID
        if cancellationRequested { interrupt(processID) }
    }

    func unregister(processID: pid_t) {
        if self.processID == processID { self.processID = nil }
    }

    func cancel() {
        cancellationRequested = true
        guard let processID else { return }
        interrupt(processID)
    }

    private func interrupt(_ processID: pid_t) {
        kill(processID, SIGINT)
        Task { @concurrent [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.forceKillIfCurrent(processID)
        }
    }

    private func forceKillIfCurrent(_ processID: pid_t) {
        guard self.processID == processID else { return }
        kill(processID, SIGKILL)
    }
}
