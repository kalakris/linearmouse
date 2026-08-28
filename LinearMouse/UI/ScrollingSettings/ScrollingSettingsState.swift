// MIT License
// Copyright (c) 2021-2026 LinearMouse

import AppKit
import Combine
import Foundation
import PublishedObject
import SwiftUI

class ScrollingSettingsState: ObservableObject {
    static let shared: ScrollingSettingsState = .init()

    @PublishedObject private var schemeState = SchemeState.shared
    private let deviceState = DeviceState.shared
    private var subscriptions = Set<AnyCancellable>()
    private var smoothedCache = Scheme.Scrolling.Bidirectional<Scheme.Scrolling.Smoothed>()
    private var touchStreamCache: Scheme.Scrolling.TouchStream?

    @Published private(set) var highResolutionWheelInfo: Device.HighResolutionWheelInfo?
    @Published private(set) var highResolutionWheelInfoRefreshing = false

    private init() {
        deviceState.$currentDeviceRef
            .debounce(for: 0.1, scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.resetHighResolutionWheelInfo()
                self?.refreshHighResolutionWheelInfo()
            }
            .store(in: &subscriptions)

        NSWorkspace.shared
            .notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .delay(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.resetHighResolutionWheelInfo()
                self?.refreshHighResolutionWheelInfo()
            }
            .store(in: &subscriptions)

        // "Raw Touch" mode availability follows stream device presence.
        TouchStreamManager.shared
            .$streamingDeviceIdentities
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
    }

    var scheme: Scheme {
        get { schemeState.scheme }
        set { schemeState.scheme = newValue }
    }

    var mergedScheme: Scheme {
        schemeState.mergedScheme
    }

    @Published var direction: Scheme.Scrolling.BidirectionalDirection = .vertical

    private var currentDevice: Device? {
        deviceState.currentDeviceRef?.value
    }
}

extension ScrollingSettingsState {
    var reverseScrolling: Bool {
        get { mergedScheme.scrolling.reverse[direction] ?? false }
        set { scheme.scrolling.reverse[direction] = newValue }
    }

    var showsHighResolutionWheelControl: Bool {
        highResolutionWheelInfo?.supportsHighResolutionWheel == true
    }

    var highResolutionWheel: Bool {
        get {
            schemeState.deviceScheme.logitech.highResolutionWheel
                ?? highResolutionWheelInfo?.enabled
                ?? false
        }
        set {
            var deviceScheme = schemeState.deviceScheme
            deviceScheme.logitech.highResolutionWheel = newValue
            schemeState.deviceScheme = deviceScheme

            if let currentDevice {
                DeviceManager.shared.updateHighResolutionWheel(for: currentDevice)
            }
        }
    }

    func refreshHighResolutionWheelInfo() {
        guard !highResolutionWheelInfoRefreshing else {
            return
        }

        guard let device = currentDevice else {
            resetHighResolutionWheelInfo()
            return
        }

        highResolutionWheelInfoRefreshing = true
        device.refreshHighResolutionWheelInfo { [weak self] info in
            guard let self else {
                return
            }

            guard self.currentDevice === device else {
                self.highResolutionWheelInfoRefreshing = false
                self.resetHighResolutionWheelInfo()
                self.refreshHighResolutionWheelInfo()
                return
            }

            self.highResolutionWheelInfo = info
            self.highResolutionWheelInfoRefreshing = false
            self.applyConfiguredHighResolutionWheelIfNeeded(info: info, device: device)
        }
    }

    private func resetHighResolutionWheelInfo() {
        highResolutionWheelInfo = nil
        highResolutionWheelInfoRefreshing = false
    }

    private func applyConfiguredHighResolutionWheelIfNeeded(info: Device.HighResolutionWheelInfo, device: Device) {
        guard info.supportsHighResolutionWheel,
              let configuredHighResolutionWheel = schemeState.deviceScheme.logitech.highResolutionWheel,
              info.enabled != configuredHighResolutionWheel else {
            return
        }

        DeviceManager.shared.updateHighResolutionWheel(for: device)
    }

    enum ScrollingMode: String, Identifiable, CaseIterable {
        var id: Self {
            self
        }

        case accelerated = "Accelerated"
        case smoothed = "Smoothed"
        case rawTouch = "Raw Touch"
        case byLines = "By Lines"
        case byPixels = "By Pixels"

        var label: LocalizedStringKey {
            switch self {
            case .accelerated: "Accelerated"
            case .smoothed: "Smoothed (Beta)"
            case .rawTouch: "Raw Touch"
            case .byLines: "By Lines"
            case .byPixels: "By Pixels"
            }
        }

        var sendsContinuousScrollEvents: Bool {
            switch self {
            case .smoothed, .byPixels:
                true
            case .accelerated, .rawTouch, .byLines:
                false
            }
        }
    }

