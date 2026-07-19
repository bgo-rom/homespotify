import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';

/// Résumé de la bibliothèque du compte courant (section Compte). Les valeurs
/// viennent du backend, filtrées par le token — jamais un autre compte.
class UserLibrarySummary {
  const UserLibrarySummary({
    required this.trackCount,
    required this.favoriteCount,
    required this.playlistCount,
    required this.logicalSizeBytes,
  });

  final int trackCount;
  final int favoriteCount;
  final int playlistCount;
  final int logicalSizeBytes;

  static UserLibrarySummary fromJson(Map<String, dynamic> json) {
    return UserLibrarySummary(
      trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      favoriteCount: (json['favoriteCount'] as num?)?.toInt() ?? 0,
      playlistCount: (json['playlistCount'] as num?)?.toInt() ?? 0,
      logicalSizeBytes: (json['logicalSizeBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

final userLibrarySummaryProvider = FutureProvider<UserLibrarySummary>((
  ref,
) async {
  final dio = ref.watch(apiClientProvider);
  final Response<Map<String, dynamic>> res = await dio
      .get<Map<String, dynamic>>('/api/library/summary');
  final summary = res.data?['summary'];
  if (summary is! Map<String, dynamic>) {
    throw const FormatException('Résumé de bibliothèque invalide.');
  }
  return UserLibrarySummary.fromJson(summary);
});
