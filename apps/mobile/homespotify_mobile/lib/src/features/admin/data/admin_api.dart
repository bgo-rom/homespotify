import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';

class AdminApiException implements Exception {
  const AdminApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'AdminApiException($statusCode): $message';
}

class AdminOverview {
  const AdminOverview({
    required this.backendStatus,
    required this.uptimeSeconds,
    required this.version,
    required this.serverTime,
    required this.diskTotalBytes,
    required this.diskUsedBytes,
    required this.diskFreeBytes,
    required this.libraryTrackCount,
    required this.librarySizeBytes,
    required this.totalUsers,
    required this.activeUsers,
    required this.blockedUsers,
    required this.activeSessions,
  });

  factory AdminOverview.fromJson(Map<String, dynamic> json) {
    final backend = json['backend'] as Map<String, dynamic>? ?? const {};
    final disk = json['disk'] as Map<String, dynamic>?;
    final library = json['library'] as Map<String, dynamic>? ?? const {};
    final users = json['users'] as Map<String, dynamic>? ?? const {};
    final sessions = json['sessions'] as Map<String, dynamic>? ?? const {};
    return AdminOverview(
      backendStatus: backend['status'] as String? ?? 'inconnu',
      uptimeSeconds: (backend['uptimeSeconds'] as num?)?.toInt() ?? 0,
      version: backend['version'] as String? ?? '?',
      serverTime: backend['serverTime'] as String? ?? '',
      diskTotalBytes: (disk?['totalBytes'] as num?)?.toInt(),
      diskUsedBytes: (disk?['usedBytes'] as num?)?.toInt(),
      diskFreeBytes: (disk?['freeBytes'] as num?)?.toInt(),
      libraryTrackCount: (library['trackCount'] as num?)?.toInt() ?? 0,
      librarySizeBytes: (library['sizeBytes'] as num?)?.toInt() ?? 0,
      totalUsers: (users['total'] as num?)?.toInt() ?? 0,
      activeUsers: (users['active'] as num?)?.toInt() ?? 0,
      blockedUsers: (users['blocked'] as num?)?.toInt() ?? 0,
      activeSessions: (sessions['active'] as num?)?.toInt() ?? 0,
    );
  }

  final String backendStatus;
  final int uptimeSeconds;
  final String version;
  final String serverTime;
  final int? diskTotalBytes;
  final int? diskUsedBytes;
  final int? diskFreeBytes;
  final int libraryTrackCount;
  final int librarySizeBytes;
  final int totalUsers;
  final int activeUsers;
  final int blockedUsers;
  final int activeSessions;
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.isActive,
    required this.mustChangePassword,
    required this.createdAt,
    this.lastLoginAt,
    this.disabledReason,
    this.activeSessionCount,
    this.storageUsage,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    return AdminUser(
      id: json['id'] as int,
      username: json['username'] as String,
      displayName: json['displayName'] as String,
      role: json['role'] as String,
      isActive: json['isActive'] as bool? ?? true,
      mustChangePassword: json['mustChangePassword'] as bool? ?? false,
      createdAt: json['createdAt'] as String? ?? '',
      lastLoginAt: json['lastLoginAt'] as String?,
      disabledReason: json['disabledReason'] as String?,
      activeSessionCount: (json['activeSessionCount'] as num?)?.toInt(),
      storageUsage: (json['storageUsage'] as num?)?.toInt(),
    );
  }

  final int id;
  final String username;
  final String displayName;
  final String role;
  final bool isActive;
  final bool mustChangePassword;
  final String createdAt;
  final String? lastLoginAt;
  final String? disabledReason;
  final int? activeSessionCount;

  /// null tant que les relations user↔tracks n'existent pas côté backend
  /// (cf. MULTI_USER_DATA_MODEL.md) — jamais de valeur inventée.
  final int? storageUsage;

  bool get isOwner => role == 'OWNER';
}

