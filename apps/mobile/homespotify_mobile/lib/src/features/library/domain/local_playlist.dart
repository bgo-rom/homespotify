class LocalPlaylist {
  const LocalPlaylist({
    required this.id,
    required this.name,
    required this.trackIds,
  });

  final String id;
  final String name;
  final List<int> trackIds;

  int get trackCount => trackIds.length;

  LocalPlaylist copyWith({String? name, List<int>? trackIds}) {
    return LocalPlaylist(
      id: id,
      name: name ?? this.name,
      trackIds: List<int>.unmodifiable(trackIds ?? this.trackIds),
    );
  }

  factory LocalPlaylist.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    if (!isSafePlaylistId(id) || name.isEmpty) {
      throw const FormatException('Playlist locale invalide.');
    }
    final rawTrackIds = json['trackIds'];
    if (rawTrackIds is! List<dynamic>) {
      throw const FormatException('Liste de pistes invalide.');
    }
    final seen = <int>{};
    final trackIds = <int>[];
    for (final value in rawTrackIds.whereType<num>()) {
      final id = value.toInt();
      if (id > 0 && seen.add(id)) trackIds.add(id);
    }
    return LocalPlaylist(
      id: id,
      name: name,
      trackIds: List<int>.unmodifiable(trackIds),
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'id': id,
    'name': name,
    'trackIds': trackIds,
  };
}

bool isSafePlaylistId(String id) => RegExp(r'^[a-z0-9_-]+$').hasMatch(id);
