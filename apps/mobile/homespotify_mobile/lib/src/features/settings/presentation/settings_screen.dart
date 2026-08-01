import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/platform/app_package_info.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/biometric_service.dart';
import '../../discovery/application/discovery_settings.dart';
import '../../library/presentation/library_favorites.dart';
import '../../library/presentation/library_playlists.dart';
import '../../library/presentation/library_summary.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/audio/replay_gain.dart';
import '../data/settings_server_checker.dart';

/// Formatage compact octets → Go/Mo/Ko pour la section Compte.
String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} Ko';
  }
  return '$bytes o';
}

const Color _background = Color(0xFF0D0D10);
const Color _card = Color(0xFF1A1A22);
const Color _accent = Color(0xFF1DB954);

enum _ServerStatus { idle, testing, connected, inaccessible }

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  _ServerStatus _serverStatus = _ServerStatus.idle;
  String? _serverError;
  bool _biometricSupported = false;
  bool _biometricEnabled = false;
  bool _biometricBusy = false;
  BiometricAvailability? _biometricAvailability;
  String _appVersion = 'Chargement…';

  @override
  void initState() {
    super.initState();
    logUi('ouverture Paramètres');
    _loadBiometricState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final package = await AppPackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersion = package.displayVersion;
      });
    } catch (error, stackTrace) {
      logError(
        'lecture version application impossible',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _appVersion = 'Indisponible');
    }
  }

  Future<void> _loadBiometricState() async {
    final availability = await ref
        .read(biometricServiceProvider)
        .checkAvailability();
    final enabled = await ref.read(tokenStoreProvider).readBiometricEnabled();
    if (!mounted) return;
    setState(() {
      _biometricAvailability = availability;
      _biometricSupported = availability.available;
      _biometricEnabled = enabled && availability.available;
    });
  }

  Future<void> _toggleBiometric(bool enabled) async {
    if (_biometricBusy) return;
    setState(() => _biometricBusy = true);
    final result = await ref
        .read(authControllerProvider.notifier)
        .setBiometricEnabled(enabled);
    if (!mounted) return;
    setState(() {
      _biometricBusy = false;
      if (result.succeeded) _biometricEnabled = enabled;
    });
    if (!result.succeeded && enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: _card, content: Text(result.userMessage)),
      );
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _card,
        title: const Text(
          'Se déconnecter ?',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'La session de cet appareil sera fermée.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              'Annuler',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Se déconnecter',
              style: TextStyle(color: Color(0xFFE57373)),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(authControllerProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final favoriteCount = ref
        .watch(favoriteTrackIdsProvider)
        .asData
        ?.value
        .length;
    final playlistCount = ref.watch(playlistsProvider).asData?.value.length;
    final summary = ref.watch(userLibrarySummaryProvider);
    final authUser = ref.watch(
      authControllerProvider.select((state) => state.user),
    );
    final discoverySettings = ref.watch(discoverySettingsProvider);
    final audioHandler = ref.watch(audioHandlerProvider);
    final replayGainController = ref.watch(replayGainControllerProvider);

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        title: const Text(
          'Paramètres',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          if (authUser != null)
            _SettingsSection(
              title: 'Compte',
              children: [
                _InfoRow(label: 'Nom affiché', value: authUser.displayName),
                _InfoRow(label: 'Utilisateur', value: '@${authUser.username}'),
                _InfoRow(label: 'Rôle', value: authUser.role),
                ...summary.when(
                  loading: () => const <Widget>[
                    _InfoRow(label: 'Bibliothèque', value: 'Chargement…'),
                  ],
                  error: (_, _) => <Widget>[
                    const _InfoRow(
                      label: 'Bibliothèque',
                      value: 'Indisponible',
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            ref.invalidate(userLibrarySummaryProvider),
                        child: const Text('Réessayer'),
                      ),
                    ),
                  ],
                  data: (value) => <Widget>[
                    _InfoRow(label: 'Morceaux', value: '${value.trackCount}'),
                    _InfoRow(label: 'Favoris', value: '${value.favoriteCount}'),
                    _InfoRow(
                      label: 'Playlists',
                      value: '${value.playlistCount}',
                    ),
                    _InfoRow(
                      label: 'Stockage logique',
                      value: _formatBytes(value.logicalSizeBytes),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE57373),
                      side: const BorderSide(color: Color(0xFFE57373)),
                    ),
                    onPressed: _logout,
                    icon: const Icon(Icons.logout_rounded),
                    label: const Text('Se déconnecter'),
                  ),
                ),
              ],
            ),
          _SettingsSection(
            title: 'Sécurité',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Déverrouiller HomeSpotify avec la biométrie',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: Text(
                  _biometricSupported
                      ? 'Empreinte ou visage, uniquement pour la session '
                            'locale de cet appareil.'
                      : _biometricAvailability?.failureReason ==
                            BiometricFailureReason.notConfigured
                      ? 'Aucune biométrie n’est configurée dans Android.'
                      : 'La biométrie est indisponible sur cet appareil.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                activeThumbColor: _accent,
                value: _biometricEnabled,
                onChanged: _biometricSupported && !_biometricBusy
                    ? _toggleBiometric
                    : null,
              ),
            ],
          ),
          _SettingsSection(
            title: 'Découverte',
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Lecture automatique des aperçus',
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
                subtitle: const Text(
                  'Joue l’extrait de la carte affichée après un court instant.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                activeThumbColor: _accent,
                value: discoverySettings.autoplayPreviews,
                onChanged: (value) => ref
                    .read(discoverySettingsProvider.notifier)
                    .setAutoplayPreviews(value),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Musique',
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history_rounded, color: _accent),
                title: const Text(
                  'Activité d’écoute',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Reprendre un titre et consulter les écoutes récentes.',
                  style: TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white38,
                ),
                onTap: () => context.push('/listening-activity'),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.explore_rounded, color: _accent),
                title: const Text(
                  'Découvrir',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Swiper des recommandations et découvrir des morceaux.',
                  style: TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(
                  Icons.chevron_right_rounded,
                  color: Colors.white38,
                ),
                onTap: () => context.go('/discover'),
              ),
            ],
          ),
          if (authUser != null && authUser.isOwner)
            _SettingsSection(
              title: 'Administration',
              children: [
                const _Note(
                  'Section réservée au propriétaire. Les droits sont '
                  'revérifiés par le serveur à chaque action.',
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => context.push('/admin'),
                    icon: const Icon(Icons.admin_panel_settings_rounded),
                    label: const Text('Tableau de bord'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: _accent),
                    ),
                    onPressed: () => context.push('/admin/imports'),
                    icon: const Icon(Icons.move_to_inbox_rounded),
                    label: const Text('Imports utilisateurs'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: _accent),
                    ),
                    onPressed: () => context.push('/admin/recommendations'),
                    icon: const Icon(Icons.monitor_heart_rounded),
                    label: const Text('Diagnostics recommandations'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _accent,
                      side: const BorderSide(color: _accent),
                    ),
                    onPressed: () => context.push('/admin/users'),
                    icon: const Icon(Icons.group_rounded),
                    label: const Text('Utilisateurs'),
                  ),
                ),
              ],
            ),
          _SettingsSection(
            title: 'Serveur',
            children: [
              const _InfoRow(
                label: 'URL API actuelle',
                value: AppConfig.apiBaseUrl,
              ),
              _InfoRow(label: 'État', value: _statusLabel),
              if (_serverError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _serverError!,
                    style: const TextStyle(
                      color: Color(0xFFE57373),
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: _serverStatus == _ServerStatus.testing
                      ? null
                      : _testConnection,
                  icon: _serverStatus == _ServerStatus.testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black54,
                          ),
                        )
                      : const Icon(Icons.wifi_tethering_rounded),
                  label: const Text('Tester la connexion'),
                ),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Informations de l’application',
            children: [
              const _InfoRow(label: 'Nom', value: 'HomeSpotify'),
              _InfoRow(label: 'Version', value: _appVersion),
              _InfoRow(label: 'Mode', value: _buildMode),
              const _InfoRow(label: 'Plateforme', value: 'Android'),
            ],
          ),
          _SettingsSection(
            title: 'Données du compte',
            children: [
              _InfoRow(label: 'Favoris', value: _countLabel(favoriteCount)),
              _InfoRow(label: 'Playlists', value: _countLabel(playlistCount)),
              const _Note(
                'Ces données sont synchronisées avec le serveur pour le compte courant.',
              ),
            ],
          ),
          if (authUser?.isOwner == true || kDebugMode)
            _SettingsSection(
              title: 'Diagnostic',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(
                    Icons.monitor_heart_rounded,
                    color: _accent,
                  ),
                  title: const Text(
                    'Diagnostic audio',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'État temps réel, trace, marqueur de problème et export.',
                    style: TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white38,
                  ),
                  onTap: () => context.push('/dev/audio-diagnostics'),
                ),
              ],
            ),
          _SettingsSection(
            title: 'Audio',
            children: [
              const _InfoRow(
                label: 'Formats pris en charge',
                value: 'WAV / FLAC',
              ),
              _ReplayGainSetting(controller: replayGainController),
              _InfoRow(
                label: 'Time-stretch',
                value: audioHandler.currentTimeStretchEngineName,
              ),
              const _InfoRow(
                label: 'Transcodage',
                value: 'Aucun — fichier original',
              ),
            ],
          ),
          _SettingsSection(
            title: 'Accès distant',
            children: [
              _InfoRow(label: 'Adresse effective', value: AppConfig.apiBaseUrl),
              _InfoRow(
                label: 'HTTPS',
                value: AppConfig.usesTls ? 'Activé' : 'Non activé',
              ),
              _Note(
                AppConfig.remoteAccessConfigured
                    ? 'Une adresse distante chiffrée est compilée dans cette version.'
                    : 'Cette version utilise une adresse locale ou de développement.',
              ),
            ],
          ),
        ],
      ),
    );
  }

  String get _statusLabel => switch (_serverStatus) {
    _ServerStatus.idle => 'Non testé',
    _ServerStatus.testing => 'Test en cours',
    _ServerStatus.connected => 'Connecté',
    _ServerStatus.inaccessible => 'Inaccessible',
  };

  static String get _buildMode {
    if (kDebugMode) return 'Debug';
    if (kProfileMode) return 'Profile';
    return 'Release';
  }

  static String _countLabel(int? count) => count?.toString() ?? 'Chargement…';

  Future<void> _testConnection() async {
    if (_serverStatus == _ServerStatus.testing) return;
    logUi('lancement test serveur url=$_loggableApiUrl');
    setState(() {
      _serverStatus = _ServerStatus.testing;
      _serverError = null;
    });
    try {
      await ref.read(settingsServerCheckerProvider).checkHealth();
      if (!mounted) return;
      logUi('succès test serveur url=$_loggableApiUrl');
      setState(() => _serverStatus = _ServerStatus.connected);
    } catch (error, stackTrace) {
      logError(
        'échec test serveur url=$_loggableApiUrl type=${error.runtimeType}',
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _serverStatus = _ServerStatus.inaccessible;
        _serverError = AppConfig.serverUnreachableMessage;
      });
    }
  }

  String get _loggableApiUrl {
    final uri = Uri.tryParse(AppConfig.apiBaseUrl);
    if (uri == null || !uri.hasAuthority) return '<URL invalide>';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: const TextStyle(
                color: _accent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: children),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: ValueKey<String>('settings-info-$label'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              value,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReplayGainSetting extends StatelessWidget {
  const _ReplayGainSetting({required this.controller});

  final ReplayGainController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReplayGainState>(
      valueListenable: controller.state,
      builder: (context, state, _) {
        return SwitchListTile(
          key: const ValueKey('settings-replay-gain'),
          contentPadding: EdgeInsets.zero,
          activeThumbColor: _accent,
          value: state.enabled,
          title: const Text(
            'Volume homogène (ReplayGain)',
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
          subtitle: Text(
            _subtitle(state),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          onChanged: (enabled) async {
            try {
              await controller.setEnabled(enabled);
            } catch (_) {
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Le réglage ReplayGain n’a pas pu être enregistré.',
                  ),
                ),
              );
            }
          },
        );
      },
    );
  }

  static String _subtitle(ReplayGainState state) {
    if (!state.enabled) {
      return 'Désactivé par défaut · mesure R128, aucun fichier modifié.';
    }
    final analysis = state.analysis;
    return switch (state.phase) {
      ReplayGainPhase.applied =>
        'Actif sur ce titre · ${_signed(analysis?.replayGainDb)} dB '
            '(${analysis?.integratedLufs?.toStringAsFixed(1) ?? '?'} LUFS).',
      ReplayGainPhase.analyzing => 'Analyse R128 du titre en arrière-plan…',
      ReplayGainPhase.unavailable =>
        state.message ?? 'Mesure indisponible pour ce titre.',
      ReplayGainPhase.error =>
        state.message ?? 'Le réglage est temporairement indisponible.',
      _ => 'Activé · cible -18 LUFS, plafond -1 dBTP.',
    };
  }

  static String _signed(double? value) {
    if (value == null) return '?';
    final fixed = value.toStringAsFixed(1);
    return value > 0 ? '+$fixed' : fixed;
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline_rounded,
            color: Colors.white38,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white54, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
