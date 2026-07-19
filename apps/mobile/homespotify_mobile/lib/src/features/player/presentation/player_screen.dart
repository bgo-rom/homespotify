import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../library/presentation/library_albums.dart';
import '../../library/presentation/library_artists.dart';
import '../../library/application/track_library_membership.dart';
import '../../library/presentation/library_favorites.dart';
import '../../library/presentation/playlist_dialogs.dart';
import '../../library/presentation/track_removal.dart';
import '../../library/presentation/widgets/track_favorite_button.dart';
import '../../auth/application/auth_controller.dart';
import '../audio/homespotify_audio_handler.dart';
import 'player_providers.dart';
import 'widgets/file_details_sheet.dart';
import 'widgets/seek_bar.dart';
import 'track_speed_sheet.dart';

const Color _accent = Color(0xFF1DB954);
String? _lastPlayerArtworkTrace;
final Set<String> _playerArtworkErrors = <String>{};

void _tracePlayerArtwork(MediaItem? mediaItem) {
  if (!kDebugMode || mediaItem == null) return;
  final uri = mediaItem.artUri;
  final key = '${mediaItem.id}|$uri';
  if (_lastPlayerArtworkTrace == key) return;
  _lastPlayerArtworkTrace = key;
  final scheme = uri == null || uri.scheme.isEmpty ? 'null' : uri.scheme;
  debugPrint(
    '[ARTWORK_TRACE] F full-player trackId=${mediaItem.id} '
    'mediaItemId=${mediaItem.id} artUri=${uri ?? 'null'} scheme=$scheme '
    'widget=${uri == null ? 'placeholder' : 'AuthenticatedNetworkImage'} '
    'fallback=${uri == null} reason=${uri == null ? 'artUri_null' : 'none'}',
  );
}

