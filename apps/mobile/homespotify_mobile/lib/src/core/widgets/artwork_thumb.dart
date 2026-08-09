import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../network/authenticated_network_image.dart';
import '../theme/app_colors.dart';
import '../theme/app_shapes.dart';

/// Erreurs de pochette déjà tracées (dédoublonnage du log de debug).
final Set<String> _artworkErrors = <String>{};

/// Pochette carrée mutualisée : rayon, placeholder et cache identiques partout.
///
/// Remplace les implémentations locales dupliquées (`_DashboardArtwork`,
/// `_MiniArtwork`, tuiles album/artiste). Le comportement réseau reste celui
/// d'[AuthenticatedNetworkImage] : aucun changement de politique de cache.
class ArtworkThumb extends StatelessWidget {
  const ArtworkThumb({
    super.key,
    required this.size,
    required this.identity,
    this.artUri,
    this.radius,
    this.traceLabel,
  });

  final double size;

  /// Identifiant stable de la pochette (id de piste) — sert de clé d'image.
  final String identity;

  final Uri? artUri;
  final double? radius;
  final String? traceLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final borderRadius = BorderRadius.circular(radius ?? AppRadius.artwork);
    final placeholder = ColoredBox(
      color: colors.surfaceSunken,
      child: Icon(
        Icons.music_note_rounded,
        color: colors.textTertiary,
        size: size * 0.34,
      ),
    );
    final uri = artUri;

    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        width: size,
        height: size,
        child: uri == null
            ? placeholder
            : AuthenticatedNetworkImage(
                uri.toString(),
                key: ValueKey<String>('artwork-$identity-$uri'),
                artworkTraceLabel: traceLabel,
                fit: BoxFit.cover,
                cacheWidth: (size * 2).round(),
                cacheHeight: (size * 2).round(),
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : placeholder,
                errorBuilder: (_, error, stackTrace) {
                  // Trace conservée de l'ancien mini-player : indispensable
                  // pour diagnostiquer les pochettes qui n'arrivent pas.
                  final label = traceLabel;
                  if (kDebugMode && label != null) {
                    final key = '$identity|$uri|$error';
                    if (_artworkErrors.add(key)) {
                      final stack = stackTrace
                          ?.toString()
                          .split('\n')
                          .take(3)
                          .join(' | ');
                      debugPrint(
                        '[ARTWORK_TRACE] G $label uri=$uri '
                        'errorType=${error.runtimeType} message=$error '
                        'stack=${stack ?? 'none'}',
                      );
                    }
                  }
                  return placeholder;
                },
              ),
      ),
    );
  }
}
