import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/offline_models.dart';

const _prefKey = 'offline_profile_preference';

/// Préférence de qualité PAR APPAREIL (jamais par compte : c'est un choix de
/// stockage local). Elle présélectionne la feuille mais ne cache jamais les
/// trois choix. Défaut : Opus 256 (recommandé).
abstract interface class OfflineProfilePreference {
  Future<OfflineProfile> load();
  Future<void> save(OfflineProfile profile);
}

class SharedPrefsOfflineProfilePreference implements OfflineProfilePreference {
  const SharedPrefsOfflineProfilePreference(this._prefs);
  final SharedPreferencesAsync _prefs;

  @override
  Future<OfflineProfile> load() async {
    final raw = await _prefs.getString(_prefKey);
    if (raw == null) return OfflineProfile.opus256;
    try {
      return OfflineProfileWire.parse(raw);
    } on ArgumentError {
      return OfflineProfile.opus256;
    }
  }

  @override
  Future<void> save(OfflineProfile profile) =>
      _prefs.setString(_prefKey, profile.wire);
}

final offlineProfilePreferenceProvider = Provider<OfflineProfilePreference>(
  (ref) => SharedPrefsOfflineProfilePreference(SharedPreferencesAsync()),
);
