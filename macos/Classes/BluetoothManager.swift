import Foundation
import CoreBluetooth

/// CoreBluetooth wrapper for scanning + connecting to **BLE** peripherals on macOS.
///
/// CoreBluetooth on macOS will discover BLE peripherals that are advertising.
/// It does **not** provide a "classic Bluetooth device list" like System Settings.
final class BluetoothManager: NSObject, CBCentralManagerDelegate {
  private enum NameSource: String {
    case advertisement
    case peripheral
    case resolvedAfterConnect
  }

  private final class DeviceRecord {
    let id: UUID
    var peripheral: CBPeripheral
    var advertisementName: String?
    var peripheralName: String?
    var displayName: String?
    var isHidden: Bool
    var nameSource: NameSource?
    var rssi: Int?
    var isConnectable: Bool?
    var isConnected: Bool
    var lastSeenMs: Int64

    init(
      id: UUID,
      peripheral: CBPeripheral,
      advertisementName: String?,
      peripheralName: String?,
      displayName: String?,
      isHidden: Bool,
      nameSource: NameSource?,
      rssi: Int?,
      isConnectable: Bool?,
      isConnected: Bool,
      lastSeenMs: Int64
    ) {
      self.id = id
      self.peripheral = peripheral
      self.advertisementName = advertisementName
      self.peripheralName = peripheralName
      self.displayName = displayName
      self.isHidden = isHidden
      self.nameSource = nameSource
      self.rssi = rssi
      self.isConnectable = isConnectable
      self.isConnected = isConnected
      self.lastSeenMs = lastSeenMs
    }

    func toMap() -> [String: Any] {
      return [
        "deviceId": id.uuidString.lowercased(),
        // New fields for user-facing filtering.
        "displayName": displayName ?? NSNull(),
        "isHidden": isHidden,
        "nameSource": nameSource?.rawValue ?? NSNull(),
        // Backwards compatibility: keep "name" as an alias.
        "name": displayName ?? NSNull(),
        "rssi": rssi ?? NSNull(),
        "isConnectable": isConnectable ?? NSNull(),
        "isConnected": isConnected,
        "lastSeenMs": lastSeenMs
      ]
    }
  }

  // MARK: - Callbacks (wired to Flutter EventChannels by the plugin)

  /// Sends scan events (deviceDiscovered / scanState).
  var onScanEvent: (([String: Any]) -> Void)?

  /// Sends connection events (adapterState / connectionState).
  var onConnectionEvent: (([String: Any]) -> Void)?

  // MARK: - State

  private let logTag = "[Bluetooth]"
  private var central: CBCentralManager!

  private var deviceRecords: [UUID: DeviceRecord] = [:]
  private var pendingUpdatedDeviceIds: Set<UUID> = []
  private var pendingRemovedDeviceIds: Set<UUID> = []

  /// Throttle scan events to avoid spamming Flutter with every advertisement callback.
  private let scanBatchIntervalSeconds: TimeInterval = 0.25
  private var scanBatchTimer: Timer?

  /// Stale devices cleanup.
  private let staleDeviceTimeoutMs: Int64 = 15_000
  private let cleanupIntervalSeconds: TimeInterval = 2.0
  private var cleanupTimer: Timer?

  private var isScanningInternal: Bool = false

  private var scanRequested: Bool = false
  private var requestedScanTimeoutMs: Int? = nil
  private var scanTimeoutTimer: Timer?

  override init() {
    super.init()
    // nil queue -> main queue callbacks (fine for a minimal demo).
    central = CBCentralManager(delegate: self, queue: nil)
  }

  // MARK: - Public helpers

  var adapterStateString: String {
    return BluetoothManager.adapterStateString(from: central.state)
  }

  var isScanning: Bool {
    return isScanningInternal
  }

  func startScan(timeoutMs: Int?) -> (code: String, message: String)? {
    scanRequested = true
    requestedScanTimeoutMs = timeoutMs

    switch central.state {
    case .poweredOn:
      startScanInternal(reason: "started")
      return nil
    case .unknown, .resetting:
      // Central isn't ready yet; we'll start scanning once it becomes poweredOn.
      log("\(logTag) startScan deferred (state=\(adapterStateString))")
      emitScanState(isScanning: false, reason: "waitingForPoweredOn")
      return nil
    case .poweredOff:
      return (code: "bluetooth_off", message: "Bluetooth is powered off.")
    case .unauthorized:
      return (code: "unauthorized", message: "Bluetooth permission is not granted.")
    case .unsupported:
      return (code: "unsupported", message: "Bluetooth is not supported on this Mac.")
    @unknown default:
      return (code: "unknown", message: "Unknown Bluetooth adapter state.")
    }
  }

