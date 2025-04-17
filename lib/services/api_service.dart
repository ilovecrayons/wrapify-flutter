import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/sync_job.dart';

class ApiService {
  // Base URLs for the API endpoints
  static const String _baseUrl = 'https://wrapifyapi.dedyn.io';
  static const String _altBaseUrl = 'https://wrapifyapi.duckdns.org';
  
  static const String _syncPlaylistUrl = '$_altBaseUrl/syncplaylist';
  static const String _playlistDetailsUrl = '$_baseUrl/playlist';
  static const String _streamBaseUrl = '$_baseUrl/stream';
  static const String _syncStatusUrl = '$_baseUrl/syncstatus';
  static const String _playlistErrorsUrl = '$_baseUrl/playlist-errors';
  
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

  // Sync a playlist from Spotify to the server - now returns SyncJob details
  Future<SyncJob> syncPlaylist(String spotifyUrl) async {
    try {
      // Create a client that bypasses certificate validation
      final client = HttpClient()
        ..badCertificateCallback = 
            ((X509Certificate cert, String host, int port) => true);
            
      final request = await client.postUrl(Uri.parse(_syncPlaylistUrl));
      request.headers.set('Content-Type', 'application/json');
      request.add(utf8.encode(jsonEncode({'url': spotifyUrl})));
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == 202) {
        final data = jsonDecode(responseBody);
        return SyncJob(
          id: data['jobId'],
          playlistId: data['playlistId'] ?? '',
          playlistName: data['playlistName'] ?? 'New Playlist',
          status: 'queued',
          progress: 0,
          startTime: DateTime.now().toIso8601String(),
        );
      } else {
        throw Exception('Failed to sync playlist: ${response.statusCode}');
      }
    } catch (e) {
      print('Error syncing playlist: $e');
      throw Exception('Failed to sync playlist: $e');
    }
  }
  
  // Get the status of a syncing job
  Future<SyncJob> getSyncStatus(String jobId) async {
    try {
      final client = HttpClient()
        ..badCertificateCallback = 
            ((X509Certificate cert, String host, int port) => true);
            
      final request = await client.getUrl(Uri.parse('$_syncStatusUrl/$jobId'));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == 200) {
        final data = jsonDecode(responseBody);
        return SyncJob.fromJson(data);
      } else {
        throw Exception('Failed to get sync status: ${response.statusCode}');
      }
    } catch (e) {
      print('Error getting sync status: $e');
      throw Exception('Failed to get sync status: $e');
    }
  }
  
  // Get error information for songs in a playlist
  Future<Map<String, dynamic>> getPlaylistErrors(String playlistId) async {
    try {
      final client = HttpClient()
        ..badCertificateCallback = 
            ((X509Certificate cert, String host, int port) => true);
            
      final request = await client.getUrl(Uri.parse('$_playlistErrorsUrl/$playlistId'));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode == 200) {
        return jsonDecode(responseBody);
      } else {
        throw Exception('Failed to get playlist errors: ${response.statusCode}');
      }
    } catch (e) {
      print('Error getting playlist errors: $e');
      return {
        'playlistId': playlistId,
        'errorCount': 0,
        'songs': []
      };
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