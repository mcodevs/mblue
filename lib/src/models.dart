/// Minimal data models for the `mblue` macOS Bluetooth (BLE) plugin.
///
/// Notes:
/// - On macOS, CoreBluetooth primarily supports **BLE** peripherals.
/// - Some fields may be `null` if the system/peripheral doesn't provide them.
library;

enum MblueAdapterState {
  unknown,
  resetting,
  unsupported,
  unauthorized,
  poweredOff,
  poweredOn;

  static MblueAdapterState fromString(String value) {
    switch (value) {
      case 'unknown':
        return MblueAdapterState.unknown;
      case 'resetting':
        return MblueAdapterState.resetting;
      case 'unsupported':
        return MblueAdapterState.unsupported;
      case 'unauthorized':
        return MblueAdapterState.unauthorized;
      case 'poweredOff':
        return MblueAdapterState.poweredOff;
      case 'poweredOn':
        return MblueAdapterState.poweredOn;
      default:
        return MblueAdapterState.unknown;
    }
  }
}

enum MblueNameSource {
  advertisement,
  peripheral,
  resolvedAfterConnect;

  static MblueNameSource fromString(String value) {
    switch (value) {
      case 'advertisement':
        return MblueNameSource.advertisement;
      case 'peripheral':
        return MblueNameSource.peripheral;
      case 'resolvedAfterConnect':
        return MblueNameSource.resolvedAfterConnect;
      default:
        return MblueNameSource.peripheral;
    }
  }
}

class MblueDevice {
  final String id;

  /// User-facing name to display. If null, the device is considered hidden.
  final String? displayName;
  final bool isHidden;
  final MblueNameSource? nameSource;
  final int? rssi;
  final bool? isConnectable;
  final bool isConnected;
  final int lastSeenMs;

  const MblueDevice({
    required this.id,
    required this.displayName,
    required this.isHidden,
    required this.nameSource,
    required this.rssi,
    required this.isConnectable,
    required this.isConnected,
    required this.lastSeenMs,
  });

  @Deprecated('Use displayName')
  String? get name => displayName;

  DateTime get lastSeen => DateTime.fromMillisecondsSinceEpoch(lastSeenMs);

