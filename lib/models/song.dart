class Song {
  final String id;
  final String title;
  final String artist;
  final String? imageUrl;
  final Map<String, dynamic>? externalUrls;
  final String? errorMessage;
  final bool hasError;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.imageUrl,
    this.externalUrls,
    this.errorMessage,
    this.hasError = false,
  });

  // Convert to a map for storage
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': title,
      'artists': artist,
      'image': imageUrl,
      'external_urls': externalUrls,
      'error_message': errorMessage,
      'has_error': hasError,
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
      errorMessage: json['error_message'],
      hasError: json['has_error'] ?? false,
    );
  }
  
  // Create a copy of this song with error info
  Song copyWithError(String error) {
    return Song(
      id: id,
      title: title,
      artist: artist,
      imageUrl: imageUrl,
      externalUrls: externalUrls,
      errorMessage: error,
      hasError: true,
    );
  }
}