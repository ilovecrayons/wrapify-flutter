class Song {
  final String id;
  final String title;
  final String artist;
  final String? imageUrl;
  final Map<String, dynamic>? externalUrls;
  final String? errorMessage;
  final bool hasError;
  final bool isIgnored;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.imageUrl,
    this.externalUrls,
    this.errorMessage,
    this.hasError = false,
    this.isIgnored = false,
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
      'is_ignored': isIgnored,
    };
  }

  // Create from a map (for loading from storage)
  factory Song.fromJson(Map<String, dynamic> json) {
    // Handle case where error info might be stored differently
    final hasError = json['has_error'] == true || json['error_message'] != null;
    
    return Song(
      id: json['id'],
      title: json['name'] ?? json['title'] ?? 'Unknown Song',
      artist: json['artists'] ?? json['artist'] ?? 'Unknown Artist',
      imageUrl: json['image'] ?? json['imageUrl'],
      externalUrls: json['external_urls'],
      errorMessage: json['error_message'] ?? json['errorMessage'],
      hasError: hasError,
      isIgnored: json['is_ignored'] == true,
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
      isIgnored: isIgnored,
    );
  }
  
  // Create a copy of this song with the ignored flag toggled
  Song copyWithIgnored(bool ignored) {
    return Song(
      id: id,
      title: title,
      artist: artist,
      imageUrl: imageUrl,
      externalUrls: externalUrls,
      errorMessage: errorMessage,
      hasError: hasError,
      isIgnored: ignored,
    );
  }
}