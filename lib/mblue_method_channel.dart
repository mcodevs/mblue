import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mblue_platform_interface.dart';
import 'src/models.dart';

/// An implementation of [MbluePlatform] that uses method channels.
class MethodChannelMblue extends MbluePlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('mblue');

  static const EventChannel _scanEventChannel = EventChannel('mblue/scan');
  static const EventChannel _connectionEventChannel = EventChannel('mblue/connection');

  late final Stream<dynamic> _scanRawStream = _scanEventChannel.receiveBroadcastStream();
  late final Stream<dynamic> _connectionRawStream = _connectionEventChannel.receiveBroadcastStream();

  late final Stream<Map<String, dynamic>> _scanEventMaps = _scanRawStream
      .where((event) => event is Map)
      .map((event) => Map<String, dynamic>.from(event as Map));

  @override
  Stream<MblueScanUpdate> get scanUpdates => _scanEventMaps
      .where((map) => map['event'] == 'scanState')
      .map(MblueScanUpdate.fromMap);

  @override
  Stream<MblueDeviceBatchUpdate> get deviceBatchUpdates => _scanEventMaps.asyncExpand((map) async* {
        final event = map['event'];
        if (event == 'deviceBatch') {
          final batch = MblueDeviceBatchUpdate.fromMap(map);
          // Enforce filtering at the plugin layer too (defense in depth):
          // never surface unnamed/hidden devices to Flutter UI.
          final filteredUpdated = batch.updated
              .where((d) => !d.isHidden && (d.displayName?.trim().isNotEmpty ?? false))
              .toList(growable: false);
          yield MblueDeviceBatchUpdate(updated: filteredUpdated, removed: batch.removed);
          return;
        }
        // Backwards compatibility: treat a single discovery event as a batch with 1 update.
        if (event == 'deviceDiscovered') {
          final d = MblueDevice.fromMap(map);
          if (!d.isHidden && (d.displayName?.trim().isNotEmpty ?? false)) {
            yield MblueDeviceBatchUpdate(updated: [d], removed: const []);
          } else {
            yield const MblueDeviceBatchUpdate(updated: [], removed: []);
          }
          return;
        }
        // No-op for unrelated events.
      });

  @override
  Stream<MblueDevice> get discoveredDevices => deviceBatchUpdates.expand((batch) => batch.updated);

  @override
  Stream<MblueAdapterState> get adapterState => _connectionRawStream
      .where((event) => event is Map)
      .map((event) => Map<String, dynamic>.from(event as Map))
      .where((map) => map['event'] == 'adapterState')
      .map((map) => MblueAdapterState.fromString((map['state'] as String?) ?? 'unknown'));

  @override
  Stream<MblueConnectionUpdate> get connectionUpdates => _connectionRawStream
      .where((event) => event is Map)
      .map((event) => Map<String, dynamic>.from(event as Map))
      .where((map) => map['event'] == 'connectionState')
      .map(MblueConnectionUpdate.fromMap);

  @override
  Future<void> startScan({Duration? timeout}) async {
    await methodChannel.invokeMethod<void>('startScan', <String, dynamic>{
      if (timeout != null) 'timeoutMs': timeout.inMilliseconds,
    });
  }

  @override
  Future<void> stopScan() async {
    await methodChannel.invokeMethod<void>('stopScan');
  }

  @override
  Future<void> connect(String deviceId) async {
    await methodChannel.invokeMethod<void>('connect', <String, dynamic>{'deviceId': deviceId});
  }

  @override
  Future<void> disconnect(String deviceId) async {
    await methodChannel.invokeMethod<void>('disconnect', <String, dynamic>{'deviceId': deviceId});
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
