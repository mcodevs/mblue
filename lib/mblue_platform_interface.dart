import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'mblue_method_channel.dart';
import 'src/models.dart';

abstract class MbluePlatform extends PlatformInterface {
  /// Constructs a MbluePlatform.
  MbluePlatform() : super(token: _token);

  static final Object _token = Object();

  static MbluePlatform _instance = MethodChannelMblue();

  /// The default instance of [MbluePlatform] to use.
  ///
  /// Defaults to [MethodChannelMblue].
  static MbluePlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [MbluePlatform] when
  /// they register themselves.
  static set instance(MbluePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Stream of scan lifecycle updates (started/stopped/timeout).
  Stream<MblueScanUpdate> get scanUpdates;

  /// Stream of devices discovered during scanning.
  Stream<MblueDevice> get discoveredDevices;

  /// Stream of batched scan diffs (updated devices + removed devices).
  ///
  /// Prefer this over [discoveredDevices] for UI updates to avoid rebuilding on
  /// every single advertisement callback.
  Stream<MblueDeviceBatchUpdate> get deviceBatchUpdates;

  /// Stream of adapter (system Bluetooth) state changes.
  Stream<MblueAdapterState> get adapterState;

  /// Stream of per-device connection state updates.
  Stream<MblueConnectionUpdate> get connectionUpdates;

  Future<void> startScan({Duration? timeout});

  Future<void> stopScan();

  Future<void> connect(String deviceId);

  Future<void> disconnect(String deviceId);

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
