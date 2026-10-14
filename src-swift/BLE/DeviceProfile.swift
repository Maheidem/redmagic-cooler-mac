import Foundation
import CoreBluetooth

/// Everything the app knows about one cooler model, gathered in one place:
/// how to recognise it in a scan, which GATT characteristics drive it, and how
/// to decode its telemetry frames.
///
/// This is the single seam for supporting another device. To add a model,
/// define a new profile below and append it to `all` — the rest of the app is
/// model-agnostic and follows whichever profile matched during discovery.
/// The full walkthrough is in `docs/ADDING_DEVICES.md`.
///
/// The UUIDs are stored pre-parsed as `CBUUID` because they're compared for
/// every characteristic on every notification, and `CBUUID(string:)` parses
/// on each call.
struct DeviceProfile {

    /// Human-readable model name, for logs and the device picker.
    let modelName: String

    /// Lowercased substrings that identify this model in a scan result.
    ///
    /// Matching is by advertised *name* because these devices omit their
    /// service UUID from the scan record — filtering a scan by service would
    /// never find them.
    let nameHints: [String]

    /// The vendor GATT service that carries all the control characteristics.
    let serviceUUID: CBUUID

    // ── Characteristics ──────────────────────────────────────────────────────

    /// Write `[mode]` — see `CoolingMode`.
    let coolingModeUUID: CBUUID
    /// Write `[percent]`, 0–100.
    let fanSpeedUUID: CBUUID
    /// Write `[effect, R, G, B]` — see `LedEffect`.
    let lightModeUUID: CBUUID
    /// Notify. Reports whether the magnetic mount is seated.
    let hallUUID: CBUUID
    /// Notify. Periodic telemetry frames, decoded by `makeTelemetryDecoder`.
    let telemetryUUID: CBUUID

    // ── Command encoding ─────────────────────────────────────────────────────

    /// Bytes to write to `coolingModeUUID` for a mode.
    let modeBytes: (CoolingMode) -> [UInt8]

    /// Bytes to write to `fanSpeedUUID` for a fan request (0–100) made while
    /// `mode` is being applied. Must be safe for `percent == 0`: the app sends
    /// that whenever it turns the cooler off.
    let fanBytes: (CoolingMode, UInt8) -> [UInt8]

    /// Effect byte of the light characteristic that switches the light off.
    let lightOffEffect: UInt8

    /// Whether reading the mode and fan characteristics tells the truth about
    /// what the cooler is doing. When false the app keeps its own record of
    /// what it last asked for, rather than adopting the device's values and
    /// re-asserting them from the heartbeat.
    let readBackReflectsState: Bool

    // ── Frame decoding ───────────────────────────────────────────────────────

    /// Returns a fresh decoder for one connection. It is called once per link
    /// so a model whose telemetry arrives as separate single-field frames can
    /// keep the latest value of each between calls. The decoder returns `nil`
    /// for frames that don't parse (wrong marker, truncated) or that carry
    /// nothing new.
    let makeTelemetryDecoder: () -> (Data) -> CoolerTelemetry?

    /// Whether a hall-sensor frame means the magnetic mount is attached.
    let decodeMountAttached: (Data) -> Bool

    // ── Derived ──────────────────────────────────────────────────────────────

    /// Characteristics to subscribe to.
    var notifyingUUIDs: Set<CBUUID> { [hallUUID, telemetryUUID] }

    /// Characteristics the app writes to. Resolved at connect and held so
    /// `write` can find them; the device exposes more (a threshold and an
    /// auto-temp flag for its own automation, mapped in `docs/FINDINGS.md`),
    /// but this app runs its own autopilot and drives none of them.
    var writableUUIDs: Set<CBUUID> { [coolingModeUUID, fanSpeedUUID, lightModeUUID] }

    // ── Registry ─────────────────────────────────────────────────────────────

    /// Every model the app can drive, in match order. Add new profiles here.
    ///
    /// Order matters: the first match wins, and the 6 Pro's `magcooler` hint is
    /// a substring of every `RM Magcooler …` name, so more specific profiles
    /// go ahead of it.
    static let all: [DeviceProfile] = [.cryoCooler8Pro, .vcCooler6Pro]

