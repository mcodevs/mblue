import Foundation
import CoreBluetooth

/// CoreBluetooth wrapper for scanning + connecting to **BLE** peripherals on macOS.
///
/// CoreBluetooth on macOS will discover BLE peripherals that are advertising.
/// It does **not** provide a "classic Bluetooth device list" like System Settings.
final class BluetoothManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private enum NameSource: String {
    case advertisement
    case peripheral
    case resolvedAfterConnect
  }

  private enum ConnectionState: String {
    case idle
    case connecting
    case connected_unverified
    case connected_verified
    case disconnecting
    case disconnected
    case failed
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

    // Connection lifecycle (production-ish)
    var connectionState: ConnectionState = .idle
    var userInitiatedDisconnect: Bool = false
    var reconnectAttempt: Int = 0
    var pendingReconnectAfterAdapterOn: Bool = false
    var verifyTimer: Timer?
    var reconnectTimer: Timer?

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

  // Connection verification + reconnection config
  private let verifyTimeoutSeconds: TimeInterval = 6.0
  private let autoReconnectEnabled: Bool = true
  private let maxReconnectAttempts: Int = 5
  private let reconnectBaseDelayMs: Int = 600
  private let reconnectMaxDelayMs: Int = 30_000

  // Known devices persistence (identifier -> last known displayName)
  private let knownDevicesUserDefaultsKey = "mblue_known_devices_v1"
  private var knownDevices: [UUID: String] = [:]
  private var didAttemptAutoConnectKnownDevices: Bool = false

  // User control: if a user manually disconnects, we should not auto-reconnect or auto-connect on next launch
  // until they explicitly connect again.
  private let userDisconnectedUserDefaultsKey = "mblue_user_disconnected_v1"
  private var userDisconnectedDevices: Set<UUID> = []

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
    knownDevices = loadKnownDevicesFromUserDefaults()
    userDisconnectedDevices = loadUserDisconnectedFromUserDefaults()
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

  /// Snapshot of currently visible (named) devices as a single `deviceBatch` event.
  /// Useful when a Flutter listener attaches after some discoveries already happened.
  func visibleDeviceBatchSnapshotEvent() -> [String: Any] {
    let updated = deviceRecords.values
      .filter { !$0.isHidden && $0.displayName != nil }
      .sorted(by: { $0.id.uuidString < $1.id.uuidString })
      .map { $0.toMap() }
    return [
      "event": "deviceBatch",
      "updated": updated,
      "removed": []
    ]
  }

  /// Snapshot of current connection states (non-idle) as `connectionState` events.
  func connectionStateSnapshotEvents() -> [[String: Any]] {
    let now = nowMs()
    return deviceRecords.values
      .filter { !$0.isHidden && $0.displayName != nil && $0.connectionState != .idle }
      .sorted(by: { $0.id.uuidString < $1.id.uuidString })
      .map { record in
        [
          "event": "connectionState",
          "deviceId": record.id.uuidString.lowercased(),
          "state": record.connectionState.rawValue,
          "error": NSNull(),
          "reason": "snapshot",
          "timestampMs": now
        ]
      }
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

    // Reset connection/reconnect flags for a user-initiated connect.
    // If the user connects, it also re-enables auto-connect/reconnect for this device.
    if userDisconnectedDevices.contains(uuid) {
      userDisconnectedDevices.remove(uuid)
      saveUserDisconnectedToUserDefaults()
    }
    record.userInitiatedDisconnect = false
    record.pendingReconnectAfterAdapterOn = false
    record.reconnectAttempt = 0
    record.verifyTimer?.invalidate()
    record.verifyTimer = nil
    record.reconnectTimer?.invalidate()
    record.reconnectTimer = nil

    log("\(logTag) connect requested: \(normalizedDeviceId) displayName=\(record.displayName ?? "nil")")
    record.connectionState = .connecting
    emitConnectionState(
      deviceId: normalizedDeviceId,
      state: ConnectionState.connecting.rawValue,
      error: nil,
      reason: "userInitiated"
    )

    // If macOS already reports the peripheral connected, verify it via GATT.
    if peripheral.state == .connected {
      log("\(logTag) connect: already connected at OS level, verifying via GATT: \(normalizedDeviceId)")
      record.peripheral.delegate = self
      record.isConnected = true
      record.connectionState = .connected_unverified
      emitConnectionState(deviceId: normalizedDeviceId, state: ConnectionState.connected_unverified.rawValue, error: nil, reason: "alreadyConnected")
      startVerification(for: uuid)
      return nil
    }

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

    // User explicitly requested a disconnect => do NOT auto-reconnect.
    record.userInitiatedDisconnect = true
    userDisconnectedDevices.insert(uuid)
    saveUserDisconnectedToUserDefaults()
    record.pendingReconnectAfterAdapterOn = false
    record.reconnectAttempt = 0
    record.verifyTimer?.invalidate()
    record.verifyTimer = nil
    record.reconnectTimer?.invalidate()
    record.reconnectTimer = nil

    log("\(logTag) disconnect requested: \(normalizedDeviceId) displayName=\(record.displayName ?? "nil")")
    record.connectionState = .disconnecting
    emitConnectionState(
      deviceId: normalizedDeviceId,
      state: ConnectionState.disconnecting.rawValue,
      error: nil,
      reason: "userInitiated"
    )

    if peripheral.state == .disconnected {
      record.connectionState = .disconnected
      emitConnectionState(deviceId: normalizedDeviceId, state: ConnectionState.disconnected.rawValue, error: nil, reason: "alreadyDisconnected")
      record.userInitiatedDisconnect = false
      record.pendingReconnectAfterAdapterOn = false
      record.reconnectAttempt = 0
      return nil
    }

    central.cancelPeripheralConnection(peripheral)
    return nil
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    log("\(logTag) central state updated: \(adapterStateString)")
    emitAdapterState()

    // If Bluetooth became unavailable, stop scanning and transition active connections.
    if central.state != .poweredOn {
      stopScanInternal(reason: "bluetoothUnavailable")
      handleAdapterUnavailable()
      return
    }

    // Bluetooth powered on:
    // - start scanning if requested
    // - attempt auto-connect to known devices (once per app session)
    // - resume pending reconnects
    attemptAutoConnectKnownDevicesIfNeeded()
    resumePendingReconnectsIfNeeded()

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
    log("\(logTag) didConnect: \(deviceId) peripheral.name=\(peripheral.name ?? "nil")")

    let id = peripheral.identifier
    guard let record = deviceRecords[id] else {
      // Shouldn't happen if connect() was called on a known device, but handle defensively.
      return
    }

    // Cancel any pending reconnect/verify timers.
    record.reconnectTimer?.invalidate()
    record.reconnectTimer = nil
    record.verifyTimer?.invalidate()
    record.verifyTimer = nil
    record.pendingReconnectAfterAdapterOn = false

    // Update record + delegate
    record.peripheral = peripheral
    record.peripheral.delegate = self
    record.isConnected = true
    record.lastSeenMs = nowMs()

    // Mark as connected but not yet verified.
    record.connectionState = .connected_unverified
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.connected_unverified.rawValue,
      error: nil,
      reason: "didConnect"
    )

    // Post-connect validation: service discovery must succeed.
    // Only after didDiscoverServices (no error) do we mark connected_verified.
    record.verifyTimer = Timer.scheduledTimer(withTimeInterval: verifyTimeoutSeconds, repeats: false) { [weak self] _ in
      self?.handleVerificationTimeout(for: id)
    }
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    log("\(logTag) didFailToConnect: \(deviceId) error=\(String(describing: error))")

    let id = peripheral.identifier
    if let record = deviceRecords[id] {
      record.isConnected = false
      record.lastSeenMs = nowMs()
      record.verifyTimer?.invalidate()
      record.verifyTimer = nil
      record.connectionState = .failed
    }

    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.failed.rawValue,
      error: error?.localizedDescription ?? "Failed to connect.",
      reason: "didFailToConnect"
    )

    // Auto-reconnect on failures if not user-initiated.
    if let record = deviceRecords[id], autoReconnectEnabled, !record.userInitiatedDisconnect, record.displayName != nil {
      scheduleAutoReconnect(for: id, lastError: error?.localizedDescription ?? "Failed to connect.")
    }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    log("\(logTag) didDisconnect: \(deviceId) error=\(String(describing: error))")

    let id = peripheral.identifier
    guard let record = deviceRecords[id] else {
      emitConnectionState(deviceId: deviceId, state: ConnectionState.disconnected.rawValue, error: error?.localizedDescription)
      return
    }

    record.isConnected = false
    record.lastSeenMs = nowMs()
    record.verifyTimer?.invalidate()
    record.verifyTimer = nil

    // Determine whether this disconnect was user-initiated.
    if record.userInitiatedDisconnect {
      record.connectionState = .disconnected
      emitConnectionState(
        deviceId: deviceId,
        state: ConnectionState.disconnected.rawValue,
        error: nil,
        reason: "userInitiated"
      )
      record.userInitiatedDisconnect = false
      record.reconnectAttempt = 0
      record.pendingReconnectAfterAdapterOn = false
      return
    }

    // Unexpected disconnect (error may be nil). Auto-reconnect if enabled.
    record.connectionState = .disconnected
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.disconnected.rawValue,
      error: error?.localizedDescription,
      reason: "unexpectedDisconnect"
    )

    if autoReconnectEnabled, record.displayName != nil {
      scheduleAutoReconnect(for: id, lastError: error?.localizedDescription)
    }
  }

  // MARK: - CBPeripheralDelegate (post-connect verification)

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    let id = peripheral.identifier
    let deviceId = id.uuidString.lowercased()
    guard let record = deviceRecords[id] else { return }

    record.verifyTimer?.invalidate()
    record.verifyTimer = nil

    if let error = error {
      log("\(logTag) didDiscoverServices FAILED: \(deviceId) error=\(error.localizedDescription)")
      record.connectionState = .failed
      emitConnectionState(
        deviceId: deviceId,
        state: ConnectionState.failed.rawValue,
        error: error.localizedDescription,
        reason: "serviceDiscoveryFailed"
      )

      // Disconnect and attempt auto-reconnect (if allowed).
      central.cancelPeripheralConnection(peripheral)
      scheduleAutoReconnect(for: id, lastError: error.localizedDescription)
      return
    }

    guard peripheral.state == .connected else {
      log("\(logTag) didDiscoverServices but peripheral not connected: \(deviceId) state=\(peripheral.state.rawValue)")
      record.connectionState = .failed
      emitConnectionState(
        deviceId: deviceId,
        state: ConnectionState.failed.rawValue,
        error: "Peripheral is not connected.",
        reason: "notConnectedDuringVerification"
      )
      central.cancelPeripheralConnection(peripheral)
      scheduleAutoReconnect(for: id, lastError: "Peripheral is not connected.")
      return
    }

    // Verification success: at least one GATT operation (service discovery) succeeded.
    record.isConnected = true
    record.lastSeenMs = nowMs()
    record.connectionState = .connected_verified
    record.reconnectAttempt = 0
    record.pendingReconnectAfterAdapterOn = false

    if let displayName = record.displayName {
      knownDevices[id] = displayName
      saveKnownDevicesToUserDefaults()
    }
    if userDisconnectedDevices.contains(id) {
      userDisconnectedDevices.remove(id)
      saveUserDisconnectedToUserDefaults()
    }

    log("\(logTag) VERIFIED connected: \(deviceId) services=\(peripheral.services?.count ?? 0)")
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.connected_verified.rawValue,
      error: nil,
      reason: "servicesDiscovered"
    )

    // Optional additional verification signal: discover characteristics for one service.
    if let firstService = peripheral.services?.first {
      peripheral.discoverCharacteristics(nil, for: firstService)
    }

    // Optional: request RSSI to confirm ongoing link-level communication.
    peripheral.readRSSI()
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    let deviceId = peripheral.identifier.uuidString.lowercased()
    if let error = error {
      log("\(logTag) didDiscoverCharacteristics FAILED: \(deviceId) error=\(error.localizedDescription)")
      return
    }
    log("\(logTag) didDiscoverCharacteristics OK: \(deviceId) service=\(service.uuid.uuidString) chars=\(service.characteristics?.count ?? 0)")
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    let id = peripheral.identifier
    guard let record = deviceRecords[id] else { return }
    let deviceId = id.uuidString.lowercased()

    if let error = error {
      log("\(logTag) didReadRSSI FAILED: \(deviceId) error=\(error.localizedDescription)")
      return
    }

    let rssiInt = RSSI.intValue
    // 127 means unavailable
    if rssiInt == 127 { return }

    record.rssi = rssiInt
    record.lastSeenMs = nowMs()

    // Update visible device snapshot for the UI.
    if !record.isHidden, record.displayName != nil {
      pendingUpdatedDeviceIds.insert(id)
      scheduleScanBatchFlush()
    }
  }

  // MARK: - Internals

  private func startScanInternal(reason: String) {
    guard central.state == .poweredOn else { return }
    guard !isScanningInternal else {
      emitScanState(isScanning: true, reason: "alreadyScanning")
      return
    }

    // Note: we do NOT clear `deviceRecords` here.
    // Reasons:
    // - connected devices should remain stable/visible
    // - reconnect/verification state is tracked per record
    // Stale devices are cleaned up by the periodic stale eviction timer.

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

  // MARK: - Connection verification / reconnection

  private func startVerification(for id: UUID) {
    guard let record = deviceRecords[id] else { return }
    let deviceId = id.uuidString.lowercased()

    record.verifyTimer?.invalidate()
    record.verifyTimer = Timer.scheduledTimer(withTimeInterval: verifyTimeoutSeconds, repeats: false) { [weak self] _ in
      self?.handleVerificationTimeout(for: id)
    }

    log("\(logTag) discoverServices start: \(deviceId)")
    record.peripheral.discoverServices(nil)
  }

  private func handleVerificationTimeout(for id: UUID) {
    guard let record = deviceRecords[id] else { return }
    guard record.connectionState == .connected_unverified else { return }
    let deviceId = id.uuidString.lowercased()

    record.verifyTimer?.invalidate()
    record.verifyTimer = nil

    log("\(logTag) verify timeout: \(deviceId)")
    record.connectionState = .failed
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.failed.rawValue,
      error: "Service discovery timed out.",
      reason: "verificationTimeout"
    )

    // Treat as failed connection and disconnect; allow auto-reconnect.
    central.cancelPeripheralConnection(record.peripheral)

    if autoReconnectEnabled,
       record.displayName != nil,
       !userDisconnectedDevices.contains(id),
       !record.userInitiatedDisconnect {
      scheduleAutoReconnect(for: id, lastError: "Service discovery timed out.")
    }
  }

  private func scheduleAutoReconnect(for id: UUID, lastError: String?) {
    guard let record = deviceRecords[id] else { return }
    guard autoReconnectEnabled else { return }
    guard record.displayName != nil else { return }
    guard !userDisconnectedDevices.contains(id) else { return }
    guard !record.userInitiatedDisconnect else { return }
    // If we already have a pending reconnect timer, don't stack retries.
    if record.reconnectTimer != nil {
      return
    }

    // If the adapter isn't ready, wait until it becomes poweredOn again.
    guard central.state == .poweredOn else {
      record.pendingReconnectAfterAdapterOn = true
      emitConnectionState(
        deviceId: id.uuidString.lowercased(),
        state: ConnectionState.disconnected.rawValue,
        error: "Bluetooth unavailable.",
        reason: "adapterUnavailable"
      )
      return
    }

    let nextAttempt = record.reconnectAttempt + 1
    if nextAttempt > maxReconnectAttempts {
      record.reconnectAttempt = nextAttempt
      record.connectionState = .failed
      emitConnectionState(
        deviceId: id.uuidString.lowercased(),
        state: ConnectionState.failed.rawValue,
        error: "Exceeded max reconnect attempts (\(maxReconnectAttempts)).",
        reason: "maxRetriesExceeded",
        attempt: nextAttempt,
        maxAttempts: maxReconnectAttempts
      )
      return
    }

    record.reconnectAttempt = nextAttempt
    record.pendingReconnectAfterAdapterOn = false

    let delayMs = computeReconnectDelayMs(attempt: nextAttempt)
    let deviceId = id.uuidString.lowercased()
    log("\(logTag) schedule reconnect: \(deviceId) attempt=\(nextAttempt)/\(maxReconnectAttempts) in \(delayMs)ms")

    record.reconnectTimer?.invalidate()
    record.reconnectTimer = Timer.scheduledTimer(withTimeInterval: Double(delayMs) / 1000.0, repeats: false) { [weak self] _ in
      self?.startConnect(for: id, reason: "autoReconnect", attempt: nextAttempt, maxAttempts: self?.maxReconnectAttempts)
    }

    record.connectionState = .connecting
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.connecting.rawValue,
      error: lastError,
      reason: "autoReconnect",
      attempt: nextAttempt,
      maxAttempts: maxReconnectAttempts,
      nextDelayMs: delayMs
    )
  }

  private func startConnect(for id: UUID, reason: String, attempt: Int?, maxAttempts: Int?) {
    guard let record = deviceRecords[id] else { return }
    let deviceId = id.uuidString.lowercased()

    guard central.state == .poweredOn else {
      record.pendingReconnectAfterAdapterOn = true
      emitConnectionState(
        deviceId: deviceId,
        state: ConnectionState.disconnected.rawValue,
        error: "Bluetooth unavailable.",
        reason: "adapterUnavailable"
      )
      return
    }

    // Never connect to hidden/unnamed devices in this user-facing app.
    guard !record.isHidden, record.displayName != nil else { return }
    guard !userDisconnectedDevices.contains(id) else { return }

    record.userInitiatedDisconnect = false
    record.pendingReconnectAfterAdapterOn = false
    record.reconnectTimer?.invalidate()
    record.reconnectTimer = nil
    record.verifyTimer?.invalidate()
    record.verifyTimer = nil

    record.connectionState = .connecting
    emitConnectionState(
      deviceId: deviceId,
      state: ConnectionState.connecting.rawValue,
      error: nil,
      reason: reason,
      attempt: attempt,
      maxAttempts: maxAttempts
    )

    // If macOS already considers the peripheral connected, still verify via service discovery.
    if record.peripheral.state == .connected {
      log("\(logTag) startConnect: already connected at OS level, verifying via GATT: \(deviceId)")
      record.peripheral.delegate = self
      record.isConnected = true
      record.connectionState = .connected_unverified
      emitConnectionState(deviceId: deviceId, state: ConnectionState.connected_unverified.rawValue, error: nil, reason: "alreadyConnected")
      startVerification(for: id)
      return
    }

    log("\(logTag) startConnect: \(deviceId) reason=\(reason)")
    central.connect(record.peripheral, options: nil)
  }

  private func computeReconnectDelayMs(attempt: Int) -> Int {
    // Exponential backoff with jitter.
    // attempt=1 => base
    // attempt=2 => base*2
    // attempt=3 => base*4 ...
    let exp = max(0, attempt - 1)
    let multiplier = Int64(1) << min(exp, 10) // avoid overflow
    let base = min(Int64(reconnectMaxDelayMs), Int64(reconnectBaseDelayMs) * multiplier)
    let jitter = Double.random(in: -0.1 ... 0.1)
    let withJitter = Int64(Double(base) * (1.0 + jitter))
    return Int(max(0, min(Int64(reconnectMaxDelayMs), withJitter)))
  }

  private func handleAdapterUnavailable() {
    // Ensure UI never gets stuck in "Connected" when Bluetooth turns off.
    for (id, record) in deviceRecords {
      record.verifyTimer?.invalidate()
      record.verifyTimer = nil
      record.reconnectTimer?.invalidate()
      record.reconnectTimer = nil

      let wasActive =
        record.connectionState == .connecting ||
        record.connectionState == .connected_unverified ||
        record.connectionState == .connected_verified ||
        record.connectionState == .disconnecting

      if wasActive {
        record.isConnected = false
        record.connectionState = .disconnected
        record.pendingReconnectAfterAdapterOn =
          autoReconnectEnabled &&
          record.displayName != nil &&
          !userDisconnectedDevices.contains(id) &&
          !record.userInitiatedDisconnect

        emitConnectionState(
          deviceId: id.uuidString.lowercased(),
          state: ConnectionState.disconnected.rawValue,
          error: "Bluetooth unavailable.",
          reason: "adapterUnavailable"
        )
      }
    }
  }

  private func resumePendingReconnectsIfNeeded() {
    guard central.state == .poweredOn else { return }
    for (id, record) in deviceRecords where record.pendingReconnectAfterAdapterOn {
      guard autoReconnectEnabled else { continue }
      guard record.displayName != nil else { continue }
      guard !userDisconnectedDevices.contains(id) else { continue }
      guard !record.userInitiatedDisconnect else { continue }

      record.pendingReconnectAfterAdapterOn = false
      scheduleAutoReconnect(for: id, lastError: "Bluetooth restored.")
    }
  }

  private func attemptAutoConnectKnownDevicesIfNeeded() {
    guard central.state == .poweredOn else { return }
    guard !didAttemptAutoConnectKnownDevices else { return }
    didAttemptAutoConnectKnownDevices = true

    guard !knownDevices.isEmpty else { return }
    let identifiers = Array(knownDevices.keys)
    let peripherals = central.retrievePeripherals(withIdentifiers: identifiers)
    if peripherals.isEmpty {
      log("\(logTag) retrievePeripherals: no known peripherals available to auto-connect")
      return
    }

    let now = nowMs()
    for peripheral in peripherals {
      let id = peripheral.identifier
      let deviceId = id.uuidString.lowercased()

      let storedName = normalizeName(knownDevices[id])
      let pName = normalizeName(peripheral.name)
      let displayName = storedName ?? pName

      if let record = deviceRecords[id] {
        record.peripheral = peripheral
        record.lastSeenMs = now
        record.peripheralName = pName ?? record.peripheralName
        if record.displayName == nil, let displayName = displayName {
          record.displayName = displayName
          record.isHidden = false
          record.nameSource = .resolvedAfterConnect
        }
      } else {
        let record = DeviceRecord(
          id: id,
          peripheral: peripheral,
          advertisementName: nil,
          peripheralName: pName,
          displayName: displayName,
          isHidden: displayName == nil,
          nameSource: displayName == nil ? nil : .resolvedAfterConnect,
          rssi: nil,
          isConnectable: nil,
          isConnected: peripheral.state == .connected,
          lastSeenMs: now
        )
        deviceRecords[id] = record
      }

      // Surface known devices to the UI (they have a stable, user-identifiable name).
      if let record = deviceRecords[id], !record.isHidden, record.displayName != nil {
        pendingUpdatedDeviceIds.insert(id)
        scheduleScanBatchFlush()
      }

      // Auto-connect only if the user hasn't explicitly disconnected it.
      if userDisconnectedDevices.contains(id) {
        log("\(logTag) auto-connect skipped (user disconnected): \(deviceId)")
        continue
      }

      // If already connected, verify it; otherwise attempt connect.
      if let record = deviceRecords[id] {
        if record.peripheral.state == .connected {
          log("\(logTag) auto-connect: already connected, verifying: \(deviceId)")
          record.peripheral.delegate = self
          record.isConnected = true
          record.connectionState = .connected_unverified
          emitConnectionState(deviceId: deviceId, state: ConnectionState.connected_unverified.rawValue, error: nil, reason: "autoConnectAlreadyConnected")
          startVerification(for: id)
        } else if record.connectionState == .idle || record.connectionState == .disconnected || record.connectionState == .failed {
          log("\(logTag) auto-connect attempt: \(deviceId)")
          startConnect(for: id, reason: "autoConnectOnLaunch", attempt: nil, maxAttempts: nil)
        }
      }
    }
  }

  // MARK: - UserDefaults persistence

  private func loadKnownDevicesFromUserDefaults() -> [UUID: String] {
    guard let raw = UserDefaults.standard.dictionary(forKey: knownDevicesUserDefaultsKey) as? [String: String] else {
      return [:]
    }
    var result: [UUID: String] = [:]
    for (k, v) in raw {
      if let id = UUID(uuidString: k), let name = normalizeName(v) {
        result[id] = name
      }
    }
    return result
  }

  private func saveKnownDevicesToUserDefaults() {
    var raw: [String: String] = [:]
    for (id, name) in knownDevices {
      raw[id.uuidString.lowercased()] = name
    }
    UserDefaults.standard.set(raw, forKey: knownDevicesUserDefaultsKey)
  }

  private func loadUserDisconnectedFromUserDefaults() -> Set<UUID> {
    guard let raw = UserDefaults.standard.array(forKey: userDisconnectedUserDefaultsKey) as? [String] else {
      return []
    }
    return Set(raw.compactMap { UUID(uuidString: $0) })
  }

  private func saveUserDisconnectedToUserDefaults() {
    let raw = userDisconnectedDevices.map { $0.uuidString.lowercased() }.sorted()
    UserDefaults.standard.set(raw, forKey: userDisconnectedUserDefaultsKey)
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

  private func emitConnectionState(
    deviceId: String,
    state: String,
    error: String?,
    reason: String? = nil,
    attempt: Int? = nil,
    maxAttempts: Int? = nil,
    nextDelayMs: Int? = nil
  ) {
    var event: [String: Any] = [
      "event": "connectionState",
      "deviceId": deviceId,
      "state": state,
      "error": error ?? NSNull(),
      "timestampMs": nowMs()
    ]
    if let reason = reason { event["reason"] = reason }
    if let attempt = attempt { event["attempt"] = attempt }
    if let maxAttempts = maxAttempts { event["maxAttempts"] = maxAttempts }
    if let nextDelayMs = nextDelayMs { event["nextDelayMs"] = nextDelayMs }
    emitConnectionEvent(event)
  }

  private func log(_ message: String) {
    // Keep it simple; can be swapped for os_log if needed.
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    print("\(ts) \(message)")
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