/// Écran principal de lecture.
///
/// Sombre, centré, branché sur les streams de [HomeSpotifyAudioHandler] via
/// Riverpod. Le tick de position est isolé dans [_ProgressBar] pour ne pas
/// reconstruire la pochette/les contrôles ~5 fois par seconde.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static const Duration _seekStep = Duration(seconds: 10);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    _tracePlayerArtwork(mediaItem);
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final queue = ref.watch(queueProvider).asData?.value ?? const <MediaItem>[];

    final hasTrack = mediaItem != null;
    final playing = playback?.playing ?? false;
    final processing = playback?.processingState;
    final isBusy =
        processing == AudioProcessingState.loading ||
        processing == AudioProcessingState.buffering;
    final hasError = processing == AudioProcessingState.error;
    final queueIndex = playback?.queueIndex ?? -1;
    final shuffleOn = playback?.shuffleMode == AudioServiceShuffleMode.all;
    final repeatMode = playback?.repeatMode ?? AudioServiceRepeatMode.none;
    // Avec shuffle ou répétition de file, l'ordre effectif permet toujours de
    // naviguer (le handler borne lui-même) ; sinon, limites séquentielles.
    final wrap = shuffleOn || repeatMode == AudioServiceRepeatMode.all;
    final canSkipPrevious =
        queueIndex >= 0 &&
        queueIndex < queue.length &&
        queue.length > 1 &&
        (wrap || queueIndex > 0);
    final canSkipNext =
        queueIndex >= 0 &&
        queue.length > 1 &&
        (wrap || queueIndex < queue.length - 1);

    return PopScope(
      // Retour UI et retour système Android identiques : retour à l'écran qui
      // a ouvert le lecteur (bibliothèque, albums, détail album). Une seule
      // instance de /player est garantie par openPlayer → jamais de double
      // retour. La lecture audio n'est pas touchée.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        closePlayer(context);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0D10),
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF20202A), Color(0xFF0D0D10)],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final header = Row(
                    children: [
                      IconButton(
                        tooltip: 'Retour',
                        onPressed: () => closePlayer(context),
                        color: Colors.white,
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                      Expanded(
                        child: Text(
                          'EN LECTURE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 12,
                            letterSpacing: 2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TrackFavoriteButton(
                        trackId: int.tryParse(mediaItem?.id ?? ''),
                        iconSize: 22,
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        tooltip: 'Arrêter',
                        onPressed: hasTrack
                            ? () => ref.read(audioHandlerProvider).stop()
                            : null,
                        color: Colors.white,
                        disabledColor: Colors.white24,
                        icon: const Icon(Icons.stop_rounded),
                      ),
                      _PlayerMenu(mediaItem: mediaItem),
                    ],
                  );
                  final controlsBlock = Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _TrackInfo(
                        title: mediaItem?.title ?? 'Aucune piste en lecture',
                        artist: mediaItem?.artist ?? '—',
                        dimmed: !hasTrack,
                      ),
                      if (hasError)
                        _ErrorBanner(message: playback?.errorMessage),
                      const SizedBox(height: 20),
                      _ProgressBar(enabled: hasTrack),
                      const SizedBox(height: 8),
                      _Controls(
                        playing: playing,
                        isBusy: isBusy,
                        enabled: hasTrack,
                        onPlayPause: isBusy && !playing
                            ? null
                            : hasError
                            ? null
                            : () {
                                final handler = ref.read(audioHandlerProvider);
                                playing ? handler.pause() : handler.play();
                              },
                        onPrevious: canSkipPrevious
                            ? () => ref
                                  .read(audioHandlerProvider)
                                  .skipToPrevious()
                            : null,
                        onNext: canSkipNext
                            ? () => ref.read(audioHandlerProvider).skipToNext()
                            : null,
                        onSeekBackward: () => _seekBy(ref, -_seekStep),
                        onSeekForward: () => _seekBy(ref, _seekStep),
                      ),
                      _ShuffleRepeatRow(
                        enabled: hasTrack,
                        shuffleOn: shuffleOn,
                        repeatMode: repeatMode,
                      ),
                      const SizedBox(height: 4),
                      const _VolumeControl(),
                      const SizedBox(height: 12),
                    ],
                  );

                  // Hauteur très réduite (paysage, multi-fenêtre) : pas de
                  // pochette et contenu défilant — aucun overflow possible.
                  if (constraints.maxHeight < 480) {
                    return SingleChildScrollView(
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          header,
                          if (isBusy) ...[
                            const SizedBox(height: 8),
                            _PlaybackStatus(processingState: processing),
                          ],
                          const SizedBox(height: 20),
                          controlsBlock,
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: [
                      const SizedBox(height: 12),
                      header,
                      if (isBusy) ...[
                        const SizedBox(height: 8),
                        _PlaybackStatus(processingState: processing),
                      ],
                      // La pochette absorbe la hauteur restante et se réduit
                      // d'elle-même : les contrôles gardent toujours leur place.
                      Expanded(
                        child: Center(
                          child: _Artwork(
                            trackId: mediaItem?.id,
                            artUri: mediaItem?.artUri,
                          ),
                        ),
                      ),
                      controlsBlock,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _seekBy(WidgetRef ref, Duration delta) {
    final data = ref.read(positionDataProvider).asData?.value;
    if (data == null || data.duration <= Duration.zero) return;
    var target = data.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > data.duration) target = data.duration;
    ref.read(audioHandlerProvider).seek(target);
  }
}

enum _PlayerMenuAction {
  artistPage('Voir la page de l’artiste', Icons.person_rounded),
  artistAlbums('Voir les albums de l’artiste', Icons.library_music_rounded),
  trackAlbum('Voir l’album de cette piste', Icons.album_rounded),
  favorite('Ajouter aux favoris', Icons.favorite_border_rounded),
  playlist('Ajouter à une playlist', Icons.playlist_add_rounded),
  speed('Vitesse du titre', Icons.speed_rounded),
  fileDetails('Détails du fichier', Icons.info_outline_rounded),
  share('Partager', Icons.share_rounded),

  /// Libellé RÉEL résolu à l'ouverture du menu selon `inMyLibrary` du compte
  /// connecté (cf. trackMembershipProvider) : « Ajouter à ma bibliothèque » si
  /// la piste n'y est pas — cas d'une écoute depuis le catalogue global.
  libraryMembership(
    'Supprimer de ma bibliothèque',
    Icons.delete_outline_rounded,
  );

  const _PlayerMenuAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// Menu « 3 points » du lecteur complet. Aucune action ici ne touche à la
/// lecture audio : navigation ou SnackBar seulement.
class _PlayerMenu extends ConsumerWidget {
  const _PlayerMenu({required this.mediaItem});

  final MediaItem? mediaItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = mediaItem != null;
    final trackId = int.tryParse(mediaItem?.id ?? '');
    final isFavorite =
        trackId != null && ref.watch(isFavoriteProvider(trackId));
    // Appartenance RÉELLE à la bibliothèque du compte connecté : jamais déduite
    // de l'écran d'origine, du catalogue ni du fait que la piste soit en cours
    // de lecture (une piste du catalogue global se joue sans être possédée).
    final membership = trackId == null
        ? null
        : ref.watch(trackMembershipProvider(trackId));
    return PopupMenuButton<_PlayerMenuAction>(
      tooltip: 'Plus d’options',
      icon: const Icon(Icons.more_vert_rounded, color: Colors.white),
      color: const Color(0xFF23232B),
      onOpened: () => logUi('tap menu 3 points lecteur'),
      onSelected: (action) => _onSelected(context, ref, action),
      itemBuilder: (context) => [
        _item(_PlayerMenuAction.artistPage, enabled: hasTrack),
        _item(_PlayerMenuAction.artistAlbums, enabled: hasTrack),
        _item(_PlayerMenuAction.trackAlbum, enabled: hasTrack),
        const PopupMenuDivider(),
        _item(
          _PlayerMenuAction.favorite,
          enabled: hasTrack && trackId != null,
          label: isFavorite ? 'Retirer des favoris' : 'Ajouter aux favoris',
        ),
        _item(_PlayerMenuAction.playlist, enabled: hasTrack),
        _item(_PlayerMenuAction.speed, enabled: hasTrack && trackId != null),
        _item(_PlayerMenuAction.fileDetails, enabled: hasTrack),
        _item(_PlayerMenuAction.share, enabled: hasTrack),
        const PopupMenuDivider(),
        // Libellé STRICTEMENT dérivé de l'appartenance réelle (`user_tracks`)
        // du compte connecté. Tant que l'état est inconnu, l'entrée est
        // désactivée : jamais de bouton menteur.
        _item(
          _PlayerMenuAction.libraryMembership,
          enabled:
              hasTrack && trackId != null && membership?.inMyLibrary != null,
          label: (membership?.inMyLibrary ?? false)
              ? 'Supprimer de ma bibliothèque'
              : 'Ajouter à ma bibliothèque',
          icon: (membership?.inMyLibrary ?? false)
              ? Icons.delete_outline_rounded
              : Icons.library_add_outlined,
        ),
      ],
    );
  }

  PopupMenuItem<_PlayerMenuAction> _item(
    _PlayerMenuAction action, {
    required bool enabled,
    String? label,
    IconData? icon,
  }) {
    return PopupMenuItem<_PlayerMenuAction>(
      value: action,
      enabled: enabled,
      child: Row(
        children: [
          Icon(
            icon ?? action.icon,
            size: 18,
            color: enabled ? Colors.white70 : Colors.white24,
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              label ?? action.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: enabled ? Colors.white : Colors.white38,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onSelected(
    BuildContext context,
    WidgetRef ref,
    _PlayerMenuAction action,
  ) {
    logUi('menu lecteur: ${action.name} ("${action.label}")');
    switch (action) {
      case _PlayerMenuAction.trackAlbum:
        // Clé dérivée des métadonnées de la piste (album absent → « Album
        // inconnu ») ; route base64Url sûre, aucun caractère spécial dans
        // l'URI. Remplace /player pour ne jamais empiler deux lecteurs.
        openAlbumDetailFromPlayer(context, albumKeyForTitle(mediaItem?.album));
      case _PlayerMenuAction.artistPage:
        _openArtist(context, focusAlbums: false);
      case _PlayerMenuAction.artistAlbums:
        _openArtist(context, focusAlbums: true);
      case _PlayerMenuAction.favorite:
        final trackId = int.tryParse(mediaItem?.id ?? '');
        if (trackId != null) {
          toggleFavoriteWithFeedback(context, ref, trackId);
        }
      case _PlayerMenuAction.playlist:
        final trackId = int.tryParse(mediaItem?.id ?? '');
        if (trackId != null) {
          showAddTrackToPlaylistSheet(context, trackId: trackId);
        }
      case _PlayerMenuAction.speed:
        final item = mediaItem;
        final trackId = int.tryParse(item?.id ?? '');
        final streamUri = Uri.tryParse(
          item?.extras?['streamUri'] as String? ?? '',
        );
        if (item != null &&
            trackId != null &&
            streamUri != null &&
            streamUri.hasScheme) {
          showTrackSpeedSheet(
            context,
            ref,
            target: TrackSpeedTarget(
              id: trackId,
              title: item.title,
              artist: item.artist ?? 'Artiste inconnu',
              streamUri: streamUri,
              headers: ref.read(mediaAuthorizationHeadersProvider),
            ),
          );
        }
      case _PlayerMenuAction.fileDetails:
        final item = mediaItem;
        if (item != null) {
          showFileDetailsSheet(context, mediaItem: item);
        }
      case _PlayerMenuAction.share:
        _comingSoon(context, '${action.label} : bientôt disponible');
      case _PlayerMenuAction.libraryMembership:
        final trackId = int.tryParse(mediaItem?.id ?? '');
        if (trackId == null) return;
        final title = mediaItem?.title ?? 'cette piste';
        // L'état réel décide de l'action : la lecture n'est JAMAIS interrompue
        // (la piste reste jouable depuis le catalogue global).
        if (ref.read(trackMembershipProvider(trackId)).inMyLibrary ?? false) {
          confirmAndRemoveTrackFromLibrary(
            context,
            ref,
            trackId: trackId,
            title: title,
          );
        } else {
          addTrackToLibraryWithFeedback(
            context,
            ref,
            trackId: trackId,
            title: title,
          );
        }
    }
  }

  void _openArtist(BuildContext context, {required bool focusAlbums}) {
    final artistKey = artistKeyForName(mediaItem?.artist);
    if (artistKey == unknownArtistKey) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Artiste inconnu : aucune page artiste disponible.'),
        ),
      );
      return;
    }
    if (focusAlbums) {
      openArtistAlbumsFromPlayer(context, artistKey);
    } else {
      openArtistDetailFromPlayer(context, artistKey);
    }
  }

  void _comingSoon(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Boutons lecture aléatoire (gauche) et répétition (droite), sous les
/// contrôles principaux. Actif = vert accent, inactif = gris discret.
/// Ces boutons ne changent que l'ordre de lecture — aucun effet audio.
class _ShuffleRepeatRow extends ConsumerWidget {
  const _ShuffleRepeatRow({
    required this.enabled,
    required this.shuffleOn,
    required this.repeatMode,
  });

  final bool enabled;
  final bool shuffleOn;
  final AudioServiceRepeatMode repeatMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repeatActive = repeatMode != AudioServiceRepeatMode.none;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: shuffleOn
                ? 'Désactiver la lecture aléatoire'
                : 'Lecture aléatoire',
            onPressed: enabled
                ? () {
                    final next = !shuffleOn;
                    logUi(
                      'tap shuffle lecteur → ${next ? 'activé' : 'désactivé'}',
                    );
                    ref
                        .read(audioHandlerProvider)
                        .setShuffleMode(
                          next
                              ? AudioServiceShuffleMode.all
                              : AudioServiceShuffleMode.none,
                        );
                  }
                : null,
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            color: shuffleOn ? _accent : Colors.white54,
            disabledColor: Colors.white24,
            icon: const Icon(Icons.shuffle_rounded),
          ),
          IconButton(
            tooltip: 'File d’attente',
            onPressed: enabled ? () => openQueue(context) : null,
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            color: Colors.white54,
            disabledColor: Colors.white24,
            icon: const Icon(Icons.queue_music_rounded),
          ),
          IconButton(
            tooltip: switch (repeatMode) {
              AudioServiceRepeatMode.none => 'Répéter la file',
              AudioServiceRepeatMode.all ||
              AudioServiceRepeatMode.group => 'Répéter la piste',
              AudioServiceRepeatMode.one => 'Désactiver la répétition',
            },
            onPressed: enabled
                ? () {
                    // Cycle : aucune → file → piste → aucune.
                    final next = switch (repeatMode) {
                      AudioServiceRepeatMode.none => AudioServiceRepeatMode.all,
                      AudioServiceRepeatMode.all ||
                      AudioServiceRepeatMode.group =>
                        AudioServiceRepeatMode.one,
                      AudioServiceRepeatMode.one => AudioServiceRepeatMode.none,
                    };
                    logUi('tap repeat lecteur → ${next.name}');
                    ref.read(audioHandlerProvider).setRepeatMode(next);
                  }
                : null,
            iconSize: 22,
            visualDensity: VisualDensity.compact,
            color: repeatActive ? _accent : Colors.white54,
            disabledColor: Colors.white24,
            icon: Icon(
              repeatMode == AudioServiceRepeatMode.one
                  ? Icons.repeat_one_rounded
                  : Icons.repeat_rounded,
            ),
          ),
        ],
      ),
    );
  }
}

/// Barre de progression isolée : seul ce widget se reconstruit à chaque tick.
class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data =
        ref.watch(positionDataProvider).asData?.value ??
        PlayerPositionData.zero;
    final speed = ref.watch(playbackStateProvider).asData?.value.speed ?? 1;
    return SeekBar(
      position: data.position,
      bufferedPosition: data.bufferedPosition,
      duration: data.duration,
      speed: speed,
      onSeek: enabled
          ? (pos) => ref.read(audioHandlerProvider).seek(pos)
          : null,
    );
  }
}

