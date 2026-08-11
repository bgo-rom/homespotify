import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../domain/local_playlist.dart';
import 'library_playlists.dart';

Future<LocalPlaylist?> showCreatePlaylistDialog(BuildContext context) {
  return showDialog<LocalPlaylist>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const _CreatePlaylistDialog(),
  );
}

Future<bool?> showRenamePlaylistDialog(
  BuildContext context, {
  required LocalPlaylist playlist,
}) {
  return showDialog<bool>(
    context: context,
    useRootNavigator: true,
    builder: (_) => _RenamePlaylistDialog(playlist: playlist),
  );
}

class _RenamePlaylistDialog extends ConsumerStatefulWidget {
  const _RenamePlaylistDialog({required this.playlist});

  final LocalPlaylist playlist;

  @override
  ConsumerState<_RenamePlaylistDialog> createState() =>
      _RenamePlaylistDialogState();
}

class _RenamePlaylistDialogState extends ConsumerState<_RenamePlaylistDialog> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.playlist.name,
  );
  String? _validationMessage;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      title: Text(
        'Renommer la playlist',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: TextField(
        controller: _nameController,
        autofocus: true,
        maxLength: 100,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Nom',
          errorText: _validationMessage,
        ),
        onSubmitted: _saving ? null : (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text('Annuler', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
          ),
          onPressed: _saving ? null : _submit,
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _validationMessage = null;
    });
    try {
      final renamed = await ref
          .read(playlistsProvider.notifier)
          .rename(widget.playlist.id, _nameController.text);
      if (!mounted) return;
      if (!renamed) {
        setState(() {
          _saving = false;
          _validationMessage = 'Playlist introuvable.';
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on PlaylistValidationException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationMessage = error.message;
      });
    } catch (error, stackTrace) {
      logError(
        'échec renommage playlist',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationMessage = 'Impossible de renommer la playlist.';
      });
    }
  }
}

class _CreatePlaylistDialog extends ConsumerStatefulWidget {
  const _CreatePlaylistDialog();

  @override
  ConsumerState<_CreatePlaylistDialog> createState() =>
      _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends ConsumerState<_CreatePlaylistDialog> {
  final TextEditingController _nameController = TextEditingController();
  String? _validationMessage;
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      title: Text(
        'Créer une playlist',
        style: TextStyle(color: colors.textPrimary),
      ),
      content: TextField(
        controller: _nameController,
        autofocus: true,
        maxLength: 80,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          labelText: 'Nom',
          errorText: _validationMessage,
        ),
        onSubmitted: _saving ? null : (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: Text('Annuler', style: TextStyle(color: colors.textSecondary)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.accent,
            foregroundColor: colors.onAccent,
          ),
          onPressed: _saving ? null : _submit,
          child: const Text('Créer'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _validationMessage = null;
    });
    try {
      final playlist = await ref
          .read(playlistsProvider.notifier)
          .create(_nameController.text);
      if (!mounted) return;
      Navigator.of(context).pop(playlist);
    } on PlaylistValidationException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationMessage = error.message;
      });
    } catch (error, stackTrace) {
      logError(
        'échec création playlist depuis dialogue',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _validationMessage = 'Impossible de créer la playlist.';
      });
    }
  }
}

Future<void> showAddTrackToPlaylistSheet(
  BuildContext context, {
  required int trackId,
}) {
  logUi('ouverture sélection playlist: trackId=$trackId');
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: context.colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.tile)),
    ),
    builder: (_) => _AddTrackToPlaylistSheet(trackId: trackId),
  );
}

class _AddTrackToPlaylistSheet extends ConsumerStatefulWidget {
  const _AddTrackToPlaylistSheet({required this.trackId});

  final int trackId;

  @override
  ConsumerState<_AddTrackToPlaylistSheet> createState() =>
      _AddTrackToPlaylistSheetState();
}