  factory MblueDevice.fromMap(Map<String, dynamic> map) {
    // Expected event shape (from native):
    // {
    //   "event": "deviceDiscovered",
    //   "deviceId": "...",
    //   "displayName": String? | null,
    //   "isHidden": bool,
    //   "nameSource": "advertisement|peripheral|resolvedAfterConnect",
    //   "rssi": int? | null,
    //   "isConnectable": bool? | null,
    //   "isConnected": bool,
    //   "lastSeenMs": int
    // }
    final deviceId = map['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) {
      throw FormatException('Invalid deviceId in event: $map');
    }

    // Backwards compatibility: some older events may use "name".
    final displayName = map['displayName'] is String
        ? map['displayName'] as String
        : (map['name'] is String ? map['name'] as String : null);

    final isHidden = map['isHidden'] is bool
        ? map['isHidden'] as bool
        : (displayName == null || displayName.trim().isEmpty);

    final nameSource = map['nameSource'] is String ? MblueNameSource.fromString(map['nameSource'] as String) : null;

    return MblueDevice(
      id: deviceId,
      displayName: (displayName != null && displayName.trim().isNotEmpty) ? displayName : null,
      isHidden: isHidden,
      nameSource: nameSource,
      rssi: map['rssi'] is int ? map['rssi'] as int : null,
      isConnectable: map['isConnectable'] is bool ? map['isConnectable'] as bool : null,
      isConnected: map['isConnected'] is bool ? map['isConnected'] as bool : false,
      lastSeenMs: map['lastSeenMs'] is int ? map['lastSeenMs'] as int : DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// A batched diff of scan results, emitted at a throttled interval.
///
/// This keeps Flutter UI stable by avoiding:
/// - emitting one event for every advertisement callback
/// - rebuilding lists on every RSSI update
class MblueDeviceBatchUpdate {
  final List<MblueDevice> updated;
  final List<String> removed;

  const MblueDeviceBatchUpdate({required this.updated, required this.removed});

  factory MblueDeviceBatchUpdate.fromMap(Map<String, dynamic> map) {
    // Expected event shape:
    // {
    //   "event": "deviceBatch",
    //   "updated": [ { device map }, ... ],
    //   "removed": [ "deviceId", ... ]
    // }
    final updatedRaw = map['updated'];
    final removedRaw = map['removed'];

    final updated = <MblueDevice>[];
    if (updatedRaw is List) {
      for (final item in updatedRaw) {
        if (item is Map) {
          updated.add(MblueDevice.fromMap(Map<String, dynamic>.from(item)));
        }
      }
    }

    final removed = <String>[];
    if (removedRaw is List) {
      for (final item in removedRaw) {
        if (item is String && item.isNotEmpty) {
          removed.add(item);
        }
      }
    }

    return MblueDeviceBatchUpdate(updated: updated, removed: removed);
  }
}

class MblueScanUpdate {
  final bool isScanning;
  final String? reason;

  const MblueScanUpdate({required this.isScanning, required this.reason});

  factory MblueScanUpdate.fromMap(Map<String, dynamic> map) {
    // Expected event shape:
    // {
    //   "event": "scanState",
    //   "isScanning": bool,
    //   "reason": String? | null
    // }
    return MblueScanUpdate(
      isScanning: map['isScanning'] is bool ? map['isScanning'] as bool : false,
      reason: map['reason'] is String ? map['reason'] as String : null,
    );
  }
}

enum MblueDeviceConnectionState {
  idle,
  connecting,
  connectedUnverified,
  connectedVerified,
  disconnecting,
  disconnected,
  failed;

  static MblueDeviceConnectionState fromString(String value) {
    switch (value) {
      case 'idle':
        return MblueDeviceConnectionState.idle;
      case 'connecting':
        return MblueDeviceConnectionState.connecting;
      case 'connected_unverified':
        return MblueDeviceConnectionState.connectedUnverified;
      case 'connected_verified':
        return MblueDeviceConnectionState.connectedVerified;
      // Backwards compatibility:
      case 'disconnected':
        return MblueDeviceConnectionState.disconnected;
      case 'connected':
        return MblueDeviceConnectionState.connectedVerified;
      case 'disconnecting':
        return MblueDeviceConnectionState.disconnecting;
      case 'failed':
        return MblueDeviceConnectionState.failed;
      default:
        return MblueDeviceConnectionState.failed;
    }
  }
}

class MblueConnectionUpdate {
  final String deviceId;
  final MblueDeviceConnectionState state;
  final String? error;
  final String? reason;
  final int? attempt;
  final int? maxAttempts;
  final int? nextDelayMs;
  final int? timestampMs;

  const MblueConnectionUpdate({
    required this.deviceId,
    required this.state,
    required this.error,
    required this.reason,
    required this.attempt,
    required this.maxAttempts,
    required this.nextDelayMs,
    required this.timestampMs,
  });

  factory MblueConnectionUpdate.fromMap(Map<String, dynamic> map) {
    // Expected event shape:
    // {
    //   "event": "connectionState",
    //   "deviceId": "...",
    //   "state": "idle|connecting|connected_unverified|connected_verified|disconnecting|disconnected|failed",
    //   "error": String? | null
    //   "reason": String? | null
    //   "attempt": int? | null
    //   "maxAttempts": int? | null
    //   "nextDelayMs": int? | null
    //   "timestampMs": int? | null
    // }
    final deviceId = map['deviceId'];
    final state = map['state'];
    if (deviceId is! String || deviceId.isEmpty || state is! String) {
      throw FormatException('Invalid connectionState event: $map');
    }
    return MblueConnectionUpdate(
      deviceId: deviceId,
      state: MblueDeviceConnectionState.fromString(state),
      error: map['error'] is String ? map['error'] as String : null,
      reason: map['reason'] is String ? map['reason'] as String : null,
      attempt: map['attempt'] is int ? map['attempt'] as int : null,
      maxAttempts: map['maxAttempts'] is int ? map['maxAttempts'] as int : null,
      nextDelayMs: map['nextDelayMs'] is int ? map['nextDelayMs'] as int : null,
      timestampMs: map['timestampMs'] is int ? map['timestampMs'] as int : null,
    );
  }
}
