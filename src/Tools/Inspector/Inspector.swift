import Foundation
import Darwin

@main
struct Inspector {
    static func main() throws {
        let args = CommandLine.arguments
        func option(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if args.contains("--help") {
            print("Usage: run.sh [--join-file invitation.txt] [--input commands.jsonl]\nJSON lines on stdin/stdout; logs on stderr. EOF stops the inspector and retains membership.")
            return
        }
        guard let rootPath = option("--root"), let erlPath = option("--erl") else {
            fputs("Use src/Tools/Inspector/run.sh.\n", stderr); exit(2)
        }
        let root = URL(fileURLWithPath: rootPath)
        let native = root.appendingPathComponent("builds/Inspector/runtime/native_lib")
        let control = root.appendingPathComponent("builds/intermediates/control/default/lib")
        guard FileManager.default.fileExists(atPath: native.path) else {
            fputs("Build the inspector first (src/Tools/Inspector/build.sh).\n", stderr); exit(2)
        }
        let identity = try NativeIdentity.loadInspector()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: erlPath)
        let libraries = try [control, native].flatMap {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
                .map { $0.appendingPathComponent("ebin").path }
        }
        process.arguments = ["-noshell", "-pa"] + libraries + [
            "-start_epmd", "false", "-proto_dist", "ba_webrtc",
            "-kernel", "connect_all", "false", "dist_auto_connect", "never", "logger_level", "warning",
            "-s", "ba_inspector", "boot"
        ]
        var env = ProcessInfo.processInfo.environment
        env["BA_IDENTITY_SEED"] = identity.seedHex
        env["BA_STATE_DIR"] = identity.stateDirectory.path
        env["ERL_CRASH_DUMP"] = identity.stateDirectory.appendingPathComponent("erl_crash.dump").path
        if let file = option("--join-file") { env["BA_INSPECTOR_JOIN_FILE"] = file }
        else { env.removeValue(forKey: "BA_INSPECTOR_JOIN_FILE") }
        process.environment = env
        let inputPipe = Pipe()
        if let input = option("--input") { process.standardInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: input)) }
        else { process.standardInput = inputPipe }
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        if option("--input") == nil {
            // Process creates a separate process group on macOS. Read the
            // foreground terminal here; the BEAM child receives a normal pipe.
            DispatchQueue.global().async {
                while true {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    do { try inputPipe.fileHandleForWriting.write(contentsOf: Data(buffer.prefix(count))) }
                    catch { break }
                }
                try? inputPipe.fileHandleForWriting.close()
            }
        }
        let signals = [SIGINT,SIGTERM].map { number -> DispatchSourceSignal in
            signal(number,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { if process.isRunning { process.terminate() } }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() } }
        process.waitUntilExit()
        exit(process.terminationStatus)
    }
}