    /// The profile whose name hints match an advertised device name, if any.
    static func matching(deviceName: String) -> DeviceProfile? {
        let lowercased = deviceName.lowercased()
        return all.first { $0.nameHints.contains(where: lowercased.contains) }
    }

    /// Loose substrings suggesting a vendor cooler the app has *no* profile for.
    ///
    /// Deliberately broader than any profile's `nameHints`, and used only to
    /// decide what to *show*. A device matching these but no profile is listed
    /// in the picker as unsupported and cannot be connected to — the app has no
    /// idea what its bytes mean. The point is that its owner can see the app
    /// noticed it, and read `docs/ADDING_DEVICES.md` rather than concluding the
    /// app is broken.
    static let vendorHints = [
        "redmagic", "red magic", "magcooler", "magic cooler",
        "rm cooler", "vc cooler", "nubia",
    ]

    static func looksLikeVendorDevice(deviceName: String) -> Bool {
        let lowercased = deviceName.lowercased()
        return vendorHints.contains(where: lowercased.contains)
    }
}

// ── Known models ─────────────────────────────────────────────────────────────

extension DeviceProfile {

    /// REDMAGIC VC Cooler 6 Pro (advertises as `RM Magcooler 6pro`).
    ///
    /// The protocol was reverse-engineered from BLE captures and the vendor
    /// APK; every byte here is documented in `docs/FINDINGS.md`.
    static let vcCooler6Pro = DeviceProfile(
        modelName: "REDMAGIC VC Cooler 6 Pro",
        // Only names this model is actually known to advertise. `rm cooler`
        // used to live here as a guess at sibling models, which meant any
        // "RM Cooler 5" in range was silently driven with 6 Pro byte layouts.
        // It now sits in `vendorHints`, so an unknown RM cooler is listed as
        // unsupported instead of being written to on a hunch.
        nameHints: ["magcooler"],
        serviceUUID: CBUUID(string: "d52082ad-e805-9f97-9d4e-1c682d9c9ce6"),
        coolingModeUUID: CBUUID(string: "00001011-0000-1000-8000-00805f9b34fb"),
        fanSpeedUUID:    CBUUID(string: "00001012-0000-1000-8000-00805f9b34fb"),
        lightModeUUID:   CBUUID(string: "00001013-0000-1000-8000-00805f9b34fb"),
        hallUUID:        CBUUID(string: "00001015-0000-1000-8000-00805f9b34fb"),
        telemetryUUID:   CBUUID(string: "00001016-0000-1000-8000-00805f9b34fb"),
        modeBytes: { [$0.rawValue] },
        fanBytes: { _, percent in [min(percent, 100)] },
        lightOffEffect: LedEffect.DeviceEffect.off.rawValue,
        readBackReflectsState: true,
        makeTelemetryDecoder: { { data in
            // `[0]=0xAA marker, [2]=cold °C, [3]=hot °C, [7]=ambient °C,
            //  [13..14]=fan RPM little-endian`. Older firmware sends a shorter
            // frame that stops before the RPM field.
            guard data.count >= 8, data[0] == 0xAA else { return nil }
            let rpm = data.count >= 15 ? Int(data[13]) | (Int(data[14]) << 8) : nil
            return CoolerTelemetry(coldC: Int(data[2]),
                                   hotC: Int(data[3]),
                                   ambientC: Int(data[7]),
                                   fanRPM: rpm)
        } },
        decodeMountAttached: { data in
            // Byte 0 == 4 means the magnetic mount is seated (5 = detached).
            !data.isEmpty && data[0] == 4
        }
    )

