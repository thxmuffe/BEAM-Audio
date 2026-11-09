// Offline AVAudioEngine candidate. Compile separately; never selects app defaults.
import Foundation
import AVFAudio
let engine = AVAudioEngine(), a = AVAudioPlayerNode(), b = AVAudioPlayerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
engine.attach(a); engine.attach(b)
engine.connect(a, to: engine.mainMixerNode, format: format)
engine.connect(b, to: engine.mainMixerNode, format: format)
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
func buffer(_ value: Float) -> AVAudioPCMBuffer {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
    pcm.frameLength = 960
    for c in 0..<2 { for n in 0..<960 { pcm.floatChannelData![c][n] = value } }
    return pcm
}
a.scheduleBuffer(buffer(0.25), at: AVAudioTime(sampleTime: 0, atRate: 48000))
b.scheduleBuffer(buffer(0.5), at: AVAudioTime(sampleTime: 480, atRate: 48000))
try engine.start(); a.play(); b.play()
defer { a.stop(); b.stop(); engine.stop() }
let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
var frames = 0
while frames < 1440 {
    let count = AVAudioFrameCount(min(256, 1440-frames))
    guard try engine.renderOffline(count, to: rendered) == .success else { fatalError("Offline renderer not ready") }
    for c in 0..<2 { for n in 0..<Int(count) {
        let position = frames+n
        let expected: Float = position < 480 ? 0.25 : position < 960 ? 0.75 : 0.5
        guard abs(rendered.floatChannelData![c][n]-expected) < 0.0001 else { fatalError("Native mixing differs at \(position)") }
    }}
    frames += Int(count)
}
print("PASS: two independent native sample schedules mix offline; hardware timing/recovery remain unqualified")
