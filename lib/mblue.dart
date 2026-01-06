
import 'mblue_platform_interface.dart';
import 'src/models.dart';

export 'src/models.dart';

class Mblue {
  /// Scan lifecycle updates (started/stopped/timeout).
  Stream<MblueScanUpdate> get scanUpdates => MbluePlatform.instance.scanUpdates;

  /// Discovered devices while scanning.
  Stream<MblueDevice> get discoveredDevices =>
      MbluePlatform.instance.discoveredDevices;

  /// Batched scan diffs (updated devices + removed devices).
  Stream<MblueDeviceBatchUpdate> get deviceBatchUpdates =>
      MbluePlatform.instance.deviceBatchUpdates;

  /// System Bluetooth adapter state.
  Stream<MblueAdapterState> get adapterState =>
      MbluePlatform.instance.adapterState;

  /// Per-device connection state updates.
  Stream<MblueConnectionUpdate> get connectionUpdates =>
      MbluePlatform.instance.connectionUpdates;

  /// Start scanning for nearby BLE peripherals.
  ///
  /// If [timeout] is provided, scanning will automatically stop after it elapses.
  Future<void> startScan({Duration? timeout}) {
    return MbluePlatform.instance.startScan(timeout: timeout);
  }

  /// Stop scanning.
  Future<void> stopScan() {
    return MbluePlatform.instance.stopScan();
  }

  /// Connect to a previously discovered device by its `deviceId` (UUID string).
  Future<void> connect(String deviceId) {
    return MbluePlatform.instance.connect(deviceId);
  }

  /// Disconnect from a device by its `deviceId` (UUID string).
  Future<void> disconnect(String deviceId) {
    return MbluePlatform.instance.disconnect(deviceId);
  }

  Future<String?> getPlatformVersion() {
    return MbluePlatform.instance.getPlatformVersion();
  }
}
