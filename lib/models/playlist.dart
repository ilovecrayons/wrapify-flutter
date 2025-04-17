class Playlist {
  final String id;
  final String name;
  final String? imageUrl;
  final String spotifyUrl;
  final List<String> songIds; // IDs of songs in this playlist
  final String? syncJobId; // ID of the most recent sync job

  Playlist({
    required this.id,
    required this.name,
    this.imageUrl,
    required this.spotifyUrl,
    this.songIds = const [],
    this.syncJobId,
  });

  // Convert to a map for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'imageUrl': imageUrl,
      'spotifyUrl': spotifyUrl,
      'songIds': songIds,
      'syncJobId': syncJobId,
    };
  }

  // Create from a map (for loading from storage)
  factory Playlist.fromJson(Map<String, dynamic> json) {
    return Playlist(
      id: json['id'],
      name: json['name'],
      imageUrl: json['imageUrl'],
      spotifyUrl: json['spotifyUrl'],
      songIds: List<String>.from(json['songIds'] ?? []),
      syncJobId: json['syncJobId'],
    );
  }
}