  func stopScan(reason: String = "stopped") {
    scanRequested = false
    requestedScanTimeoutMs = nil
    stopScanInternal(reason: reason)
  }

  func connect(deviceId: String) -> (code: String, message: String)? {
    guard central.state == .poweredOn else {
      return (code: "bluetooth_unavailable", message: "Bluetooth is not powered on.")
    }
    guard let uuid = UUID(uuidString: deviceId) else {
      return (code: "invalid_device_id", message: "Invalid deviceId (expected UUID string).")
    }
    let normalizedDeviceId = uuid.uuidString.lowercased()
    guard let record = deviceRecords[uuid] else {
      return (code: "device_not_found", message: "Device not found. Scan first, then connect.")
    }
    // Safe default (user-facing app): never connect to unnamed/hidden devices.
    // Trade-off: some BLE peripherals never advertise a local name; those will be hidden.
    if record.isHidden || record.displayName == nil {
      return (code: "unnamed_device_hidden", message: "This device is hidden because it doesn't advertise a usable name.")
    }
    let peripheral = record.peripheral

    log("\(logTag) connect requested: \(normalizedDeviceId) name=\(peripheral.name ?? "nil")")
    emitConnectionState(deviceId: normalizedDeviceId, state: "connecting", error: nil)
    central.connect(peripheral, options: nil)
    return nil
  }

