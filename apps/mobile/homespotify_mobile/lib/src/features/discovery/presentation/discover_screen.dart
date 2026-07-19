import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../app/main_navigation_state.dart';
import '../../../app/route_observer.dart';
import '../../../core/logging/app_logger.dart';
import '../../player/presentation/player_providers.dart';
import '../application/discovery_settings.dart';
import '../domain/discovery_models.dart';
import 'animated_success_overlay.dart';
import 'discover_deck_controller.dart';
import 'discovery_preview_controller.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _card = Color(0xFF1A1A22);
const Color _accent = Color(0xFF1DB954);
const Color _danger = Color(0xFFE57373);

/// Écran « Découvrir » : pile de cartes swipeables sur file pré-calculée.
///
/// - Rendu instantané depuis la file locale du serveur (skeletons brefs).
/// - Les 2 cartes suivantes sont pré-rendues sous la carte du dessus.
/// - Swipe verrouillé pendant la transmission d'une action ; en cas d'échec
///   backend la carte revient visuellement (rollback).
/// - L'état du paquet vit dans [discoverDeckProvider] : il survit aux cycles
///   de rebuild Riverpod et à la navigation.
/// - Extrait audio : lecteur global unique ([discoveryPreviewProvider]),
///   coupé au changement de carte, à la sortie d'écran, au logout et dès
///   qu'une piste de la bibliothèque démarre.
class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with WidgetsBindingObserver, RouteAware {
  /// Notifiers capturés en initState pour les arrêts déclenchés par ÉVÉNEMENT
  /// (arrière-plan via didChangeAppLifecycleState) — jamais dans dispose().
  late final DiscoveryPreviewController _preview;
  late final DiscoverDeckController _deck;

  /// Dernière carte pour laquelle l'autoplay a été armé (évite le ré-armement
  /// à chaque rebuild).
  int? _lastArmedId;

  /// true tant que l'overlay « Demande envoyée » est visible : suspend
  /// l'autoplay pour que le prochain extrait ne démarre QUE sur carte stable.
  bool _overlayActive = false;

