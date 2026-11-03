import XCTest
import Darwin
@testable import ParviKit

final class SnapshotReaderTests: XCTestCase {
    func testFragmentedPipeSnapshots() async throws {
        let pipe = Pipe()
        try await checkReader(pipe.fileHandleForReading, writer: pipe.fileHandleForWriting)
    }

    func testFragmentedSocketSnapshots() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        try await checkReader(FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
                              writer: FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
    }

    @MainActor
    private func checkReader(_ input: FileHandle, writer: FileHandle) async throws {
        defer { try? input.close(); try? writer.close() }
        let received = expectation(description: "Both snapshots arrive before EOF")
        received.expectedFulfillmentCount = 2
        let finished = expectation(description: "Reader exits at EOF")
        var nodes: [String] = []
        let reader = Task {
            do {
                try await ChatSnapshot.read(from: input) { snapshot in
                    XCTAssertTrue(Thread.isMainThread)
                    nodes.append(snapshot.node)
                    received.fulfill()
                }
            } catch { XCTFail("Read failed: \(error)") }
            finished.fulfill()
        }
        defer { reader.cancel() }
        let name = "🐦\u{2028}Music"
        let message = Data("{\"node\":\"\(name)\",\"peers\":[],\"messages\":[]}\n".utf8)
        let bird = message.range(of: Data("🐦".utf8))!.lowerBound
        // Split inside a multibyte character, then combine two frames in one write.
        try writer.write(contentsOf: message.prefix(bird + 1))
        try await Task.sleep(nanoseconds: 20_000_000)
        try writer.write(contentsOf: message.dropFirst(bird + 1) + Data("not JSON\n".utf8) + message)
        await fulfillment(of: [received], timeout: 3)
        XCTAssertEqual(nodes, [name, name])
        try writer.write(contentsOf: Data("{\"node\":\"unfinished".utf8))
        try writer.close()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(nodes, [name, name])
    }

    @MainActor
    func testCancellationStopsSnapshotDelivery() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let received = expectation(description: "Initial snapshot")
        let finished = expectation(description: "Cancelled reader exits")
        var count = 0
        let reader = Task {
            do {
                try await ChatSnapshot.read(from: pipe.fileHandleForReading) { _ in
                    count += 1
                    received.fulfill()
                }
            } catch is CancellationError {
                // A cancelled reader must not deliver buffered or subsequent snapshots.
            } catch { XCTFail("Unexpected read failure: \(error)") }
            finished.fulfill()
        }
        defer { reader.cancel() }
        let message = Data("{\"node\":\"test\",\"peers\":[],\"messages\":[]}\n".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: message)
        await fulfillment(of: [received], timeout: 3)
        reader.cancel()
        try pipe.fileHandleForWriting.write(contentsOf: message)
        try pipe.fileHandleForWriting.close()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSocketShutdownEndsAnIdleReader() async throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let input = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        defer { try? input.close(); try? writer.close() }
        let finished = expectation(description: "Idle socket reader exits while peer stays open")
        let reader = Task {
            do { try await ChatSnapshot.read(from: input) { _ in XCTFail("Unexpected snapshot") } }
            catch is CancellationError {} catch { XCTFail("Unexpected failure: \(error)") }
            finished.fulfill()
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        reader.cancel()
        XCTAssertEqual(shutdown(input.fileDescriptor, SHUT_RDWR), 0)
        await fulfillment(of: [finished], timeout: 3)
    }
}
