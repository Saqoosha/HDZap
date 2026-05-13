import Foundation
import CoreBluetooth

enum OSDCommand: UInt8 {
    case clear = 0x01
    case resetLaps = 0x02
    /// Debug-only: fire a single test message ("HDZAP TEST") at the
    /// goggle OSD to verify ESP-NOW delivery end-to-end without having
    /// to start the timer and record a lap.
    case testOSD = 0x03
}

/// One ESP-NOW packet captured by the firmware telemetry sniffer.
/// Wire format is the 20-byte record produced by
/// `telemetry_sniff::_telemetry_recv_cb` — keep this struct's decoder
/// in lockstep with that layout.
struct BackpackTelemetryRecord: Identifiable {
    let id = UUID()
    /// Wall-clock timestamp at iOS receive time. Used by the debug
    /// view for the "packets/sec" rate calculation and for ordering
    /// the live log; the firmware doesn't include a timestamp in the
    /// record because the connection interval already serializes
    /// arrivals to a few-ms resolution at the iOS side.
    let receivedAt: Date
    /// Source MAC of the ESP-NOW packet. ELRS backpacks use their UID
    /// as the MAC, so this directly identifies the broadcaster (TX
    /// backpack, goggle backpack, another peer).
    let mac: [UInt8]
    /// MSP function code (MSPv1 cmd byte or MSPv2 16-bit function),
    /// or nil when the packet didn't carry an MSP preamble.
    let mspFunctionCode: UInt16?
    /// Raw ESP-NOW packet length, capped at 255 by the firmware.
    let payloadLength: UInt8
    /// True when the packet starts with `$X<` (modern ELRS format).
    let isMSPv2: Bool
    /// True when the packet starts with `$M<` (legacy MSP).
    let isMSPv1: Bool
    /// First 10 bytes of the raw packet, for hex-dump display.
    let firstBytes: [UInt8]

    /// Decode a 20-byte BLE notify payload into a record. Returns nil
    /// on a short or malformed payload — same defensive pattern as the
    /// status / battery decoders, which surface size mismatches as a
    /// version-skew error rather than silently misinterpreting bytes.
    init?(data: Data) {
        guard data.count >= 20 else { return nil }
        receivedAt = Date()
        mac = Array(data[0..<6])
        let fnRaw = UInt16(data[6]) | (UInt16(data[7]) << 8)
        payloadLength = data[8]
        let flags = data[9]
        isMSPv2 = (flags & 0x01) != 0
        isMSPv1 = (flags & 0x02) != 0
        // 0xFFFF is the firmware's "non-MSP" sentinel — see
        // telemetry_sniff.h::_telemetry_recv_cb.
        mspFunctionCode = (isMSPv2 || isMSPv1) ? fnRaw : nil
        firstBytes = Array(data[10..<20])
    }
}

// Service UUID ...d491 → ...d492 adds flightBatteryUUID (`…d48d`) while
// preserving telemetryDebugUUID (`…d48c`) from the Backpack Telemetry Debug
// subview. iOS may need BT toggle or forget device to invalidate
// CoreBluetooth's service cache after a bump.
private let serviceUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d492")
private let uidConfigUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d481")
private let bindCommandUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d482")
// CHR_LAP_TIME_UUID (...d483) was retired when the firmware switched to the
// iOS-owned OSD text path; iOS now formats and sends the full 4-row OSD frame
// itself, so the lap-frame characteristic is gone from the firmware GATT.
private let osdControlUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d484")
private let statusUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d485")
private let txSniffUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d486")
private let osdTextUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d487")
private let batteryUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d488")
private let deviceNameUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d489")
private let osdLayoutUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d48b")
/// Flight pack CRSF Battery via ESP-NOW telemetry (optional on older firmware).
private let flightBatteryUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d48d")
private let firmwareVersionUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d48f")
/// Backpack telemetry debug stream (write start/stop, notify records).
private let telemetryDebugUUID = CBUUID(string: "f47ac10b-58cc-4372-a567-0e02b2c3d48c")

/// BLE adv scan-response leaves room for ~20 bytes of UTF-8 device name
/// after the 128-bit service UUID. Match the firmware constant in
/// `nvs_store::kDeviceNameMaxLen` — diverging here would let iOS write
/// a longer string that the firmware silently rejects.
let bleDeviceNameMaxBytes = 20

@MainActor
@Observable
class BluetoothManager: NSObject {
    private(set) var isConnected = false
    private(set) var isScanning = false

    /// True once we're connected AND the writeable characteristics have been
    /// discovered. Use this for any UI gate that depends on actually being
    /// able to write to the goggle — `isConnected` alone is true for the
    /// sub-second window between `didConnect` and `didDiscoverCharacteristics`,
    /// during which `write()` would fail with "characteristic not ready".
    var isReady: Bool {
        isConnected
            && characteristics[osdControlUUID] != nil
            && characteristics[osdTextUUID] != nil
    }

