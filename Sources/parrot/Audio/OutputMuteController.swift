import AudioToolbox
import CoreAudio
import Foundation

/// Temporarily silences the current macOS output route while Parrot records.
///
/// It prefers the hardware mute control and falls back to the output volume for
/// Bluetooth/AirPods-style devices. The original state is captured once and is
/// restored as soon as the Fn key is released.
final class OutputMuteController {
    private enum SilenceState {
        case mute(deviceID: AudioDeviceID, wasMuted: Bool)
        case volume(deviceID: AudioDeviceID, controls: [VolumeControl])
    }

    private struct VolumeControl {
        let address: AudioObjectPropertyAddress
        let previousVolume: Float32
    }

    private var state: SilenceState?

    func mute() {
        guard state == nil else { return }

        do {
            let deviceID = try defaultOutputDeviceID()
            do {
                let wasMuted = try isMuted(deviceID: deviceID)
                try setMuted(true, deviceID: deviceID)
                state = .mute(deviceID: deviceID, wasMuted: wasMuted)
                log("muted \(deviceName(deviceID: deviceID))")
            } catch {
                let controls = try readVolumeControls(deviceID: deviceID)
                try setVolume(0, controls: controls, deviceID: deviceID)
                state = .volume(deviceID: deviceID, controls: controls)
                log("muted \(deviceName(deviceID: deviceID)) using volume fallback")
            }
        } catch {
            log("mute failed: \(error)")
        }
    }

    func restore() {
        guard let state else { return }

        do {
            switch state {
            case .mute(let deviceID, let wasMuted):
                try setMuted(wasMuted, deviceID: deviceID)
                log("restored \(deviceName(deviceID: deviceID))")
            case .volume(let deviceID, let controls):
                try restoreVolume(controls, deviceID: deviceID)
                log("restored volume for \(deviceName(deviceID: deviceID))")
            }
            self.state = nil
        } catch {
            log("restore failed: \(error)")
        }
    }

    deinit {
        restore()
    }

    private func defaultOutputDeviceID() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw OutputMuteError.defaultOutputUnavailable(status)
        }
        return deviceID
    }

    private func isMuted(deviceID: AudioDeviceID) throws -> Bool {
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = mutePropertyAddress()
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted)
        guard status == noErr else { throw OutputMuteError.readMute(status) }
        return muted != 0
    }

    private func setMuted(_ muted: Bool, deviceID: AudioDeviceID) throws {
        var value = UInt32(muted ? 1 : 0)
        var address = mutePropertyAddress()
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw OutputMuteError.writeMute(kAudioHardwareUnknownPropertyError)
        }
        let status = AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
        guard status == noErr else { throw OutputMuteError.writeMute(status) }
    }

    private func readVolumeControls(deviceID: AudioDeviceID) throws -> [VolumeControl] {
        if let control = try? readVolumeControl(
            deviceID: deviceID,
            address: volumePropertyAddress()
        ) {
            return [control]
        }
        if let control = try? readVolumeControl(
            deviceID: deviceID,
            address: scalarVolumePropertyAddress(element: kAudioObjectPropertyElementMain)
        ) {
            return [control]
        }
        let channels = [AudioObjectPropertyElement(1), AudioObjectPropertyElement(2)].compactMap { element in
            try? readVolumeControl(
                deviceID: deviceID,
                address: scalarVolumePropertyAddress(element: element)
            )
        }
        guard !channels.isEmpty else {
            throw OutputMuteError.readVolume(kAudioHardwareUnknownPropertyError)
        }
        return channels
    }

    private func readVolumeControl(
        deviceID: AudioDeviceID,
        address: AudioObjectPropertyAddress
    ) throws -> VolumeControl {
        var value = Float32(0)
        var mutableAddress = address
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(deviceID, &mutableAddress) else {
            throw OutputMuteError.readVolume(kAudioHardwareUnknownPropertyError)
        }
        let status = AudioObjectGetPropertyData(
            deviceID, &mutableAddress, 0, nil, &size, &value
        )
        guard status == noErr else { throw OutputMuteError.readVolume(status) }
        return VolumeControl(address: address, previousVolume: value)
    }

    private func setVolume(_ volume: Float32, controls: [VolumeControl], deviceID: AudioDeviceID) throws {
        for control in controls {
            var value = min(max(volume, 0), 1)
            var address = control.address
            let size = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectSetPropertyData(
                deviceID, &address, 0, nil, size, &value
            )
            guard status == noErr else { throw OutputMuteError.writeVolume(status) }
        }
    }

    private func restoreVolume(_ controls: [VolumeControl], deviceID: AudioDeviceID) throws {
        if let currentControls = try? readVolumeControls(deviceID: deviceID),
           let previousVolume = controls.first?.previousVolume {
            try setVolume(previousVolume, controls: currentControls, deviceID: deviceID)
        } else {
            try setVolume(controls.first?.previousVolume ?? 0, controls: controls, deviceID: deviceID)
        }
    }

    private func mutePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func volumePropertyAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func scalarVolumePropertyAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private func deviceName(deviceID: AudioDeviceID) -> String {
        var name: CFString = "default output" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return status == noErr ? name as String : "default output"
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("parrot audio: \(message)\n".utf8))
    }
}

private enum OutputMuteError: Error {
    case defaultOutputUnavailable(OSStatus)
    case readMute(OSStatus)
    case writeMute(OSStatus)
    case readVolume(OSStatus)
    case writeVolume(OSStatus)
}