class _AddTrackToPlaylistSheetState
    extends ConsumerState<_AddTrackToPlaylistSheet> {
  final TextEditingController _search = TextEditingController();
  final TextEditingController _newName = TextEditingController();
  bool _creating = false;
  bool _saving = false;
  final Set<String> _pendingPlaylistIds = <String>{};
  String? _creationError;

  @override
  void dispose() {
    _search.dispose();
    _newName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final playlists = ref.watch(playlistsProvider);
    final playlistItems = playlists.asData?.value ?? const <LocalPlaylist>[];
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.62,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.surfaceSunken,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Ajouter à une playlist',
                style: TextStyle(
                  color: colors.textPrimary,
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          ListTile(
            leading: Icon(Icons.add_rounded, color: colors.accent),
            title: Text(
              'Créer une playlist',
              style: TextStyle(color: colors.textPrimary),
            ),
            onTap: () => setState(() => _creating = !_creating),
          ),
          if (_creating)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('playlist-inline-name'),
                      controller: _newName,
                      autofocus: true,
                      enabled: !_saving,
                      decoration: InputDecoration(
                        labelText: 'Nom de la nouvelle playlist',
                        errorText: _creationError,
                      ),
                      onSubmitted: (_) => _createAndAdd(context, ref),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: 'Créer et ajouter',
                    onPressed: _saving
                        ? null
                        : () => _createAndAdd(context, ref),
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                  ),
                ],
              ),
            ),
          Divider(height: 1, color: colors.surfaceSunken),
          if (playlistItems.length > 8)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: TextField(
                key: const ValueKey('playlist-search'),
                controller: _search,
                decoration: const InputDecoration(
                  hintText: 'Rechercher une playlist',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          Expanded(
            child: playlists.when(
              loading: () => Center(
                child: CircularProgressIndicator(color: colors.accent),
              ),
              error: (_, _) => Center(
                child: Text(
                  'Impossible de charger les playlists.',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ),
              data: (items) => items.isEmpty
                  ? Center(
                      child: Text(
                        'Aucune playlist',
                        style: TextStyle(color: colors.textTertiary),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _filtered(items).length,
                      itemBuilder: (context, index) {
                        final playlist = _filtered(items)[index];
                        final alreadyAdded = playlist.trackIds.contains(
                          widget.trackId,
                        );
                        return ListTile(
                          key: ValueKey('playlist-toggle-${playlist.id}'),
                          leading: Icon(
                            Icons.queue_music_rounded,
                            color: colors.textSecondary,
                          ),
                          title: Text(
                            playlist.name,
                            style: TextStyle(color: colors.textPrimary),
                          ),
                          subtitle: Text(
                            '${playlist.trackCount} '
                            '${playlist.trackCount > 1 ? 'pistes' : 'piste'}',
                            style: TextStyle(color: colors.textSecondary),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_pendingPlaylistIds.contains(playlist.id))
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colors.accent,
                                    ),
                                  ),
                                ),
                              AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                child: alreadyAdded
                                    ? Icon(
                                        Icons.check_circle_rounded,
                                        key: const ValueKey('playlist-selected'),
                                        color: colors.accent,
                                      )
                                    : Icon(
                                        Icons.circle_outlined,
                                        key: const ValueKey(
                                          'playlist-unselected',
                                        ),
                                        color: colors.textTertiary,
                                      ),
                              ),
                            ],
                          ),
                          onTap: _pendingPlaylistIds.contains(playlist.id)
                              ? null
                              : () => _togglePlaylist(
                                  context,
                                  ref,
                                  playlist,
                                  alreadyAdded: alreadyAdded,
                                ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createAndAdd(BuildContext context, WidgetRef ref) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _creationError = null;
    });
    try {
      final playlist = await ref
          .read(playlistsProvider.notifier)
          .create(_newName.text);
      if (!context.mounted) return;
      await _togglePlaylist(context, ref, playlist, alreadyAdded: false);
      if (!mounted) return;
      _newName.clear();
      setState(() => _creating = false);
    } on PlaylistValidationException catch (error) {
      if (mounted) setState(() => _creationError = error.message);
    } catch (error, stackTrace) {
      logError(
        'échec création playlist inline',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _creationError = 'Impossible de créer la playlist.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<LocalPlaylist> _filtered(List<LocalPlaylist> items) {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return items;
    return items
        .where((playlist) => playlist.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  Future<void> _togglePlaylist(
    BuildContext context,
    WidgetRef ref,
    LocalPlaylist playlist, {
    required bool alreadyAdded,
  }) async {
    if (!_pendingPlaylistIds.add(playlist.id)) return;
    setState(() {});
    final messenger = ScaffoldMessenger.of(context);
    try {
      final controller = ref.read(playlistsProvider.notifier);
      final changed = alreadyAdded
          ? await controller.removeTrack(playlist.id, widget.trackId)
          : await controller.addTrack(playlist.id, widget.trackId);
      if (!context.mounted) return;
      if (changed) {
        messenger.showSnackBar(
          SnackBar(
            duration: const Duration(milliseconds: 900),
            content: Text(
              alreadyAdded
                  ? 'Piste retirée de « ${playlist.name} ».'
                  : 'Piste ajoutée à « ${playlist.name} ».',
            ),
          ),
        );
      }
    } catch (error, stackTrace) {
      logError(
        'échec modification playlist depuis lecteur',
        error: error,
        stackTrace: stackTrace,
      );
      messenger.showSnackBar(
        const SnackBar(content: Text('Impossible de modifier la playlist.')),
      );
    } finally {
      if (mounted) {
        setState(() => _pendingPlaylistIds.remove(playlist.id));
      }
    }
  }
}