    private(set) var discoveredDevices: [CBPeripheral] = []
    /// Local name captured from advertisement / scan response, keyed by
    /// peripheral identifier. Solves the "Unknown" first-pairing flicker:
    /// while iOS has no cached GAP 0x2A00 device name for this peripheral,
    /// `peripheral.name` is nil during scan because the firmware's BLE
    /// library auto-spills the local name into the scan response (the
    /// 128-bit service UUID consumes most of the 31-byte primary adv
    /// slot — see `firmware/include/ble_service.h::ble_init`; if that
    /// ever switches to a 16-bit UUID this iOS-side mitigation can be
    /// dropped). The scan response *is* delivered in `advertisementData`,
    /// so we capture it here and let the UI prefer this over
    /// `peripheral.name`. Load-bearing whenever iOS lacks a cached GAP
    /// name — typically the first pairing per app install, but also
    /// after a Bluetooth cache reset, OS BT toggle, or "Forget This
    /// Device".
    private(set) var advertisedNames: [UUID: String] = [:]
    private(set) var connectedDeviceName: String?
    /// Current advertised BLE name as reported by the firmware's
    /// CHR_DEVICE_NAME read. Populated by the post-connect read kicked
    /// off in `didDiscoverCharacteristicsFor`. Distinct from
    /// `connectedDeviceName` (which is the cached `peripheral.name` /
    /// scan-response local name CoreBluetooth surfaces during scan):
    /// this one is the *firmware's* current truth, including a freshly
    /// applied rename that hasn't yet propagated to the iOS scan cache.
    /// Drives the rename UI's initial text-field value.
    private(set) var currentDeviceName: String?
    /// Identifier of the currently-connected peripheral, if any.
    /// Lets the UI deduplicate the discovered-devices list against the
    /// active connection without exposing the full `CBPeripheral`.
    var connectedIdentifier: UUID? { connectedPeripheral?.identifier }
    private(set) var currentUID: [UInt8]?
    /// Last UID seen from a live status frame, persisted to UserDefaults
    /// so the Settings root can show it across app launches before a BLE
    /// reconnect lands. Distinct from `currentUID` (which is `nil` while
    /// disconnected) so callers needing live truth — pairing flow,
    /// rollback baseline, current-UID-section gating — keep those
    /// semantics. Best-effort cache; UserDefaults write failures (disk
    /// full, sandbox revocation) surface as a regression to "—" on the
    /// next launch but never block the in-memory copy.
    ///
    /// Clearing policy:
    /// - User-tapped `disconnect()` clears the stash explicitly so a
    ///   stash from the prior M5Stick doesn't display after the user
    ///   swaps devices.
    /// - A short / malformed status frame (firmware/app version skew)
    ///   also clears it — the stash would otherwise contradict the
    ///   error banner that announces the schema mismatch.
    /// - Involuntary disconnects (range / sleep / OS BT toggle) do
    ///   *not* clear the stash. The whole point of persistence is to
    ///   survive those drops so the operator sees the remembered UID
    ///   on next launch before BLE reconnects.
    private(set) var lastKnownUID: [UInt8]?
    private static let lastKnownUIDKey = "lastKnownUID"
    /// Latest Test OSD outcome from the firmware status notify.
    /// Encodes the `g_last_test_result` byte:
    ///   .none      = no test result yet (or the firmware byte was 0)
    ///   .ok        = ESP-NOW MAC layer ack'd every test packet
    ///   .lost      = at least one test packet was not delivered
    ///
    /// Bumped each time a fresh status frame *carrying a real test
    /// result* arrives. Drives the auto-test+rollback workflow in
    /// `PairingSettingsView` — that view tracks a sequence number from
    /// `testResultRevision` so it can ignore stale frames that arrived
    /// before its own pairing attempt.
    ///
    /// Disconnect frames (byte 0 == 0) are deliberately skipped: the
    /// firmware reuses `g_last_test_result` rather than clearing it on
    /// disconnect, so a disconnect-during-verify would otherwise replay
    /// a stale `.ok` and falsely report success on the next attempt.
    enum TestResult: UInt8 { case none = 0, ok = 1, lost = 2 }
    private(set) var lastTestResult: TestResult = .none
    private(set) var testResultRevision: UInt32 = 0
    /// Reset by `PairingSettingsView` immediately before sending its
    /// verify probe so the loop can wait on `lastTestResult != .none`
    /// (i.e. "an actual test result has landed") rather than just on
    /// the revision counter — which can advance from any status frame
    /// the firmware fires for an unrelated reason.
    func clearTestResult() {
        lastTestResult = .none
    }
    /// UID we displaced on the most recent Apply attempt. Survives the
    /// Settings sheet being dismissed (which is why it lives here, not
    /// on the view) so the user can return to the sheet later and still
    /// tap Restore — even after a *successful* pairing, since "go back
    /// to my old goggle" is a real workflow.
    ///
    /// Replaced on every Apply attempt that has a known `currentUID` to
    /// displace; if `currentUID` is nil at Apply time, the prior stash is
    /// explicitly cleared instead so a UID from an earlier session can't
    /// be applied to the wrong M5Stick. Cleared by Restore taps and by
    /// the auto-rollback path inside `runPairingFlow` *only* when the
    /// rollback BLE write actually queued — failed dispatches keep the
    /// stash so the user can retry. Also cleared on intentional teardown
    /// (user disconnect, discovery failure, connect failure): those
    /// signal "different goggle next time, don't apply the previous
    /// one's UID by accident".
    private(set) var previousUID: [UInt8]?
    /// Most recently captured TX UID from a sniff session. Set when the
    /// firmware notifies via CHR_TX_SNIFF_UUID. Cleared on disconnect so
    /// a stale capture from a prior session can't be applied to the next M5Stick.
    private(set) var capturedTXUID: [UInt8]?
    /// Battery state pushed from the M5Stick over `batteryUUID`. Cleared on
    /// disconnect / teardown / notify error so a stale "85%" can't linger
    /// after the link drops. `batteryPercent == nil` is also the firmware's
    /// "unknown" wire-format sentinel (0xFF).
    ///
    /// On the wire, the charging bit and the alarm-tier bits are
    /// independent. Firmware policy in `battery_monitor.h::tick` enforces
    /// `charging → tier == None`, so in practice these never co-occur.
    /// Anything in this app that assumes "charging beats alarm" should
    /// be revisited if the firmware policy changes.
    ///
    /// `silenced` lives on the alarm cases as an associated value so the
    /// previously-legal `silenced && alarm == .none` state is unrepresentable
    /// — the firmware tier transitions (LOW → CRITICAL escalate, either →
    /// NONE recovery) re-arm beeps by collapsing back to `.none` / a new
    /// case with `silenced: false`, which the wire format already encodes.
    enum BatteryAlarm: Equatable {
        case none
        case low(silenced: Bool)
        case critical(silenced: Bool)

        /// Wire-format → enum decoder. Centralised here so the
        /// "silenced bit is dropped when tier==None" invariant lives
        /// next to the type definition rather than in a BLE callback.
        /// Bit layout: bit1 LOW, bit2 CRITICAL, bit3 silenced.
        /// Critical strictly dominates Low if both bits are set.
        init(flags: UInt8) {
            let silenced = (flags & 0x08) != 0
            if (flags & 0x04) != 0 {
                self = .critical(silenced: silenced)
            } else if (flags & 0x02) != 0 {
                self = .low(silenced: silenced)
            } else {
                self = .none
            }
        }
    }
    private(set) var batteryPercent: UInt8?
    private(set) var isCharging = false
    private(set) var batteryAlarm: BatteryAlarm = .none

    /// Raw last NOTIFY from flight-battery telemetry (10-byte v1 frame).
    private(set) var lastFlightBatteryWire: Data?
    private(set) var flightBatteryNotifyRevision: UInt32 = 0
    private(set) var flightBatteryVoltageDv: Int?
    private(set) var flightBatteryCurrentDa: Int?
    private(set) var flightBatteryConsumedMah: Int?
    private(set) var flightBatteryRemainingPercent: Int?
    /// Wall-clock timestamp of the most recent decoded flight-battery
    /// notify. `nil` until the first packet lands; cleared on disconnect.
    /// Used by the main-screen strip to distinguish LIVE / STALE / NO TX
    /// without needing a separate firmware-side "TX telemetry enabled"
    /// signal — if the radio's LUA telemetry switch is off, no decode
    /// ever happens and this stays nil.
    private(set) var lastFlightBatteryReceivedAt: Date?

    /// Firmware version string read once on connect from CHR_FW_VERSION.
    /// Format mirrors `git describe --tags --dirty --always`:
    ///   - tagged release commit:  `v1.0.0`
    ///   - post-tag dev commit:    `v1.0.0-12-gabc1234` (`-dirty` suffix
    ///                             when the tree had uncommitted changes)
    ///   - untagged dev commit:    `<short-sha>` or `<short-sha>-dirty`
    ///   - no-history fallback:    literal "unknown"
    /// `nil` until the firmware-version characteristic has been read.
    /// Cleared on disconnect / teardown so a stale version can't linger
    /// past the link drop and lie about the next M5Stick the user pairs.
    private(set) var firmwareVersion: String?
    /// Set on connect when `firmwareMajor(from:)` parses a real major
    /// integer from `firmwareVersion` AND it disagrees with the app's
    /// `CFBundleShortVersionString` major. Drives the
    /// `ConnectionSettingsView` warning row.
    ///
    /// Intentionally NOT triggered by an unparseable firmware version —
    /// dev builds, untagged commits (`<short-sha>`), and the no-history
    /// "unknown" fallback all skip the compare so dev/CI connects don't
    /// fire false positives. The `app/firmware both shipped from the
    /// same release tag` guarantee is what makes the major-version
    /// compare meaningful in the first place.
    private(set) var firmwareIncompatible = false

