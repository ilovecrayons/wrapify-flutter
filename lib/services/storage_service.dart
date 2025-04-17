import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../models/sync_job.dart';

class StorageService {
  static const String _playlistsKey = 'wrapify_playlists';
  static const String _songsKey = 'wrapify_songs';
  static const String _syncJobsKey = 'wrapify_sync_jobs';
  static const String _songErrorsKey = 'wrapify_song_errors';

  // Save playlists to persistent storage
  Future<void> savePlaylists(List<Playlist> playlists) async {
    final prefs = await SharedPreferences.getInstance();
    final playlistsJson = playlists.map((playlist) => playlist.toJson()).toList();
    await prefs.setString(_playlistsKey, jsonEncode(playlistsJson));
  }

  // Load playlists from persistent storage
  Future<List<Playlist>> loadPlaylists() async {
    final prefs = await SharedPreferences.getInstance();
    final playlistsJson = prefs.getString(_playlistsKey);
    
    if (playlistsJson == null || playlistsJson.isEmpty) {
      return [];
    }
    
    try {
      final List<dynamic> decoded = jsonDecode(playlistsJson);
      return decoded.map((json) => Playlist.fromJson(json)).toList();
    } catch (e) {
      print('Error loading playlists: $e');
      return [];
    }
  }

  // Save songs to persistent storage
  Future<void> saveSongs(Map<String, Song> songs) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> songsMap = {};
    
    songs.forEach((key, song) {
      songsMap[key] = song.toJson();
    });
    
