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

    final nameSource = map['nameSource'] is String
        ? MblueNameSource.fromString(map['nameSource'] as String)
        : null;

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
  disconnected,
  connecting,
  connected,
  disconnecting,
  failed;

  static MblueDeviceConnectionState fromString(String value) {
    switch (value) {
      case 'disconnected':
        return MblueDeviceConnectionState.disconnected;
      case 'connecting':
        return MblueDeviceConnectionState.connecting;
      case 'connected':
        return MblueDeviceConnectionState.connected;
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

  const MblueConnectionUpdate({required this.deviceId, required this.state, required this.error});

  factory MblueConnectionUpdate.fromMap(Map<String, dynamic> map) {
    // Expected event shape:
    // {
    //   "event": "connectionState",
    //   "deviceId": "...",
    //   "state": "connecting|connected|disconnected|disconnecting|failed",
    //   "error": String? | null
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
    );
  }
}