    /// True while the app has asked the firmware to listen for TX bind packets.
    /// Toggled locally on start/stop — firmware has no state echo.
    /// Intentionally preserved across auto-reconnects: the firmware recv
    /// callback survives BLE drops (only sniff_stop clears it), so both sides
    /// stay consistent without a reset. Cleared on user-initiated disconnect
    /// and tearDownConnection where firmware state is also discarded.
    private(set) var isTXSniffActive = false

    /// True while the Backpack Telemetry Debug subview has asked the
    /// firmware to capture all incoming ESP-NOW packets. Same locally-
    /// toggled-no-firmware-echo pattern as isTXSniffActive. Cleared on
    /// disconnect / teardown. Mutually exclusive with isTXSniffActive on
    /// the firmware side — the iOS view does not need to track the
    /// other state because the firmware silently preempts the loser.
    private(set) var isTelemetryDebugActive = false

    /// Rolling buffer of recently-captured backpack telemetry records,
    /// newest first. Capped at `telemetryDebugCapacity` so a long-running
    /// debug session can't grow @Observable state without bound. Cleared
    /// when the user starts a fresh session (so per-session counts are
    /// meaningful) and on disconnect / teardown.
    private(set) var telemetryDebugRecords: [BackpackTelemetryRecord] = []
    /// Total notifies received since the current session started. The
    /// firmware ring's dropped count is logged to serial on the device
    /// but not currently surfaced over BLE — the 20-byte notify payload
    /// is fully spent on packet data. If/when ring overflow shows up in
    /// real-world testing we can extend the wire format to include it.
    private(set) var telemetryDebugTotalSeen: UInt32 = 0

    /// Capacity for `telemetryDebugRecords`. ~200 lines covers several
    /// seconds of even a chatty ELRS link without overwhelming the
    /// SwiftUI list renderer or the @Observable diff cost.
    static let telemetryDebugCapacity = 200
    /// Recent errors, newest at index 0. Capped at `errorLogCapacity`;
    /// overflows and consecutive-duplicate collapses both increment
    /// `droppedErrorCount`, which the UI surfaces as
    /// "N more queued (+M suppressed)" so either form of lost signal is
    /// visible rather than silent.
    private(set) var errorLog: [String] = []
    /// Count of errors that were suppressed — either trimmed by overflow
    /// or collapsed as a repeat of the current head. Sticky across
    /// `clearError()` calls so an ongoing error storm stays visible after
    /// the user drains the queue; only `clearAllErrors()` zeroes it.
    /// Named `droppedErrorCount` for legacy reasons; the user-visible
    /// label is "suppressed".
    private(set) var droppedErrorCount = 0

    /// Single-string view of the top of `errorLog` (newest entry).
    /// - Getter returns `errorLog.first`.
    /// - Setter with a non-nil String calls `recordError`.
    /// - Setter with `nil` is shorthand for `clearAllErrors()`.
    /// Prefer `clearError()` for user-dismissed banners (pops one); reserve
    /// `clearAllErrors()` for explicit "Clear all" UX actions.
    var lastError: String? {
        get { errorLog.first }
        set {
            if let newValue {
                recordError(newValue)
            } else {
                clearAllErrors()
            }
        }
    }

