import Foundation
import CoreMediaIO

/// "Some app is using the camera" — CMIO DeviceIsRunningSomewhere per video
/// device. Listener callbacks are known to fire spuriously on Apple Silicon,
/// so every callback just triggers a debounced re-read of the actual flags.
@MainActor
final class CameraDetector: ContextDetector {
    let flag = ContextFlag.cameraInUse
    var onChange: (() -> Void)?
    private(set) var isDetected = false

    private var running = false
    private let queue = DispatchQueue(label: "halftone.camera-monitor", qos: .utility)
    private var listenedDevices: [CMIOObjectID] = []
    private var debounce: DispatchWorkItem?

    private lazy var listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleRecheck()
    }

    private var runningAddr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    private var devicesAddr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))

    func start() {
        guard !running else { return }
        running = true
        // Hot-plug awareness (Continuity Camera comes and goes)
        CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddr, queue, listener)
        rebuildDeviceListeners()
        recheck()
    }

    func stop() {
        guard running else { return }
        running = false
        CMIOObjectRemovePropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddr, queue, listener)
        for dev in listenedDevices {
            CMIOObjectRemovePropertyListenerBlock(dev, &runningAddr, queue, listener)
        }
        listenedDevices = []
        isDetected = false
    }

    private nonisolated func scheduleRecheck() {
        Task { @MainActor in
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    self.rebuildDeviceListeners()
                    self.recheck()
                }
            }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func devices() -> [CMIOObjectID] {
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddr, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devs = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &devicesAddr, 0, nil, size, &used, &devs) == noErr
        else { return [] }
        return devs
    }

    private func rebuildDeviceListeners() {
        for dev in listenedDevices {
            CMIOObjectRemovePropertyListenerBlock(dev, &runningAddr, queue, listener)
        }
        listenedDevices = devices()
        for dev in listenedDevices {
            CMIOObjectAddPropertyListenerBlock(dev, &runningAddr, queue, listener)
        }
    }

    private func recheck() {
        var any = false
        for dev in listenedDevices {
            var value: UInt32 = 0
            var used: UInt32 = 0
            var addr = runningAddr
            if CMIOObjectGetPropertyData(dev, &addr, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr, value != 0 {
                any = true
                break
            }
        }
        if any != isDetected {
            isDetected = any
            onChange?()
        }
    }
}
