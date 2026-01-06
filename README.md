# mblue (macOS CoreBluetooth demo plugin)

Minimal Flutter **macOS** Bluetooth (BLE) plugin built on **Apple CoreBluetooth** (`CBCentralManager`).

This is intentionally small and beginner-friendly:
- No third-party Dart Bluetooth packages
- MethodChannel + EventChannels
- Scan nearby **BLE** peripherals, show basic info, connect/disconnect

## What this supports (and what it doesn’t)

### Supports
- **BLE scanning** (`scanForPeripherals`)
- Basic device info:
  - **name** (if advertised / available)
  - **deviceId** (UUID string from `CBPeripheral.identifier`)
  - **RSSI** (when available)
  - **connectable** flag (when available)
  - **connection state** (connected/connecting/etc.)
- **Connect / disconnect** to a discovered peripheral

### Limitations (important)
- CoreBluetooth on macOS is primarily for **BLE**. It does **not** provide a “classic Bluetooth devices list” like System Settings.
- You generally **cannot get the MAC address** of BLE devices via CoreBluetooth. The `deviceId` is a UUID.
- “Paired” state for classic devices is not exposed via CoreBluetooth. This demo reports **connection** state only.

## Folder structure

```
lib/
  mblue.dart
  mblue_method_channel.dart
  mblue_platform_interface.dart
  src/models.dart
macos/Classes/
  BluetoothManager.swift
  MbluePlugin.swift
example/
  lib/main.dart
  macos/Runner/Info.plist
  macos/Runner/DebugProfile.entitlements
  macos/Runner/Release.entitlements
```

## Dart API

```dart
final mblue = Mblue();

// Streams
mblue.adapterState.listen((s) => print('adapter=$s'));
mblue.scanUpdates.listen((u) => print('scan=${u.isScanning} reason=${u.reason}'));
mblue.discoveredDevices.listen((d) => print('device=${d.id} rssi=${d.rssi}'));
mblue.connectionUpdates.listen((u) => print('conn=${u.deviceId} ${u.state}'));

// Actions
await mblue.startScan(timeout: const Duration(seconds: 10));
await mblue.stopScan();
await mblue.connect(deviceId);
await mblue.disconnect(deviceId);
```

## macOS permissions / entitlements (required)

### Info.plist
In `example/macos/Runner/Info.plist`:
- `NSBluetoothAlwaysUsageDescription`
- `NSBluetoothPeripheralUsageDescription` (older compatibility)

These are already added in this repo.

### App Sandbox entitlement
In `example/macos/Runner/DebugProfile.entitlements` and `Release.entitlements`:
- `com.apple.security.device.bluetooth = true`

These are already added in this repo.

If you open the example app in Xcode, you can also confirm this in:
`Runner` target → **Signing & Capabilities** → **App Sandbox** → **Bluetooth**.

## How to run (example app)

From the repo root:

```bash
cd example
flutter run -d macos
```

Expected behavior:
- App shows a **Scan (10s)** button
- Devices appear in the list while scanning
- Tap **Connect** / **Disconnect** to change connection state
- Check Xcode console for logs tagged with `[Bluetooth]`

## Error handling

Native errors are surfaced as `PlatformException`/`FlutterError` codes such as:
- `bluetooth_off`
- `unauthorized`
- `unsupported`
- `bluetooth_unavailable`
- `device_not_found`
- `invalid_device_id`

## Native implementation notes

The macOS implementation is in:
- `macos/Classes/BluetoothManager.swift` (CoreBluetooth logic + logging `[Bluetooth]`)
- `macos/Classes/MbluePlugin.swift` (MethodChannel + EventChannels)


