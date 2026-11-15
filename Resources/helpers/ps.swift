// A minimal `ps` for add-on servers running in 23's sandbox. macOS's /bin/ps runs with raised privileges,
// which a sandboxed program may not start; this one reads the process list with sysctl as the user.
// Supports: -ax / -axo / -o with pid, ppid, pgid, uid, stat, sess, command (a trailing "=" means no header).
import Darwin

func allProcs() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    sysctl(&mib, 4, nil, &size, nil, 0)
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    return Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
}

func commandLine(_ pid: pid_t, fallback: String) -> String {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return fallback }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return fallback }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }          // executable path
    while i < size && buf[i] == 0 { i += 1 }
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args.isEmpty ? fallback : args.joined(separator: " ")
}

var fields = ["pid", "command"]
var headers = true
var argv = Array(CommandLine.arguments.dropFirst())
var k = 0
while k < argv.count {
    let a = argv[k]
    if a == "-o" || a.hasSuffix("o") && a.hasPrefix("-") {
        if k + 1 < argv.count {
            let spec = argv[k + 1]
            headers = !spec.contains("=")
            fields = spec.split(separator: ",").map { String($0.filter { $0 != "=" }).lowercased() }
            k += 1
        }
    }
    k += 1
}
if headers { print(fields.map { $0.uppercased() }.joined(separator: " ")) }
for p in allProcs() {
    let pid = p.kp_proc.p_pid
    guard pid > 0 else { continue }
    let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    var out: [String] = []
    for f in fields {
        switch f {
        case "pid": out.append(String(pid))
        case "ppid": out.append(String(p.kp_eproc.e_ppid))
        case "pgid": out.append(String(p.kp_eproc.e_pgid))
        case "uid": out.append(String(p.kp_eproc.e_ucred.cr_uid))
        case "sess": out.append("0")
        case "stat":
            let s: String
            switch Int32(p.kp_proc.p_stat) { case SRUN: s = "R"; case SSTOP: s = "T"; case SZOMB: s = "Z"; case SIDL: s = "I"; default: s = "S" }
            out.append(s)
        case "command", "args": out.append(commandLine(pid, fallback: comm))
        case "comm", "ucomm": out.append(comm)
        default: out.append("-")
        }
    }
    print(out.joined(separator: " "))
}
