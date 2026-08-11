import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../auth/application/auth_controller.dart';
import '../../library/domain/track.dart';
import '../application/offline_index.dart';
import '../application/offline_artwork_cache.dart';
import '../application/offline_profile_preference.dart';
import '../application/offline_track_downloader.dart';
import '../data/offline_api.dart';
import '../domain/offline_models.dart';

/// Feuille de téléchargement hors ligne : les TROIS choix sont toujours
/// visibles, Opus 256 est présélectionné (ou la préférence appareil), les
/// tailles estimées sont explicitement marquées « estimée ».
Future<void> showOfflineDownloadSheet(
  BuildContext context, {
  required Track track,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.tile)),
    ),
    builder: (_) => OfflineDownloadSheet(track: track),
  );
}

class OfflineDownloadSheet extends ConsumerStatefulWidget {
  const OfflineDownloadSheet({super.key, required this.track});

  final Track track;

  @override
  ConsumerState<OfflineDownloadSheet> createState() =>
      _OfflineDownloadSheetState();
}

class _OfflineDownloadSheetState extends ConsumerState<OfflineDownloadSheet> {
  List<OfflineOption>? _options;
  String? _loadError;
  OfflineProfile _selected = OfflineProfile.opus256;
  OfflineDownloadProgress? _progress;
  String? _downloadError;
  bool _done = false;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _options = null;
    });
    try {
      final preference = await ref
          .read(offlineProfilePreferenceProvider)
          .load();
      final options = await ref
          .read(offlineApiProvider)
          .fetchOptions(widget.track.id);
      if (!mounted) return;
      setState(() {
        _options = options;
        _selected = preference;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.toString());
    }
  }

  Future<void> _download() async {
    final userId = ref.read(authControllerProvider).user?.id;
    if (userId == null) return;
    // La préférence est mémorisée pour présélectionner la prochaine fois —
    // le choix reste visible et modifiable à chaque téléchargement.
    await ref.read(offlineProfilePreferenceProvider).save(_selected);
    final cancelToken = CancelToken();
    setState(() {
      _downloadError = null;
      _cancelToken = cancelToken;
      _progress = const OfflineDownloadProgress(
        status: OfflineDownloadStatus.waitingServer,
        receivedBytes: 0,
      );
    });
    try {
      await ref
          .read(offlineTrackDownloaderProvider)
          .download(
            userId: userId,
            track: widget.track,
            profile: _selected,
            cancelToken: cancelToken,
            onProgress: (progress) {
              if (mounted) setState(() => _progress = progress);
            },
          );
      if (!mounted) return;
      setState(() {
        _done = true;
        _cancelToken = null;
      });
      // Badge bibliothèque et écran Téléchargements à jour immédiatement.
      ref.invalidate(offlineIndexProvider);
      unawaited(_cacheCover(userId));
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() {
        _cancelToken = null;
        _progress = null;
        // Annulé par l'utilisateur : pas un échec, la reprise reste possible.
        _downloadError = CancelToken.isCancel(error)
            ? null
            : 'Téléchargement interrompu. Réessaie.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _cancelToken = null;
        _progress = null;
        _downloadError = error.toString();
      });
    }
  }

  Future<void> _cacheCover(int userId) async {
    final changed = await ref
        .read(offlineArtworkCacheProvider)
        .ensureCover(userId: userId, trackId: widget.track.id);
    if (mounted && changed) {
      ref.invalidate(offlineIndexProvider);
    }
  }

  void _cancel() => _cancelToken?.cancel('annulé par l’utilisateur');

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final options = _options;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 5,
                decoration: BoxDecoration(
                  color: colors.surfaceSunken,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Télécharger « ${widget.track.title} »',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            if (_loadError != null) ...[
              Text(_loadError!, style: TextStyle(color: colors.danger)),
              const SizedBox(height: 10),
              TextButton(onPressed: _load, child: const Text('Réessayer')),
            ] else if (options == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: CircularProgressIndicator(color: colors.accent),
                ),
              )
            else ...[
              for (final option in options)
                _OfflineChoiceTile(
                  key: ValueKey('offline-choice-${option.profile.wire}'),
                  option: option,
                  selected: _selected == option.profile,
                  enabled: _progress == null && !_done,
                  onTap: () => setState(() => _selected = option.profile),
                ),
              const SizedBox(height: 14),
              if (_done)
                ListTile(
                  key: const ValueKey('offline-download-done'),
                  leading: Icon(
                    Icons.check_circle_rounded,
                    color: colors.accent,
                  ),
                  title: Text(
                    'Téléchargement terminé et vérifié.',
                    style: TextStyle(color: colors.textPrimary),
                  ),
                )
              else if (_progress != null) ...[
                _DownloadProgressView(progress: _progress!),
                const SizedBox(height: 8),
                TextButton(
                  key: const ValueKey('offline-download-cancel'),
                  onPressed: _cancel,
                  child: Text('Annuler', style: TextStyle(color: colors.danger)),
                ),
              ] else ...[
                if (_downloadError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _downloadError!,
                      key: const ValueKey('offline-download-error'),
                      style: TextStyle(color: colors.danger),
                    ),
                  ),
                FilledButton.icon(
                  key: const ValueKey('offline-download-start'),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: colors.onAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _download,
                  icon: const Icon(Icons.download_rounded),
                  label: Text(
                    _downloadError == null ? 'Télécharger' : 'Réessayer',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String formatOfflineSize(int? sizeBytes, String? sizeKind) {
  if (sizeBytes == null) return 'taille inconnue';
  final mo = (sizeBytes / 1_000_000).toStringAsFixed(1);
  return sizeKind == 'estimated' ? '$mo Mo (estimée)' : '$mo Mo';
}

/// Libellés VÉRACES : un Opus est toujours « compressé (lossy) », y compris
/// 256 ; l'original n'affiche que la qualité mesurée par l'analyse technique.
String offlineOptionTitle(OfflineOption option) => switch (option.profile) {
  OfflineProfile.opus128 => 'Opus 128 kb/s',
  OfflineProfile.opus256 => 'Opus 256 kb/s',
  OfflineProfile.original => 'Original (copie exacte)',
};

String offlineOptionSubtitle(OfflineOption option) {
  final size = formatOfflineSize(option.sizeBytes, option.sizeKind);
  return switch (option.profile) {
    OfflineProfile.opus128 =>
      'Économie de stockage · compressé (lossy) · $size',
    OfflineProfile.opus256 =>
      'Haute qualité compacte · compressé (lossy) · $size',
    OfflineProfile.original => [
      if (option.codec != null) option.codec!.toUpperCase(),
      'qualité ${option.qualityStatus ?? 'inconnue'}',
      size,
    ].join(' · '),
  };
}

class _OfflineChoiceTile extends StatelessWidget {
  const _OfflineChoiceTile({
    super.key,
    required this.option,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final OfflineOption option;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return ListTile(
      enabled: enabled,
      onTap: enabled ? onTap : null,
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.chipRadius,
        side: BorderSide(
          color: selected ? colors.accent : colors.surfaceSunken,
          width: selected ? 2 : 1,
        ),
      ),
      leading: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_off_rounded,
        color: selected ? colors.accent : colors.textTertiary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              offlineOptionTitle(option),
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (option.recommended)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.accentSoft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Recommandé',
                  style: TextStyle(
                    color: colors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        offlineOptionSubtitle(option),
        style: TextStyle(color: colors.textTertiary, fontSize: 12),
      ),
    );
  }
}

class _DownloadProgressView extends StatelessWidget {
  const _DownloadProgressView({required this.progress});

  final OfflineDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final label = switch (progress.status) {
      OfflineDownloadStatus.waitingServer =>
        progress.message ?? 'Préparation sur le serveur…',
      OfflineDownloadStatus.downloading => 'Téléchargement…',
      OfflineDownloadStatus.verifying => 'Vérification de l’empreinte…',
      _ => '…',
    };
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          key: const ValueKey('offline-download-progress'),
          value: progress.ratio,
          color: colors.accent,
          backgroundColor: colors.surfaceSunken,
        ),
        const SizedBox(height: 8),
        Text(label, style: TextStyle(color: colors.textSecondary)),
      ],
    );
  }
}
