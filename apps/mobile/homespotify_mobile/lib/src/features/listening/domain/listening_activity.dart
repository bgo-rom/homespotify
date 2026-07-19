class ListeningTrack {
  const ListeningTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationMs,
    required this.coverUrl,
    required this.available,
  });

  factory ListeningTrack.fromJson(Map<String, dynamic> json) => ListeningTrack(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String? ?? '',
    artist: json['artist'] as String? ?? '',
    album: json['album'] as String? ?? '',
    durationMs: (json['durationMs'] as num?)?.toInt(),
    coverUrl: json['coverUrl'] as String?,
    available: json['available'] as bool? ?? true,
  );

  final int id;
  final String title;
  final String artist;
  final String album;
  final int? durationMs;
  final String? coverUrl;
  final bool available;
}

class ListeningSession {
  const ListeningSession({
    required this.id,
    required this.track,
    required this.startedAt,
    required this.lastActivityAt,
    required this.listenedMs,
    required this.positionMs,
    required this.durationMs,
    required this.status,
    required this.endReason,
    required this.qualifiedPlay,
    required this.completed,
  });

  factory ListeningSession.fromJson(Map<String, dynamic> json) =>
      ListeningSession(
        id: (json['id'] as num).toInt(),
        track: ListeningTrack.fromJson(
          json['track'] as Map<String, dynamic>? ?? const {},
        ),
        startedAt: DateTime.parse(json['startedAt'] as String).toLocal(),
        lastActivityAt: DateTime.parse(
          json['lastActivityAt'] as String,
        ).toLocal(),
        listenedMs: (json['listenedMs'] as num?)?.toInt() ?? 0,
        positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        status: json['status'] as String? ?? 'ENDED',
        endReason: json['endReason'] as String?,
        qualifiedPlay: json['qualifiedPlay'] as bool? ?? false,
        completed: json['completed'] as bool? ?? false,
      );

  final int id;
  final ListeningTrack track;
  final DateTime startedAt;
  final DateTime lastActivityAt;
  final int listenedMs;
  final int positionMs;
  final int? durationMs;
  final String status;
  final String? endReason;
  final bool qualifiedPlay;
  final bool completed;

  bool get canResume {
    final duration = durationMs ?? track.durationMs;
    return track.available &&
        !completed &&
        duration != null &&
        positionMs >= 5000 &&
        positionMs / duration < 0.9;
  }
}

class ResumeListeningItem {
  const ResumeListeningItem({
    required this.track,
    required this.positionMs,
    required this.durationMs,
    required this.updatedAt,
    required this.progress,
  });

  factory ResumeListeningItem.fromJson(Map<String, dynamic> json) =>
      ResumeListeningItem(
        track: ListeningTrack.fromJson(
          json['track'] as Map<String, dynamic>? ?? const {},
        ),
        positionMs: (json['positionMs'] as num).toInt(),
        durationMs: (json['durationMs'] as num).toInt(),
        updatedAt: DateTime.parse(json['updatedAt'] as String).toLocal(),
        progress: (json['progress'] as num).toDouble(),
      );

  final ListeningTrack track;
  final int positionMs;
  final int durationMs;
  final DateTime updatedAt;
  final double progress;
}

class ListeningActivityPage {
  const ListeningActivityPage({required this.items, required this.nextCursor});

  final List<ListeningSession> items;
  final String? nextCursor;
}