    private static let errorLogCapacity = 5
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    /// Suppresses iOS background auto-reconnect. Set by both `disconnect()`
    /// (user tapped Disconnect) and `tearDownConnection(_:)` (app-initiated
    /// abort after discovery failure). Consumed by `didDisconnectPeripheral`.
    private var suppressAutoReconnect = false
    /// Distinguishes "user actually tapped Disconnect" from other teardown
    /// sources. Used only by `centralManagerDidUpdateState` to decide
    /// whether to surface the BT-state banner — an app-initiated teardown
    /// has its own error message and shouldn't mask a concurrent BT-off.
    private var userTappedDisconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        // Restore the last UID we saw on a previous run so the Settings
        // root's "Goggle pairing" row can render the remembered value
        // immediately on launch, before a BLE reconnect populates the
        // live `currentUID`. Length-checked because Data of any other
        // size means a corrupted preference (older app version, manual
        // edit) and we'd rather show "—" than a malformed UID. This is
        // a display-only stash, so the unicast-MAC bit-0 invariant
        // (`uid[0] & 0x01 == 0`) isn't enforced here — if this ever
        // feeds a write path, normalize it first.
        //
        // Self-heal: a non-Data type or wrong-length Data would
        // otherwise re-fail on every launch with no recovery short of
        // deleting the app, so wipe the bad value and log it once.
        if let any = UserDefaults.standard.object(forKey: Self.lastKnownUIDKey) {
            if let saved = any as? Data, saved.count == 6 {
                lastKnownUID = Array(saved)
            } else {
                let kind = (any as? Data).map { "wrong length (\($0.count)B)" }
                    ?? "wrong type (\(type(of: any)))"
                print("BLE lastKnownUID restore: discarding persisted value — \(kind).")
                UserDefaults.standard.removeObject(forKey: Self.lastKnownUIDKey)
            }
        }
    }

    /// Dismiss the currently-displayed error. Other queued errors stay
    /// visible on the next tick so a burst isn't lost to one tap.
    /// `droppedErrorCount` stays sticky: an ongoing storm would otherwise
    /// look like a trickle once the user drains the queue. Use
    /// `clearAllErrors()` when the user explicitly wants to zero the log.
    func clearError() {
        guard !errorLog.isEmpty else { return }
        errorLog.removeFirst()
    }

    /// Wipe the whole log plus the dropped counter.
    func clearAllErrors() {
        errorLog.removeAll()
        droppedErrorCount = 0
    }

    private func recordError(_ message: String) {
        // `@MainActor` on the class handles Swift callers; this runtime
        // assertion catches @objc bridged entry via CBCentralManagerDelegate
        // if its dispatch queue is ever changed away from main (today it's
        // `queue: nil` which maps to the main queue).
        MainActor.assertIsolated()
        // Collapse consecutive identical errors so an error storm doesn't
        // flood the ring — but count the collapsed ones so the user can
        // still see "(+N dropped)" rather than a single error hiding many.
        if errorLog.first == message {
            droppedErrorCount += 1
            return
        }
        errorLog.insert(message, at: 0)
        let overflow = errorLog.count - Self.errorLogCapacity
        if overflow > 0 {
            errorLog.removeLast(overflow)
            droppedErrorCount += overflow
        }
    }

    func startScan() {
        switch centralManager.state {
        case .poweredOn:
            break
        case .poweredOff:
            lastError = "Bluetooth is off. Enable it in Control Center."
            return
        case .unauthorized:
            lastError = "Bluetooth permission denied. Open Settings → HDZap → Bluetooth."
            return
        case .unsupported:
            lastError = "This device doesn't support Bluetooth LE."
            return
        default:
            lastError = "Bluetooth not ready (state \(centralManager.state.rawValue))."
            return
        }
        discoveredDevices = []
        // Drop names from a prior scan so a peripheral that was renamed
        // out-of-band (rare, but possible if the firmware was reflashed
        // with a different `ble_init` name) can't keep its stale label.
        advertisedNames = [:]
        isScanning = true
        // `allowDuplicates: true` so we keep getting `didDiscover`
        // callbacks for the same peripheral — without it iOS only fires
        // the first one, and on first pairing that first event can land
        // before the scan response has been merged in (the local name
        // lives in the scan response, not the primary adv packet).
        // Allowing duplicates means the next event after the scan
        // response arrives will include the name and we update the map.
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        suppressAutoReconnect = false
        userTappedDisconnect = false
        connectedPeripheral = peripheral
        centralManager.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        suppressAutoReconnect = true
        userTappedDisconnect = true
        // Drop the rollback target — the next session is likely to talk to a
        // different M5Stick / goggle pair, and silently surfacing the prior
        // pair's UID as "Restore" would write the wrong value to the new one.
        previousUID = nil
        // Same reasoning: clear the persisted summary stash so the
        // Settings root doesn't keep parading the prior pair's UID
        // after the user has explicitly walked away from this device.
        lastKnownUID = nil
        UserDefaults.standard.removeObject(forKey: Self.lastKnownUIDKey)
        capturedTXUID = nil
        isTXSniffActive = false
        resetTelemetryDebugState()
        resetBatteryState()
        resetFirmwareVersion()
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Best-known display name for a discovered peripheral. Prefers the
    /// scan-response local name we captured during `didDiscover`, then
    /// the OS-cached GAP name on `CBPeripheral`, then nil. The UI layer
    /// owns the "Unknown" fallback so that decision stays in one place.
    func displayName(for peripheral: CBPeripheral) -> String? {
        if let name = advertisedNames[peripheral.identifier], !name.isEmpty {
            return name
        }
        return peripheral.name
    }

    /// Bind phrases share a 63-byte cap with the firmware so the MD5 input
    /// (and therefore the derived UID) is identical on both sides.
    static let maxBindPhraseBytes = 63

    /// Mark a UID as the rollback target. Call before sending a new UID
    /// config so a failed pairing can be reverted. Pass `nil` to clear —
    /// used by the manual Restore tap, the auto-rollback path inside
    /// `runPairingFlow`, and by Apply itself when no `currentUID` baseline
    /// exists yet.
    func recordPreviousUID(_ uid: [UInt8]?) {
        previousUID = uid
    }

    @discardableResult
    func sendUIDConfig(mode: UIDMode) -> Bool {
        var data = Data()
        switch mode {
        case .bindPhrase(let phrase):
            let bytes = Array(phrase.utf8)
            guard !bytes.isEmpty else {
                lastError = "Bind phrase is empty."
                return false
            }
            guard bytes.count <= Self.maxBindPhraseBytes else {
                lastError = "Bind phrase is \(bytes.count) bytes; max is \(Self.maxBindPhraseBytes)."
                return false
            }
            data.append(0x01)
            data.append(contentsOf: bytes)
        case .manualUID(let uid):
            guard uid.count == 6 else {
                lastError = "UID must be 6 bytes, got \(uid.count)."
                return false
            }
            data.append(0x02)
            data.append(contentsOf: uid)
        case .newPairing:
            data.append(0x03)
        }
        return write(data: data, to: uidConfigUUID)
    }

    @discardableResult
    func sendBindCommand() -> Bool {
        return write(data: Data([0x01]), to: bindCommandUUID)
    }

    /// Send a single OSD row. Firmware writeStrings just this row plus
    /// a draw, no clear — relies on the goggle keeping prior overlay
    /// content. Caller pre-pads `text` to a stable width per row so
    /// the centered position is invariant across updates (otherwise
    /// shorter text leaves the prior longer text's tail visible).
    /// `writeWithoutResponse` (matches `sendOSDRows`) so a 1 Hz TIME
    /// LEFT tick that lands right after a `sendMetricRows` burst still
    /// fits inside the firmware's 40 ms render-staging window — a
    /// `.withResponse` write here would add a ~30 ms ATT round-trip and
    /// push the TIME LEFT row past the window onto a separate render
    /// cycle, which the operator sees as the lap row settling first
    /// and TIME LEFT settling a beat later.
    @discardableResult
    func sendOSDRow(row: Int, text: String) -> Bool {
        guard (0..<4).contains(row) else {
            lastError = "OSD row \(row) out of range (0..3)."
            return false
        }
        var data = Data([UInt8(row)])
        data.append(Self.osdASCIIData(for: text))
        return writeWithoutResponse(data: data, to: osdTextUUID)
    }

    /// Send a batch of OSD rows without waiting for per-row BLE
    /// acknowledgement. All rows fire back-to-back so they arrive at the
    /// firmware within a single connection interval instead of serialising
    /// 30+ ms each. The firmware's render staging window collects them
    /// into one atomic ESP-NOW cycle.
    @discardableResult
    func sendOSDRows(_ rows: [(row: Int, text: String)]) -> Bool {
        for entry in rows {
            guard (0..<4).contains(entry.row) else {
                lastError = "OSD row \(entry.row) out of range (0..3)."
                return false
            }
            var data = Data([UInt8(entry.row)])
            data.append(Self.osdASCIIData(for: entry.text))
            guard writeWithoutResponse(data: data, to: osdTextUUID) else { return false }
        }
        return true
    }

    @discardableResult
    func sendOSDControl(command: OSDCommand) -> Bool {
        write(data: Data([command.rawValue]), to: osdControlUUID)
    }

    /// Push the OSD layout Y offset to the firmware. Single signed byte:
    /// rows to shift the 4-row block up from the bottom of the grid
    /// (0 = bottom-anchored default, negative = move up). Per-row
    /// alignment / show-hide are applied entirely on the iOS side via
    /// the existing OSD text path, so they don't ride this characteristic.
    ///
    /// `urgent`:
    /// - `false` (default, used by the editor's slider debounce):
    ///   write-without-response, same as `sendOSDRows`, so a drag's
    ///   layout writes don't each pay the ~30 ms ATT ack round-trip.
    ///   If a write does drop, the next debounced push or
    ///   state-transition flush re-sends the value.
    /// - `true` (state transitions: Ready ↔ Running ↔ Result, reconnect
    ///   replay): write-with-response. Pays the ATT ack cost so a busy
    ///   BLE outbound queue can't silently drop the offset right when
    ///   the goggle is about to render at the wrong base row, which
    ///   would also throw off the partial-update slot routing in the
    ///   following sendTimeLeftRow / sendMetricRows ticks.
    ///
    /// Optional on the firmware side (older builds without the
    /// characteristic just return false here without surfacing an error,
    /// since the layout setting is a UX-only feature, not a correctness
    /// requirement for laps).
    @discardableResult
    func sendOSDLayout(yOffset: Int, urgent: Bool = false) -> Bool {
        let clamped = max(-128, min(127, yOffset))
        let byte = UInt8(bitPattern: Int8(clamped))
        guard characteristics[osdLayoutUUID] != nil else {
            // Older firmware without CHR_OSD_LAYOUT: silently no-op so a
            // mixed app/firmware version doesn't spam the error log every
            // time the user touches a slider.
            return false
        }
        if urgent {
            return write(data: Data([byte]), to: osdLayoutUUID)
        }
        return writeWithoutResponse(data: Data([byte]), to: osdLayoutUUID)
    }

    /// True once the OSD layout characteristic has been discovered.
    /// Lets the layout-settings view show a hint when paired against
    /// older firmware that doesn't carry the new char.
    var supportsOSDLayout: Bool { characteristics[osdLayoutUUID] != nil }

    /// Rename the M5StickS3's advertised BLE name. Firmware persists to
    /// NVS and reboots — the connection drops for ~3 s and bonded iOS
    /// reconnects automatically with the new name in scan results.
    /// Trims leading/trailing whitespace and silently rejects empty /
    /// oversized inputs (returning `false`) — the rename view's `canSave`
    /// gate is the user-visible enforcement and shows byte-count
    /// feedback inline, so a duplicate `lastError` write here would only
    /// route the same UX through the global error banner.
    @discardableResult
    func sendDeviceName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(trimmed.utf8)
        guard !bytes.isEmpty, bytes.count <= bleDeviceNameMaxBytes else {
            return false
        }
        return write(data: bytes, to: deviceNameUUID)
    }

    /// True once the device-name characteristic has been discovered.
    /// Lets the rename UI hide itself when paired with older firmware
    /// that doesn't carry the new char, instead of surfacing a generic
    /// "characteristic not ready" error on tap.
    var supportsDeviceRename: Bool { characteristics[deviceNameUUID] != nil }

    @discardableResult
    func startTXSniff() -> Bool {
        let ok = write(data: Data([0x01]), to: txSniffUUID)
        if ok {
            isTXSniffActive = true
            // Firmware preempts telemetry sniff on a TX-sniff start
            // (one ESP-NOW recv-cb slot, see telemetry_sniff.h docstring).
            // Mirror that here so the iOS state doesn't lie about the
            // telemetry stream still being live after the preempt.
            isTelemetryDebugActive = false
        }
        return ok
    }

    @discardableResult
    func stopTXSniff() -> Bool {
        let ok = write(data: Data([0x00]), to: txSniffUUID)
        if ok { isTXSniffActive = false }
        return ok
    }

    func clearCapturedTXUID() {
        capturedTXUID = nil
    }

    /// Ask the firmware to start streaming every captured ESP-NOW packet
    /// over CHR_TELEMETRY_DEBUG_UUID. Wipes the local rolling log + per-
    /// session counters so the debug view starts each session from a
    /// clean slate; the firmware does the same on its side (see
    /// telemetry_sniff::telemetry_sniff_start). Mutually exclusive with
    /// TX sniff — the firmware preempts whichever was running.
    @discardableResult
    func startTelemetryDebug() -> Bool {
        let ok = write(data: Data([0x01]), to: telemetryDebugUUID)
        if ok {
            isTelemetryDebugActive = true
            // Mirror the firmware-side preempt: a telemetry-debug start
            // takes the recv-cb slot away from TX sniff. Without this
            // mirror, the Settings TX UID Capture row would keep
            // showing the spinner while the firmware has already
            // dropped the listener.
            isTXSniffActive = false
            telemetryDebugRecords = []
            telemetryDebugTotalSeen = 0
        }
        return ok
    }

    @discardableResult
    func stopTelemetryDebug() -> Bool {
        let ok = write(data: Data([0x00]), to: telemetryDebugUUID)
        if ok { isTelemetryDebugActive = false }
        return ok
    }

    /// Wipe the local rolling log without touching the firmware sniffer.
    /// Used by the debug view's "Clear log" button so the operator can
    /// reset the visible window without restarting the capture.
    func clearTelemetryDebugLog() {
        telemetryDebugRecords = []
    }

    @discardableResult
    private func write(data: Data, to uuid: CBUUID) -> Bool {
        return write(data: data, to: uuid, type: .withResponse)
    }

    /// Write without waiting for ATT-layer acknowledgement. Used for bulk
    /// OSD rows where speed matters more than per-write confirmation —
    /// 4 rows fire back-to-back instead of serialising 30+ ms each.
    /// CoreBluetooth queues writes past `canSendWriteWithoutResponse`
    /// rather than dropping them in practice, and a 5-write burst
    /// (1 layout char + 4 rows) sits well inside the queue depth on
    /// every supported iOS version we ship to. A prior attempt to gate
    /// on `canSendWriteWithoutResponse` and fall back to write-with-
    /// response added a 30 ms ATT round-trip to every saturated write,
    /// turning the slider drag into a visibly laggy path. Atomicity-
    /// critical writes (state-transition layout char) opt into write-
    /// with-response via the `urgent` flag on `sendOSDLayout` instead.
    @discardableResult
    private func writeWithoutResponse(data: Data, to uuid: CBUUID) -> Bool {
        return write(data: data, to: uuid, type: .withoutResponse)
    }

    @discardableResult
    private func write(data: Data, to uuid: CBUUID, type: CBCharacteristicWriteType) -> Bool {
        guard let peripheral = connectedPeripheral else {
            lastError = "Not connected. Tap Scan and reconnect."
            return false
        }
        guard let characteristic = characteristics[uuid] else {
            lastError = "Characteristic not ready. Wait for discovery or reconnect."
            return false
        }
        peripheral.writeValue(data, for: characteristic, type: type)
        return true
    }

    private func resetBatteryState() {
        batteryPercent = nil
        isCharging = false
        batteryAlarm = .none
        resetFlightBatteryState()
    }

    private func resetFlightBatteryState() {
        lastFlightBatteryWire = nil
        flightBatteryNotifyRevision = 0
        flightBatteryVoltageDv = nil
        flightBatteryCurrentDa = nil
        flightBatteryConsumedMah = nil
        flightBatteryRemainingPercent = nil
        lastFlightBatteryReceivedAt = nil
    }

    /// Wipe all backpack-telemetry-debug state. Called on every teardown
    /// path (user disconnect, app-initiated tear, peripheral drop) so a
    /// stale capture window from a prior M5Stick can't surface against
    /// the next one.
    private func resetTelemetryDebugState() {
        isTelemetryDebugActive = false
        telemetryDebugRecords = []
        telemetryDebugTotalSeen = 0
    }

    private func resetFirmwareVersion() {
        firmwareVersion = nil
        firmwareIncompatible = false
    }

    /// Parse the leading `<major>` integer from a `git describe`-style
    /// version string. Returns `nil` for unparseable inputs (dev builds
    /// without a tag, "unknown", empty), which the caller treats as
    /// "skip the compatibility check".
    ///
    /// Accepts the optional leading `v` prefix the release flow uses
    /// (`v1.0.0`, `v1.0.0-12-gabc1234`, `v1.0.0-12-gabc1234-dirty`).
    /// Splitting on the first `.` rejects bare integers / short SHAs
    /// that happen to start with digits — `git describe` always emits
    /// either `<sha>` (no dot, not a real version) or `vX.Y.Z[...]`.
    static func firmwareMajor(from version: String) -> Int? {
        var s = Substring(version)
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int(parts[0]) else { return nil }
        return n
    }

    /// App's `CFBundleShortVersionString` (== MARKETING_VERSION, set in
    /// `app/project.yml`). `nil` if the bundle returned a malformed
    /// version string. Centralised so the firmware-compat check and the
    /// `ConnectionSettingsView` version row read it the same way.
    static func appVersionString() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Single source of truth for the mismatch-warning text used by
    /// every UI surface that flags `firmwareIncompatible`. Keeps the
    /// Settings root About row, the ConnectionSettingsView version
    /// row, and the recordError banner from drifting out of sync —
    /// SwiftUI treats the literal as a localization key, so a future
    /// edit on one site would silently break the others.
    static let firmwareMismatchSummary = String(
        localized: "Major version mismatch — update HDZap or reflash the M5StickS3."
    )

    /// Major component of `appVersionString()`. `nil` when the bundle
    /// version is missing or unparseable.
    static func appMajor() -> Int? {
        guard let v = appVersionString() else { return nil }
        return firmwareMajor(from: v)
    }

    private func evaluateFirmwareCompatibility() {
        guard let fwVersion = firmwareVersion,
              let fwMajor = Self.firmwareMajor(from: fwVersion),
              let appMajor = Self.appMajor() else {
            // Either side unparseable — don't fire a false-positive
            // warning on dev builds. UI still shows the raw fwVersion
            // string for diagnostics.
            firmwareIncompatible = false
            return
        }
        let mismatch = fwMajor != appMajor
        firmwareIncompatible = mismatch
        if mismatch {
            // Surface in the error log too so the user sees the warning
            // even if they aren't on the Connection settings screen.
            // recordError's consecutive-duplicate collapse keeps repeated
            // reconnects to the same firmware from spamming the queue.
            let appV = Self.appVersionString() ?? "?"
            lastError = "Firmware \(fwVersion) is from a different major version than this app (v\(appV)). Update one of them — features may not match."
        }
    }
    private static func osdASCIIData(for line: String) -> Data {
        let ascii = line.uppercased().unicodeScalars.map { scalar -> UInt8 in
            scalar.isASCII ? UInt8(scalar.value) : 63
        }
        return Data(ascii.prefix(RaceMetrics.osdRowMaxBytes))
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { return }
        isScanning = false
        // A mid-session state change (Bluetooth toggled off, permission
        // revoked, stack reset) leaves the cached peripheral stale —
        // CoreBluetooth needs cancelPeripheralConnection to keep its own
        // bookkeeping consistent, so route through tearDownConnection
        // instead of nil-ing the fields inline.
        guard isConnected, let peripheral = connectedPeripheral else { return }
        let wasUserTap = userTappedDisconnect
        tearDownConnection(peripheral)
        // Only a real user tap suppresses the state-change banner —
        // an app-initiated teardown (tearDownConnection from a discovery
        // failure) has its own error message but shouldn't mask a
        // concurrent BT-off event the user also needs to know about.
        if wasUserTap {
            // Consume the flag here so a later state change that isn't
            // user-initiated (e.g. BT toggled off during a subsequent
            // auto-reconnected session) doesn't inherit the suppression.
            userTappedDisconnect = false
            return
        }
        switch central.state {
        case .poweredOff:
            lastError = "Bluetooth turned off mid-session. Laps are not reaching the goggle — enable Bluetooth and tap Scan."
        case .unauthorized:
            lastError = "Bluetooth permission revoked. Re-grant in Settings → HDZap → Bluetooth."
        case .resetting:
            lastError = "Bluetooth stack resetting. Wait a moment, then tap Scan."
        case .unsupported:
            lastError = "This device no longer reports Bluetooth LE support."
        default:
            lastError = "Bluetooth unavailable (state \(central.state.rawValue))."
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredDevices.append(peripheral)
        }
        // Local name lives in the firmware's scan response — capture it
        // so the discovered-devices row can show "HDZeroOSD" instead of
        // "Unknown" before the first connect. Only update on a real
        // change so the @Observable storage doesn't churn the UI on
        // every duplicate scan tick.
        if let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           advertisedNames[peripheral.identifier] != name {
            advertisedNames[peripheral.identifier] = name
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        // Clean slate for the intent flags on every successful connection,
        // regardless of which path (explicit connect() or iOS auto-reconnect
        // after an unexpected drop) got us here.
        suppressAutoReconnect = false
        userTappedDisconnect = false
        // `displayName(for:)` returns the captured scan-response local
        // name when present, otherwise the OS-cached GAP name, otherwise
        // nil. The trailing `??` adds a short identifier prefix so the
        // UI shows *something* rather than implying there's no active
        // connection — `peripheral.name` can still be nil at didConnect
        // on a first pairing, before iOS has resolved the GAP name.
        connectedDeviceName = displayName(for: peripheral)
            ?? "Device \(peripheral.identifier.uuidString.prefix(8))"
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedPeripheral = nil
        connectedDeviceName = nil
        // Clear the disconnect-intent flags so the next connect() starts
        // from a clean slate — connect() already resets them, but making
        // it explicit here prevents stale flags leaking across sessions
        // if that reset path ever changes.
        suppressAutoReconnect = false
        userTappedDisconnect = false
        // The connection never came up, so any rollback target tied to the
        // previous goggle is meaningless — drop it before the user reaches
        // for it on the wrong M5Stick.
        previousUID = nil
        lastError = "Connection failed: \(error?.localizedDescription ?? "unknown"). Tap Scan to retry."
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        connectedDeviceName = nil
        // Drop the firmware-reported name on disconnect; the next reconnect
        // re-reads CHR_DEVICE_NAME and surfaces the current truth, which
        // matters across the rename-triggered reboot when the post-restart
        // peripheral may advertise a new name.
        currentDeviceName = nil
        characteristics = [:]
        // Drop battery state on every disconnect — a "47%" lingering after
        // the link is gone is misleading whether the next state is
        // suppressed (user tap) or auto-reconnect.
        resetBatteryState()
        // Same reasoning for firmware version: the next reconnect will
        // re-read it, and a stale string would otherwise contradict the
        // disconnected state shown in the UI.
        resetFirmwareVersion()
        if suppressAutoReconnect {
            suppressAutoReconnect = false
            userTappedDisconnect = false
            connectedPeripheral = nil
            return
        }
        // Auto-reconnect: iOS will retry indefinitely in the background.
        // Don't flash the user a red error for a drop we're about to recover
        // from; only surface the disconnect reason via serial-level logging.
        if let error {
            print("BLE auto-reconnecting after disconnect: \(error.localizedDescription)")
        }
        centralManager.connect(peripheral)
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            lastError = "Service discovery failed: \(error.localizedDescription)"
            tearDownConnection(peripheral)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            lastError = "ESP32 doesn't advertise expected service. Update firmware?"
            tearDownConnection(peripheral)
            return
        }
        peripheral.discoverCharacteristics([
            uidConfigUUID, bindCommandUUID, osdControlUUID, statusUUID,
            txSniffUUID, osdTextUUID, batteryUUID, deviceNameUUID, osdLayoutUUID,
            firmwareVersionUUID, telemetryDebugUUID, flightBatteryUUID,
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Only process the service we actually care about — a future added
        // service on the peripheral would otherwise false-positive below.
        guard service.uuid == serviceUUID else { return }
        if let error {
            lastError = "Characteristic discovery failed: \(error.localizedDescription)"
            tearDownConnection(peripheral)
            return
        }
        // nil and empty are both "no characteristics reported" — fold them
        // together so the verification block runs uniformly.
        let chars = service.characteristics ?? []
        for char in chars {
            characteristics[char.uuid] = char
            if char.uuid == statusUUID || char.uuid == txSniffUUID
                || char.uuid == batteryUUID || char.uuid == telemetryDebugUUID
                || char.uuid == flightBatteryUUID {
                peripheral.setNotifyValue(true, for: char)
            }
            // Battery is push-only from firmware: the connect-edge notify
            // fires before iOS has finished writing the CCCD, so the very
            // first frame is dropped and the row sits on "—" until the
            // next state-change poll (worst case never, on a stable
            // %/charging snapshot). An explicit one-shot read fills the
            // initial value from the characteristic's cached `setValue`,
            // independent of CCCD timing — `didUpdateValueFor` handles
            // both paths the same way.
            if char.uuid == batteryUUID || char.uuid == flightBatteryUUID {
                peripheral.readValue(for: char)
            }
            // Pull the current advertised name once on connect so the
            // rename UI can preselect it without a separate "fetch"
            // step. The firmware seeds this char's read value with its
            // boot-time name (`pDeviceName->setValue` in ble_init), so
            // the read serves directly from the cached attribute value
            // without a firmware-side onRead callback round-trip.
            if char.uuid == deviceNameUUID {
                peripheral.readValue(for: char)
            }
            // Firmware version is a constant for the running build (no
            // notify), so a single read is sufficient. The compatibility
            // warning fires from `didUpdateValueFor` once the value lands.
            if char.uuid == firmwareVersionUUID {
                peripheral.readValue(for: char)
            }
        }
        // Point out schema mismatch explicitly rather than letting the user
        // tap Apply/Bind/Lap and hit the generic "Characteristic not ready"
        // error on every write. Missing characteristics almost always mean
        // firmware/app version skew — surface that directly.
        // txSniffUUID and batteryUUID are intentionally excluded — both are
        // optional (older firmware won't advertise them) and their absence
        // doesn't block core functionality.
        let expected: [CBUUID] = [uidConfigUUID, bindCommandUUID, osdControlUUID, statusUUID, osdTextUUID]
        let missing = expected.filter { characteristics[$0] == nil }
        if !missing.isEmpty {
            let names = missing.map(characteristicName).joined(separator: ", ")
            lastError = "Firmware missing characteristics: \(names). Update firmware?"
            tearDownConnection(peripheral)
        }
    }

    /// Cancel the CB connection and zero the cached peripheral state.
    /// Called when we've surfaced an error that makes the current session
    /// unusable (wrong service, missing characteristics, discovery failure);
    /// leaving `isConnected = true` with an empty characteristics map would
    /// make every write fail with the generic "not ready" error.
    ///
    /// Sets `suppressAutoReconnect = true` so the upcoming
    /// `didDisconnectPeripheral` takes the early-return branch instead of
    /// triggering auto-reconnect — the flag does double duty as "user
    /// tapped Disconnect" (from `disconnect()`) and "internal teardown
    /// wants iOS not to retry" (from here). If that callback never fires
    /// (iOS can skip it when the peripheral was still in .connecting),
    /// the flag remains sticky until the next call to `connect(_:)`.
    private func tearDownConnection(_ peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
        isConnected = false
        connectedDeviceName = nil
        currentDeviceName = nil
        // Same reasoning as `disconnect()`: the next session will likely
        // be a different M5Stick / goggle, and a stale rollback UID would
        // be applied to the wrong device.
        previousUID = nil
        capturedTXUID = nil
        isTXSniffActive = false
        resetTelemetryDebugState()
        resetBatteryState()
        resetFirmwareVersion()
        connectedPeripheral = nil
        characteristics = [:]
        suppressAutoReconnect = true
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == txSniffUUID {
            if let error {
                lastError = "TX sniff subscribe failed: \(error.localizedDescription). TX UID capture will not work."
            }
            return
        }
        if characteristic.uuid == batteryUUID {
            if let error {
                resetBatteryState()
                lastError = "Battery subscribe failed: \(error.localizedDescription). Device battery state won't appear in-app."
            }
            return
        }
        if characteristic.uuid == telemetryDebugUUID {
            if let error {
                resetTelemetryDebugState()
                lastError = "Telemetry debug subscribe failed: \(error.localizedDescription). Backpack Telemetry Debug won't show packets."
            }
            return
        }
        if characteristic.uuid == flightBatteryUUID {
            if let error {
                resetFlightBatteryState()
                lastError = "Flight battery subscribe failed: \(error.localizedDescription). Flight battery state won't appear in-app."
            }
            return
        }
        // Gate on statusUUID so a future notify-on-another-characteristic
        // failure doesn't get misattributed as "Status subscribe failed".
        guard characteristic.uuid == statusUUID else { return }
        if let error {
            lastError = "Status subscribe failed: \(error.localizedDescription). Laps still send, but goggle state won't appear in-app."
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = formatBLEError(kind: "write failed", uuid: characteristic.uuid, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            // Notify error means we can't trust the last published status
            // frame any more — drop the derived fields so the UI doesn't
            // keep rendering values the firmware may have already changed.
            if characteristic.uuid == statusUUID {
                currentUID = nil
            }
            if characteristic.uuid == batteryUUID {
                resetBatteryState()
            }
            if characteristic.uuid == telemetryDebugUUID {
                resetTelemetryDebugState()
            }
            if characteristic.uuid == flightBatteryUUID {
                resetFlightBatteryState()
            }
            lastError = formatBLEError(kind: "notify error", uuid: characteristic.uuid, error: error)
            return
        }
        if characteristic.uuid == txSniffUUID {
            guard let data = characteristic.value, data.count == 6 else { return }
            capturedTXUID = Array(data)
            return
        }
        if characteristic.uuid == telemetryDebugUUID {
            guard let data = characteristic.value,
                  let record = BackpackTelemetryRecord(data: data) else {
                let n = characteristic.value?.count ?? 0
                lastError = "Telemetry debug frame unexpected size (\(n)B, expected 20). Firmware/app version mismatch?"
                return
            }
            telemetryDebugRecords.insert(record, at: 0)
            if telemetryDebugRecords.count > Self.telemetryDebugCapacity {
                telemetryDebugRecords.removeLast(
                    telemetryDebugRecords.count - Self.telemetryDebugCapacity)
            }
            telemetryDebugTotalSeen &+= 1
            return
        }
        if characteristic.uuid == deviceNameUUID {
            guard let data = characteristic.value else { return }
            guard let name = String(data: data, encoding: .utf8),
                  !name.isEmpty else {
                lastError = "Device name read returned undecodable bytes (\(data.count)B). Firmware/app version mismatch?"
                return
            }
            currentDeviceName = name
            connectedDeviceName = name
            if peripheral.identifier == connectedPeripheral?.identifier {
                advertisedNames[peripheral.identifier] = name
            }
            return
        }
        if characteristic.uuid == firmwareVersionUUID {
            guard let data = characteristic.value else { return }
            guard !data.isEmpty,
                  let v = String(data: data, encoding: .utf8) else {
                resetFirmwareVersion()
                lastError = "Firmware version frame malformed (\(data.count)B, non-UTF-8 or empty). Firmware/app version mismatch?"
                return
            }
            firmwareVersion = v
            evaluateFirmwareCompatibility()
            return
        }
        if characteristic.uuid == batteryUUID {
            // 2-byte payload: [percent | 0xFF unknown][flags: bit0 charging,
            // bit1 LOW, bit2 CRITICAL, bit3 silenced]. Tolerate an over-
            // length payload — only the first 2 bytes are defined; future
            // additions stay forward-compatible if we just ignore the tail.
            guard let data = characteristic.value, data.count >= 2 else {
                let n = characteristic.value?.count ?? 0
                resetBatteryState()
                lastError = "Battery frame unexpected size (\(n)B, expected ≥2). Firmware/app version mismatch?"
                return
            }
            let pct = data[0]
            let flags = data[1]
            batteryPercent = (pct == 0xFF) ? nil : pct
            isCharging = (flags & 0x01) != 0
            batteryAlarm = BatteryAlarm(flags: flags)

            // Forward-compat watchdog: bits 0-3 are the schema we know
            // (charging / LOW / CRITICAL / silenced). A future firmware
            // that assigns bit 4+ would otherwise be silently masked
            // off — surface via lastError so a TestFlight build paired
            // with newer firmware tells the user instead of lying.
            // Message intentionally omits the full flags byte: only
            // `unknownHex` is stable across the legitimate wire churn
            // (silenced toggles, tier transitions, charging edges), so
            // recordError's consecutive-duplicate collapse keeps the
            // log from filling with the same forward-compat warning
            // across an unrelated state-change run.
            let unknownBits = flags & ~UInt8(0x0F)
            if unknownBits != 0 {
                let unknownHex = String(unknownBits, radix: 16, uppercase: true)
                lastError = "Battery wire format has unknown bits 0x\(unknownHex). Firmware is newer than this build — update HDZap."
                #if DEBUG
                let flagsHex = String(flags, radix: 16, uppercase: true)
                print("Battery flags 0x\(flagsHex) unknown bits 0x\(unknownHex)")
                #endif
            }
            // `BatteryAlarm.init(flags:)` makes (silenced=1, tier=None)
            // unrepresentable on the iOS side, so this watchdog catches
            // wire-format violations only — i.e. firmware shipped
            // without the post-tier-transition silence reset (or with
            // a regressed `payload()` defensive clear). User-visible
            // symptom would be a stuck silenced indicator with no
            // active tier; surface so the cause isn't invisible.
            let silencedBit = (flags & 0x08) != 0
            let alarmBits = flags & 0x06
            if silencedBit && alarmBits == 0 {
                lastError = "Battery wire invariant violated: silenced=1 with tier=None. Firmware/app version mismatch?"
            }
            return
        }
        if characteristic.uuid == flightBatteryUUID {
            // Empty value = "no telemetry has been decoded yet on the
            // firmware side." Firmware doesn't seed g_flight_battery_chr
            // at boot (it only setValue's once a CRSF Battery frame
            // decodes), so the explicit readValue() we kick off in
            // didDiscoverCharacteristicsFor returns 0 bytes until the
            // first push lands. Most visible after a deep-sleep wake
            // before the bound TX has resumed sending telemetry. Stay
            // silent — this is the steady state, not a wire mismatch.
            guard let data = characteristic.value, !data.isEmpty else { return }
            guard let fields = RaceFlightBatterySample.decodeFieldsV1(data) else {
                resetFlightBatteryState()
                lastError = "Flight battery frame unexpected size/version (\(data.count)B). Firmware/app version mismatch?"
                return
            }
            lastFlightBatteryWire = data
            flightBatteryVoltageDv = fields.voltageDv
            flightBatteryCurrentDa = fields.currentDa
            flightBatteryConsumedMah = fields.consumedMah
            flightBatteryRemainingPercent = fields.remainingPercent
            lastFlightBatteryReceivedAt = Date()
            flightBatteryNotifyRevision &+= 1
            return
        }
        guard characteristic.uuid == statusUUID else { return }
        guard let data = characteristic.value, data.count >= 8 else {
            // Short frame points at firmware/app version skew — surface as
            // actionable error and invalidate the derived fields so the UI
            // doesn't keep showing a UID that no longer reflects the
            // firmware. Drop the persisted summary stash too: the
            // Settings root would otherwise keep rendering the prior
            // UID while the error banner contradicts it.
            let n = characteristic.value?.count ?? 0
            currentUID = nil
            lastKnownUID = nil
            UserDefaults.standard.removeObject(forKey: Self.lastKnownUIDKey)
            lastError = "Status frame unexpected size (\(n)B, expected ≥8). Firmware/app version mismatch?"
            return
        }
        // Frame layout depends on firmware version:
        //   8 bytes (current): [connected:u8][uid:6][test_result:u8]
        //                      → test_result at index 7
        //   9 bytes (legacy):  [connected:u8][uid:6][lap_count:u8][test_result:u8]
        //                      → test_result at index 8
        // Pinning byte 7 unconditionally would let an old-firmware
        // status frame's lap_count count as a test result and break
        // the pairing-flow auto-rollback (e.g. lap_count == 2 reads
        // as .lost and rolls back a successful pairing). Discriminate
        // on length instead.
        let uid = Array(data[1...6])
        currentUID = uid
        // Disconnect frame: firmware sends one final status update with
        // byte 0 = 0 just before tearing down the BLE link, but it
        // doesn't clear `g_last_test_result` first. Trusting the test
        // result byte here would replay a stale `.ok` (or `.lost`) and
        // poison the next pairing attempt's verify probe. We'll get a
        // CB didDisconnect callback shortly anyway.
        //
        // Sit *above* the `lastKnownUID` persist below so the goodbye
        // frame can't poison the persisted summary stash either —
        // matches the documented "byte 0 == 0 means don't trust this
        // frame" invariant for every derived field, not just
        // `lastTestResult`.
        guard data[0] != 0 else { return }
        // All-zeros sanity: a real paired UID is never 00:00:00:00:00:00
        // (firmware refuses to apply it in `applyStagedUid`). Treat as
        // transient garbage from the firmware's BSS-zero state pre-NVS-
        // load rather than ground truth — without this guard a too-
        // early status frame would persist zeros into UserDefaults and
        // the Settings root would render "0,0,0,0,0,0" forever.
        let isAllZero = !uid.contains { $0 != 0 }
        // Persist on UID change (cheap UserDefaults write; the
        // byte-equality guard skips the no-op steady-state writes). The
        // Settings root reads the stash on next launch before BLE
        // reconnects so the "Goggle pairing" row can show the
        // remembered value immediately.
        if !isAllZero, lastKnownUID != uid {
            lastKnownUID = uid
            UserDefaults.standard.set(Data(uid), forKey: Self.lastKnownUIDKey)
        }
        let testResultByte: UInt8 = data.count >= 9 ? data[8] : data[7]
        lastTestResult = TestResult(rawValue: testResultByte) ?? .none
        // Bump even when the encoded value matches — observers want to
        // know "a fresh frame landed" not "a different result".
        testResultRevision &+= 1
    }

    /// Composed error message that keeps the underlying NSError domain +
    /// code in the text. Matters primarily for CoreBluetooth errors
    /// (`CBError`, `CBATTError`): two distinct codes that share a
    /// `localizedDescription` would otherwise dedup into one row and mask
    /// a shifting failure mode. Pure Swift errors bridge too, though the
    /// resulting domain string (e.g. "HDZeroLapTimer.MyError") is cosmetic
    /// noise rather than useful signal.
    private func formatBLEError(kind: String, uuid: CBUUID, error: Error) -> String {
        let ns = error as NSError
        return "\(characteristicName(uuid)) \(kind): \(error.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    private func characteristicName(_ uuid: CBUUID) -> String {
        switch uuid {
        case uidConfigUUID: return "UID config"
        case bindCommandUUID: return "Bind"
        case osdControlUUID: return "OSD control"
        case statusUUID: return "Status"
        case txSniffUUID: return "TX sniff"
        case osdTextUUID: return "OSD text"
        case batteryUUID: return "Battery"
        case telemetryDebugUUID: return "Telemetry debug"
        case deviceNameUUID: return "Device name"
        case flightBatteryUUID: return "Flight battery"
        case firmwareVersionUUID: return "Firmware version"
        case osdLayoutUUID: return "OSD layout"
        default: return uuid.uuidString
        }
    }
}