/// Volume interne du lecteur, borné à 0–100 % sans gain supérieur à l'unité.
class _VolumeControl extends ConsumerWidget {
  const _VolumeControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = (ref.watch(volumeProvider).asData?.value ?? 1.0)
        .clamp(0.0, 1.0)
        .toDouble();
    return Row(
      children: [
        Icon(
          volume <= 0.0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          color: Colors.white54,
          size: 20,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: Colors.white70,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: const Color(0x291DB954),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: volume,
              onChanged: (v) => ref.read(audioHandlerProvider).setVolume(v),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(volume * 100).round()} %',
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFE57373),
            size: 16,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message ?? 'Erreur audio pendant la lecture.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFE57373), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackStatus extends StatelessWidget {
  const _PlaybackStatus({required this.processingState});

  final AudioProcessingState? processingState;

  @override
  Widget build(BuildContext context) {
    final label = processingState == AudioProcessingState.buffering
        ? 'Mise en tampon audio...'
        : 'Preparation de la lecture...';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.trackId, this.artUri});

  final String? trackId;
  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Marge verticale pour l'ombre portée ; plafonnée à 340 px.
        final side = math
            .min(constraints.maxWidth, constraints.maxHeight - 24)
            .clamp(0.0, 340.0);
        // Trop petit pour être utile : on laisse la place aux contrôles.
        if (side < 72) return const SizedBox.shrink();
        return _ArtworkBox(trackId: trackId, artUri: artUri, side: side);
      },
    );
  }
}

