import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import '../models/playlist.dart';

class ApiService {
  // Base URLs for the API endpoints
  static const String _syncPlaylistUrl = 'https://wrapifyapi.duckdns.org/syncplaylist';
  static const String _playlistDetailsUrl = 'https://wrapifyapi.dedyn.io/playlist';
  static const String _streamBaseUrl = 'https://wrapifyapi.dedyn.io/stream';
  
  // Create an HTTP client that accepts all certificates
  http.Client _createClient() {
    HttpClient httpClient = HttpClient()
      ..badCertificateCallback = 
          ((X509Certificate cert, String host, int port) => true);
          
    return http.Client();
  }

  // Fetch a playlist's songs from the API
  Future<List<Song>> fetchPlaylistSongs(String playlistId) async {
    try {
      // Create a client that bypasses certificate validation
      final client = HttpClient()
        ..badCertificateCallback = 
            ((X509Certificate cert, String host, int port) => true);
            
      final request = await client.getUrl(Uri.parse('$_playlistDetailsUrl/$playlistId'));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        final items = data['items'] as List;
        
        return items.map((item) => Song.fromJson(item)).toList();
      } else {
        throw Exception('Failed to fetch playlist: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching playlist songs: $e');
      throw Exception('Failed to fetch songs: $e');
    }
  }

  // Sync a playlist from Spotify to the server
  Future<void> syncPlaylist(String spotifyUrl) async {
    try {
      // Create a client that bypasses certificate validation
      final client = HttpClient()
        ..badCertificateCallback = 
            ((X509Certificate cert, String host, int port) => true);
            
      final request = await client.postUrl(Uri.parse(_syncPlaylistUrl));
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode({'url': spotifyUrl})));
      
      final response = await request.close();
      
      // We don't wait for the response as mentioned in requirements
      print('Sync playlist request submitted: $spotifyUrl');
    } catch (e) {
      print('Error syncing playlist: $e');
      throw Exception('Failed to sync playlist: $e');
    }
  }

  // Get the streaming URL for a song
  String getStreamUrl(String songId) {
    return '$_streamBaseUrl/$songId';
  }

  // Extract playlist ID from Spotify URL
  static String extractPlaylistId(String spotifyUrl) {
    // Typical Spotify URL: https://open.spotify.com/playlist/37i9dQZF1DX0XUsuxWHRQd
    final uri = Uri.parse(spotifyUrl);
    
    final segments = uri.pathSegments;
    if (segments.length >= 2 && segments[0] == 'playlist') {
      return segments[1];
    }
    
    // If we can't extract the ID properly, use the last segment
    return segments.isNotEmpty ? segments.last : '';
  }
}