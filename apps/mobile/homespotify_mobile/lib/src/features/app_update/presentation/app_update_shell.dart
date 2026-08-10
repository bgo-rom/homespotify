import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../application/app_update_controller.dart';
import '../domain/app_update_models.dart';

/// Formate une taille pour l'utilisateur (Mo/Go).
String formatUpdateSize(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} Go';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} Mo';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} Ko';
}

/// Enveloppe l'application : déclenche la vérification automatique, suit le
/// cycle de vie, et superpose l'assistant de mise à jour quand il y a lieu.
///
/// Le contenu de l'application est TOUJOURS monté en dessous : une panne du
/// service de mise à jour ne peut jamais empêcher HomeSpotify de démarrer.
class AppUpdateShell extends ConsumerStatefulWidget {
  const AppUpdateShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppUpdateShell> createState() => _AppUpdateShellState();
}

class _AppUpdateShellState extends ConsumerState<AppUpdateShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Après le premier rendu : l'application est déjà utilisable quand la
    // vérification part.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).checkAutomatically(),
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle != AppLifecycleState.resumed) return;
    unawaited(ref.read(appUpdateControllerProvider.notifier).handleAppResumed());
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(appUpdateControllerProvider);
    if (!state.shouldPrompt) return widget.child;

    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: _UpdateOverlay(state: state),
        ),
      ],
    );
  }
}

class _UpdateOverlay extends ConsumerWidget {
  const _UpdateOverlay({required this.state});

  final AppUpdateState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final controller = ref.read(appUpdateControllerProvider.notifier);
    final release = state.latest!;

    return Material(
      key: const ValueKey('app-update-overlay'),
      color: colors.scrim,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Container(
              constraints: const BoxConstraints(maxWidth: 420),
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        state.phase == AppUpdatePhase.error
                            ? Icons.error_outline_rounded
                            : Icons.system_update_rounded,
                        color: state.phase == AppUpdatePhase.error
                            ? colors.danger
                            : colors.accent,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          state.mandatory
                              ? 'Mise à jour requise'
                              : 'Mise à jour disponible',
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'HomeSpotify ${release.display} · '
                    '${formatUpdateSize(release.sizeBytes)}',
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                  if (state.current != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Version installée : ${state.current!.display}',
                        style: TextStyle(
                          color: colors.textTertiary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (release.releaseNotes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    ...release.releaseNotes.map(
                      (note) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '· ',
                              style: TextStyle(color: colors.textSecondary),
                            ),
                            Expanded(
                              child: Text(
                                note,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 13,
                                  height: 1.35,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _UpdateBody(state: state, colors: colors),
                  const SizedBox(height: 18),
                  _UpdateActions(state: state, controller: controller),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _UpdateBody extends StatelessWidget {
  const _UpdateBody({required this.state, required this.colors});

  final AppUpdateState state;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    switch (state.phase) {
      case AppUpdatePhase.downloading:
        final progress = state.progress;
        final percent = progress == null ? null : (progress * 100).round();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              percent == null
                  ? 'Téléchargement de la mise à jour…'
                  : 'Téléchargement de la mise à jour · $percent %',
              key: const ValueKey('app-update-progress-label'),
              style: TextStyle(color: colors.textPrimary, fontSize: 14),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: colors.surfaceSunken,
                color: colors.accent,
              ),
            ),
          ],
        );

      case AppUpdatePhase.verifying:
        return _Line(
          colors: colors,
          text: 'Vérification de la mise à jour…',
          showSpinner: true,
        );

      case AppUpdatePhase.readyToInstall:
        return _Line(
          colors: colors,
          text: 'Mise à jour vérifiée. Android va demander confirmation.',
        );

      case AppUpdatePhase.installing:
        return _Line(
          colors: colors,
          text:
              'Installation lancée. Confirme dans l’écran Android, puis rouvre '
              'HomeSpotify.',
        );

      case AppUpdatePhase.permissionRequired:
        return _Line(
          colors: colors,
          text:
              'Android doit autoriser HomeSpotify à installer ses propres mises '
              'à jour. Ouvre les réglages, active l’autorisation, puis reviens.',
        );

      case AppUpdatePhase.error:
        return _Line(
          colors: colors,
          text: state.message ?? 'La mise à jour a échoué.',
          danger: true,
        );

      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
      case AppUpdatePhase.upToDate:
      case AppUpdatePhase.available:
        return _Line(
          colors: colors,
          text: state.mandatory
              ? 'Cette version est nécessaire pour continuer à utiliser '
                    'HomeSpotify.'
              : 'Une nouvelle version de HomeSpotify est disponible.',
        );
    }
  }
}

class _Line extends StatelessWidget {
  const _Line({
    required this.colors,
    required this.text,
    this.showSpinner = false,
    this.danger = false,
  });

  final AppColors colors;
  final String text;
  final bool showSpinner;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showSpinner) ...[
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: colors.accent),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: danger ? colors.danger : colors.textSecondary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _UpdateActions extends StatelessWidget {
  const _UpdateActions({required this.state, required this.controller});

  final AppUpdateState state;
  final AppUpdateController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final primary = switch (state.phase) {
      AppUpdatePhase.permissionRequired => (
        'Ouvrir les réglages Android',
        controller.openInstallSettings,
      ),
      AppUpdatePhase.readyToInstall || AppUpdatePhase.installing => (
        'Installer',
        controller.requestInstall,
      ),
      AppUpdatePhase.error => ('Réessayer', controller.downloadAndInstall),
      AppUpdatePhase.downloading || AppUpdatePhase.verifying => (null, null),
      _ => ('Mettre à jour', controller.downloadAndInstall),
    };

    return Column(
      children: [
        if (primary.$1 != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('app-update-primary-action'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
              ),
              onPressed: () => unawaited(Future<void>.sync(primary.$2!)),
              child: Text(primary.$1!),
            ),
          ),
        if (!state.mandatory) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              key: const ValueKey('app-update-later'),
              onPressed: () {
                if (state.phase == AppUpdatePhase.downloading) {
                  controller.cancelDownload();
                }
                controller.postpone();
              },
              child: Text(
                state.phase == AppUpdatePhase.downloading
                    ? 'Annuler'
                    : 'Plus tard',
                style: TextStyle(color: colors.textSecondary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