  @override
  void initState() {
    super.initState();
    logUi('ouverture découverte par swipe');
    _preview = ref.read(discoveryPreviewProvider.notifier);
    _deck = ref.read(discoverDeckProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    // Rendu instantané si le paquet est déjà en mémoire ; sinon chargement.
    Future.microtask(() {
      if (!mounted) return;
      final deck = ref.read(discoverDeckProvider);
      if (!deck.loadedOnce) {
        ref.read(discoverDeckProvider.notifier).load();
      } else {
        ref.read(discoverDeckProvider.notifier).loadMoreIfNeeded();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Abonnement à l'observateur de routes : réagit à la VISIBILITÉ de l'écran
    // (didPushNext quand une route couvre Découvrir, didPopNext au retour), pas
    // seulement à son pop. Ré-abonnement idempotent (unsubscribe d'abord).
    final route = ModalRoute.of(context);
    if (route is ModalRoute<void>) {
      routeObserver
        ..unsubscribe(this)
        ..subscribe(this, route);
    }
  }

  /// Une route vient d'être empilée PAR-DESSUS Découvrir (ex. `/requests`,
  /// `/player`, tout push/go) : l'écran n'est plus visible → l'extrait s'arrête
  /// IMMÉDIATEMENT. C'est un ÉVÉNEMENT de navigation (hors phase de build), donc
  /// la mutation de provider est légale — contrairement à dispose/deactivate.
  @override
  void didPushNext() {
    _preview.stop();
  }

  /// Retour sur Découvrir (la route qui la couvrait a été dépilée). On NE force
  /// PAS de lecture : on laisse la logique normale de stabilisation réarmer
  /// l'autoplay UNIQUEMENT si les conditions sont réunies (cf. _maybeArmOnReturn).
  @override
  void didPopNext() {
    _maybeArmAutoplayOnReturn();
  }

  /// La route Découvrir elle-même a été DÉPILÉE (retour, mais aussi `go`/`pop`
  /// programmatique vers un ancêtre que le PopScope ne couvre pas toujours) :
  /// arrêt de l'extrait + du sondage. Événement de navigation → mutation légale.
  /// Idempotent avec le PopScope (les deux peuvent se déclencher sur un retour).
  @override
  void didPop() {
    _onLeaveScreen();
  }

  @override
  void dispose() {
    // dispose() ne mute AUCUN provider observé : Riverpod l'interdit pendant le
    // teardown/build (dispose ET deactivate crashent, tout comme un onDispose
    // de provider). L'arrêt de l'extrait + du sondage à la sortie d'écran passe
    // par un ÉVÉNEMENT de navigation (PopScope → _onLeaveScreen ; didPushNext),
    // seule phase où la mutation est légale. Ici, désabonnement de l'observateur
    // de routes et retrait de l'observer de cycle de vie — aucune mutation.
    routeObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App en arrière-plan : l'extrait se coupe (arrêt technique, pas de
    // signal PREVIEW_STOPPED_EARLY). En pause/détaché, on stoppe aussi le
    // sondage adaptatif de préparation (économie réseau/batterie).
    // Android passe brièvement par `inactive` lorsque le volet de notifications
    // est ouvert. Cet état seul ne masque pas l'app : conserver le lecteur et
    // son timer d'autoplay garantit un retour `resumed` transparent.
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _preview.stop();
        _deck.cancelRefresh();
      case AppLifecycleState.inactive:
      case AppLifecycleState.resumed:
        break;
    }
  }

  /// Arme l'autoplay différé pour la carte active, si le réglage l'autorise
  /// et qu'un extrait fiable existe. Une seule fois par carte. Suspendu tant
  /// que l'overlay de confirmation est visible (carte pas encore stable).
  void _armAutoplayFor(RecommendationCandidate? candidate) {
    if (_overlayActive) return;
    if (candidate == null) {
      _lastArmedId = null;
      _preview.disarmAutoplay();
      return;
    }
    if (candidate.id == _lastArmedId) return;
    _lastArmedId = candidate.id;
    final autoplayEnabled = ref
        .read(discoverySettingsProvider)
        .autoplayPreviews;
    if (autoplayEnabled && candidate.previewUrl != null) {
      _preview.armAutoplay(candidate);
    } else {
      _preview.disarmAutoplay();
    }
  }

  /// Réarme l'autoplay au RETOUR sur l'écran, sans JAMAIS forcer de double
  /// lecture. Ne réarme QUE si toutes les conditions sont réunies :
  ///  - overlay de succès inactif ;
  ///  - app au premier plan ;
  ///  - aucune piste de la bibliothèque en lecture ;
  ///  - une carte du dessus existe (non swipée / file non vide).
  /// Le réarmement délègue à [_armAutoplayFor], qui respecte le réglage
  /// autoplay et la présence d'un extrait (jamais de second lecteur ni de
  /// timer dupliqué : armAutoplay annule tout timer précédent).
  void _maybeArmAutoplayOnReturn() {
    if (!mounted || _overlayActive) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final libraryPlaying =
        ref.read(playbackStateProvider).asData?.value.playing ?? false;
    if (libraryPlaying) return;
    final top = ref.read(discoverDeckProvider).top;
    if (top == null) return;
    // Ancre réinitialisée : la carte redevenue visible peut être réarmée
    // proprement par la logique conditionnelle habituelle.
    _lastArmedId = null;
    _armAutoplayFor(top);
  }

  void _advance() {
    // Geste utilisateur : arrêt AVEC signal d'écoute écourtée éventuel.
    _lastArmedId = null;
    ref.read(discoveryPreviewProvider.notifier).stop(reportEarlyStop: true);
    ref.read(discoverDeckProvider.notifier).advance();
  }

  /// Précharge en cache les pochettes des 2 prochaines cartes : le swipe révèle
  /// une image déjà décodée (aucun flash). Erreur réseau ignorée (opportuniste).
  void _preloadNextArtworks(DiscoverDeckState deck) {
    for (final candidate in deck.deck.skip(1).take(2)) {
      final url = candidate.artworkUrl;
      if (url == null || url.isEmpty) continue;
      precacheImage(NetworkImage(url), context).catchError((Object _) {});
    }
  }

  Future<bool> _onDislike(RecommendationCandidate candidate) async {
    return ref.read(discoverDeckProvider.notifier).dislike(candidate);
  }

  /// Swipe droite : confirmation obligatoire avant l'envoi de la demande.
  Future<bool> _onRequest(RecommendationCandidate candidate) async {
    // La confirmation de demande coupe l'extrait (geste utilisateur).
    _preview.stop(reportEarlyStop: true);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: const Text(
          'Envoyer une demande ?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          '« ${candidate.title} » de ${candidate.artist} sera demandé au '
          'propriétaire du serveur, qui le traitera manuellement.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'Annuler',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Envoyer la demande'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;

    final accepted = await _deck.request(candidate);
    if (!mounted) return accepted;
    // Succès RÉEL (créé, sans erreur) : overlay premium. Un doublon / déjà
    // possédée retire aussi la carte (accepted) mais porte une erreur : pas
    // d'overlay de succès, seulement le message compact.
    final hasError = ref.read(discoverDeckProvider).error != null;
    if (accepted && !hasError) {
      _showSuccessOverlay(candidate);
    }
    _flushError();
    return accepted;
  }

  /// Overlay animé « Demande envoyée » : coupe l'extrait, suspend l'autoplay
  /// puis, une fois l'overlay terminé et la nouvelle carte stable, réarme
  /// l'autoplay sur la carte du dessus.
  void _showSuccessOverlay(RecommendationCandidate candidate) {
    _preview.stop();
    _overlayActive = true;
    _preview.disarmAutoplay();
    AnimatedSuccessOverlay.show(
      context,
      title: candidate.title,
      artist: candidate.artist,
      onDismissed: () {
        if (!mounted) return;
        _overlayActive = false;
        // Carte suivante désormais stable : autoplay autorisé à nouveau.
        _lastArmedId = null;
        _armAutoplayFor(ref.read(discoverDeckProvider).top);
      },
    );
  }

  /// SnackBar d'erreur COMPACTE, sombre et brève (échec/refus d'action). Les
  /// messages viennent du backend et restent affichés fidèlement.
  void _flushError() {
    final message = _deck.takeError();
    if (message != null && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message, style: const TextStyle(color: Colors.white)),
            backgroundColor: _card,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
    }
  }

  /// Arrêt de l'extrait + du sondage à la SORTIE d'écran (retour système /
  /// pop). Appelé depuis un ÉVÉNEMENT de navigation (PopScope), jamais depuis
  /// un life-cycle widget/provider : c'est la SEULE phase où Riverpod autorise
  /// la mutation des providers observés (dispose/deactivate/onDispose sont
  /// tous interdits — assertions de cycle de vie).
  void _onLeaveScreen() {
    _preview.stop();
    _deck.cancelRefresh();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(mainNavigationIndexProvider, (_, index) {
      if (index != HomeDestination.discover) {
        _preview.stop();
        _deck.cancelRefresh();
      } else if (ref.read(mainShellVisibilityProvider)) {
        _maybeArmAutoplayOnReturn();
      }
    });
    ref.listen<bool>(mainShellVisibilityProvider, (_, visible) {
      if (!visible) {
        _preview.stop();
        _deck.cancelRefresh();
      } else if (ref.read(mainNavigationIndexProvider) ==
          HomeDestination.discover) {
        _maybeArmAutoplayOnReturn();
      }
    });
    final deck = ref.watch(discoverDeckProvider);
    // Les erreurs d'action asynchrone remontent en snackbar, une seule fois.
    ref.listen(discoverDeckProvider.select((state) => state.error), (
      _,
      message,
    ) {
      if (message != null) _flushError();
    });
    // PopScope : intercepte la sortie d'écran (retour système / pop) comme un
    // ÉVÉNEMENT de navigation pour couper l'extrait IMMÉDIATEMENT, sans jamais
    // muter un provider depuis dispose()/deactivate() (interdit par Riverpod).
    // canPop reste true : on n'entrave pas la navigation, on l'observe.
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _onLeaveScreen();
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: Colors.white,
          title: const Text(
            'Découvrir',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          actions: [
            IconButton(
              key: const ValueKey('discover-catalog-search-button'),
              tooltip: 'Rechercher dans les catalogues',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => openCatalogSearch(context),
            ),
            IconButton(
              tooltip: 'Actualiser les recommandations',
              icon: deck.refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _accent,
                      ),
                    )
                  : const Icon(Icons.refresh_rounded),
              onPressed: deck.busy || deck.loading || deck.refreshing
                  ? null
                  : () => ref.read(discoverDeckProvider.notifier).refresh(),
            ),
            IconButton(
              tooltip: 'Mes demandes',
              icon: const Icon(Icons.inbox_rounded),
              onPressed: () => openMusicRequests(context),
            ),
          ],
        ),
        body: _buildBody(deck),
      ),
    );
  }

  Widget _buildBody(DiscoverDeckState deck) {
    final firstLoad = !deck.loadedOnce && deck.error == null;
    // File MEDIA_READY vide + préparation en cours : écran dédié avec les
    // statistiques temps réel du job (jamais de placeholder générique muet).
    if (deck.refreshing && deck.deck.isEmpty) {
      return _PreparationState(status: deck.status);
    }
    if (deck.loading || firstLoad) {
      return const _SkeletonDeck();
    }
    if (deck.error != null && deck.deck.isEmpty) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        message: deck.error!,
        actionLabel: 'Réessayer',
        onAction: () => ref.read(discoverDeckProvider.notifier).load(),
      );
    }
    final top = deck.top;
    if (top == null) {
      return _MessageState(
        icon: Icons.explore_off_rounded,
        message: 'Aucune recommandation pour le moment.',
        actionLabel: 'Actualiser les recommandations',
        onAction: () => ref.read(discoverDeckProvider.notifier).refresh(),
      );
    }
    final preview = ref.watch(discoveryPreviewProvider);
    // La carte du dessus vient d'être présentée : arme l'autoplay différé
    // après le frame (jamais pendant le build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _armAutoplayFor(top);
        _preloadNextArtworks(deck);
      }
    });
    // Les 2 cartes suivantes sont PRÉ-RENDUES sous la carte active : le swipe
    // révèle une carte déjà peinte (aucun flash de chargement).
    final nextCards = deck.deck.skip(1).take(2).toList(growable: false);
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Stack(
              fit: StackFit.expand,
              children: [
                for (var i = nextCards.length - 1; i >= 0; i -= 1)
                  Positioned.fill(
                    child: Transform.translate(
                      offset: Offset(0, 10.0 * (i + 1)),
                      child: Transform.scale(
                        scale: 1 - 0.04 * (i + 1),
                        child: IgnorePointer(
                          child: _CandidateCard(
                            candidate: nextCards[i],
                            previewPlaying: false,
                            onTogglePreview: null,
                          ),
                        ),
                      ),
                    ),
                  ),
                Dismissible(
                  key: ValueKey('candidate-${top.id}'),
                  direction: deck.busy
                      ? DismissDirection.none
                      : DismissDirection.horizontal,
                  // Échec backend → false → la carte revient (rollback visuel).
                  confirmDismiss: (direction) =>
                      direction == DismissDirection.startToEnd
                      ? _onRequest(top)
                      : _onDislike(top),
                  onDismissed: (_) => _advance(),
                  background: const _SwipeHint(
                    alignment: Alignment.centerLeft,
                    color: _accent,
                    icon: Icons.favorite_rounded,
                    label: 'Demander',
                  ),
                  secondaryBackground: const _SwipeHint(
                    alignment: Alignment.centerRight,
                    color: _danger,
                    icon: Icons.thumb_down_rounded,
                    label: 'Pas pour moi',
                  ),
                  child: _CandidateCard(
                    candidate: top,
                    previewPlaying: preview.isActiveFor(top.id),
                    previewLoading:
                        preview.candidateId == top.id && preview.loading,
                    previewProgress: preview.candidateId == top.id
                        ? preview.progress
                        : 0,
                    onTogglePreview: top.previewUrl == null
                        ? null
                        : () => ref
                              .read(discoveryPreviewProvider.notifier)
                              .toggle(top),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 24, top: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _RoundAction(
                icon: Icons.thumb_down_rounded,
                color: _danger,
                tooltip: 'Pas pour moi',
                onPressed: deck.busy
                    ? null
                    : () async {
                        if (await _onDislike(top)) {
                          _advance();
                        } else {
                          _flushError();
                        }
                      },
              ),
              const SizedBox(width: 20),
              _RoundAction(
                icon: Icons.skip_next_rounded,
                color: Colors.white70,
                tooltip: 'Passer',
                onPressed: deck.busy
                    ? null
                    : () {
                        _lastArmedId = null;
                        ref
                            .read(discoveryPreviewProvider.notifier)
                            .stop(reportEarlyStop: true);
                        ref.read(discoverDeckProvider.notifier).skip(top);
                      },
              ),
              const SizedBox(width: 20),
              _RoundAction(
                icon: Icons.favorite_rounded,
                color: _accent,
                tooltip: 'Envoyer une demande',
                onPressed: deck.busy
                    ? null
                    : () async {
                        if (await _onRequest(top)) _advance();
                      },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Carte candidat : pochette, titre, artiste, album, raison, extrait.
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.previewPlaying,
    required this.onTogglePreview,
    this.previewLoading = false,
    this.previewProgress = 0,
  });

  final RecommendationCandidate candidate;
  final bool previewPlaying;
  final bool previewLoading;
  final double previewProgress;
  final VoidCallback? onTogglePreview;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Pochette candidate = URL de catalogue EXTERNE : chargée SANS en-tête
          // (le Bearer HomeSpotify ne sort jamais vers un tiers). Carrée, cover,
          // skeleton pendant le chargement, réessais sur erreur transitoire.
          Expanded(child: _Artwork(url: candidate.artworkUrl)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            candidate.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              candidate.artist,
                              if ((candidate.album ?? '').isNotEmpty)
                                candidate.album!,
                            ].join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Le bouton extrait n'existe QUE si une previewUrl https
                    // a été résolue par le backend.
                    if (onTogglePreview != null)
                      previewLoading
                          ? const Padding(
                              padding: EdgeInsets.all(10),
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: _accent,
                                ),
                              ),
                            )
                          : IconButton(
                              tooltip: previewPlaying
                                  ? 'Pause de l\'extrait'
                                  : 'Écouter un extrait',
                              iconSize: 40,
                              color: _accent,
                              icon: Icon(
                                previewPlaying
                                    ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_fill_rounded,
                              ),
                              onPressed: onTogglePreview,
                            ),
                  ],
                ),
                // Barre de progression de l'extrait (carte active seulement).
                if (previewPlaying || previewProgress > 0) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: previewProgress,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation(_accent),
                    ),
                  ),
                ],
                if (candidate.reason != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      candidate.reason!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _accent, fontSize: 12.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pochette carrée `BoxFit.cover` avec skeleton pendant le chargement réseau
/// et RÉESSAIS bornés sur erreur transitoire (jamais marquée définitivement
/// manquante après un simple pépin réseau). Fallback icône seulement en dernier
/// recours (URL absente ou échecs répétés).
class _Artwork extends StatefulWidget {
  const _Artwork({required this.url});

  final String? url;

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  static const int _maxRetries = 3;
  int _attempt = 0;
  bool _failed = false;

  @override
  void didUpdateWidget(_Artwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Nouvelle carte (URL différente) : on repart d'un état propre.
    if (oldWidget.url != widget.url) {
      _attempt = 0;
      _failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null || url.isEmpty || _failed) return const _ArtworkFallback();
    return Image.network(
      url,
      // Clé de réessai : changer la key force un nouveau GET réseau.
      key: ValueKey('art-$url-$_attempt'),
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child; // image décodée
        return const _ArtworkSkeleton();
      },
      errorBuilder: (context, _, _) {
        // Erreur transitoire : on réessaie après un court délai, jusqu'à
        // _maxRetries, avant de déclarer l'échec (fallback icône).
        if (_attempt < _maxRetries) {
          Future<void>.delayed(
            Duration(milliseconds: 400 * (_attempt + 1)),
            () {
              if (mounted) setState(() => _attempt += 1);
            },
          );
          return const _ArtworkSkeleton();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_failed) setState(() => _failed = true);
        });
        return const _ArtworkSkeleton();
      },
    );
  }
}

