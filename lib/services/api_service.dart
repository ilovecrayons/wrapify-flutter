import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/sync_job.dart';

class ApiService {
  // Base URLs for the API endpoints
  static const String _baseUrl = 'https://wrapifyapi.dedyn.io';
  static const String _syncPlaylistUrl = '$_baseUrl/syncplaylist';
  static const String _playlistDetailsUrl = '$_baseUrl/playlist';
  static const String _streamBaseUrl = '$_baseUrl/stream';
  static const String _syncStatusUrl = '$_baseUrl/syncstatus';
  static const String _playlistErrorsUrl = '$_baseUrl/playlist-errors';
  static const String _resyncSongUrl = '$_baseUrl/resyncsong';
  
  // Use the standard http client for default validation
  final http.Client _client = http.Client();

  // Fetch a playlist's songs from the API
  Future<List<Song>> fetchPlaylistSongs(String playlistId) async {
    try {
      final response = await _client.get(Uri.parse('$_playlistDetailsUrl/$playlistId'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final items = data['items'] as List;
        
        return items.map((item) => Song.fromJson(item)).toList();
      } else {
        throw Exception('Failed to fetch playlist: ${response.statusCode}');
      }
    } catch (e) {
      // Keep print for now as requested
      throw Exception('Failed to fetch songs: $e');
    }
  }

  // Sync a playlist from Spotify to the server - now returns SyncJob details
  Future<SyncJob> syncPlaylist(String spotifyUrl) async {
    try {
      final response = await _client.post(
        Uri.parse(_syncPlaylistUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'url': spotifyUrl}),
      );
      
      if (response.statusCode == 202) {
        final data = jsonDecode(response.body);
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
      // Keep print for now
      throw Exception('Failed to sync playlist: $e');
    }
  }
  
  // Get the status of a syncing job
  Future<SyncJob> getSyncStatus(String jobId) async {
    try {
      final response = await _client.get(Uri.parse('$_syncStatusUrl/$jobId'));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return SyncJob.fromJson(data);
      } else {
        throw Exception('Failed to get sync status: ${response.statusCode}');
      }
    } catch (e) {
      // Keep print for now
      throw Exception('Failed to get sync status: $e');
    }
  }
  
  // Get error information for songs in a playlist
  Future<Map<String, dynamic>> getPlaylistErrors(String playlistId) async {
    try {
      final response = await _client.get(Uri.parse('$_playlistErrorsUrl/$playlistId'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        throw Exception('Failed to get playlist errors: ${response.statusCode}');
      }
    } catch (e) {
      // Keep print for now
      return {
        'playlistId': playlistId,
        'errorCount': 0,
        'songs': []
      };
    }
  }

  // Resync a specific song that might have issues
  Future<Map<String, dynamic>> resyncSong(String songId) async {
    try {
      final response = await _client.post(Uri.parse('$_resyncSongUrl/$songId'));
      
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        final errorData = jsonDecode(response.body);
        throw Exception(errorData['message'] ?? 'Failed to resync song');
      }
    } catch (e) {
      // Keep print for now
      throw Exception('Failed to resync song: $e');
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