  func disconnect(deviceId: String) -> (code: String, message: String)? {
    guard let uuid = UUID(uuidString: deviceId) else {
      return (code: "invalid_device_id", message: "Invalid deviceId (expected UUID string).")
    }
    let normalizedDeviceId = uuid.uuidString.lowercased()
    guard let record = deviceRecords[uuid] else {
      return (code: "device_not_found", message: "Device not found.")
    }
    let peripheral = record.peripheral

    log("\(logTag) disconnect requested: \(normalizedDeviceId) name=\(peripheral.name ?? "nil")")
    emitConnectionState(deviceId: normalizedDeviceId, state: "disconnecting", error: nil)
    central.cancelPeripheralConnection(peripheral)
    return nil
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log("\(logTag) central state updated: \(adapterStateString)")
    emitAdapterState()

    // If Bluetooth became unavailable, stop scanning.
    if central.state != .poweredOn {
      stopScanInternal(reason: "bluetoothUnavailable")
      return
    }

    // If a scan was requested while state was unknown/resetting, start it now.
    if scanRequested {
      startScanInternal(reason: "started")
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    // CBCentralManager may call didDiscover very frequently (especially when allowing duplicates).
    // We deduplicate by the stable key: peripheral.identifier (UUID).
    let id = peripheral.identifier
    let now = nowMs()

    // Capture both advertised local name and peripheral.name.
    // Priority for display:
    // 1) Advertisement local name
    // 2) peripheral.name
    let advName = normalizeName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
    let pName = normalizeName(peripheral.name)
    let isConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool

    // RSSI may be 127 when unavailable.
    let rssiInt = RSSI.intValue
    let rssiValue: Int? = (rssiInt == 127) ? nil : rssiInt

    let connected = peripheral.state == .connected

    if let record = deviceRecords[id] {
      // Update-in-place.
      record.peripheral = peripheral
      record.lastSeenMs = now
      if let advName = advName { record.advertisementName = advName }
      if let pName = pName { record.peripheralName = pName }
      if let rssi = rssiValue {
        record.rssi = rssi
      }
      if let connectable = isConnectable {
        record.isConnectable = connectable
      }
      record.isConnected = connected

      // Re-resolve visibility + displayName using stored names (so name can appear later).
      let resolved = resolveDisplayName(advertisementName: record.advertisementName, peripheralName: record.peripheralName)
      record.displayName = resolved?.name
      record.nameSource = resolved?.source
      record.isHidden = (record.displayName == nil)
    } else {
      // New device. Keep it internally even if unnamed, but hide it from UI until it has a name.
      let resolved = resolveDisplayName(advertisementName: advName, peripheralName: pName)
      let displayName = resolved?.name
      let nameSource = resolved?.source
      let isHidden = (displayName == nil)
      let record = DeviceRecord(
        id: id,
        peripheral: peripheral,
        advertisementName: advName,
        peripheralName: pName,
        displayName: displayName,
        isHidden: isHidden,
        nameSource: nameSource,
        rssi: rssiValue,
        isConnectable: isConnectable,
        isConnected: connected,
        lastSeenMs: now
      )
      deviceRecords[id] = record
    }

    // Only surface devices that have a usable name.
    // Hidden devices remain internal and can be promoted later if a name appears.
    if let record = deviceRecords[id], !record.isHidden {
      pendingUpdatedDeviceIds.insert(id)
      scheduleScanBatchFlush()
    }

  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    log("\(logTag) connected: \(deviceId) name=\(peripheral.name ?? "nil")")

    // Update our device record too (name sometimes becomes available after connect).
    let id = peripheral.identifier
    if let record = deviceRecords[id] {
      record.peripheral = peripheral
      record.isConnected = true
      record.lastSeenMs = nowMs()

      // If a name becomes available after connect, we can promote a previously hidden device.
      let pName = normalizeName(peripheral.name)
      if let pName = pName { record.peripheralName = pName }

      if record.displayName == nil, let pName = pName {
        record.displayName = pName
        record.isHidden = false
        record.nameSource = .resolvedAfterConnect
      } else {
        // If we already have a displayName, keep the priority rule (advertisement > peripheral).
        let resolved = resolveDisplayName(advertisementName: record.advertisementName, peripheralName: record.peripheralName)
        record.displayName = resolved?.name
        record.nameSource = resolved?.source ?? record.nameSource
        record.isHidden = (record.displayName == nil)
      }

      if !record.isHidden {
        pendingUpdatedDeviceIds.insert(id)
        scheduleScanBatchFlush()
      }
    }

    emitConnectionState(deviceId: deviceId, state: "connected", error: nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    log("\(logTag) failed to connect: \(deviceId) error=\(String(describing: error))")

    let id = peripheral.identifier
    if let record = deviceRecords[id] {
      record.isConnected = false
      record.lastSeenMs = nowMs()
      pendingUpdatedDeviceIds.insert(id)
      scheduleScanBatchFlush()
    }

    emitConnectionState(
      deviceId: deviceId,
      state: "failed",
      error: error?.localizedDescription ?? "Failed to connect."
    )
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    log("\(logTag) disconnected: \(deviceId) error=\(String(describing: error))")

    let id = peripheral.identifier
    if let record = deviceRecords[id] {
      record.isConnected = false
      record.lastSeenMs = nowMs()
      pendingUpdatedDeviceIds.insert(id)
      scheduleScanBatchFlush()
    }

    emitConnectionState(
      deviceId: deviceId,
      state: "disconnected",
      error: error?.localizedDescription
    )
  }

  // MARK: - Internals

  private func startScanInternal(reason: String) {
    guard central.state == .poweredOn else { return }
    guard !isScanningInternal else {
      emitScanState(isScanning: true, reason: "alreadyScanning")
      return
    }

    // Start of a new scan session: clear previous discovery results to keep UI stable.
    if !deviceRecords.isEmpty {
      let removed = Array(deviceRecords.keys)
      deviceRecords.removeAll()
      pendingUpdatedDeviceIds.removeAll()
      pendingRemovedDeviceIds.formUnion(removed)
      scheduleScanBatchFlush()
    }

    // Reset timer.
    scanTimeoutTimer?.invalidate()
    scanTimeoutTimer = nil

    // Duplicates allow RSSI updates over time.
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )
    isScanningInternal = true
    emitScanState(isScanning: true, reason: reason)
    log("\(logTag) scanning started")

    startCleanupTimerIfNeeded()

    if let timeoutMs = requestedScanTimeoutMs, timeoutMs > 0 {
      scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Double(timeoutMs) / 1000.0, repeats: false) { [weak self] _ in
        guard let self = self else { return }
        self.stopScan(reason: "timeout")
      }
    }
  }

  private func stopScanInternal(reason: String) {
    scanTimeoutTimer?.invalidate()
    scanTimeoutTimer = nil
    scanBatchTimer?.invalidate()
    scanBatchTimer = nil
    stopCleanupTimer()

    guard isScanningInternal else {
      emitScanState(isScanning: false, reason: reason)
      return
    }

    central.stopScan()
    isScanningInternal = false
    emitScanState(isScanning: false, reason: reason)
    log("\(logTag) scanning stopped reason=\(reason)")
  }