class _ArtworkSkeleton extends StatelessWidget {
  const _ArtworkSkeleton();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF23232B),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            color: Colors.white24,
          ),
        ),
      ),
    );
  }
}

class _ArtworkFallback extends StatelessWidget {
  const _ArtworkFallback();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF23232B),
      child: Icon(Icons.music_note_rounded, color: Colors.white24, size: 96),
    );
  }
}

/// Écran de PRÉPARATION affiché quand la file MEDIA_READY est vide et qu'un job
/// de préparation tourne : message dédié + stats temps réel (jamais un
/// placeholder générique). Les compteurs viennent du /status de la file.
class _PreparationState extends StatelessWidget {
  const _PreparationState({required this.status});

  final RecommendationQueueStatus? status;

  @override
  Widget build(BuildContext context) {
    final ready = status?.readyCount ?? 0;
    final reserve = status?.reserveCount ?? 0;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 44,
              height: 44,
              child: CircularProgressIndicator(color: _accent, strokeWidth: 3),
            ),
            const SizedBox(height: 24),
            const Text(
              'Préparation de vos recommandations audio…',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Chaque carte reçoit un extrait jouable et sa pochette avant '
              'd’entrer dans le paquet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _PrepStat(label: 'Prêtes', value: ready),
                const SizedBox(width: 28),
                _PrepStat(label: 'En réserve', value: reserve),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PrepStat extends StatelessWidget {
  const _PrepStat({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '$value',
          style: const TextStyle(
            color: _accent,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }
}

/// Skeleton bref affiché pendant la première lecture de la file locale.
class _SkeletonDeck extends StatelessWidget {
  const _SkeletonDeck();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 88),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: _card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(child: ColoredBox(color: Color(0xFF23232B))),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _skeletonBar(width: 180, height: 18),
                        const SizedBox(height: 8),
                        _skeletonBar(width: 120, height: 13),
                        const SizedBox(height: 12),
                        _skeletonBar(width: 220, height: 24),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeletonBar({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}

class _SwipeHint extends StatelessWidget {
  const _SwipeHint({
    required this.alignment,
    required this.color,
    required this.icon,
    required this.label,
  });

  final Alignment alignment;
  final Color color;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: color, size: 40),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(color: color, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton.filled(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: _card,
        disabledBackgroundColor: _card.withValues(alpha: 0.5),
        padding: const EdgeInsets.all(16),
      ),
      iconSize: 30,
      color: color,
      icon: Icon(icon),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              onPressed: onAction,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
