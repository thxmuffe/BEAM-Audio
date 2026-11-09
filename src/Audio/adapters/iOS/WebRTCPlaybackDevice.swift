import AudioToolbox
import AVFAudio
import WebRTC

/// Output-only OS binding. NetEq supplies decoded S16 audio; RemoteIO renders it.
/// No recording unit, microphone permission, jitter algorithm or extra scheduler.
final class WebRTCPlaybackDevice: NSObject, RTCAudioDevice {
    private let outputTiming = ba_output_timing_create()
    deinit { ba_output_timing_destroy(outputTiming) }
    func timingSnapshot() -> [String: Any] { ba_output_timing_snapshot(outputTiming) }

    private var audioDelegate: RTCAudioDeviceDelegate?
    private var unit: AudioUnit?
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    let isRecordingInitialized = false
    let isRecording = false
    let deviceInputSampleRate = 48000.0
    let inputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1
    let inputLatency = 0.0
    let deviceOutputSampleRate = 48000.0
    let outputNumberOfChannels = 2
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        audioDelegate = delegate; isInitialized = true; return true
    }
    func initializePlayout() -> Bool {
        if isPlayoutInitialized { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setPreferredSampleRate(48000)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch { return false }
        var component = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_RemoteIO, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let found = AudioComponentFindNext(nil, &component),
              AudioComponentInstanceNew(found, &unit) == noErr, let unit else { return false }
        var disabled: UInt32 = 0
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var callback = AURenderCallbackStruct(inputProc: { context, flags, timestamp, bus, frames, data in
            let device = Unmanaged<WebRTCPlaybackDevice>.fromOpaque(context).takeUnretainedValue()
            guard let data else { return noErr }
            if let delegate = device.audioDelegate {
                let status = delegate.getPlayoutData(flags, timestamp, Int(bus), frames, data)
                ba_output_timing_record(device.outputTiming, timestamp, frames, status)
                return status
            }
            for buffer in UnsafeMutableAudioBufferListPointer(data) {
                if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let configured = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                1, &disabled, UInt32(MemoryLayout.size(ofValue: disabled))) == noErr &&
            AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                0, &format, UInt32(MemoryLayout.size(ofValue: format))) == noErr &&
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                0, &callback, UInt32(MemoryLayout.size(ofValue: callback))) == noErr && AudioUnitInitialize(unit) == noErr
        if !configured { AudioComponentInstanceDispose(unit); self.unit = nil; return false }
        isPlayoutInitialized = true
        return true
    }
    func startPlayout() -> Bool {
        if isPlaying { return true }
        guard initializePlayout(), let unit else { return false }
        if let delegate = audioDelegate {
            delegate.dispatchSync {
                delegate.notifyAudioOutputInterrupted()
                delegate.notifyAudioOutputParametersChange()
            }
        }
        isPlaying = AudioOutputUnitStart(unit) == noErr
        return isPlaying
    }
    func stopPlayout() -> Bool {
        if let unit { AudioOutputUnitStop(unit) }
        isPlaying = false
        return true
    }
    func terminateDevice() -> Bool {
        _ = stopPlayout()
        if let unit { AudioUnitUninitialize(unit); AudioComponentInstanceDispose(unit) }
        unit = nil; audioDelegate = nil; isPlayoutInitialized = false; isInitialized = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }
    func initializeRecording() -> Bool { false }
    func startRecording() -> Bool { false }
    func stopRecording() -> Bool { true }
}