    await prefs.setString(_songsKey, jsonEncode(songsMap));
  }

  // Load songs from persistent storage
  Future<Map<String, Song>> loadSongs() async {
    final prefs = await SharedPreferences.getInstance();
    final songsJson = prefs.getString(_songsKey);
    
    if (songsJson == null || songsJson.isEmpty) {
      return {};
    }
    
    try {
      final Map<String, dynamic> decoded = jsonDecode(songsJson);
      final Map<String, Song> songs = {};
      
      decoded.forEach((key, value) {
        songs[key] = Song.fromJson(value);
      });
      
      return songs;
    } catch (e) {
      print('Error loading songs: $e');
      return {};
    }
  }

  // Add a song to storage
  Future<void> addSongs(List<Song> songs) async {
    final existingSongs = await loadSongs();
    
    for (final song in songs) {
      // If the song already exists with an error, preserve error status
      if (existingSongs.containsKey(song.id) && existingSongs[song.id]!.hasError) {
        existingSongs[song.id] = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: existingSongs[song.id]!.errorMessage,
          hasError: true,
        );
      } else {
        existingSongs[song.id] = song;
      }
    }
    
    await saveSongs(existingSongs);
  }

  // Save song errors
  Future<void> saveSongErrors(String playlistId, List<Map<String, dynamic>> errorSongs) async {
    final prefs = await SharedPreferences.getInstance();
    final existingSongs = await loadSongs();
    final existingPlaylists = await loadPlaylists();
    
    // Find the playlist
    final playlistIndex = existingPlaylists.indexWhere((p) => p.id == playlistId);
    if (playlistIndex < 0) return;
    
    final playlist = existingPlaylists[playlistIndex];
    
    // Update songs with errors
    for (final songData in errorSongs) {
      final songId = songData['id'];
      final errorMessage = songData['errorMessage'] ?? 'Unknown error';
      
      if (existingSongs.containsKey(songId)) {
        // Update existing song with error
        existingSongs[songId] = existingSongs[songId]!.copyWithError(errorMessage);
      } else {
        // Create a new song with error
        existingSongs[songId] = Song(
          id: songId,
          title: songData['title'] ?? 'Unknown Song',
          artist: songData['artist'] ?? 'Unknown Artist',
          errorMessage: errorMessage,
          hasError: true,
        );
        
        // Add to playlist's song IDs if not already there
        if (!playlist.songIds.contains(songId)) {
          final updatedSongIds = List<String>.from(playlist.songIds)..add(songId);
          existingPlaylists[playlistIndex] = Playlist(
            id: playlist.id,
            name: playlist.name,
            spotifyUrl: playlist.spotifyUrl,
            imageUrl: playlist.imageUrl,
            songIds: updatedSongIds,
          );
        }
      }
    }
    
    // Save updated songs and playlists
    await saveSongs(existingSongs);
    await savePlaylists(existingPlaylists);
    
    // Also store as a separate list for quick access
    await prefs.setString('$_songErrorsKey:$playlistId', jsonEncode(errorSongs));
  }
  
  // Load song errors for a specific playlist
  Future<List<Map<String, dynamic>>> loadSongErrors(String playlistId) async {
    final prefs = await SharedPreferences.getInstance();
    final errorsJson = prefs.getString('$_songErrorsKey:$playlistId');
    
    if (errorsJson == null || errorsJson.isEmpty) {
      return [];
    }
    
    try {
      final List<dynamic> decoded = jsonDecode(errorsJson);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      print('Error loading song errors: $e');
      return [];
    }
  }
  
  // Save a sync job
  Future<void> saveSyncJob(SyncJob job) async {
    final prefs = await SharedPreferences.getInstance();
    final existingJobsJson = prefs.getString(_syncJobsKey);
    
    List<Map<String, dynamic>> jobs = [];
    if (existingJobsJson != null && existingJobsJson.isNotEmpty) {
      try {
        final List<dynamic> decoded = jsonDecode(existingJobsJson);
        jobs = decoded.cast<Map<String, dynamic>>();
      } catch (e) {
        print('Error parsing existing jobs: $e');
      }
    }
    
    // Check if job already exists
    final existingJobIndex = jobs.indexWhere((j) => j['jobId'] == job.id);
    if (existingJobIndex >= 0) {
      jobs[existingJobIndex] = job.toJson();
    } else {
      jobs.add(job.toJson());
    }
    
    // Limit to last 20 jobs
    if (jobs.length > 20) {
      jobs = jobs.sublist(jobs.length - 20);
    }
    
    await prefs.setString(_syncJobsKey, jsonEncode(jobs));
    
    // Also store latest job for each playlist
    await prefs.setString('syncJob:${job.playlistId}', jsonEncode(job.toJson()));
  }
  
  // Get the latest sync job for a playlist
  Future<SyncJob?> getLatestSyncJobForPlaylist(String playlistId) async {
    final prefs = await SharedPreferences.getInstance();
    final jobJson = prefs.getString('syncJob:$playlistId');
    
    if (jobJson == null || jobJson.isEmpty) {
      return null;
    }
    
    try {
      final Map<String, dynamic> decoded = jsonDecode(jobJson);
      return SyncJob.fromJson(decoded);
    } catch (e) {
      print('Error loading sync job: $e');
      return null;
    }
  }
  
  // Get all sync jobs
  Future<List<SyncJob>> getAllSyncJobs() async {
    final prefs = await SharedPreferences.getInstance();
    final jobsJson = prefs.getString(_syncJobsKey);
    
    if (jobsJson == null || jobsJson.isEmpty) {
      return [];
    }
    
    try {
      final List<dynamic> decoded = jsonDecode(jobsJson);
      return decoded.map((json) => SyncJob.fromJson(json)).toList();
    } catch (e) {
      print('Error loading sync jobs: $e');
      return [];
    }
  }

  // Add a playlist to storage
  Future<void> addPlaylist(Playlist playlist) async {
    final existingPlaylists = await loadPlaylists();
    final existingIndex = existingPlaylists.indexWhere((p) => p.id == playlist.id);
    
    if (existingIndex >= 0) {
      existingPlaylists[existingIndex] = playlist;
    } else {
      existingPlaylists.add(playlist);
    }
    
    await savePlaylists(existingPlaylists);
  }

  // Remove a playlist from storage
  Future<void> removePlaylist(String playlistId) async {
    final existingPlaylists = await loadPlaylists();
    existingPlaylists.removeWhere((playlist) => playlist.id == playlistId);
    await savePlaylists(existingPlaylists);
  }
}