class AdminMusicRequest {
  const AdminMusicRequest({
    required this.id,
    required this.requesterName,
    required this.requesterId,
    required this.requesterUsername,
    required this.title,
    required this.artist,
    required this.itemType,
    required this.status,
    required this.createdAt,
    required this.presentInRequesterLibrary,
    required this.requestedItemCount,
    required this.completedItemCount,
    required this.unavailableItemCount,
    required this.items,
    this.album,
    this.userNote,
    this.ownerNote,
    this.externalUrl,
    this.resultingTrackId,
    this.externalSource,
  });

  factory AdminMusicRequest.fromJson(Map<String, dynamic> json) {
    final requester = json['requester'] as Map<String, dynamic>? ?? const {};
    return AdminMusicRequest(
      id: (json['id'] as num).toInt(),
      requesterName: requester['displayName'] as String? ?? '?',
      requesterId: (requester['id'] as num?)?.toInt() ?? 0,
      requesterUsername: requester['username'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String?,
      itemType:
          json['requestType'] as String? ??
          json['itemType'] as String? ??
          'TRACK',
      status: json['status'] as String? ?? 'SENT',
      userNote: json['userNote'] as String?,
      ownerNote: json['ownerNote'] as String?,
      externalUrl: json['externalUrl'] as String?,
      resultingTrackId: (json['resultingTrackId'] as num?)?.toInt(),
      createdAt: json['createdAt'] as String? ?? '',
      presentInRequesterLibrary:
          json['presentInRequesterLibrary'] as bool? ?? false,
      requestedItemCount: (json['requestedItemCount'] as num?)?.toInt() ?? 0,
      completedItemCount: (json['completedItemCount'] as num?)?.toInt() ?? 0,
      unavailableItemCount:
          (json['unavailableItemCount'] as num?)?.toInt() ?? 0,
      externalSource: json['externalSource'] as String?,
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(AdminMusicRequestItem.fromJson)
          .toList(growable: false),
    );
  }

  final int id;
  final String requesterName;
  final int requesterId;
  final String requesterUsername;
  final String title;
  final String artist;
  final String? album;
  final String itemType;
  final String status;
  final String? userNote;
  final String? ownerNote;
  final String? externalUrl;
  final int? resultingTrackId;
  final String createdAt;
  final bool presentInRequesterLibrary;
  final int requestedItemCount;
  final int completedItemCount;
  final int unavailableItemCount;
  final String? externalSource;
  final List<AdminMusicRequestItem> items;
}

class AdminMusicRequestItem {
  const AdminMusicRequestItem({
    required this.id,
    required this.position,
    required this.title,
    required this.status,
    required this.presentInRequesterLibrary,
    this.artist,
    this.album,
    this.resultingTrackId,
  });

  factory AdminMusicRequestItem.fromJson(Map<String, dynamic> json) =>
      AdminMusicRequestItem(
        id: (json['id'] as num).toInt(),
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        status: json['status'] as String? ?? 'PENDING',
        resultingTrackId: (json['resultingTrackId'] as num?)?.toInt(),
        presentInRequesterLibrary:
            json['presentInRequesterLibrary'] as bool? ?? false,
      );

  final int id;
  final int position;
  final String title;
  final String? artist;
  final String? album;
  final String status;
  final int? resultingTrackId;
  final bool presentInRequesterLibrary;
}

class AdminTrackSearchResult {
  const AdminTrackSearchResult({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    this.durationSeconds,
  });

  factory AdminTrackSearchResult.fromJson(Map<String, dynamic> json) =>
      AdminTrackSearchResult(
        id: (json['id'] as num).toInt(),
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        album: json['album'] as String? ?? '',
        durationSeconds: (json['durationSeconds'] as num?)?.toDouble(),
      );