class _ArtworkBox extends StatelessWidget {
  const _ArtworkBox({
    required this.trackId,
    required this.artUri,
    required this.side,
  });

  final String? trackId;
  final Uri? artUri;
  final double side;

  @override
  Widget build(BuildContext context) {
    final cacheSide = (side * MediaQuery.devicePixelRatioOf(context)).round();
    return SizedBox(
      width: side,
      height: side,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: artUri == null
              ? const _ArtworkPlaceholder()
              : AuthenticatedNetworkImage(
                  artUri.toString(),
                  key: ValueKey('player_${trackId ?? 'none'}_$artUri'),
                  artworkTraceLabel: 'full-player trackId=${trackId ?? 'null'}',
                  fit: BoxFit.cover,
                  cacheWidth: cacheSide,
                  cacheHeight: cacheSide,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, error, stackTrace) {
                    final errorKey = '${trackId ?? 'none'}|$artUri|$error';
                    if (kDebugMode && _playerArtworkErrors.add(errorKey)) {
                      final stack = stackTrace
                          ?.toString()
                          .split('\n')
                          .take(3)
                          .join(' | ');
                      debugPrint(
                        '[ARTWORK_TRACE] G full-player '
                        'trackId=${trackId ?? 'null'} uri=$artUri '
                        'errorType=${error.runtimeType} message=$error '
                        'stack=${stack ?? 'none'}',
                      );
                    }
                    return const _ArtworkPlaceholder();
                  },
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : const _ArtworkPlaceholder(),
                ),
        ),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF33333F), Color(0xFF1A1A22)],
        ),
      ),
      child: Center(
        child: Icon(Icons.music_note_rounded, size: 88, color: Colors.white24),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.title,
    required this.artist,
    required this.dimmed,
  });

  final String title;
  final String artist;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: dimmed ? Colors.white54 : Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          artist,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.playing,
    required this.isBusy,
    required this.enabled,
    required this.onPlayPause,
    required this.onPrevious,
    required this.onNext,
    required this.onSeekBackward,
    required this.onSeekForward,
  });

  final bool playing;
  final bool isBusy;
  final bool enabled;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundIcon(
          tooltip: 'Piste précédente',
          icon: Icons.skip_previous_rounded,
          onPressed: enabled ? onPrevious : null,
        ),
        _RoundIcon(
          tooltip: 'Reculer de 10 secondes',
          icon: Icons.replay_10_rounded,
          onPressed: enabled ? onSeekBackward : null,
        ),
        _PlayPauseButton(
          playing: playing,
          isBusy: isBusy,
          onPressed: enabled ? onPlayPause : null,
        ),
        _RoundIcon(
          tooltip: 'Avancer de 10 secondes',
          icon: Icons.forward_10_rounded,
          onPressed: enabled ? onSeekForward : null,
        ),
        _RoundIcon(
          tooltip: 'Piste suivante',
          icon: Icons.skip_next_rounded,
          onPressed: enabled ? onNext : null,
        ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.tooltip, required this.icon, this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 32,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.playing,
    required this.isBusy,
    this.onPressed,
  });

  final bool playing;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled ? _accent : Colors.white12,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 72,
          height: 72,
          child: isBusy
              ? const Padding(
                  padding: EdgeInsets.all(22),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 40,
                  color: enabled ? Colors.black : Colors.white38,
                ),
        ),
      ),
    );
  }
}
