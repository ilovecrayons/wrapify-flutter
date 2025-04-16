class Song {
  final String id;
  final String title;
  final String artist;
  final String? imageUrl;
  final Map<String, dynamic>? externalUrls;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.imageUrl,
    this.externalUrls,
  });

  // Convert to a map for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': title,
      'artists': artist,
      'image': imageUrl,
      'external_urls': externalUrls,
    };
  }

  // Create from a map (for loading from storage)
  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      id: json['id'],
      title: json['name'],
      artist: json['artists'],
      imageUrl: json['image'],
      externalUrls: json['external_urls'],
    );
  }
}