    /// Whether the currently selected device is a detected streaming device
    /// (its touch-stream vendor collection is connected and passed capability
    /// detection).
    var isTouchStreamAvailable: Bool {
        guard let currentDevice else {
            return false
        }

        return TouchStreamManager.shared.isStreamingDevice(currentDevice)
    }

    /// The modes offered by the mode picker: "Raw Touch" only appears for
    /// detected streaming devices (or when it is already the selected mode,
    /// so a temporarily disconnected keyboard does not break the picker).
    var availableScrollingModes: [ScrollingMode] {
        ScrollingMode.allCases.filter { mode in
            guard mode == .rawTouch else {
                return true
            }
            return isTouchStreamAvailable || scrollingMode == .rawTouch
        }
    }

    var scrollingMode: ScrollingMode {
        get {
            if currentTouchStreamConfiguration != nil {
                return .rawTouch
            }

            if currentSmoothedConfiguration != nil {
                return .smoothed
            }

            switch mergedScheme.scrolling.distance[direction] ?? .auto {
            case .auto:
                return .accelerated
            case .line:
                return .byLines
            case .pixel:
                return .byPixels
            }
        }
        set {
            if newValue != .rawTouch {
                clearTouchStreamConfiguration()
            }

            switch newValue {
            case .accelerated:
                clearSmoothedConfiguration()
                scheme.scrolling.distance[direction] = .auto
                scheme.scrolling.acceleration[direction] = 1
                scheme.scrolling.speed[direction] = 0
            case .smoothed:
                let smoothed = currentSmoothedConfiguration ?? makeDefaultSmoothedConfiguration()
                setSmoothedConfiguration(smoothed)
                scheme.scrolling.distance[direction] = .auto
                scheme.scrolling.acceleration[direction] = 1
                scheme.scrolling.speed[direction] = 0
            case .rawTouch:
                clearSmoothedConfiguration()
                let touchStream = currentTouchStreamConfiguration
                    ?? touchStreamCache
                    ?? Scheme.Scrolling.TouchStream()
                setTouchStreamConfiguration(touchStream)
                scheme.scrolling.distance[direction] = .auto
                scheme.scrolling.acceleration[direction] = 1
                scheme.scrolling.speed[direction] = 0
            case .byLines:
                clearSmoothedConfiguration()
                scheme.scrolling.distance[direction] = .line(3)
                scheme.scrolling.acceleration[direction] = 1
                scheme.scrolling.speed[direction] = 0
            case .byPixels:
                clearSmoothedConfiguration()
                scheme.scrolling.distance[direction] = .pixel(36)
                scheme.scrolling.acceleration[direction] = 1
                scheme.scrolling.speed[direction] = 0
            }
        }
    }

    var scrollingAcceleration: Double {
        get { mergedScheme.scrolling.acceleration[direction]?.asTruncatedDouble ?? 1 }
        set { scheme.scrolling.acceleration[direction] = Decimal(newValue).rounded(2) }
    }

    var scrollingAccelerationFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var scrollingSpeed: Double {
        get { mergedScheme.scrolling.speed[direction]?.asTruncatedDouble ?? 0 }
        set { scheme.scrolling.speed[direction] = Decimal(newValue).rounded(2) }
    }

    var scrollingSpeedFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var scrollingDistanceInLines: Double {
        get {
            guard case let .line(lines) = mergedScheme.scrolling.distance[direction] else {
                return 3
            }
            return Double(lines)
        }
        set {
            scheme.scrolling.distance[direction] = .line(Int(newValue))
        }
    }

    var scrollingDistanceInPixels: Double {
        get {
            guard case let .pixel(pixels) = mergedScheme.scrolling.distance[direction] else {
                return 36
            }
            return pixels.asTruncatedDouble
        }
        set {
            scheme.scrolling.distance[direction] = .pixel(Decimal(newValue).rounded(1))
        }
    }

    var smoothedPreset: Scheme.Scrolling.Smoothed.Preset {
        get { currentSmoothedConfiguration?.preset ?? .defaultPreset }
        set {
            selectSmoothedPreset(newValue)
        }
    }

    var smoothedResponse: Double {
        get { currentSmoothedConfiguration?.response?.asTruncatedDouble ?? 0.68 }
        set {
            updateSmoothedConfiguration {
                $0.response = Decimal(newValue).rounded(2)
            }
        }
    }

    var smoothedResponseFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var smoothedSpeed: Double {
        get { currentSmoothedConfiguration?.speed?.asTruncatedDouble ?? 1.02 }
        set {
            updateSmoothedConfiguration {
                $0.speed = Decimal(newValue).rounded(2)
            }
        }
    }

