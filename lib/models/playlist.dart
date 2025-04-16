class Playlist {
  final String id;
  final String name;
  final String? imageUrl;
  final String spotifyUrl;
  final List<String> songIds; // IDs of songs in this playlist

  Playlist({
    required this.id,
    required this.name,
    this.imageUrl,
    required this.spotifyUrl,
    this.songIds = const [],
  });

  // Convert to a map for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'imageUrl': imageUrl,
      'spotifyUrl': spotifyUrl,
      'songIds': songIds,
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
    );
  }
}