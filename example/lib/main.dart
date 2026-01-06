import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mblue/mblue.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _mblue = Mblue();

  final Map<String, MblueDevice> _devicesById = <String, MblueDevice>{};
  final Map<String, MblueConnectionUpdate> _connById = <String, MblueConnectionUpdate>{};
  final Map<String, int> _firstSeenMsById = <String, int>{};
  final Set<String> _expandedDeviceIds = <String>{};

  MblueAdapterState _adapterState = MblueAdapterState.unknown;
  bool _isScanning = false;
  String? _status;

  StreamSubscription<MblueDeviceBatchUpdate>? _batchSub;
  StreamSubscription<MblueScanUpdate>? _scanSub;
  StreamSubscription<MblueAdapterState>? _adapterSub;
  StreamSubscription<MblueConnectionUpdate>? _connSub;

  @override
  void initState() {
    super.initState();

    _batchSub = _mblue.deviceBatchUpdates.listen(
      (batch) {
        setState(() {
          for (final d in batch.updated) {
            _devicesById[d.id] = d;
            _firstSeenMsById.putIfAbsent(d.id, () => d.lastSeenMs);
          }
          for (final id in batch.removed) {
            _devicesById.remove(id);
            _connById.remove(id);
            _firstSeenMsById.remove(id);
            _expandedDeviceIds.remove(id);
          }
        });
      },
      onError: (Object e) {
        setState(() {
          _status = 'Scan device batch error: $e';
        });
      },
    );

    _scanSub = _mblue.scanUpdates.listen(
      (update) {
        setState(() {
          _isScanning = update.isScanning;
          if (update.reason == 'timeout') {
            _status = 'Scan timed out.';
          } else if (update.reason == 'bluetoothUnavailable') {
            _status = 'Bluetooth unavailable.';
          }
        });
      },
      onError: (Object e) {
        setState(() {
          _status = 'Scan stream error: $e';
        });
      },
    );

    _adapterSub = _mblue.adapterState.listen(
      (state) {
        setState(() {
          _adapterState = state;
        });
      },
      onError: (Object e) {
        setState(() {
          _status = 'Adapter state stream error: $e';
        });
      },
    );

    _connSub = _mblue.connectionUpdates.listen(
      (update) {
        setState(() {
          _connById[update.deviceId] = update;
          // Avoid noisy global errors for transient reconnect attempts.
          if (update.state == MblueDeviceConnectionState.failed && update.error != null) {
            _status = 'Connection failed: ${update.error}';
          } else if (update.state == MblueDeviceConnectionState.connectedVerified) {
            // Clear old error banner once we have a verified connection.
            if (_status != null && _status!.startsWith('Connection')) {
              _status = null;
            }
          }
        });
      },
      onError: (Object e) {
        setState(() {
          _status = 'Connection stream error: $e';
        });
      },
    );
  }

  @override
  void dispose() {
    _batchSub?.cancel();
    _scanSub?.cancel();
    _adapterSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  Future<void> _toggleScan() async {
    setState(() {
      _status = null;
    });
    try {
      if (_isScanning) {
        await _mblue.stopScan();
      } else {
        // New scan session: clear UI state so users don't see stale results.
        setState(() {
          _devicesById.clear();
          _connById.clear();
          _firstSeenMsById.clear();
          _expandedDeviceIds.clear();
        });
        // Keep it simple: scan for 10 seconds by default.
        await _mblue.startScan(timeout: const Duration(seconds: 10));
      }
    } catch (e) {
      setState(() {
        _status = 'Scan failed: $e';
      });
    }
  }

  Future<void> _connect(String deviceId) async {
    setState(() {
      _status = null;
      _connById[deviceId] = MblueConnectionUpdate(
        deviceId: deviceId,
        state: MblueDeviceConnectionState.connecting,
        error: null,
        reason: 'userInitiated',
        attempt: null,
        maxAttempts: null,
        nextDelayMs: null,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    try {
      await _mblue.connect(deviceId);
    } catch (e) {
      setState(() {
        _status = 'Connect failed: $e';
        _connById[deviceId] = MblueConnectionUpdate(
          deviceId: deviceId,
          state: MblueDeviceConnectionState.failed,
          error: e.toString(),
          reason: 'connectCallFailed',
          attempt: null,
          maxAttempts: null,
          nextDelayMs: null,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        );
      });
    }
  }

  Future<void> _disconnect(String deviceId) async {
    setState(() {
      _status = null;
      _connById[deviceId] = MblueConnectionUpdate(
        deviceId: deviceId,
        state: MblueDeviceConnectionState.disconnecting,
        error: null,
        reason: 'userInitiated',
        attempt: null,
        maxAttempts: null,
        nextDelayMs: null,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
    });
    try {
      await _mblue.disconnect(deviceId);
    } catch (e) {
      setState(() {
        _status = 'Disconnect failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final adapter = _adapterState;
    final bool bluetoothReady = adapter == MblueAdapterState.poweredOn;
    final bool bluetoothOff = adapter == MblueAdapterState.poweredOff;
    final bool bluetoothUnauthorized = adapter == MblueAdapterState.unauthorized;
    final bool bluetoothUnsupported = adapter == MblueAdapterState.unsupported;

    // Stable ordering: keep discovery order (firstSeen) so the list doesn't jump as RSSI updates.
    final devices = _devicesById.values.toList()
      ..sort((a, b) {
        final aState = _effectiveConnectionState(a);
        final bState = _effectiveConnectionState(b);

        int rank(MblueDeviceConnectionState s) {
          if (s == MblueDeviceConnectionState.connectedVerified) return 0;
          if (s == MblueDeviceConnectionState.connectedUnverified) return 1;
          return 2;
        }

        final aRank = rank(aState);
        final bRank = rank(bState);
        if (aRank != bRank) return aRank.compareTo(bRank);

        final aFirst = _firstSeenMsById[a.id] ?? a.lastSeenMs;
        final bFirst = _firstSeenMsById[b.id] ?? b.lastSeenMs;
        return aFirst.compareTo(bFirst);
      });

    final theme = _buildTheme(Brightness.light);
    final darkTheme = _buildTheme(Brightness.dark);

    return MaterialApp(
      theme: theme,
      darkTheme: darkTheme,
      themeMode: ThemeMode.system,
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderRow(
                  title: 'Bluetooth Devices',
                  deviceCount: devices.length,
                  pill: _ScanStatePill(adapterState: adapter, isScanning: _isScanning),
                ),
                const SizedBox(height: 12),
                if (bluetoothOff || bluetoothUnauthorized || bluetoothUnsupported) ...[
                  _CalloutCard(
                    tone: _CalloutTone.warning,
                    title: bluetoothOff
                        ? 'Bluetooth is off'
                        : bluetoothUnauthorized
                        ? 'Bluetooth access not allowed'
                        : 'Bluetooth not supported',
                    message: bluetoothOff
                        ? 'Turn on Bluetooth in System Settings → Bluetooth, then try scanning again.'
                        : bluetoothUnauthorized
                        ? 'Allow Bluetooth access for this app in System Settings → Privacy & Security → Bluetooth.'
                        : 'This Mac does not support Bluetooth Low Energy scanning.',
                  ),
                  const SizedBox(height: 12),
                ],
                if (_status != null) ...[
                  _CalloutCard(tone: _CalloutTone.error, title: 'Something went wrong', message: _status!),
                  const SizedBox(height: 12),
                ],
                Row(
                  children: [
                    _PrimaryScanButton(enabled: bluetoothReady, isScanning: _isScanning, onPressed: _toggleScan),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Make sure your device is powered on and nearby.',
                        style: Theme.of(
                          context,
                        ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: devices.isEmpty
                        ? _EmptyState(
                            key: ValueKey<String>('empty:$bluetoothReady:$_isScanning'),
                            isScanning: _isScanning,
                            bluetoothReady: bluetoothReady,
                            onScanPressed: bluetoothReady ? _toggleScan : null,
                          )
                        : _DeviceList(
                            key: ValueKey<int>(devices.length),
                            devices: devices,
                            expandedDeviceIds: _expandedDeviceIds,
                            onToggleExpanded: (id) {
                              setState(() {
                                if (_expandedDeviceIds.contains(id)) {
                                  _expandedDeviceIds.remove(id);
                                } else {
                                  _expandedDeviceIds.add(id);
                                }
                              });
                            },
                            connectionUpdateById: _connById,
                            onConnect: _connect,
                            onDisconnect: _disconnect,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    // Calm, macOS-ish palette using a system-blue accent and neutral surfaces.
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0A84FF), brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: brightness == Brightness.light ? const Color(0xFFF5F5F7) : const Color(0xFF1C1C1E),
      dividerColor: brightness == Brightness.light ? const Color(0xFFD2D2D7) : const Color(0xFF3A3A3C),
      textTheme: Typography.material2021().black.apply(fontFamily: 'System'),
    );
  }

  MblueDeviceConnectionState _effectiveConnectionState(MblueDevice d) {
    final update = _connById[d.id];
    if (update != null) return update.state;
    return d.isConnected ? MblueDeviceConnectionState.connectedUnverified : MblueDeviceConnectionState.disconnected;
  }
}

enum _CalloutTone { warning, error }

class _CalloutCard extends StatelessWidget {
  final _CalloutTone tone;
  final String title;
  final String message;

  const _CalloutCard({required this.tone, required this.title, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bool isError = tone == _CalloutTone.error;
    final Color accent = isError ? const Color(0xFFFF3B30) : const Color(0xFFFF9F0A);
    final Color bg = accent.withOpacity(Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.12);

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withOpacity(0.25)),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isError ? Icons.error_outline : Icons.info_outline, color: accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.onSurface)),
                const SizedBox(height: 2),
                Text(message, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final String title;
  final int deviceCount;
  final Widget pill;

  const _HeaderRow({required this.title, required this.deviceCount, required this.pill});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                '$deviceCount device${deviceCount == 1 ? '' : 's'}',
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        pill,
      ],
    );
  }
}

class _ScanStatePill extends StatelessWidget {
  final MblueAdapterState adapterState;
  final bool isScanning;

  const _ScanStatePill({required this.adapterState, required this.isScanning});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;

    final String label;
    final IconData icon;
    final Color dot;

    if (adapterState == MblueAdapterState.poweredOff) {
      label = 'Bluetooth Off';
      icon = Icons.bluetooth_disabled;
      dot = const Color(0xFFFF3B30);
    } else if (adapterState == MblueAdapterState.unauthorized) {
      label = 'Not Allowed';
      icon = Icons.lock_outline;
      dot = const Color(0xFFFF3B30);
    } else if (adapterState == MblueAdapterState.unsupported) {
      label = 'Unsupported';
      icon = Icons.block;
      dot = const Color(0xFFFF3B30);
    } else if (isScanning) {
      label = 'Scanning';
      icon = Icons.radar;
      dot = const Color(0xFF0A84FF);
    } else {
      label = 'Paused';
      icon = Icons.pause_circle_outline;
      dot = const Color(0xFF8E8E93);
    }

    final Color bg = (brightness == Brightness.dark ? scheme.surfaceContainerHighest : Colors.white).withOpacity(0.95);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.7)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(color: dot),
          const SizedBox(width: 8),
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurface)),
          if (isScanning) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PrimaryScanButton extends StatelessWidget {
  final bool enabled;
  final bool isScanning;
  final VoidCallback onPressed;

  const _PrimaryScanButton({required this.enabled, required this.isScanning, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: Icon(isScanning ? Icons.stop_circle_outlined : Icons.search),
      label: Text(isScanning ? 'Stop scan' : 'Scan for devices'),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isScanning;
  final bool bluetoothReady;
  final VoidCallback? onScanPressed;

  const _EmptyState({super.key, required this.isScanning, required this.bluetoothReady, required this.onScanPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = !bluetoothReady
        ? 'Bluetooth isn’t available'
        : isScanning
        ? 'Looking for nearby devices…'
        : 'No named Bluetooth devices found nearby';
    final message = !bluetoothReady
        ? 'Enable Bluetooth to scan for devices.'
        : isScanning
        ? 'This can take a few seconds. Keep your device close and in pairing mode.'
        : 'Make sure your device is powered on, nearby, and advertising Bluetooth with a device name.';

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark ? scheme.surfaceContainerHighest : Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.7)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                bluetoothReady ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
                size: 44,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 10),
              Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              if (!isScanning) FilledButton(onPressed: onScanPressed, child: const Text('Scan for devices')),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  final List<MblueDevice> devices;
  final Set<String> expandedDeviceIds;
  final void Function(String deviceId) onToggleExpanded;
  final Map<String, MblueConnectionUpdate> connectionUpdateById;
  final void Function(String deviceId) onConnect;
  final void Function(String deviceId) onDisconnect;

  const _DeviceList({
    super.key,
    required this.devices,
    required this.expandedDeviceIds,
    required this.onToggleExpanded,
    required this.connectionUpdateById,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final surface = Theme.of(context).brightness == Brightness.dark ? scheme.surfaceContainerHighest : Colors.white;

    // Extra safety: UI should never show unnamed devices.
    final visibleDevices = devices.where((d) => d.displayName?.trim().isNotEmpty ?? false).toList(growable: false);

    return Container(
      decoration: BoxDecoration(
        color: surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.7)),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: visibleDevices.length,
        separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).dividerColor.withOpacity(0.6)),
        itemBuilder: (context, index) {
          final d = visibleDevices[index];
          final expanded = expandedDeviceIds.contains(d.id);
          final update = connectionUpdateById[d.id];
          final state =
              update?.state ??
              (d.isConnected
                  ? MblueDeviceConnectionState.connectedUnverified
                  : MblueDeviceConnectionState.disconnected);
          final busy =
              state == MblueDeviceConnectionState.connecting ||
              state == MblueDeviceConnectionState.disconnecting ||
              state == MblueDeviceConnectionState.connectedUnverified;
          final connectable = d.isConnectable != false;

          return _DeviceRow(
            device: d,
            update: update,
            state: state,
            isBusy: busy,
            isConnectable: connectable,
            expanded: expanded,
            onToggleExpanded: () => onToggleExpanded(d.id),
            onConnect: busy || !connectable ? null : () => onConnect(d.id),
            onDisconnect: busy ? null : () => onDisconnect(d.id),
          );
        },
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  final MblueDevice device;
  final MblueConnectionUpdate? update;
  final MblueDeviceConnectionState state;
  final bool isBusy;
  final bool isConnectable;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  const _DeviceRow({
    required this.device,
    required this.update,
    required this.state,
    required this.isBusy,
    required this.isConnectable,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onConnect,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // This app intentionally hides unnamed devices; displayName should be present.
    final name = device.displayName?.trim() ?? '';
    final bool isConnected =
        state == MblueDeviceConnectionState.connectedVerified ||
        state == MblueDeviceConnectionState.connectedUnverified;

    String statusLabel() {
      switch (state) {
        case MblueDeviceConnectionState.connectedVerified:
          return 'Connected (Verified)';
        case MblueDeviceConnectionState.connectedUnverified:
          return 'Connected (Verifying…)';
        case MblueDeviceConnectionState.connecting:
          if (update?.reason == 'autoReconnect' && update?.attempt != null && update?.maxAttempts != null) {
            return 'Reconnecting… (${update!.attempt}/${update!.maxAttempts})';
          }
          return 'Connecting…';
        case MblueDeviceConnectionState.disconnecting:
          return 'Disconnecting…';
        case MblueDeviceConnectionState.disconnected:
          if (update?.reason == 'unexpectedDisconnect') return 'Connection lost';
          return 'Disconnected';
        case MblueDeviceConnectionState.failed:
          return 'Failed';
        case MblueDeviceConnectionState.idle:
          return 'Disconnected';
      }
    }

    final status = statusLabel();

    final statusColor = switch (state) {
      MblueDeviceConnectionState.connectedVerified => const Color(0xFF34C759),
      MblueDeviceConnectionState.connectedUnverified => const Color(0xFF0A84FF),
      MblueDeviceConnectionState.connecting => const Color(0xFF0A84FF),
      MblueDeviceConnectionState.disconnecting => const Color(0xFF0A84FF),
      MblueDeviceConnectionState.disconnected => const Color(0xFF8E8E93),
      MblueDeviceConnectionState.idle => const Color(0xFF8E8E93),
      MblueDeviceConnectionState.failed => const Color(0xFFFF3B30),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: Theme.of(
                        context,
                      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _StatusDot(color: statusColor),
                        const SizedBox(width: 8),
                        Text(
                          status,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(width: 10),
                        _SignalBars(rssi: device.rssi),
                        if (!isConnectable) ...[
                          const SizedBox(width: 10),
                          Text(
                            'Not connectable',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                        if (isBusy) ...[
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _DeviceActionButton(connected: isConnected, onConnect: onConnect, onDisconnect: onDisconnect),
            ],
          ),
          const SizedBox(height: 8),
          _DetailsToggle(expanded: expanded, onPressed: onToggleExpanded),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _DeviceDetails(device: device),
            ),
            secondChild: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _DeviceActionButton extends StatelessWidget {
  final bool connected;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  const _DeviceActionButton({required this.connected, required this.onConnect, required this.onDisconnect});

  @override
  Widget build(BuildContext context) {
    if (connected) {
      return OutlinedButton(
        onPressed: onDisconnect,
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF3B30),
          side: BorderSide(color: const Color(0xFFFF3B30).withOpacity(0.6)),
        ),
        child: const Text('Disconnect'),
      );
    }

    return FilledButton(onPressed: onConnect, child: const Text('Connect'));
  }
}

class _DetailsToggle extends StatelessWidget {
  final bool expanded;
  final VoidCallback onPressed;

  const _DetailsToggle({required this.expanded, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0.0,
              duration: const Duration(milliseconds: 160),
              child: Icon(Icons.chevron_right, size: 18, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(width: 4),
            Text(
              expanded ? 'Hide details' : 'Details',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceDetails extends StatelessWidget {
  final MblueDevice device;

  const _DeviceDetails({required this.device});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(
          Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.45,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor.withOpacity(0.6)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Device ID',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.onSurface),
                ),
              ),
              SelectableText(device.id, style: textStyle),
            ],
          ),
          const SizedBox(height: 6),
          _DetailLine(label: 'RSSI', value: device.rssi != null ? '${device.rssi} dBm' : 'n/a'),
          _DetailLine(label: 'Connectable', value: device.isConnectable?.toString() ?? 'n/a'),
          _DetailLine(label: 'Last seen', value: _formatLastSeen(device.lastSeenMs)),
        ],
      ),
    );
  }

  static String _formatLastSeen(int lastSeenMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final deltaMs = (now - lastSeenMs).clamp(0, 24 * 60 * 60 * 1000);
    final seconds = (deltaMs / 1000).floor();
    if (seconds < 2) return 'Just now';
    if (seconds < 60) return '${seconds}s ago';
    final minutes = (seconds / 60).floor();
    if (minutes < 60) return '${minutes}m ago';
    final hours = (minutes / 60).floor();
    return '${hours}h ago';
  }
}

class _DetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _DetailLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;

  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _SignalBars extends StatelessWidget {
  final int? rssi;

  const _SignalBars({required this.rssi});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bars = _barsForRssi(rssi);
    final Color on = scheme.onSurfaceVariant;
    final Color off = scheme.onSurfaceVariant.withOpacity(0.25);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final active = i < bars;
        final height = 6.0 + (i * 3.0);
        return Padding(
          padding: EdgeInsets.only(right: i == 3 ? 0 : 2),
          child: Container(
            width: 4,
            height: height,
            decoration: BoxDecoration(color: active ? on : off, borderRadius: BorderRadius.circular(2)),
          ),
        );
      }),
    );
  }

  static int _barsForRssi(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }
}