  final int id;
  final String title;
  final String artist;
  final String album;
  final double? durationSeconds;
}

class AdminImportJob {
  const AdminImportJob({
    required this.id,
    required this.userId,
    required this.requesterName,
    required this.filename,
    required this.relativePath,
    required this.directoryPath,
    required this.status,
    required this.createdAt,
    this.sizeBytes,
    this.metadata,
    this.trackId,
    this.musicRequestId,
    this.musicRequestItemId,
    this.errorMessage,
    this.availableRequestItems = const [],
  });

  factory AdminImportJob.fromJson(Map<String, dynamic> json) {
    final user = json['user'] as Map<String, dynamic>? ?? const {};
    Map<String, dynamic>? metadata;
    final rawMetadata = json['metadataJson'];
    if (rawMetadata is Map<String, dynamic>) {
      metadata = rawMetadata;
    } else if (rawMetadata is String) {
      try {
        final decoded = jsonDecode(rawMetadata);
        if (decoded is Map<String, dynamic>) metadata = decoded;
      } on FormatException {
        metadata = null;
      }
    }
    return AdminImportJob(
      id: (json['id'] as num).toInt(),
      userId: (json['userId'] as num).toInt(),
      requesterName: user['displayName'] as String? ?? '?',
      filename: json['filename'] as String? ?? '',
      relativePath: json['relativePath'] as String? ?? '',
      directoryPath: json['directoryPath'] as String? ?? '',
      status: json['status'] as String? ?? 'DISCOVERED',
      createdAt: json['createdAt'] as String? ?? '',
      sizeBytes: (json['sizeBytes'] as num?)?.toInt(),
      metadata: metadata,
      trackId: (json['trackId'] as num?)?.toInt(),
      musicRequestId: (json['musicRequestId'] as num?)?.toInt(),
      musicRequestItemId: (json['musicRequestItemId'] as num?)?.toInt(),
      errorMessage: json['errorMessage'] as String?,
      availableRequestItems:
          (json['availableRequestItems'] as List<dynamic>? ?? const [])
              .whereType<Map<String, dynamic>>()
              .map(AdminImportRequestItem.fromJson)
              .toList(growable: false),
    );
  }

  final int id;
  final int userId;
  final String requesterName;
  final String filename;
  final String relativePath;
  final String directoryPath;
  final String status;
  final String createdAt;
  final int? sizeBytes;
  final Map<String, dynamic>? metadata;
  final int? trackId;
  final int? musicRequestId;
  final int? musicRequestItemId;
  final String? errorMessage;
  final List<AdminImportRequestItem> availableRequestItems;
}

class AdminImportRequestItem {
  const AdminImportRequestItem({
    required this.id,
    required this.requestId,
    required this.position,
    required this.title,
    this.artist,
  });

