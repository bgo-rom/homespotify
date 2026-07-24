import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum OfflineNetworkPolicy { wifiOnly, wifiAndCellular }

class OfflineDownloadPreferences {
  const OfflineDownloadPreferences({
    required this.networkPolicy,
    required this.maxStorageBytes,
  });

  static const defaults = OfflineDownloadPreferences(
    networkPolicy: OfflineNetworkPolicy.wifiOnly,
    maxStorageBytes: 10 * 1024 * 1024 * 1024,
  );

  final OfflineNetworkPolicy networkPolicy;

  /// Plafond volontaire du cache HomeSpotify. `0` signifie sans plafond
  /// applicatif ; l'espace physique reste toujours vérifié.
  final int maxStorageBytes;

  bool allows(List<ConnectivityResult> transports) {
    if (transports.contains(ConnectivityResult.none) || transports.isEmpty) {
      return false;
    }
    if (networkPolicy == OfflineNetworkPolicy.wifiAndCellular) return true;
    return transports.contains(ConnectivityResult.wifi) ||
        transports.contains(ConnectivityResult.ethernet);
  }

  OfflineDownloadPreferences copyWith({
    OfflineNetworkPolicy? networkPolicy,
    int? maxStorageBytes,
  }) => OfflineDownloadPreferences(
    networkPolicy: networkPolicy ?? this.networkPolicy,
    maxStorageBytes: maxStorageBytes ?? this.maxStorageBytes,
  );
}

abstract interface class OfflineDownloadPreferencesStore {
  Future<OfflineDownloadPreferences> load();
  Future<void> save(OfflineDownloadPreferences preferences);
}

class SharedPreferencesOfflineDownloadPreferencesStore
    implements OfflineDownloadPreferencesStore {
  static const _networkKey = 'offline_network_policy_v1';
  static const _limitKey = 'offline_storage_limit_bytes_v1';

  @override
  Future<OfflineDownloadPreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    final networkName = prefs.getString(_networkKey);
    final policy = OfflineNetworkPolicy.values
        .where((value) => value.name == networkName)
        .firstOrNull;
    return OfflineDownloadPreferences(
      networkPolicy:
          policy ?? OfflineDownloadPreferences.defaults.networkPolicy,
      maxStorageBytes:
          prefs.getInt(_limitKey) ??
          OfflineDownloadPreferences.defaults.maxStorageBytes,
    );
  }

  @override
  Future<void> save(OfflineDownloadPreferences preferences) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_networkKey, preferences.networkPolicy.name);
    await prefs.setInt(_limitKey, preferences.maxStorageBytes);
  }
}

abstract interface class OfflineStoragePlatform {
  Future<int?> freeBytes();
}

class MethodChannelOfflineStoragePlatform implements OfflineStoragePlatform {
  static const _channel = MethodChannel('com.homespotify/storage');

  @override
  Future<int?> freeBytes() async {
    try {
      return await _channel.invokeMethod<int>('freeBytes');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class OfflineStorageSnapshot {
  const OfflineStorageSnapshot({
    required this.usedBytes,
    required this.freeBytes,
    required this.limitBytes,
  });

  final int usedBytes;
  final int? freeBytes;
  final int limitBytes;

  int? get remainingUnderLimit => limitBytes <= 0
      ? null
      : (limitBytes - usedBytes).clamp(0, limitBytes).toInt();

  bool canFit(int bytes, {int reserveBytes = 200 * 1024 * 1024}) {
    final underLimit = limitBytes <= 0 || usedBytes + bytes <= limitBytes;
    final physical = freeBytes == null || freeBytes! - reserveBytes >= bytes;
    return underLimit && physical;
  }
}

final offlineDownloadPreferencesStoreProvider =
    Provider<OfflineDownloadPreferencesStore>(
      (ref) => SharedPreferencesOfflineDownloadPreferencesStore(),
    );

final offlineStoragePlatformProvider = Provider<OfflineStoragePlatform>(
  (ref) => MethodChannelOfflineStoragePlatform(),
);
