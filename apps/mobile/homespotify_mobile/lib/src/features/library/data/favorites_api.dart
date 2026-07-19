import 'package:dio/dio.dart';

abstract interface class FavoritesRepository {
  Future<Set<int>> fetch();
  Future<void> add(int trackId);
  Future<void> remove(int trackId);
}

/// Accès backend aux favoris de l'utilisateur courant. Le userId n'est jamais
/// envoyé : il vient du token porté par l'intercepteur du Dio partagé.
class FavoritesApi implements FavoritesRepository {
  FavoritesApi(this._dio);

  final Dio _dio;

  @override
  Future<Set<int>> fetch() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/favorites');
    final ids = res.data?['trackIds'];
    if (ids is! List) return <int>{};
    return ids.whereType<num>().map((value) => value.toInt()).toSet();
  }

  @override
  Future<void> add(int trackId) async {
    await _dio.post<Map<String, dynamic>>(
      '/api/favorites',
      data: {'trackId': trackId},
    );
  }

  @override
  Future<void> remove(int trackId) async {
    await _dio.delete<void>('/api/favorites/$trackId');
  }
}
