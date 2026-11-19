import Foundation
@main struct Probe {
    static func main() throws {
        do {
            let lease = try DesktopInstanceLease.acquire(root: URL(fileURLWithPath: CommandLine.arguments[1]))
            print("acquired"); fflush(stdout)
            _ = readLine()
            withExtendedLifetime(lease) {}
        } catch { print("refused"); fflush(stdout) }
    }
}
