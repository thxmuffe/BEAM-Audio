import Foundation
@main struct Probe {
    static func main() throws {
        let lease = try DesktopInstanceLease.acquire(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(lease.slot); fflush(stdout)
        _ = readLine()
        withExtendedLifetime(lease) {}
    }
}
