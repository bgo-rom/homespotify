import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/home_design.dart';
import '../../discovery/data/discovery_api.dart';
import '../../discovery/domain/discovery_models.dart';
import '../domain/catalog_models.dart';

/// Clés canoniques déjà demandées pendant cette session (badge « Déjà
/// demandé » immédiat après envoi ; le serveur reste la source de vérité
/// pour les doublons).
class CatalogRequestedKeysController extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void markRequested(String key) {
    if (key.isEmpty) return;
    state = {...state, key};
  }
}

final catalogRequestedKeysProvider =
    NotifierProvider<CatalogRequestedKeysController, Set<String>>(
      CatalogRequestedKeysController.new,
      name: 'catalogRequestedKeys',
    );

/// Brouillon présenté par la bottom sheet. AUCUN champ userId, chemin cible,
/// source de téléchargement ou credential : uniquement le snapshot descriptif.
class CatalogRequestSheetData {
  const CatalogRequestSheetData({
    required this.requestType,
    required this.canonicalKey,
    required this.title,
    this.artist,
    this.album,
    this.coverUrl,
    this.externalUrl,
    this.items = const [],
    this.ownedItemTitles = const {},
  });

  final MusicRequestType requestType;
  final String canonicalKey;
  final String title;
  final String? artist;
  final String? album;
  final String? coverUrl;
  final String? externalUrl;
  final List<MusicRequestDraftItem> items;

  /// Titres (normalisés) déjà présents dans la bibliothèque du compte.
  final Set<String> ownedItemTitles;

  factory CatalogRequestSheetData.fromTrack(CatalogResult result) {
    return CatalogRequestSheetData(
      requestType: MusicRequestType.track,
      canonicalKey: result.canonicalKey,
      title: result.title,
      artist: result.artistLabel.isEmpty ? null : result.artistLabel,
      album: result.album,
      coverUrl: result.imageUrl,
      externalUrl: result.primaryReference?.externalUrl,
      items: [
        MusicRequestDraftItem(
          title: result.title,
          artist: result.artistLabel.isEmpty ? null : result.artistLabel,
          album: result.album,
          durationMs: result.durationMs,
          isrc: result.isrc,
        ),
      ],
    );
  }

  factory CatalogRequestSheetData.fromAlbum(
    CatalogAlbumDetail album, {
    Set<String> ownedItemTitles = const {},
  }) {
    final artist = album.artistNames.join(', ');
    return CatalogRequestSheetData(
      requestType: MusicRequestType.album,
      canonicalKey:
          'album:${album.reference?.provider ?? ''}:${album.reference?.externalId ?? album.title}',
      title: album.title,
      artist: artist.isEmpty ? null : artist,
      album: album.title,
      coverUrl: album.imageUrl,
      externalUrl: album.reference?.externalUrl,
      ownedItemTitles: ownedItemTitles,
      // Snapshot ORDONNÉ de la tracklist : la demande reste compréhensible
      // même si la source externe change ou disparaît.
      items: album.tracks
          .map(
            (track) => MusicRequestDraftItem(
              title: track.title,
              artist: track.artistNames.isEmpty
                  ? (artist.isEmpty ? null : artist)
                  : track.artistNames.join(', '),
              album: album.title,
              durationMs: track.durationMs,
              isrc: track.isrc,
            ),
          )
          .toList(growable: false),
    );
  }
}

/// Ouvre la bottom sheet de demande. Retourne true si la demande est partie.
Future<bool> showCatalogRequestSheet(
  BuildContext context,
  WidgetRef ref,
  CatalogRequestSheetData data,
) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: HomeDesign.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HomeDesign.radiusLarge),
      ),
    ),
    builder: (context) => _CatalogRequestSheet(data: data),
  );
  return sent ?? false;
}

class _CatalogRequestSheet extends ConsumerStatefulWidget {
  const _CatalogRequestSheet({required this.data});

  final CatalogRequestSheetData data;

  @override
  ConsumerState<_CatalogRequestSheet> createState() =>
      _CatalogRequestSheetState();
}

class _CatalogRequestSheetState extends ConsumerState<_CatalogRequestSheet> {
  final TextEditingController _noteController = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final data = widget.data;
    final note = _noteController.text.trim();
    try {
      await ref
          .read(discoveryApiProvider)
          .createCustomRequest(
            MusicRequestDraft(
              requestType: data.requestType,
              title: data.title,
              artist: data.artist,
              album: data.requestType == MusicRequestType.track
                  ? data.album
                  : null,
              externalUrl: data.externalUrl,
              coverUrl: data.coverUrl,
              userNote: note.isEmpty ? null : note,
              items: data.items,
            ),
          );
      ref
          .read(catalogRequestedKeysProvider.notifier)
          .markRequested(data.canonicalKey);
      if (mounted) Navigator.of(context).pop(true);
    } on DiscoveryApiException catch (error) {
      if (error.code == 'already_owned' ||
          error.code == 'duplicate_active_request') {
        ref
            .read(catalogRequestedKeysProvider.notifier)
            .markRequested(data.canonicalKey);
      }
      if (mounted) {
        setState(() {
          _sending = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final missingCount = data.items
        .where(
          (item) => !data.ownedItemTitles.contains(item.title.toLowerCase()),
        )
        .length;
    final ownedCount = data.items.length - missingCount;
    return Padding(
      padding: EdgeInsets.only(
        left: HomeDesign.space20,
        right: HomeDesign.space20,
        top: HomeDesign.space20,
        bottom:
            MediaQuery.of(context).viewInsets.bottom + HomeDesign.space20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: data.coverUrl == null
                      ? const ColoredBox(
                          color: HomeDesign.surfaceMuted,
                          child: Icon(
                            Icons.music_note_rounded,
                            color: Colors.white38,
                          ),
                        )
                      : Image.network(
                          data.coverUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: HomeDesign.surfaceMuted,
                            child: Icon(
                              Icons.music_note_rounded,
                              color: Colors.white38,
                            ),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: HomeDesign.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (data.artist != null)
                      Text(
                        data.artist!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    Text(
                      switch (data.requestType) {
                        MusicRequestType.track => 'Demande de titre',
                        MusicRequestType.album =>
                          'Demande d’album — ${data.items.length} pistes',
                        MusicRequestType.playlist =>
                          'Demande de playlist — ${data.items.length} titres',
                      },
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (ownedCount > 0) ...[
            const SizedBox(height: HomeDesign.space12),
            Text(
              '$ownedCount titre(s) déjà dans ta bibliothèque — '
              '$missingCount manquant(s) seront traités.',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
          const SizedBox(height: HomeDesign.space16),
          TextField(
            key: const ValueKey('catalog-request-note'),
            controller: _noteController,
            maxLength: 500,
            maxLines: 2,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: 'Note facultative pour le propriétaire',
              labelStyle: TextStyle(color: Colors.white54),
              counterStyle: TextStyle(color: Colors.white38),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderSide: BorderSide(color: HomeDesign.accent),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: HomeDesign.space8),
            Text(
              _error!,
              key: const ValueKey('catalog-request-error'),
              style: const TextStyle(color: HomeDesign.danger),
            ),
          ],
          const SizedBox(height: HomeDesign.space16),
          FilledButton.icon(
            key: const ValueKey('catalog-request-send'),
            style: FilledButton.styleFrom(
              backgroundColor: HomeDesign.accent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(
                vertical: HomeDesign.space12,
              ),
            ),
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : const Icon(Icons.send_rounded),
            label: const Text('Envoyer la demande'),
          ),
        ],
      ),
    );
  }
}