  factory AdminImportRequestItem.fromJson(Map<String, dynamic> json) =>
      AdminImportRequestItem(
        id: (json['id'] as num).toInt(),
        requestId: (json['requestId'] as num).toInt(),
        position: (json['position'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String?,
      );

  final int id;
  final int requestId;
  final int position;
  final String title;
  final String? artist;
}

/// Santé du moteur de recommandations (diagnostics OWNER).
class AdminRecommendationHealth {
  const AdminRecommendationHealth({
    required this.status,
    required this.modelVersion,
    required this.candidatesTotal,
    required this.candidatesActive,
    required this.candidatesWithPreview,
    required this.usersWithQueue,
    required this.queueEntries,
    this.lastGeneratedAt,
    this.providerErrorMessage,
    this.providerErrorAt,
  });

  factory AdminRecommendationHealth.fromJson(Map<String, dynamic> json) {
    final candidates = json['candidates'] as Map<String, dynamic>? ?? const {};
    final queues = json['queues'] as Map<String, dynamic>? ?? const {};
    final providerError = json['providerError'] as Map<String, dynamic>?;
    return AdminRecommendationHealth(
      status: json['status'] as String? ?? 'inconnu',
      modelVersion: json['modelVersion'] as String? ?? '?',
      candidatesTotal: (candidates['total'] as num?)?.toInt() ?? 0,
      candidatesActive: (candidates['active'] as num?)?.toInt() ?? 0,
      candidatesWithPreview: (candidates['withPreview'] as num?)?.toInt() ?? 0,
      usersWithQueue: (queues['usersWithQueue'] as num?)?.toInt() ?? 0,
      queueEntries: (queues['totalEntries'] as num?)?.toInt() ?? 0,
      lastGeneratedAt: queues['lastGeneratedAt'] as String?,
      providerErrorMessage: providerError?['message'] as String?,
      providerErrorAt: providerError?['at'] as String?,
    );
  }

  final String status;
  final String modelVersion;
  final int candidatesTotal;
  final int candidatesActive;
  final int candidatesWithPreview;
  final int usersWithQueue;
  final int queueEntries;
  final String? lastGeneratedAt;
  final String? providerErrorMessage;
  final String? providerErrorAt;

  bool get degraded => status != 'ok';
}

/// Compteurs d'usage du moteur de recommandations.
class AdminRecommendationMetrics {
  const AdminRecommendationMetrics({
    required this.actions,
    required this.impressions24h,
    required this.impressionsTotal,
  });

  factory AdminRecommendationMetrics.fromJson(Map<String, dynamic> json) {
    final actions = json['actions'] as Map<String, dynamic>? ?? const {};
    final impressions =
        json['impressions'] as Map<String, dynamic>? ?? const {};
    return AdminRecommendationMetrics(
      actions: {
        for (final entry in actions.entries)
          entry.key: (entry.value as num?)?.toInt() ?? 0,
      },
      impressions24h: (impressions['last24h'] as num?)?.toInt() ?? 0,
      impressionsTotal: (impressions['total'] as num?)?.toInt() ?? 0,
    );
  }

  final Map<String, int> actions;
  final int impressions24h;
  final int impressionsTotal;
}

final adminApiProvider = Provider<AdminApi>(
  (ref) => AdminApi(ref.watch(apiClientProvider)),
);

/// Client des routes /api/admin — réservées au OWNER (le backend revérifie).
class AdminApi {
  AdminApi(this._dio);

  final Dio _dio;

  Future<AdminOverview> fetchOverview() async {
    final json = await _request(() => _dio.get('/api/admin/overview'));
    return AdminOverview.fromJson(json);
  }

  Future<List<AdminUser>> listUsers() async {
    final json = await _request(() => _dio.get('/api/admin/users'));
    final items = json['items'] as List<dynamic>? ?? const [];
    return items
        .map((item) => AdminUser.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<void> createUser({
    required String username,
    required String displayName,
    required String temporaryPassword,
    required String role,
  }) async {
    await _request(
      () => _dio.post(
        '/api/admin/users',
        data: {
          'username': username,
          'displayName': displayName,
          'temporaryPassword': temporaryPassword,
          'role': role,
        },
      ),
      allowedStatuses: const {201},
    );
  }

  Future<void> setUserStatus({
    required int userId,
    required bool isActive,
    String? reason,
  }) async {
    await _request(
      () => _dio.patch(
        '/api/admin/users/$userId/status',
        data: {'isActive': isActive, 'reason': ?reason},
      ),
    );
  }

  Future<void> setUserRole({required int userId, required String role}) async {
    await _request(
      () => _dio.patch('/api/admin/users/$userId/role', data: {'role': role}),
    );
  }

  Future<void> resetPassword({
    required int userId,
    required String temporaryPassword,
  }) async {
    await _request(
      () => _dio.post(
        '/api/admin/users/$userId/reset-password',
        data: {'temporaryPassword': temporaryPassword},
      ),
    );
  }

  Future<void> revokeSessions({required int userId}) async {
    await _request(() => _dio.post('/api/admin/users/$userId/revoke-sessions'));
  }

  Future<void> deleteUser({required int userId}) async {
    await _request(
      () => _dio.delete('/api/admin/users/$userId'),
      allowedStatuses: const {204},
    );
  }

  Future<List<AdminMusicRequest>> listMusicRequests({
    int? userId,
    String? type,
    String? status,
    String? query,
  }) async {
    final json = await _request(
      () => _dio.get(
        '/api/admin/music-requests',
        queryParameters: {
          'userId': ?userId,
          'type': ?type,
          'status': ?status,
          'q': ?query,
        },
      ),
    );
    return (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AdminMusicRequest.fromJson)
        .toList(growable: false);
  }

  Future<void> updateMusicRequest(
    int id, {
    String? status,
    String? ownerNote,
  }) async {
    await _request(
      () => _dio.patch(
        '/api/admin/music-requests/$id',
        data: {'status': ?status, 'ownerNote': ?ownerNote},
      ),
    );
  }

  Future<void> assignTrack(int requestId, int itemId, int trackId) async {
    await _request(
      () => _dio.post(
        '/api/admin/music-requests/$requestId/items/$itemId/assign-track',
        data: {'trackId': trackId},
      ),
    );
  }

  Future<List<AdminTrackSearchResult>> searchTracks(String query) async {
    final json = await _request(
      () => _dio.get(
        '/api/admin/tracks/search',
        queryParameters: {'q': query, 'limit': 30},
      ),
    );
    return (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AdminTrackSearchResult.fromJson)
        .toList(growable: false);
  }

  Future<List<AdminImportJob>> listImports({
    int? userId,
    String? status,
  }) async {
    final json = await _request(
      () => _dio.get(
        '/api/admin/imports',
        queryParameters: {'userId': ?userId, 'status': ?status},
      ),
    );
    return (json['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(AdminImportJob.fromJson)
        .toList(growable: false);
  }

  Future<void> retryImport(int jobId) async {
    await _request(
      () => _dio.post('/api/admin/imports/$jobId/retry'),
      allowedStatuses: const {202},
    );
  }

  Future<void> rejectImport(int jobId) async {
    await _request(() => _dio.post('/api/admin/imports/$jobId/reject'));
  }

  Future<void> assignImport({
    required int jobId,
    required int itemId,
    required int trackId,
  }) async {
    await _request(
      () => _dio.post(
        '/api/admin/imports/$jobId/assign',
        data: {'itemId': itemId, 'trackId': trackId},
      ),
    );
  }

  Future<void> reconcileMusicRequest(int requestId) async {
    await _request(
      () => _dio.post('/api/admin/music-requests/$requestId/reconcile'),
    );
  }

  Future<AdminRecommendationHealth> fetchRecommendationHealth() async {
    final json = await _request(
      () => _dio.get('/api/admin/recommendations/health'),
    );
    return AdminRecommendationHealth.fromJson(json);
  }

  Future<AdminRecommendationMetrics> fetchRecommendationMetrics() async {
    final json = await _request(
      () => _dio.get('/api/admin/recommendations/metrics'),
    );
    return AdminRecommendationMetrics.fromJson(json);
  }

  /// Régénère la file de recommandations de tous les comptes actifs (202).
  Future<int> triggerRecommendationMaintenance() async {
    final json = await _request(
      () => _dio.post('/api/admin/recommendations/maintenance'),
      allowedStatuses: const {202},
    );
    return (json['users'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, dynamic>> _request(
    Future<Response<dynamic>> Function() send, {
    Set<int> allowedStatuses = const {200},
  }) async {
    Response<dynamic> response;
    try {
      response = await send();
    } on DioException {
      throw const AdminApiException(AppConfig.serverUnreachableMessage);
    }
    final status = response.statusCode ?? 0;
    if (!allowedStatuses.contains(status)) {
      final data = response.data;
      final message = data is Map<String, dynamic>
          ? data['message'] as String? ?? 'Action refusée.'
          : 'Action refusée.';
      throw AdminApiException(message, statusCode: status);
    }
    final data = response.data;
    return data is Map<String, dynamic> ? data : const {};
  }
}