    var smoothedSpeedFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var smoothedAcceleration: Double {
        get { currentSmoothedConfiguration?.acceleration?.asTruncatedDouble ?? 1.10 }
        set {
            updateSmoothedConfiguration {
                $0.acceleration = Decimal(newValue).rounded(2)
            }
        }
    }

    var smoothedAccelerationFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var smoothedInertia: Double {
        get { currentSmoothedConfiguration?.inertia?.asTruncatedDouble ?? 0.74 }
        set {
            updateSmoothedConfiguration {
                $0.inertia = Decimal(newValue).rounded(2)
            }
        }
    }

    var smoothedInertiaFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    var smoothedBouncing: Bool {
        get { currentSmoothedConfiguration?.allowsBouncing ?? true }
        set {
            updateSmoothedConfiguration {
                $0.bouncing = newValue
            }
        }
    }

    var scrollingDisabled: Bool {
        switch scrollingMode {
        case .accelerated:
            return scrollingAcceleration == 0 && scrollingSpeed == 0
        case .smoothed:
            return smoothedResponse == 0 && smoothedSpeed == 0 && smoothedAcceleration == 0 && smoothedInertia == 0
        case .rawTouch:
            return false
        case .byLines:
            return scrollingDistanceInLines == 0
        case .byPixels:
            return scrollingDistanceInPixels == 0
        }
    }

    var modifiers: Scheme.Scrolling.Modifiers {
        get {
            mergedScheme.scrolling.modifiers[direction] ?? .init()
        }
        set {
            scheme.scrolling.modifiers[direction] = newValue
        }
    }

    var showsContinuousScrollShiftTip: Bool {
        direction == .vertical
            && scrollingMode.sendsContinuousScrollEvents
            && (modifiers.shift?.kind ?? .defaultAction) != .alterOrientation
    }

    func setShiftModifierToAlterOrientation() {
        var modifiers = modifiers
        modifiers.shift = .alterOrientation
        self.modifiers = modifiers
    }

    private var currentSmoothedConfiguration: Scheme.Scrolling.Smoothed? {
        let configuration = scheme.scrolling.smoothed[direction]
            ?? mergedScheme.scrolling.smoothed[direction]
            ?? smoothedCache[direction]
        guard configuration?.isEnabled == true else {
            return nil
        }
        return configuration
    }

    func smoothedPreviewConfiguration(for preset: Scheme.Scrolling.Smoothed.Preset) -> Scheme.Scrolling.Smoothed {
        if preset == .custom {
            var configuration = scheme.scrolling.smoothed[direction]
                ?? smoothedCache[direction]
                ?? currentSmoothedConfiguration
                ?? makeDefaultSmoothedConfiguration()
            configuration.enabled = true
            configuration.preset = .custom
            return configuration
        }

        return preset.defaultConfiguration
    }

    func restoreDefaultSmoothedPreset() {
        selectSmoothedPreset(.defaultPreset)
    }

    private func setSmoothedConfiguration(_ configuration: Scheme.Scrolling.Smoothed) {
        var configuration = configuration
        configuration.enabled = true
        scheme.scrolling.smoothed[direction] = configuration
        smoothedCache[direction] = configuration
    }

    private func clearSmoothedConfiguration() {
        if let currentSmoothedConfiguration {
            smoothedCache[direction] = currentSmoothedConfiguration
        }

        scheme.scrolling.smoothed[direction] = .init(enabled: false)
    }

    private func makeDefaultSmoothedConfiguration() -> Scheme.Scrolling.Smoothed {
        Scheme.Scrolling.Smoothed.Preset.defaultPreset.defaultConfiguration
    }

    private func selectSmoothedPreset(_ preset: Scheme.Scrolling.Smoothed.Preset) {
        if preset == .custom {
            setSmoothedConfiguration(makeCustomSmoothedConfiguration())
        } else {
            var configuration = preset.defaultConfiguration
            configuration.bouncing = makeEditableSmoothedConfiguration().allowsBouncing
            setSmoothedConfiguration(configuration)
        }
    }

    private func makeEditableSmoothedConfiguration() -> Scheme.Scrolling.Smoothed {
        var configuration = currentSmoothedConfiguration
            ?? scheme.scrolling.smoothed[direction]
            ?? smoothedCache[direction]
            ?? makeDefaultSmoothedConfiguration()
        configuration.enabled = true
        configuration.preset = configuration.preset ?? .defaultPreset
        return configuration
    }

    private func makeCustomSmoothedConfiguration() -> Scheme.Scrolling.Smoothed {
        var configuration = makeEditableSmoothedConfiguration()
        configuration.preset = .custom
        return configuration
    }

    private func updateSmoothedConfiguration(_ update: (inout Scheme.Scrolling.Smoothed) -> Void) {
        var configuration = makeEditableSmoothedConfiguration()
        update(&configuration)
        setSmoothedConfiguration(configuration)
    }

