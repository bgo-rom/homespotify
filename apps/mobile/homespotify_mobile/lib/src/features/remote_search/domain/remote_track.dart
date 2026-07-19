class RemoteTrack {
  const RemoteTrack({
    required this.trackId,
    required this.title,
    required this.artist,
    this.coverUrl,
  });

  factory RemoteTrack.fromJson(Map<String, dynamic> json) {
    return RemoteTrack(
      trackId: json['trackId'] as String? ?? '',
      title: json['title'] as String? ?? 'Titre inconnu',
      artist: json['artist'] as String? ?? 'Artiste inconnu',
      coverUrl: json['coverUrl'] as String?,
    );
  }

  final String trackId;
  final String title;
  final String artist;
  final String? coverUrl;
}
