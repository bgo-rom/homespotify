import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/platform/app_package_info.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../app_update/application/app_update_controller.dart';
import '../../app_update/domain/app_update_models.dart';
import '../../auth/application/auth_controller.dart';
import '../../auth/data/biometric_service.dart';
import '../../discovery/application/discovery_settings.dart';
import '../../library/presentation/library_favorites.dart';
import '../../library/presentation/library_playlists.dart';
import '../../library/presentation/library_summary.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/audio/replay_gain.dart';
import '../../player/presentation/widgets/mini_player.dart';
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

enum _ServerStatus { idle, testing, connected, inaccessible }

/// Écran « Paramètres » — refonte Direction 33. Même logique, mêmes sections,
/// même comportement d'updater ; seule la présentation change.
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
      final colors = context.colors;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: colors.surfaceRaised,
          content: Text(result.userMessage),
        ),
      );
    }
  }

  Future<void> _logout() async {
    final colors = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
        title: Text(
          'Se déconnecter ?',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          'La session de cet appareil sera fermée.',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              'Annuler',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              'Se déconnecter',
              style: TextStyle(color: colors.danger),
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
    final colors = context.colors;
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
    final updateState = ref.watch(appUpdateControllerProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Paramètres',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppLayout.gutter,
                  4,
                  AppLayout.gutter,
                  32,
                ),
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
                        _DangerButton(
                          icon: Icons.logout_rounded,
                          label: 'Se déconnecter',
                          onPressed: _logout,
                        ),
                      ],
                    ),
                  _SettingsSection(
                    title: 'Sécurité',
                    children: [
                      _SettingSwitch(
                        title: 'Déverrouiller HomeSpotify avec la biométrie',
                        subtitle: _biometricSupported
                            ? 'Empreinte ou visage, uniquement pour la session '
                                  'locale de cet appareil.'
                            : _biometricAvailability?.failureReason ==
                                  BiometricFailureReason.notConfigured
                            ? 'Aucune biométrie n’est configurée dans Android.'
                            : 'La biométrie est indisponible sur cet appareil.',
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
                      _SettingSwitch(
                        title: 'Lecture automatique des aperçus',
                        subtitle:
                            'Joue l’extrait de la carte affichée après un court instant.',
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
                      _NavRow(
                        icon: Icons.history_rounded,
                        title: 'Activité d’écoute',
                        subtitle: 'Reprendre un titre et consulter les écoutes récentes.',
                        onTap: () => context.push('/listening-activity'),
                      ),
                      _NavRow(
                        icon: Icons.explore_rounded,
                        title: 'Découvrir',
                        subtitle: 'Swiper des recommandations et découvrir des morceaux.',
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
                        const SizedBox(height: 14),
                        _PrimaryButton(
                          icon: Icons.admin_panel_settings_rounded,
                          label: 'Tableau de bord',
                          onPressed: () => context.push('/admin'),
                        ),
                        const SizedBox(height: 8),
                        _OutlinedAccentButton(
                          icon: Icons.move_to_inbox_rounded,
                          label: 'Imports utilisateurs',
                          onPressed: () => context.push('/admin/imports'),
                        ),
                        const SizedBox(height: 8),
                        _OutlinedAccentButton(
                          icon: Icons.monitor_heart_rounded,
                          label: 'Diagnostics recommandations',
                          onPressed: () => context.push('/admin/recommendations'),
                        ),
                        const SizedBox(height: 8),
                        _OutlinedAccentButton(
                          icon: Icons.group_rounded,
                          label: 'Utilisateurs',
                          onPressed: () => context.push('/admin/users'),
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
                            style: TextStyle(color: colors.danger, fontSize: 13),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _PrimaryButton(
                        icon: Icons.wifi_tethering_rounded,
                        label: 'Tester la connexion',
                        busy: _serverStatus == _ServerStatus.testing,
                        onPressed: _serverStatus == _ServerStatus.testing
                            ? null
                            : _testConnection,
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
                    title: 'Mise à jour',
                    children: [
                      _InfoRow(label: 'Version actuelle', value: _appVersion),
                      _InfoRow(
                        label: 'Dernière version',
                        value: _latestVersionLabel(updateState),
                      ),
                      if (updateState.phase == AppUpdatePhase.downloading) ...[
                        const SizedBox(height: 12),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            key: const ValueKey('settings-update-progress'),
                            value: updateState.progress,
                            minHeight: 6,
                            backgroundColor: colors.surfaceSunken,
                            color: colors.accent,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Téléchargement en cours'
                          '${updateState.progress == null ? '' : ' · ${(updateState.progress! * 100).round()} %'}',
                          style: TextStyle(color: colors.textSecondary, fontSize: 12),
                        ),
                      ],
                      if (updateState.phase == AppUpdatePhase.error &&
                          updateState.message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            updateState.message!,
                            style: TextStyle(color: colors.danger, fontSize: 13),
                          ),
                        ),
                      const SizedBox(height: 14),
                      _OutlinedAccentButton(
                        key: const ValueKey('settings-check-update'),
                        icon: Icons.system_update_rounded,
                        label: 'Rechercher une mise à jour',
                        busy: updateState.phase == AppUpdatePhase.checking,
                        onPressed: updateState.busy
                            ? null
                            : () => ref
                                  .read(appUpdateControllerProvider.notifier)
                                  .checkManually(),
                      ),
                      const _Note(
                        'HomeSpotify n’est pas sur le Play Store : les mises à jour '
                        'viennent de ton propre serveur. Android demande toujours '
                        'confirmation avant d’installer.',
                      ),
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
                        _NavRow(
                          icon: Icons.monitor_heart_rounded,
                          title: 'Diagnostic audio',
                          subtitle:
                              'État temps réel, trace, marqueur de problème et export.',
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
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
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

  /// N'affirme jamais qu'une version est « à jour » sans l'avoir vérifié.
  static String _latestVersionLabel(AppUpdateState update) {
    final latest = update.latest;
    if (latest != null) {
      return update.phase == AppUpdatePhase.upToDate
          ? '${latest.display} · à jour'
          : latest.display;
    }
    return switch (update.phase) {
      AppUpdatePhase.checking => 'Vérification…',
      AppUpdatePhase.upToDate => 'À jour',
      _ => 'Inconnue',
    };
  }

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

/// Groupe sculpté Direction 33 : libellé en accent, carte unique. Remplace
/// la carte Material contourée d'origine.
class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          SoftCard(
            padding: const EdgeInsets.all(16),
            child: Column(children: children),
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
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey<String>('settings-info-$label'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              value,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ligne switch Direction 33 : titre, sous-titre, interrupteur en accent.
class _SettingSwitch extends StatelessWidget {
  const _SettingSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.settingKey,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Key? settingKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      key: settingKey,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            activeThumbColor: colors.accent,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// Ligne de navigation vers un autre écran : icône, titre, sous-titre,
/// chevron — même grammaire que les tuiles de Bibliothèque/Profil.
class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SoftCircle(
              size: 40,
              color: colors.accentSoft,
              child: Icon(icon, color: colors.accent, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: colors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// Bouton plein largeur en accent — action principale d'une section.
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
        ),
        onPressed: onPressed,
        icon: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.onAccent,
                ),
              )
            : Icon(icon),
        label: Text(label),
      ),
    );
  }
}

/// Bouton plein largeur contouré en accent — action secondaire.
class _OutlinedAccentButton extends StatelessWidget {
  const _OutlinedAccentButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.accent,
          side: BorderSide(color: colors.accent),
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
        ),
        onPressed: onPressed,
        icon: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              )
            : Icon(icon),
        label: Text(label),
      ),
    );
  }
}

/// Bouton plein largeur contouré en danger — déconnexion.
class _DangerButton extends StatelessWidget {
  const _DangerButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.danger,
          side: BorderSide(color: colors.danger),
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
        ),
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
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
        return _SettingSwitch(
          settingKey: const ValueKey('settings-replay-gain'),
          title: 'Volume homogène (ReplayGain)',
          subtitle: _subtitle(state),
          value: state.enabled,
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
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline_rounded, color: colors.textTertiary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
