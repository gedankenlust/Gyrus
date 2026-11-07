import Foundation

/// Identity of a launched backend: pid plus kernel start time. A pid alone can
/// be recycled by an unrelated process after the backend exits.
struct BackendProcessRecord: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executable: String

    var serialized: String {
        "\(pid)\n\(startSeconds).\(startMicroseconds)\n\(executable)"
    }

    init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, executable: String) {
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executable = executable
    }

    init?(serialized: String) {
        let lines = serialized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3,
              let pid = Int32(lines[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let start = lines[1].split(separator: ".")
        guard start.count == 2,
              let seconds = UInt64(start[0]), let micros = UInt64(start[1]) else { return nil }
        let executable = lines[2...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else { return nil }
        self.init(pid: pid, startSeconds: seconds, startMicroseconds: micros, executable: executable)
    }

    /// Reads the running process's start time and executable from the kernel.
    static func live(pid: Int32) -> BackendProcessRecord? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return BackendProcessRecord(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            executable: String(cString: buffer)
        )
    }

    /// True while the very process this record describes is still running.
    var isAlive: Bool {
        BackendProcessRecord.live(pid: pid) == self
    }
}
