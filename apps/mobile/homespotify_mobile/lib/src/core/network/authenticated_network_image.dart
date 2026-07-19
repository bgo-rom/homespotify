import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_controller.dart';

final Set<String> _decodedArtworkTraces = <String>{};

/// Image servie par l'API HomeSpotify. Le Bearer du compte courant est ajouté
/// sans être placé dans l'URL, les logs ou le cache métier.
class AuthenticatedNetworkImage extends ConsumerWidget {
  const AuthenticatedNetworkImage(
    this.url, {
    super.key,
    this.fit,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.low,
    this.gaplessPlayback = false,
    this.errorBuilder,
    this.loadingBuilder,
    this.artworkTraceLabel,
  });

  final String url;
  final BoxFit? fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;
  final ImageLoadingBuilder? loadingBuilder;
  final String? artworkTraceLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uri = Uri.tryParse(url);
    Widget frameBuilder(
      BuildContext context,
      Widget child,
      int? frame,
      bool wasSynchronouslyLoaded,
    ) {
      final label = artworkTraceLabel;
      if (kDebugMode &&
          label != null &&
          frame != null &&
          _decodedArtworkTraces.add('$label|$url')) {
        debugPrint(
          '[ARTWORK_TRACE] H decoded $label uri=$url frame=$frame '
          'synchronous=$wasSynchronouslyLoaded',
        );
      }
      return child;
    }

    if (uri != null && uri.scheme == 'file') {
      return Image.file(
        File.fromUri(uri),
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        filterQuality: filterQuality,
        gaplessPlayback: gaplessPlayback,
        frameBuilder: frameBuilder,
        errorBuilder: errorBuilder,
      );
    }
    return Image.network(
      url,
      headers: ref.watch(mediaAuthorizationHeadersProvider),
      fit: fit,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
      filterQuality: filterQuality,
      gaplessPlayback: gaplessPlayback,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      loadingBuilder: loadingBuilder,
    );
  }
}
