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
  static const String _ignoredSongsKey = 'wrapify_ignored_songs'; // New key for ignored songs

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
      
      // Load ignored songs list first to ensure we can apply ignored status
      final ignoredSongIds = await loadIgnoredSongs();
      print('Loading songs: Applying ignored status to ${ignoredSongIds.length} songs');
      if (ignoredSongIds.isNotEmpty) {
        print('Ignored song IDs: ${ignoredSongIds.join(', ')}');
      }
      
      int ignoredCount = 0;
      decoded.forEach((key, value) {
        // Create song from JSON
        Song song = Song.fromJson(value);
        
        // Check if the song is already marked as ignored in its own data
        final isIgnoredInJson = song.isIgnored;
        
        // Explicitly apply ignored status based on the dedicated ignored songs list
        // This ensures the ignored status is the source of truth
        if (ignoredSongIds.contains(key)) {
          ignoredCount++;
          song = song.copyWithIgnored(true);
          print('Song ID $key (${song.title}) marked as ignored (from ignored list)');
        } else if (isIgnoredInJson) {
          // If the song is marked ignored in JSON but not in the list, add it to the list
          print('Song ID $key (${song.title}) is marked as ignored in JSON but not in ignored list');
        }
        
        songs[key] = song;
      });
      
      print('Finished loading ${songs.length} songs, $ignoredCount are ignored');
      
      // If there's a mismatch, schedule a sync after loading completes
      if (ignoredCount != ignoredSongIds.length) {
        print('WARNING: Mismatch between ignored songs list (${ignoredSongIds.length}) and applied ignored status ($ignoredCount)');
        // Schedule a sync to run after this method completes
        Future.microtask(() => syncIgnoredSongsState());
      }
      
      return songs;
    } catch (e) {
      print('Error loading songs: $e');
      return {};
    }
  }

  // Save ignored song IDs separately for quicker access
  Future<void> saveIgnoredSongs(List<String> songIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Sort to ensure consistent storage
      songIds.sort();
      
      final jsonString = jsonEncode(songIds);
      final result = await prefs.setString(_ignoredSongsKey, jsonString);
      
      if (result) {
        print('Successfully saved ${songIds.length} ignored songs');
        if (songIds.isNotEmpty) {
          print('Ignored song IDs: ${songIds.join(', ')}');
        }
      } else {
        print('WARNING: Failed to save ignored songs list to SharedPreferences');
      }
    } catch (e) {
      print('ERROR saving ignored songs: $e');
    }
  }
  
  // Load ignored song IDs
  Future<List<String>> loadIgnoredSongs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ignoredJson = prefs.getString(_ignoredSongsKey);
      
      if (ignoredJson == null || ignoredJson.isEmpty) {
        print('No ignored songs found in storage');
        return [];
      }
      
      final List<dynamic> decoded = jsonDecode(ignoredJson);
      final ignoredIds = decoded.cast<String>();
      print('Loaded ${ignoredIds.length} ignored songs from storage');
      if (ignoredIds.isNotEmpty) {
        print('Ignored song IDs from storage: ${ignoredIds.join(', ')}');
      }
      return ignoredIds;
    } catch (e) {
      print('ERROR loading ignored songs: $e');
      return [];
    }
  }

  // Add a song to storage (modified to update ignored list)
  Future<void> addSongs(List<Song> songs) async {
    print('Adding/updating ${songs.length} songs to storage');
    final existingSongs = await loadSongs();
    final ignoredSongIds = await loadIgnoredSongs();
    print('Current ignored songs list has ${ignoredSongIds.length} songs');
    
    bool ignoredListChanged = false;
    int ignoredSongsFound = 0;
    
    for (final song in songs) {
      // If the song already exists, preserve error status and ignored status
      if (existingSongs.containsKey(song.id)) {
        final oldIgnoredStatus = existingSongs[song.id]!.isIgnored;
        
        if (oldIgnoredStatus) {
          ignoredSongsFound++;
          print('Preserving ignored status for existing song "${song.title}" (ID: ${song.id})');
        }
        
        existingSongs[song.id] = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: existingSongs[song.id]!.hasError ? existingSongs[song.id]!.errorMessage : song.errorMessage,
          hasError: existingSongs[song.id]!.hasError,
          isIgnored: oldIgnoredStatus, // Preserve ignored status
        );
        
        // Make sure the ignored list is in sync
        if (oldIgnoredStatus) {
          if (!ignoredSongIds.contains(song.id)) {
            print('Adding existing ignored song "${song.title}" (ID: ${song.id}) to ignored list');
            ignoredSongIds.add(song.id);
            ignoredListChanged = true;
          }
        }
      } else {
        // For new songs, check if they should be ignored based on the ignored list
        final shouldBeIgnored = ignoredSongIds.contains(song.id);
        
        if (shouldBeIgnored) {
          ignoredSongsFound++;
          print('New song "${song.title}" (ID: ${song.id}) is in ignored list, setting ignored status');
        }
        
        existingSongs[song.id] = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: song.errorMessage,
          hasError: song.hasError,
          isIgnored: shouldBeIgnored, // Set ignored status based on ignored list
        );
      }
    }
    
    print('Saving ${existingSongs.length} songs, $ignoredSongsFound have ignored status');
    await saveSongs(existingSongs);
    
    if (ignoredListChanged) {
      print('Ignored list changed, saving ${ignoredSongIds.length} song IDs');
      await saveIgnoredSongs(ignoredSongIds);
    }
  }

  // Toggle a song's ignored status with improved persistence
  Future<Song> toggleSongIgnored(String songId, bool isIgnored) async {
    final existingSongs = await loadSongs();
    final ignoredSongIds = await loadIgnoredSongs();
    
    if (existingSongs.containsKey(songId)) {
      final song = existingSongs[songId]!;
      print('Toggling song "${song.title}" (ID: $songId) ignored status to: $isIgnored');
      
      final updatedSong = song.copyWithIgnored(isIgnored);
      existingSongs[songId] = updatedSong;
      
      // Update the dedicated ignored songs list
      bool listChanged = false;
      if (isIgnored) {
        if (!ignoredSongIds.contains(songId)) {
          ignoredSongIds.add(songId);
          listChanged = true;
          print('Added song ID $songId to ignored list (now ${ignoredSongIds.length} songs)');
        } else {
          print('Song ID $songId was already in ignored list');
        }
      } else {
        if (ignoredSongIds.contains(songId)) {
          ignoredSongIds.remove(songId);
          listChanged = true;
          print('Removed song ID $songId from ignored list (now ${ignoredSongIds.length} songs)');
        } else {
          print('Song ID $songId was not in ignored list');
        }
      }
      
      // Save both the updated song and the ignored songs list
      await saveSongs(existingSongs);
      
      if (listChanged) {
        await saveIgnoredSongs(ignoredSongIds);
      }
      
      print('Song "$songId" ignored status updated to $isIgnored, ignored list has ${ignoredSongIds.length} songs');
      
      return updatedSong;
    } else {
      print('ERROR: Attempted to toggle ignored status for non-existent song: $songId');
      throw Exception('Song not found');
    }
  }

  // Method to sync and repair ignored status across storage
  Future<void> syncIgnoredSongsState() async {
    print('----- Starting ignored songs state synchronization -----');
    try {
      final existingSongs = await loadSongs();
      print('Loaded ${existingSongs.length} songs for ignored status sync');
      
      final ignoredSongIds = await loadIgnoredSongs();
      print('Loaded ${ignoredSongIds.length} song IDs from ignored list');
      
      final actualIgnoredIds = <String>[];
      bool needsUpdate = false;
      
      // First pass: Check songs that should be ignored according to the ignored list
      for (final songId in ignoredSongIds) {
        if (existingSongs.containsKey(songId)) {
          final song = existingSongs[songId]!;
          if (!song.isIgnored) {
            final title = song.title;
            print('Fixing inconsistency: Song "$title" (ID: $songId) should be ignored according to list');
            existingSongs[songId] = song.copyWithIgnored(true);
            needsUpdate = true;
          } else {
            print('Song ID $songId is correctly marked as ignored');
          }
          actualIgnoredIds.add(songId);
        } else {
          print('WARNING: Song ID $songId in ignored list but not found in songs collection');
          actualIgnoredIds.add(songId);
        }
      }
      
      // Second pass: Find songs marked as ignored in their object but missing from ignored list
      for (final entry in existingSongs.entries) {
        final song = entry.value;
        final songId = entry.key;
        
        if (song.isIgnored) {
          if (!actualIgnoredIds.contains(songId)) {
            print('Adding song "${song.title}" (ID: $songId) to ignored list based on object property');
            actualIgnoredIds.add(songId);
            needsUpdate = true;
          }
        }
      }
      
      // Save updates if needed
      if (needsUpdate) {
        print('Updating storage with ${actualIgnoredIds.length} ignored songs');
        await saveSongs(existingSongs);
        await saveIgnoredSongs(actualIgnoredIds);
        print('Successfully synced ignored songs state: ${actualIgnoredIds.length} songs are now properly ignored');
      } else {
        print('No updates needed for ignored songs state, everything is in sync');
        if (actualIgnoredIds.length != ignoredSongIds.length) {
          print('Refreshing ignored songs list to remove stale entries');
          await saveIgnoredSongs(actualIgnoredIds);
        }
      }
    } catch (e) {
      print('ERROR syncing ignored songs state: $e');
    }
    print('----- Finished ignored songs state synchronization -----');
  }

  // Update a song with new data (for resyncing)
  Future<Song> updateSong(Song song) async {
    print('Updating song "${song.title}" (ID: ${song.id})');
    final existingSongs = await loadSongs();
    final ignoredSongIds = await loadIgnoredSongs(); // Also load the ignored song IDs list
    
    // Preserve the ignored status from the existing song if it exists
    bool shouldBeIgnored = false;
    
    // Check both the existing song object and the dedicated ignored list
    if (existingSongs.containsKey(song.id)) {
      shouldBeIgnored = existingSongs[song.id]!.isIgnored;
    } else {
      // If song doesn't exist yet, check the ignored list
      shouldBeIgnored = ignoredSongIds.contains(song.id);
    }
    
    if (shouldBeIgnored) {
      print('Preserving ignored status for song "${song.title}" (ID: ${song.id}) during update');
    }
    
    // Always ensure the song object and the ignored list are in sync
    if (shouldBeIgnored && !ignoredSongIds.contains(song.id)) {
      print('Adding missing song ID ${song.id} to ignored list during update');
      ignoredSongIds.add(song.id);
      await saveIgnoredSongs(ignoredSongIds);
    } else if (!shouldBeIgnored && ignoredSongIds.contains(song.id)) {
      print('Removing song ID ${song.id} from ignored list during update as it is no longer ignored');
      ignoredSongIds.remove(song.id);
      await saveIgnoredSongs(ignoredSongIds);
    }
    
    final updatedSong = Song(
      id: song.id,
      title: song.title,
      artist: song.artist,
      imageUrl: song.imageUrl,
      externalUrls: song.externalUrls,
      errorMessage: song.errorMessage,
      hasError: song.hasError,
      isIgnored: shouldBeIgnored,
    );
    
    existingSongs[song.id] = updatedSong;
    await saveSongs(existingSongs);
    
    // Force a sync to ensure everything is consistent
    Future.microtask(() => syncIgnoredSongsState());
    
    print('Song "${song.title}" (ID: ${song.id}) updated, ignored status: $shouldBeIgnored');
    
    // Print current audio player state if we have access to it (for debugging)
    print('IMPORTANT: If this song is currently queued for playback, you may need to refresh the playlist');
    
    return updatedSong;
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
        // Update existing song with error while preserving ignored status
        final isIgnored = existingSongs[songId]!.isIgnored;
        existingSongs[songId] = Song(
          id: songId,
          title: existingSongs[songId]!.title,
          artist: existingSongs[songId]!.artist,
          imageUrl: existingSongs[songId]!.imageUrl,
          externalUrls: existingSongs[songId]!.externalUrls,
          errorMessage: errorMessage,
          hasError: true,
          isIgnored: isIgnored, // Preserve the ignored status
        );
      } else {
        // Create a new song with error
        existingSongs[songId] = Song(
          id: songId,
          title: songData['title'] ?? 'Unknown Song',
          artist: songData['artist'] ?? 'Unknown Artist',
          errorMessage: errorMessage,
          hasError: true,
          isIgnored: false, // New songs are not ignored by default
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
            syncJobId: playlist.syncJobId,
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
  
  // Debug method to print detailed information about ignored songs
  Future<void> debugIgnoredSongs() async {
    print('\n📋 IGNORED SONGS DEBUG REPORT 📋');
    
    try {
      // Load both sources of truth
      final ignoredSongIds = await loadIgnoredSongs();
      final allSongs = await loadSongs();
      
      print('Total songs in storage: ${allSongs.length}');
      print('Songs in ignored list: ${ignoredSongIds.length}');
      
      // Check for songs that are in the ignored list
      if (ignoredSongIds.isNotEmpty) {
        print('\n🔍 Songs in ignored list:');
        for (final songId in ignoredSongIds) {
          if (allSongs.containsKey(songId)) {
            final song = allSongs[songId]!;
            print('  ✓ Song "${song.title}" (ID: $songId) - isIgnored property: ${song.isIgnored}');
          } else {
            print('  ⚠️ Song ID $songId in ignored list but not found in songs collection');
          }
        }
      }
      
      // Check for songs marked as ignored in their object but not in the list
      final mismatches = <String>[];
      for (final entry in allSongs.entries) {
        if (entry.value.isIgnored && !ignoredSongIds.contains(entry.key)) {
          mismatches.add(entry.key);
          print('  ⚠️ Song "${entry.value.title}" (ID: ${entry.key}) marked as ignored in object but not in ignored list');
        }
      }
      
      // Check consistency
      final songsMarkedAsIgnored = allSongs.values.where((s) => s.isIgnored).length;
      if (songsMarkedAsIgnored != ignoredSongIds.length || mismatches.isNotEmpty) {
        print('\n⚠️ INCONSISTENCY DETECTED: ${songsMarkedAsIgnored} songs marked as ignored, but ${ignoredSongIds.length} in ignored list');
      } else {
        print('\n✅ Storage consistency check passed: ${ignoredSongIds.length} songs properly ignored');
      }
    } catch (e) {
      print('Error in debug report: $e');
    }
    
    print('📋 END OF REPORT 📋\n');
  }
  
  // Force refresh all caches and ensure ignored songs are properly applied
  Future<void> forceRefreshIgnoredSongs() async {
    print('\n🔄 FORCE REFRESHING IGNORED SONGS 🔄');
    
    try {
      // First run a sync to ensure consistency
      await syncIgnoredSongsState();
      
      // Get the latest data
      final ignoredSongIds = await loadIgnoredSongs();
      final allSongs = await loadSongs();
      
      // Create a new map with fresh song objects to avoid reference issues
      final refreshedSongs = <String, Song>{};
      
      // Recreate all song objects with correct ignored status
      for (final entry in allSongs.entries) {
        final songId = entry.key;
        final song = entry.value;
        
        // Determine the correct ignored status - ALWAYS use the ignored list as source of truth
        final shouldBeIgnored = ignoredSongIds.contains(songId);
        
        // If there's a mismatch, log it
        if (shouldBeIgnored != song.isIgnored) {
          print('Fixing mismatch: Song "${song.title}" (ID: $songId) - was: ${song.isIgnored}, should be: $shouldBeIgnored');
        }
        
        // Create a fresh song object with the correct ignored status
        refreshedSongs[songId] = Song(
          id: songId,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: song.errorMessage,
          hasError: song.hasError,
          isIgnored: shouldBeIgnored, // Apply the correct status
        );
      }
      
      // Save the refreshed songs
      await saveSongs(refreshedSongs);
      
      // Clear any local song caches in the app
      print('\n⚠️ IMPORTANT: You must manually refresh the UI and audio player after this operation');
      print('⚠️ Steps to fix playback issues:');
      print('  1. Return to home screen');
      print('  2. Re-enter the playlist');
      print('  3. Stop and restart playback if already playing');
      
      print('✅ Successfully refreshed ${refreshedSongs.length} songs with ${ignoredSongIds.length} marked as ignored');
      print('🔄 REFRESH COMPLETE - Please restart playback or reload playlists 🔄\n');
    } catch (e) {
      print('Error during force refresh: $e');
    }
  }
  
  // Get a diagnostic report on an ignored song to check all relevant statuses
  Future<void> diagnoseSong(String songId) async {
    print('\n🔍 DIAGNOSTIC REPORT FOR SONG $songId 🔍');
    try {
      final ignoredSongIds = await loadIgnoredSongs();
      final allSongs = await loadSongs();
      
      final inIgnoredList = ignoredSongIds.contains(songId);
      print('In ignored list: $inIgnoredList');
      
      if (allSongs.containsKey(songId)) {
        final song = allSongs[songId]!;
        print('Song found in storage:');
        print('  Title: ${song.title}');
        print('  Artist: ${song.artist}');
        print('  isIgnored flag: ${song.isIgnored}');
        print('  hasError flag: ${song.hasError}');
        
        if (inIgnoredList != song.isIgnored) {
          print('\n⚠️ CONSISTENCY ERROR: Ignored list says: $inIgnoredList, song object says: ${song.isIgnored}');
        } else {
          print('\n✅ Ignored status is consistent between list and object');
        }
      } else {
        print('⚠️ Song not found in storage');
      }
    } catch (e) {
      print('Error in song diagnostic: $e');
    }
    print('🔍 END OF DIAGNOSTIC REPORT 🔍\n');
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