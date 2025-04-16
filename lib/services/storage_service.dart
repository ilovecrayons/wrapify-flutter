import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/playlist.dart';
import '../models/song.dart';

class StorageService {
  static const String _playlistsKey = 'wrapify_playlists';
  static const String _songsKey = 'wrapify_songs';

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
      existingSongs[song.id] = song;
    }
    
    await saveSongs(existingSongs);
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