import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/sync_job.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_player_service.dart';
import '../utils/logger.dart';

class PlaylistScreen extends StatefulWidget {
  final String playlistId;
  final VoidCallback? onBack;

  const PlaylistScreen({
    super.key, 
    required this.playlistId,
    this.onBack,
  });

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final ApiService _apiService = ApiService();
  final StorageService _storageService = StorageService();
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  final Logger _logger = Logger('PlaylistScreen');
  
  List<Song> _songs = [];
  Playlist? _playlist;
  bool _isLoading = true;
  bool _isSyncing = false;
  Song? _currentSong;
  bool _isPlaying = false;
  PlaybackMode _playbackMode = PlaybackMode.linear;
  SyncJob? _syncJob;
  
  final Map<String, String> _songErrorMessages = {};
  int _errorCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
    _setupListeners();
    _syncIgnoredState();
    
  }

  // Sync the ignored songs state at startup
  Future<void> _syncIgnoredState() async {
    try {
      await _storageService.syncIgnoredSongsState();
    } catch (e) {
    }
  }

  void _setupListeners() {
    _audioPlayerService.currentSongStream.listen((song) {
      if (mounted) {
        setState(() {
          _currentSong = song;
        });
      }
    });

    _audioPlayerService.playbackStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state.isPlaying;
        });
      }
    });
    
    _audioPlayerService.playbackModeStream.listen((mode) {
      if (mounted) {
        setState(() {
          _playbackMode = mode;
        });
      }
    });
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final playlists = await _storageService.loadPlaylists();
      final playlist = playlists.firstWhere(
          (p) => p.id == widget.playlistId,
          orElse: () => Playlist(
                id: widget.playlistId,
                name: 'Unknown Playlist',
                spotifyUrl: '',
              ));

      if (playlist.syncJobId != null) {
        _syncJob = await _storageService.getLatestSyncJobForPlaylist(widget.playlistId);
        
        if (_syncJob != null && (_syncJob!.isProcessing || _syncJob!.isQueued)) {
          _startSyncStatusPolling(_syncJob!.id);
        }
      }

      final songs = await _apiService.fetchPlaylistSongs(widget.playlistId);

      if (songs.isNotEmpty) {
        _audioPlayerService.preCacheSong(songs.first);
      }

      await _storageService.addSongs(songs);

      // Reload songs from storage to ensure isIgnored status is correctly applied
      final allSongsFromStorage = await _storageService.loadSongs();
      
      // *** Always use the latest song IDs fetched from the API ***
      final latestSongIds = songs.map((s) => s.id).toList();

      final songsForState = latestSongIds
          .map((id) => allSongsFromStorage[id])
          .where((song) => song != null)
          .cast<Song>()
          .toList();

      await _checkForSongErrors(); // Check for errors *after* getting final song list

      // *** Always update the playlist object with the latest song IDs ***
      final updatedPlaylist = Playlist(
        id: playlist.id,
        name: playlist.name, // Keep existing name unless API provides update
        spotifyUrl: playlist.spotifyUrl,
        imageUrl: songs.isNotEmpty ? songs.first.imageUrl : playlist.imageUrl, // Update image if available
        songIds: latestSongIds, // Use the latest IDs
        syncJobId: playlist.syncJobId, // Keep existing sync job ID reference
      );

      await _storageService.addPlaylist(updatedPlaylist); // Save the updated playlist

      setState(() {
        _playlist = updatedPlaylist; // Update state with the corrected playlist
        _songs = songsForState; // Update state with the songs corresponding to latest IDs
        _isLoading = false;
      });
      
    } catch (e) {

      // Ensure error handling also loads from storage if possible
      final cachedSongs = await _storageService.loadSongs();
      final playlists = await _storageService.loadPlaylists();
      final playlist = playlists.firstWhere(
          (p) => p.id == widget.playlistId,
          orElse: () => Playlist(
                id: widget.playlistId,
                name: 'Unknown Playlist',
                spotifyUrl: '',
              ));

      final playlistSongs = <Song>[];
      for (final songId in playlist.songIds) {
        if (cachedSongs.containsKey(songId)) {
          playlistSongs.add(cachedSongs[songId]!);
        }
      }

      setState(() {
        _playlist = playlist;
        _songs = playlistSongs; // Use songs loaded from cache
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading songs: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _checkForSongErrors() async {
    try {
      final errorsData = await _apiService.getPlaylistErrors(widget.playlistId);


      _songErrorMessages.clear();

      if (errorsData['errorCount'] > 0 && errorsData['songs'] is List && errorsData['songs'].isNotEmpty) {
        final List<dynamic> errorSongs = errorsData['songs'] as List;
        final errorSongsList = List<Map<String, dynamic>>.from(errorSongs);

        for (final errorSong in errorSongsList) {
          final songId = errorSong['id'].toString();
          final errorMessage = errorSong['errorMessage'] ?? 'Unknown error';
          _songErrorMessages[songId] = errorMessage;
        }


        await _storageService.saveSongErrors(widget.playlistId, errorSongsList);

        setState(() {
          _errorCount = _songErrorMessages.length;
        });
      } else {
        setState(() {
          _errorCount = 0;
        });
      }
    } catch (e) {
    }
  }

  bool _songHasError(String songId) {
    return _songErrorMessages.containsKey(songId);
  }

  String? _getErrorMessage(String songId) {
    return _songErrorMessages[songId];
  }

  void _showErrorSongsDialog() {
    
    _refreshErrorInformation().then((_) {
      final displayErrorSongs = _songs.where((song) => _songHasError(song.id)).map((song) {
        return Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: _getErrorMessage(song.id),
          hasError: true,
        );
      }).toList();

      // Use the song variable to improve logging 
      for (var song in displayErrorSongs) {
        // Log error songs when debugging
        if (song.errorMessage != null) {
          // Using logger for actual logging instead of empty comment
          _logger.debug('Error song: ${song.title}, Error: ${song.errorMessage}');
        }
      }

      if (displayErrorSongs.isEmpty) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No Error Songs'),
            content: const Text('No songs with errors were found in this playlist.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }

      // Use Dialog instead of AlertDialog for more flexibility with large content
      showDialog(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(16.0),
          child: Container(
            width: double.maxFinite,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8, // 80% of screen height
              maxWidth: 600,
            ),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Song Errors (${displayErrorSongs.length})',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                if (displayErrorSongs.length > 5)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8.0),
                    child: Text(
                      'Scroll to see all ${displayErrorSongs.length} errors',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        color: Colors.grey[600],
                      ),
                    ),
                  ),
                Flexible(
                  child: Scrollbar(
                    thumbVisibility: true,
                    thickness: 6.0,
                    radius: const Radius.circular(10.0),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: displayErrorSongs.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final song = displayErrorSongs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.error, color: Colors.red, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      song.title,
                                      style: const TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(left: 28.0, top: 4.0),
                                child: Text(
                                  song.errorMessage ?? 'Unknown error',
                                  style: const TextStyle(color: Colors.red),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Future<void> _refreshErrorInformation() async {
    try {
      final errorsData = await _apiService.getPlaylistErrors(widget.playlistId);
      
      _songErrorMessages.clear();

      if (errorsData['errorCount'] > 0 && errorsData['songs'] is List && errorsData['songs'].isNotEmpty) {
        final List<dynamic> errorSongs = errorsData['songs'] as List;
        
        for (final errorSong in errorSongs) {
          final songId = errorSong['id'].toString();
          final errorMessage = errorSong['errorMessage'] ?? 'Unknown error';
          _songErrorMessages[songId] = errorMessage;
        }
        
        
        setState(() {
          _errorCount = _songErrorMessages.length;
        });
      } else {
        setState(() {
          _errorCount = 0;
        });
      }
    } catch (e) {
    }
  }

  void _showErrorDetails(Song song) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error Details for "${song.title}"'),
        content: Text(_getErrorMessage(song.id) ?? 'Unknown error'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _playSong(Song song) async {
    if (_songHasError(song.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot play song: ${_getErrorMessage(song.id) ?? "Unknown error"}'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    if (song.isIgnored) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This song is set to be ignored during playback'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Filter the songs first
    final playableSongs = _songs.where((s) => !_songHasError(s.id) && !s.isIgnored).toList();
    // Calculate the index within the filtered list
    final startIndexInPlayable = playableSongs.indexWhere((s) => s.id == song.id);

    // Ensure the song was found in the playable list
    if (startIndexInPlayable == -1) {
       ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Error finding song in playable list.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    _audioPlayerService.setPlaylist(playableSongs, 
      startIndex: startIndexInPlayable, // Use the correct index
      autoPlay: false);
      
    await _audioPlayerService.playSong(song);
  }

  void _startSyncStatusPolling(String jobId) async {
    bool isComplete = false;
    int attempts = 0;
    const maxAttempts = 30;
    
    while (!isComplete && attempts < maxAttempts && mounted) {
      try {
        await Future.delayed(const Duration(seconds: 10));
        final syncJob = await _apiService.getSyncStatus(jobId);
        await _storageService.saveSyncJob(syncJob);
        
        
        if (mounted) {
          setState(() {
            _syncJob = syncJob;
            _isSyncing = syncJob.isProcessing || syncJob.isQueued;
          });
        }
        
        if (syncJob.isComplete || syncJob.isError) {
          isComplete = true;
          
          if (syncJob.isComplete && mounted) {
            await _loadPlaylist();
            await _checkForSongErrors();
          } else if (syncJob.isError && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error syncing playlist: ${syncJob.error ?? "Unknown error"}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        
        attempts++;
      } catch (e) {
        attempts++;
        
        if (attempts > 5) {
          isComplete = true;
        }
      }
    }
    
    if (mounted) {
      setState(() {
        _isSyncing = false;
      });
    }
  }

  Future<void> _syncPlaylist() async {
    if (_playlist == null || _playlist!.spotifyUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No Spotify URL available for this playlist'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSyncing = true;
    });

    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Starting playlist sync...'),
          duration: Duration(seconds: 2),
        ),
      );

      final syncJob = await _apiService.syncPlaylist(_playlist!.spotifyUrl);
      
      await _storageService.saveSyncJob(syncJob);
      
      if (_playlist != null) {
        final updatedPlaylist = Playlist(
          id: _playlist!.id,
          name: syncJob.playlistName,
          spotifyUrl: _playlist!.spotifyUrl,
          imageUrl: _playlist!.imageUrl,
          songIds: _playlist!.songIds,
          syncJobId: syncJob.id,
        );
        
        await _storageService.addPlaylist(updatedPlaylist);
        
        setState(() {
          _playlist = updatedPlaylist;
          _syncJob = syncJob;
        });
      }
      
      _startSyncStatusPolling(syncJob.id);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Syncing "${syncJob.playlistName}" in the background. Check back soon!'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error syncing playlist: $e'),
          backgroundColor: Colors.red,
        ),
      );
      
      setState(() {
        _isSyncing = false;
      });
    }
  }

  Future<void> _resyncSong(Song song) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Resyncing "${song.title}"...'),
          duration: const Duration(seconds: 1),
        ),
      );
      
      // Remove the old version from cache first
      await _audioPlayerService.clearDiskCache();
      await _storageService.getAudioCacheManager().removeSongFromCache(song.id);
      
      final result = await _apiService.resyncSong(song.id);
      
      if (result['success'] == true) {
        final updatedSong = Song(
          id: song.id,
          title: song.title,
          artist: song.artist,
          imageUrl: song.imageUrl,
          externalUrls: song.externalUrls,
          errorMessage: null,
          hasError: false,
          isIgnored: song.isIgnored,
        );
        
        await _storageService.updateSong(updatedSong);
        
        setState(() {
          if (_songErrorMessages.containsKey(song.id)) {
            _songErrorMessages.remove(song.id);
          }
          
          final songIndex = _songs.indexWhere((s) => s.id == song.id);
          if (songIndex >= 0) {
            _songs[songIndex] = updatedSong;
          }
          
          _errorCount = _songErrorMessages.length;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully resynced "${song.title}"'),
            backgroundColor: Colors.green,
          ),
        );
        
        _audioPlayerService.clearDiskCache();
        _audioPlayerService.preCacheSong(updatedSong);
      } else {
        throw Exception(result['message'] ?? 'Unknown error');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to resync song: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  Future<void> _toggleIgnoreSong(Song song) async {
    try {
      final newIgnoreState = !song.isIgnored;
      
      final updatedSong = await _storageService.toggleSongIgnored(song.id, newIgnoreState);
      
      setState(() {
        final songIndex = _songs.indexWhere((s) => s.id == song.id);
        if (songIndex >= 0) {
          _songs[songIndex] = updatedSong;
        }
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newIgnoreState 
            ? 'Song "${song.title}" will be skipped during playback'
            : 'Song "${song.title}" will be included in playback'),
          backgroundColor: newIgnoreState ? Colors.orange : Colors.green,
        ),
      );
      
      // If the currently playing song is being ignored, skip to the next one
      if (newIgnoreState && _currentSong?.id == song.id && _isPlaying) {
        _audioPlayerService.playNextSong();
      }
      
      // Only update the audio player's playlist if there's a current playlist and we're playing music
      if (_playlist != null && _playlist!.songIds.isNotEmpty) {
        // Get all playable songs (not ignored, no errors)
        final playableSongs = _songs.where((s) => 
          _playlist!.songIds.contains(s.id) && 
          !s.isIgnored && 
          !_songHasError(s.id)
        ).toList();
        
        // Only update the playlist if we have playable songs
        if (playableSongs.isNotEmpty) {
          // Find current song index in playable songs if one is playing, otherwise use 0
          int currentIndex = 0;
          if (_currentSong != null) {
            final currentSongIndex = playableSongs.indexWhere((s) => s.id == _currentSong!.id);
            if (currentSongIndex >= 0) {
              currentIndex = currentSongIndex;
            }
          }
          
          _audioPlayerService.setPlaylist(
            playableSongs,
            startIndex: currentIndex,
            autoPlay: false,
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update song: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  void _showSongActionsMenu(Song song) {
    showModalBottomSheet(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundImage: song.imageUrl != null 
                ? NetworkImage(song.imageUrl!) 
                : null,
              child: song.imageUrl == null ? const Icon(Icons.music_note) : null,
            ),
            title: Text(song.title),
            subtitle: Text(song.artist),
          ),
          const Divider(),
          
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('Resync song'),
            subtitle: Text(song.hasError
              ? 'Attempt to fix error by redownloading'
              : 'Download this song again'),
            onTap: () {
              Navigator.pop(context);
              _resyncSong(song);
            },
          ),
          
          ListTile(
            leading: Icon(song.isIgnored ? Icons.check_circle : Icons.not_interested),
            title: Text(song.isIgnored ? 'Include in playback' : 'Ignore during playback'),
            subtitle: Text(song.isIgnored 
              ? 'Stop skipping this song' 
              : 'Skip this song when playing the playlist'),
            onTap: () {
              Navigator.pop(context);
              _toggleIgnoreSong(song);
            },
          ),
          
          if (song.hasError)
            ListTile(
              leading: const Icon(Icons.error_outline, color: Colors.red),
              title: const Text('View error details'),
              onTap: () {
                Navigator.pop(context);
                _showErrorDetails(song);
              },
            ),
            
          if (!song.hasError && !song.isIgnored)
            ListTile(
              leading: Icon(Icons.play_circle_filled, color: Theme.of(context).primaryColor),
              title: const Text('Play this song'),
              onTap: () {
                Navigator.pop(context);
                _playSong(song);
              },
            ),
            
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_playlist?.name ?? 'Playlist'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        leading: widget.onBack != null 
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              )
            : null,
        actions: [
          if (_isSyncing && _syncJob != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Text(
                  '${(_syncJob!.progress * 100).toInt()}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          
          IconButton(
            icon: _isSyncing 
                ? const SizedBox(
                    width: 20, 
                    height: 20, 
                    child: CircularProgressIndicator(strokeWidth: 2.0, color: Colors.white)
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync playlist',
            onPressed: _isSyncing ? null : _syncPlaylist,
          ),
          
          if (_errorCount > 0)
            IconButton(
              icon: Badge(
                label: Text(_errorCount.toString()),
                child: const Icon(Icons.error_outline),
              ),
              tooltip: 'Show song errors',
              onPressed: _showErrorSongsDialog,
            ),
            
          IconButton(
            icon: Icon(
              _audioPlayerService.optimizedModeEnabled
                ? Icons.speed
                : Icons.speed_outlined,
              color: Colors.white,
            ),
            onPressed: () {
              final newMode = !_audioPlayerService.optimizedModeEnabled;
              _audioPlayerService.setOptimizedMode(newMode);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(newMode
                      ? 'Optimized buffering enabled'
                      : 'Standard buffering mode'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
          
          // Display current playback mode with appropriate icon
          IconButton(
            icon: Icon(
              _playbackMode == PlaybackMode.shuffle 
                ? Icons.shuffle
                : _playbackMode == PlaybackMode.loop
                  ? Icons.repeat
                  : Icons.straight,
              color: Colors.white,
            ),
            tooltip: 'Playback mode: ${_playbackMode.toString().split('.').last}',
            onPressed: () {
              // Cycle through playback modes
              final nextMode = _playbackMode == PlaybackMode.linear 
                ? PlaybackMode.shuffle 
                : _playbackMode == PlaybackMode.shuffle
                  ? PlaybackMode.loop
                  : PlaybackMode.linear;
                  
              _audioPlayerService.togglePlaybackMode();
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Playback mode: ${nextMode.toString().split('.').last}'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_syncJob != null && (_syncJob!.isProcessing || _syncJob!.isQueued))
            LinearProgressIndicator(
              value: _syncJob!.progress > 0 ? _syncJob!.progress : null,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _songs.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.music_off,
                              size: 48,
                              color: Colors.grey,
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'No songs found',
                              style: TextStyle(fontSize: 18),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _loadPlaylist,
                              child: const Text('Refresh'),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        itemCount: _songs.length,
                        itemBuilder: (context, index) {
                          final song = _songs[index];
                          final hasError = _songHasError(song.id);
                          final isIgnored = song.isIgnored;
                          return ListTile(
                            leading: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: Colors.grey[300],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: song.imageUrl != null
                                      ? Image.network(song.imageUrl!,
                                          fit: BoxFit.cover,
                                          color: isIgnored ? Colors.grey : null,
                                          colorBlendMode: isIgnored ? BlendMode.saturation : null,
                                         )
                                      : Icon(Icons.music_note, color: isIgnored ? Colors.grey : null),
                                ),
                                if (hasError)
                                  Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    width: 16,
                                    height: 16,
                                    child: const Center(
                                      child: Icon(
                                        Icons.error,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                if (isIgnored && !hasError)
                                  Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.orange,
                                      shape: BoxShape.circle,
                                    ),
                                    width: 16,
                                    height: 16,
                                    child: const Center(
                                      child: Icon(
                                        Icons.not_interested,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(
                              song.title,
                              style: TextStyle(
                                color: isIgnored ? Colors.grey : (hasError ? Colors.grey : null),
                                decoration: hasError ? TextDecoration.lineThrough : null,
                                fontStyle: isIgnored ? FontStyle.italic : null,
                              ),
                            ),
                            subtitle: hasError 
                                ? Text(
                                    'Error: ${_getErrorMessage(song.id)}',
                                    style: const TextStyle(
                                      color: Colors.red,
                                      fontSize: 12,
                                    ),
                                  )
                                : isIgnored
                                    ? Text(
                                        'Ignored - ${song.artist}',
                                        style: const TextStyle(
                                          color: Colors.grey,
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      )
                                    : Text(song.artist),
                            onTap: () => _playSong(song),
                            onLongPress: () => _showSongActionsMenu(song),
                            trailing: hasError
                                ? IconButton(
                                    icon: const Icon(Icons.error, color: Colors.red),
                                    tooltip: _getErrorMessage(song.id) ?? 'Unknown error',
                                    onPressed: () => _showErrorDetails(song),
                                  )
                                : isIgnored
                                    ? IconButton(
                                        icon: const Icon(Icons.not_interested, color: Colors.orange),
                                        tooltip: 'This song will be skipped during playback',
                                        onPressed: () => _showSongActionsMenu(song),
                                      )
                                    : _currentSong?.id == song.id && _isPlaying
                                        ? const Icon(Icons.volume_up, color: Colors.green)
                                        : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}