    /// REDMAGIC Cryo Cooler 8 Pro (advertises as `RM Magcooler 8pro`).
    ///
    /// Same vendor service as the 6 Pro and a similar characteristic layout,
    /// but different semantics; every byte here is documented in
    /// `docs/FINDINGS_CRYO_COOLER_8_PRO.md`. The differences that matter:
    ///
    /// - `0x1011` is only an on/off switch (`02` / `03`). Cooling strength is
    ///   `0x1012`, a single level byte `0x2e`–`0x50` that sets fan and TEC
    ///   together, so the app's separate mode and fan speed are folded into it.
    ///   Writing a value below `0x2e` (including `0x00`) does not mean "off":
    ///   it runs the cooler at about full power.
    /// - Status arrives on `0x1015` as separate four-byte frames, one field
    ///   each, not as one frame on `0x1016` (which stays silent).
    /// - There is no mount sensor, and only the plate temperature is reported.
    static let cryoCooler8Pro = DeviceProfile(
        modelName: "REDMAGIC Cryo Cooler 8 Pro",
        nameHints: ["magcooler 8pro"],
        serviceUUID: CBUUID(string: "d52082ad-e805-9f97-9d4e-1c682d9c9ce6"),
        coolingModeUUID: CBUUID(string: "00001011-0000-1000-8000-00805f9b34fb"),
        fanSpeedUUID:    CBUUID(string: "00001012-0000-1000-8000-00805f9b34fb"),
        lightModeUUID:   CBUUID(string: "00001013-0000-1000-8000-00805f9b34fb"),
        // No mount sensor on this model: a UUID the device does not expose, so
        // discovery skips it and the mount state stays unknown.
        hallUUID:        CBUUID(string: "0000ffff-0000-1000-8000-00805f9b34fb"),
        telemetryUUID:   CBUUID(string: "00001015-0000-1000-8000-00805f9b34fb"),
        modeBytes: { mode in mode.isOn ? [0x02] : [0x03] },
        fanBytes: { mode, percent in
            // Never below the lowest level the vendor app uses: `0x00` and
            // anything under `0x2e` runs the cooler flat out. Each zone gets a
            // band of the level range (about 9–16 W / 23–26 W / 29 W measured),
            // and the requested fan speed moves within it, so the app's ladders
            // stay monotonic on a device with only one control axis. The fan
            // windows are the speeds the Auto tiers and the manual slider use
            // for that zone; anything outside is clamped.
            let band: ClosedRange<Int>
            let window: ClosedRange<Int>
            switch mode.zone {
            case .off:    return [0x2e]
            case .low:    band = 0x2e...0x3a; window = 40...80
            case .medium: band = 0x40...0x48; window = 60...95
            case .max:    band = 0x4c...0x50; window = 70...80
            }
            let speed = min(max(Int(percent), window.lowerBound), window.upperBound)
            let position = Double(speed - window.lowerBound)
                / Double(window.upperBound - window.lowerBound)
            let level = band.lowerBound
                + Int((position * Double(band.upperBound - band.lowerBound)).rounded())
            return [UInt8(level)]
        },
        // `0x00` is a steady colour here; off is `0x06`.
        lightOffEffect: 0x06,
        // Idle, the cooler reads `0x1011 = 02` and `0x1012 = 00`, which is not
        // a running state: adopting it would have the heartbeat start the cooler.
        readBackReflectsState: false,
        makeTelemetryDecoder: {
            // Frames are `[type, a, b, 0]`: `04` plate temperature (signed
            // byte, minus 6 = °C; the plate goes below zero), `08` fan RPM big-endian, `05 7f` cooling is not running (the
            // button, or `0x1011 = 03`; the fan then sends no further RPM
            // frame, so 0 RPM is inferred), `09` power draw in watts. `07` (a constant 8,
            // probably the top level) is not used.
            var plateC: Int?
            var rpm: Int?
            var watts: Int?
            var lastSent: (plate: Int?, rpm: Int?, watts: Int?, at: Date)?
            return { data in
                guard data.count >= 3 else { return nil }
                switch data[0] {
                case 0x04: plateC = Int(Int8(bitPattern: data[1])) - 6
                case 0x05: if data[1] == 0x7f { rpm = 0 }
                case 0x07: break
                case 0x08: rpm = Int(data[1]) << 8 | Int(data[2])
                case 0x09: watts = Int(data[1])
                default: return nil
                }
                guard let plateC else { return nil }
                // The device sends several frames a second, and in a steady
                // state only `05` and `07` keep arriving. Pass on changes and a
                // once-a-second heartbeat driven by any of them, so the silence
                // check in `PhysicalSwitchMonitor` still sees a live link.
                let now = Date()
                if let last = lastSent, last.plate == plateC, last.rpm == rpm,
                   last.watts == watts, now.timeIntervalSince(last.at) < 1 { return nil }
                lastSent = (plateC, rpm, watts, now)
                return CoolerTelemetry(coldC: plateC, hotC: nil, ambientC: nil,
                                       fanRPM: rpm, powerW: watts)
            }
        },
        decodeMountAttached: { _ in true }
    )
}