  private func scheduleScanBatchFlush() {
    guard scanBatchTimer == nil else { return }
    scanBatchTimer = Timer.scheduledTimer(withTimeInterval: scanBatchIntervalSeconds, repeats: false) { [weak self] _ in
      guard let self = self else { return }
      self.scanBatchTimer?.invalidate()
      self.scanBatchTimer = nil
      self.flushScanBatch()
    }
  }

  private func flushScanBatch() {
    // Build a diff: updated devices + removed devices.
    if pendingUpdatedDeviceIds.isEmpty && pendingRemovedDeviceIds.isEmpty {
      return
    }

    var updated: [[String: Any]] = []
    // Stable ordering for easier debugging.
    for id in pendingUpdatedDeviceIds.sorted(by: { $0.uuidString < $1.uuidString }) {
      if let record = deviceRecords[id] {
        // Never surface unnamed devices.
        if !record.isHidden, record.displayName != nil {
          updated.append(record.toMap())
        }
      }
    }

    let removed = pendingRemovedDeviceIds.sorted(by: { $0.uuidString < $1.uuidString }).map { $0.uuidString.lowercased() }

    pendingUpdatedDeviceIds.removeAll()
    pendingRemovedDeviceIds.removeAll()

    emitScanEvent([
      "event": "deviceBatch",
      "updated": updated,
      "removed": removed
    ])
  }

  private func startCleanupTimerIfNeeded() {
    guard cleanupTimer == nil else { return }
    cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupIntervalSeconds, repeats: true) { [weak self] _ in
      self?.purgeStaleDevices()
    }
  }

  private func stopCleanupTimer() {
    cleanupTimer?.invalidate()
    cleanupTimer = nil
  }

  private func purgeStaleDevices() {
    guard !deviceRecords.isEmpty else { return }
    let now = nowMs()
    var idsToRemove: [UUID] = []

    for (id, record) in deviceRecords {
      // Do not evict connected devices (they may stop advertising).
      let connected = record.isConnected || record.peripheral.state == .connected
      if connected { continue }

      if now - record.lastSeenMs > staleDeviceTimeoutMs {
        idsToRemove.append(id)
      }
    }

    guard !idsToRemove.isEmpty else { return }

    for id in idsToRemove {
      deviceRecords[id] = nil
      pendingRemovedDeviceIds.insert(id)
    }

    if !pendingRemovedDeviceIds.isEmpty {
      scheduleScanBatchFlush()
    }
  }

  private func nowMs() -> Int64 {
    return Int64(Date().timeIntervalSince1970 * 1000.0)
  }

  private func normalizeName(_ raw: String?) -> String? {
    guard let raw = raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func resolveDisplayName(advertisementName: String?, peripheralName: String?) -> (name: String, source: NameSource)? {
    // Priority:
    // 1) Advertisement local name
    // 2) peripheral.name
    if let adv = normalizeName(advertisementName) {
      return (adv, .advertisement)
    }
    if let p = normalizeName(peripheralName) {
      return (p, .peripheral)
    }
    return nil
  }

  private func emitScanEvent(_ event: [String: Any]) {
    guard let cb = onScanEvent else { return }
    DispatchQueue.main.async {
      cb(event)
    }
  }

  private func emitScanState(isScanning: Bool, reason: String) {
    emitScanEvent([
      "event": "scanState",
      "isScanning": isScanning,
      "reason": reason
    ])
  }

  private func emitAdapterState() {
    emitConnectionEvent([
      "event": "adapterState",
      "state": adapterStateString
    ])
  }

  private func emitConnectionEvent(_ event: [String: Any]) {
    guard let cb = onConnectionEvent else { return }
    DispatchQueue.main.async {
      cb(event)
    }
  }

  private func emitConnectionState(deviceId: String, state: String, error: String?) {
    emitConnectionEvent([
      "event": "connectionState",
      "deviceId": deviceId,
      "state": state,
      "error": error ?? NSNull()
    ])
  }

  private func log(_ message: String) {
    // Keep it simple; can be swapped for os_log if needed.
    print(message)
  }

  private static func adapterStateString(from state: CBManagerState) -> String {
    switch state {
    case .unknown:
      return "unknown"
    case .resetting:
      return "resetting"
    case .unsupported:
      return "unsupported"
    case .unauthorized:
      return "unauthorized"
    case .poweredOff:
      return "poweredOff"
    case .poweredOn:
      return "poweredOn"
    @unknown default:
      return "unknown"
    }
  }
}


