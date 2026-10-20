import AppKit

// 검증용 probe 모드: UI 없이 측정값만 출력하고 종료한다.
let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--probe-system") {
    let count = arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) ?? 3 : 3
    Probe.runSystem(count: count)
    exit(0)
}
if arguments.contains("--probe-procs") {
    Probe.runProcesses()
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
