import CoreAudio
import Foundation

/// Raises a microphone's analog input gain for the length of a recording.
///
/// A MacBook's built-in microphone is commonly found at 13% gain, which is the
/// single largest measured accuracy factor in this project: the same phrase at
/// 13% and at 70% differs by roughly ten points of word accuracy, because the
/// consonants that distinguish words sit 11 dB higher. Above ~80% the signal
/// clips and accuracy falls again, so the target is deliberately short of the
/// top.
///
/// The previous value is restored when recording stops. Dictation borrows the
/// microphone; it does not get to keep the user's system setting.
enum InputGain {
    /// Measured optimum on a MacBook Pro microphone: peak 0.375, no clipped
    /// samples, 11.6 dB more energy in the 1.5-3.5 kHz consonant band. 0.9
    /// clipped 566 samples and transcribed worse.
    static let target: Float32 = 0.7

    /// Devices already at a usable level are left alone — the point is to
    /// rescue a microphone nobody knew was turned down, not to normalise
    /// everyone's setup.
    static let floor: Float32 = 0.5
    /// Whether a device's gain can be read, and whether parrot is allowed to
    /// change it. A device that reports a level but refuses writes is the case
    /// worth telling the user about.
    static func state(of device: AudioDeviceID) -> (level: Float32, adjustable: Bool)? {
        var address = volumeAddress
        var level: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &level) == noErr else {
            return nil
        }
        var settable: DarwinBoolean = false
        let queried = AudioObjectIsPropertySettable(device, &address, &settable) == noErr
        return (level, queried && settable.boolValue)
    }

    /// Returns the value to restore, or nil when nothing was changed.
    static func raise(_ device: AudioDeviceID) -> Float32? {
        guard let state = state(of: device), state.adjustable, state.level < floor else {
            return nil
        }
        var address = volumeAddress
        var wanted = target
        guard AudioObjectSetPropertyData(device, &address, 0, nil,
                                         UInt32(MemoryLayout<Float32>.size), &wanted) == noErr
        else { return nil }
        return state.level
    }

    static func restore(_ device: AudioDeviceID, to value: Float32) {
        var address = volumeAddress
        var previous = value
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &previous)
    }

    static func defaultInput() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, 0, nil, &size, &device)
        return device
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
}
