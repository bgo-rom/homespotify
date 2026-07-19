import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_logger.dart';

/// Réglages persistants de la découverte (non sensibles — SharedPreferences).
///
/// Modèle v4 : le réglage « inclure les recommandations sans aperçu » a été
/// SUPPRIMÉ — la file ne contient que des cartes MEDIA_READY (extrait + image
/// garantis), il n'y a plus de carte muette à inclure.
class DiscoverySettings {
  const DiscoverySettings({this.autoplayPreviews = true});

  /// « Lecture automatique des aperçus » (défaut : activé).
  final bool autoplayPreviews;

  DiscoverySettings copyWith({bool? autoplayPreviews}) {
    return DiscoverySettings(
      autoplayPreviews: autoplayPreviews ?? this.autoplayPreviews,
    );
  }
}

const _autoplayKey = 'discovery.autoplay_previews';

class DiscoverySettingsController extends Notifier<DiscoverySettings> {
  SharedPreferences? _prefs;

  @override
  DiscoverySettings build() {
    _load();
    return const DiscoverySettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      if (!ref.mounted) return;
      state = DiscoverySettings(
        autoplayPreviews: prefs.getBool(_autoplayKey) ?? true,
      );
    } catch (error) {
      // Prefs indisponibles : défauts en mémoire, jamais bloquant.
      logError('réglages découverte illisibles', error: error);
    }
  }

  Future<void> setAutoplayPreviews(bool value) async {
    state = state.copyWith(autoplayPreviews: value);
    logUi('réglage autoplay aperçus: $value');
    await _prefs?.setBool(_autoplayKey, value);
  }
}

final discoverySettingsProvider =
    NotifierProvider<DiscoverySettingsController, DiscoverySettings>(
      DiscoverySettingsController.new,
      name: 'discoverySettings',
    );