    private func decimalFormatter(maxFractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.thousandSeparator = ""
        return formatter
    }
}

// MARK: - Raw touch (touch-stream) scrolling

extension ScrollingSettingsState {
    /// The active touch-stream configuration, mirroring
    /// `currentSmoothedConfiguration`: the device scheme's own value first,
    /// then the merged scheme, then the mode-switch cache. `nil` while the
    /// feature is disabled. Touch-stream settings are direction-agnostic, so
    /// unlike the smoothed configuration there is no per-direction subscript
    /// — both direction tabs edit the same values.
    private var currentTouchStreamConfiguration: Scheme.Scrolling.TouchStream? {
        let configuration = scheme.scrolling.$touchStream
            ?? mergedScheme.scrolling.$touchStream
            ?? touchStreamCache
        guard configuration?.isEnabled == true else {
            return nil
        }
        return configuration
    }

    private func setTouchStreamConfiguration(_ configuration: Scheme.Scrolling.TouchStream) {
        var configuration = configuration
        configuration.enabled = true
        scheme.scrolling.touchStream = configuration
        touchStreamCache = configuration
    }

    /// Disables touch-stream scrolling, caching the tuning so switching modes
    /// back and forth does not lose it (the smoothedCache pattern). Writes an
    /// explicit `enabled: false` only when some scheme actually configured
    /// the feature, so unrelated devices' schemes stay clean.
    func clearTouchStreamConfiguration() {
        if let currentTouchStreamConfiguration {
            touchStreamCache = currentTouchStreamConfiguration
        }

        guard scheme.scrolling.$touchStream != nil
            || mergedScheme.scrolling.$touchStream != nil else {
            return
        }

        scheme.scrolling.touchStream = .init(enabled: false)
    }

    private func makeEditableTouchStreamConfiguration() -> Scheme.Scrolling.TouchStream {
        var configuration = currentTouchStreamConfiguration
            ?? scheme.scrolling.$touchStream
            ?? touchStreamCache
            ?? Scheme.Scrolling.TouchStream()
        configuration.enabled = true
        return configuration
    }

    private func updateTouchStreamConfiguration(_ update: (inout Scheme.Scrolling.TouchStream) -> Void) {
        var configuration = makeEditableTouchStreamConfiguration()
        update(&configuration)
        setTouchStreamConfiguration(configuration)
    }

    var touchStreamScale: Double {
        get {
            currentTouchStreamConfiguration?.scale?.asTruncatedDouble
                ?? Scheme.Scrolling.TouchStream.defaultScale
        }
        set {
            updateTouchStreamConfiguration {
                $0.scale = Decimal(newValue).rounded(3)
            }
        }
    }

    var touchStreamScaleFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 3)
    }

    private func updateTouchStreamAcceleration(
        _ update: (inout Scheme.Scrolling.TouchStream.Acceleration) -> Void
    ) {
        updateTouchStreamConfiguration {
            var acceleration = $0.acceleration ?? .init()
            update(&acceleration)
            $0.acceleration = acceleration
        }
    }

    /// The single acceleration control: the gain-curve exponent, with 0
    /// meaning "acceleration off". Reads as 0 while acceleration is
    /// disabled; writing a positive exponent enables acceleration and
    /// writing 0 disables it (the coherent-config rule — exponent 0 is the
    /// identity curve anyway). `referenceSpeed`/`minGain`/`maxGain` are
    /// JSON-only expert settings.
    var touchStreamAccelerationExponent: Double {
        get {
            guard let acceleration = currentTouchStreamConfiguration?.acceleration,
                  acceleration.isEnabled else {
                return 0
            }
            return acceleration.resolvedExponent
        }
        set {
            updateTouchStreamAcceleration {
                $0.exponent = Decimal(newValue).rounded(2)
                $0.enabled = newValue > 0
            }
        }
    }

    var touchStreamAccelerationExponentFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }

    private func updateTouchStreamMomentum(
        _ update: (inout Scheme.Scrolling.TouchStream.Momentum) -> Void
    ) {
        updateTouchStreamConfiguration {
            var momentum = $0.momentum ?? .init()
            update(&momentum)
            $0.momentum = momentum
        }
    }

    var touchStreamMomentumDecayTimeConstant: Double {
        get {
            (currentTouchStreamConfiguration?.momentum ?? .init()).resolvedDecayTimeConstant
        }
        set {
            updateTouchStreamMomentum {
                $0.decayTimeConstant = Decimal(newValue).rounded(2)
            }
        }
    }

    var touchStreamMomentumDecayTimeConstantFormatter: NumberFormatter {
        decimalFormatter(maxFractionDigits: 2)
    }
}
