import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../auth/application/auth_controller.dart';
import '../../library/domain/track.dart';
import '../application/offline_batch_download_manager.dart';
import '../application/offline_profile_preference.dart';
import '../domain/offline_models.dart';
import 'offline_download_sheet.dart' show formatOfflineSize;

Future<void> showOfflineGroupDownloadSheet(
  BuildContext context, {
  required OfflineGroupType type,
  required String sourceId,
  required String title,
  required List<Track> tracks,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.tile)),
    ),
    builder: (_) => OfflineGroupDownloadSheet(
      type: type,
      sourceId: sourceId,
      title: title,
      tracks: tracks,
    ),
  );
}

class OfflineGroupDownloadSheet extends ConsumerStatefulWidget {
  const OfflineGroupDownloadSheet({
    super.key,
    required this.type,
    required this.sourceId,
    required this.title,
    required this.tracks,
  });

  final OfflineGroupType type;
  final String sourceId;
  final String title;
  final List<Track> tracks;

  @override
  ConsumerState<OfflineGroupDownloadSheet> createState() =>
      _OfflineGroupDownloadSheetState();
}

class _OfflineGroupDownloadSheetState
    extends ConsumerState<OfflineGroupDownloadSheet> {
  OfflineProfile _selected = OfflineProfile.opus256;
  bool _starting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPreference();
  }

  Future<void> _loadPreference() async {
    final profile = await ref.read(offlineProfilePreferenceProvider).load();
    if (mounted) setState(() => _selected = profile);
  }

  int _estimatedBytes(OfflineProfile profile) {
    return widget.tracks.fold<int>(0, (sum, track) {
      if (profile == OfflineProfile.original) {
        return sum + (track.sizeBytes ?? 0);
      }
      final bitrate = profile == OfflineProfile.opus256 ? 256 : 128;
      return sum + ((track.durationSeconds ?? 0) * bitrate * 125).ceil();
    });
  }

  Future<void> _start() async {
    final userId = ref.read(authControllerProvider).user?.id;
    if (userId == null || _starting) return;
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      await ref.read(offlineProfilePreferenceProvider).save(_selected);
      await ref
          .read(offlineBatchDownloadManagerProvider)
          .createAndStart(
            userId: userId,
            type: widget.type,
            sourceId: widget.sourceId,
            title: widget.title,
            tracks: widget.tracks,
            profile: _selected,
          );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Téléchargement ajouté à la file. Suivi dans Téléchargements.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final count = widget.tracks.length;
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
              'Télécharger « ${widget.title} »',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colors.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '$count ${count > 1 ? 'pistes' : 'piste'} · progression et reprise individuelles',
              style: TextStyle(color: colors.textTertiary, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            for (final profile in OfflineProfile.values)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _GroupProfileTile(
                  profile: profile,
                  selected: _selected == profile,
                  sizeBytes: _estimatedBytes(profile),
                  sizeEstimated: profile != OfflineProfile.original,
                  enabled: !_starting,
                  onTap: () => setState(() => _selected = profile),
                ),
              ),
            Text(
              'Les téléchargements utilisent le Wi‑Fi par défaut. La file '
              'reprend automatiquement après un redémarrage ou le retour du '
              'réseau autorisé.',
              style: TextStyle(color: colors.textTertiary, fontSize: 11.5),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                key: const ValueKey('offline-group-error'),
                style: TextStyle(color: colors.danger),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const ValueKey('offline-group-start'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: colors.onAccent,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _starting ? null : _start,
              icon: _starting
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colors.onAccent,
                      ),
                    )
                  : const Icon(Icons.download_for_offline_rounded),
              label: Text(_starting ? 'Ajout à la file…' : 'Télécharger tout'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupProfileTile extends StatelessWidget {
  const _GroupProfileTile({
    required this.profile,
    required this.selected,
    required this.sizeBytes,
    required this.sizeEstimated,
    required this.enabled,
    required this.onTap,
  });

  final OfflineProfile profile;
  final bool selected;
  final int sizeBytes;
  final bool sizeEstimated;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = switch (profile) {
      OfflineProfile.opus128 => 'Opus 128 kb/s',
      OfflineProfile.opus256 => 'Opus 256 kb/s · recommandé',
      OfflineProfile.original => 'Original FLAC/WAV',
    };
    final quality = switch (profile) {
      OfflineProfile.opus128 => 'Économie · compressé (lossy)',
      OfflineProfile.opus256 => 'Haute qualité compacte · compressé (lossy)',
      OfflineProfile.original => 'Copie exacte · qualité mesurée de la source',
    };
    final colors = context.colors;
    return ListTile(
      key: ValueKey('offline-group-profile-${profile.wire}'),
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
      title: Text(
        title,
        style: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '$quality · ${formatOfflineSize(sizeBytes, sizeEstimated ? 'estimated' : 'exact')}',
        style: TextStyle(color: colors.textTertiary, fontSize: 12),
      ),
    );
  }
}
