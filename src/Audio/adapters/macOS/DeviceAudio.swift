// OS binding only: execute Erlang-approved host-time output targets.
import Foundation
import AVFAudio
import CoreAudio
import Darwin

func readExactly(_ count: Int) throws -> Data? {
    var data = Data()
    while data.count < count {
        let next = try FileHandle.standardInput.read(upToCount: count - data.count) ?? Data()
        if next.isEmpty { if data.isEmpty { return nil }; throw AudioError.message("Truncated audio command") }
        data.append(next)
    }
    return data
}
func readPacket() throws -> Data? {
    guard let header = try readExactly(4) else { return nil }
    let size = header.reduce(0) { ($0 << 8) | Int($1) }
    guard size > 0 && size <= 131072 else { throw AudioError.message("Invalid audio packet size") }
    return try readExactly(size)
}
func packet(_ type: UInt8, _ body: Data = Data()) throws {
    var size = UInt32(body.count + 1).bigEndian
    var out = Data(bytes: &size, count: 4); out.append(type); out.append(body)
    try FileHandle.standardOutput.write(contentsOf: out)
}
func append<T>(_ value: T, to data: inout Data) {
    var v = value; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
}
func integer<T: FixedWidthInteger>(_ data: Data, _ offset: Int, _: T.Type) -> T {
    data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }.bigEndian
}
func hostNS() -> UInt64 { UInt64(AVAudioTime.seconds(forHostTime: mach_absolute_time()) * 1_000_000_000) }
enum AudioError: Error { case message(String) }

final class Output {
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let lock = NSLock()
    var pending = 0
    func run(rate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw AudioError.message("Unsupported output rate") }
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start(); player.play()
        try packet(1)
        defer { player.stop(); engine.stop() }
        while let command = try readPacket() {
            if command == Data([3]) {
                var data = Data(); append(hostNS().bigEndian, to: &data)
                append(UInt64(max(0,engine.outputNode.presentationLatency) * 1_000_000_000).bigEndian, to: &data)
                try packet(3,data)
            } else {
                guard engine.isRunning && player.isPlaying else { throw AudioError.message("Speaker engine stopped; waiting for output recovery") }
                guard command.count >= 13, command[0] == 2 else { throw AudioError.message("Invalid output command") }
                let target = integer(command,1,UInt64.self), frames = integer(command,9,UInt32.self), now = hostNS()
                guard frames > 0, frames <= 4096, command.count == 13 + Int(frames) * 8,
                      target > now, target - now < 1_000_000_000 else { throw AudioError.message("Missed or invalid output target") }
                lock.lock(); let full = pending >= 128; if !full { pending += 1 }; lock.unlock()
                guard !full, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                      let planes = buffer.floatChannelData else { throw AudioError.message("Output buffer overloaded") }
                buffer.frameLength = frames
                command.withUnsafeBytes { bytes in
                    memcpy(planes[0], bytes.baseAddress!.advanced(by:13), Int(frames) * 4)
                    memcpy(planes[1], bytes.baseAddress!.advanced(by:13 + Int(frames) * 4), Int(frames) * 4)
                }
                let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: Double(target) / 1_000_000_000))
                player.scheduleBuffer(buffer, at: time, options: []) { [weak self] in
                    guard let self else { return }; self.lock.lock(); self.pending -= 1; self.lock.unlock()
                }
            }
        }
    }
}
signal(SIGPIPE, SIG_IGN)
do {
    if CommandLine.arguments.count == 3, let rate = Double(CommandLine.arguments[2]) { let output = Output(); try withExtendedLifetime(output) { try output.run(rate: rate) } }
    else { throw AudioError.message("Invalid native audio mode") }
} catch {
    var data = Data(); append(Int32(-1), to: &data); data.append(Data(String(describing: error).utf8))
    try? packet(3,data); exit(1)
}
