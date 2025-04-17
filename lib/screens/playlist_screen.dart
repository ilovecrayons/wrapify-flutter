import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/sync_job.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_player_service.dart';
import '../widgets/now_playing_bar.dart';
import '../widgets/playback_controls.dart';

class PlaylistScreen extends StatefulWidget {
  final String playlistId;

  const PlaylistScreen({super.key, required this.playlistId});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  final ApiService _apiService = ApiService();
  final StorageService _storageService = StorageService();
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  
  List<Song> _songs = [];
  Playlist? _playlist;
  bool _isLoading = true;
  bool _isSyncing = false;
  Song? _currentSong;
  bool _isPlaying = false;
  double _bufferingProgress = 0.0;
  PlaybackMode _playbackMode = PlaybackMode.linear;
  SyncJob? _syncJob;
  int _errorCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
    _setupListeners();
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

    _audioPlayerService.bufferingProgressStream.listen((progress) {
      if (mounted) {
        setState(() {
          _bufferingProgress = progress;
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
      // Get playlist metadata from storage
      final playlists = await _storageService.loadPlaylists();
      final playlist = playlists.firstWhere(
          (p) => p.id == widget.playlistId,
          orElse: () => Playlist(
                id: widget.playlistId,
                name: 'Unknown Playlist',
                spotifyUrl: '',
              ));

      // Check if there's a sync job for this playlist
      if (playlist.syncJobId != null) {
        _syncJob = await _storageService.getLatestSyncJobForPlaylist(widget.playlistId);
        
        // If we have a sync job that's still processing, start polling for updates
        if (_syncJob != null && (_syncJob!.isProcessing || _syncJob!.isQueued)) {
          _startSyncStatusPolling(_syncJob!.id);
        }
      }

      // Try to fetch songs from the API
      final songs = await _apiService.fetchPlaylistSongs(widget.playlistId);

      // Pre-cache the first song for faster playback
      if (songs.isNotEmpty) {
        _audioPlayerService.preCacheSong(songs.first);
      }

      // Save newly fetched songs to storage
      await _storageService.addSongs(songs);

      // Check for song errors
      await _checkForSongErrors();

      // Update playlist with song IDs if needed
      if (playlist.songIds.isEmpty && songs.isNotEmpty) {
        final updatedPlaylist = Playlist(
          id: playlist.id,
          name: playlist.name,
          spotifyUrl: playlist.spotifyUrl,
          imageUrl: songs.isNotEmpty ? songs.first.imageUrl : null,
          songIds: songs.map((s) => s.id).toList(),
          syncJobId: playlist.syncJobId,
        );

        await _storageService.addPlaylist(updatedPlaylist);
        setState(() {
          _playlist = updatedPlaylist;
          _songs = songs;
          _isLoading = false;
        });
      } else {
        setState(() {
          _playlist = playlist;
          _songs = songs;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Error loading playlist: $e');

      // Try to load songs from cache if API fails
      final cachedSongs = await _storageService.loadSongs();
      final playlists = await _storageService.loadPlaylists();
      final playlist = playlists.firstWhere(
          (p) => p.id == widget.playlistId,
          orElse: () => Playlist(
                id: widget.playlistId,
                name: 'Unknown Playlist',
                spotifyUrl: '',
              ));

      // Filter songs that belong to this playlist
      final playlistSongs = <Song>[];
      for (final songId in playlist.songIds) {
        if (cachedSongs.containsKey(songId)) {
          playlistSongs.add(cachedSongs[songId]!);
        }
      }

      setState(() {
        _playlist = playlist;
        _songs = playlistSongs;
        _isLoading = false;
      });

      // Show error message
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

  // Check for song errors when opening the playlist
  Future<void> _checkForSongErrors() async {
    try {
      final errorsData = await _apiService.getPlaylistErrors(widget.playlistId);
      
      if (errorsData['errorCount'] > 0 && errorsData['songs'] is List && errorsData['songs'].isNotEmpty) {
        // Save the error information
        await _storageService.saveSongErrors(
          widget.playlistId, 
          List<Map<String, dynamic>>.from(errorsData['songs'])
        );
        
        // Update the songs list with error info
        final errorSongs = errorsData['songs'] as List;
        final errorSongIds = errorSongs.map((s) => s['id'].toString()).toSet();
        
        // Count errors
        setState(() {
          _errorCount = errorsData['errorCount'] ?? 0;
        });
        
        // Reload songs to get error information
        final cachedSongs = await _storageService.loadSongs();
        
        // Update the song list with error information
        setState(() {
          _songs = _songs.map((song) {
            if (errorSongIds.contains(song.id)) {
              return song.copyWithError(
                errorSongs.firstWhere((s) => s['id'] == song.id)['errorMessage'] ?? 'Unknown error'
              );
            }
            return song;
          }).toList();
        });
      }
    } catch (e) {
      print('Error checking for song errors: $e');
    }
  }
  
  // Poll for sync status updates
  void _startSyncStatusPolling(String jobId) async {
    bool isComplete = false;
    int attempts = 0;
    const maxAttempts = 30; // Poll for a maximum of 5 minutes (10 seconds * 30)
    
    while (!isComplete && attempts < maxAttempts && mounted) {
      try {
        await Future.delayed(Duration(seconds: 10));
        final syncJob = await _apiService.getSyncStatus(jobId);
        await _storageService.saveSyncJob(syncJob);
        
        print('Sync status: ${syncJob.status}, Progress: ${syncJob.progress}');
        
        if (mounted) {
          setState(() {
            _syncJob = syncJob;
            _isSyncing = syncJob.isProcessing || syncJob.isQueued;
          });
        }
        
        // If the job is complete or has an error, stop polling
        if (syncJob.isComplete || syncJob.isError) {
          isComplete = true;
          
          // Update the playlist with the final information
          if (syncJob.isComplete && mounted) {
            // Reload the playlist to get the updated data
            await _loadPlaylist();
            
            // Check for any song errors
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
        print('Error polling sync status: $e');
        attempts++;
        
        // If too many errors, just stop polling
        if (attempts > 5) {
          isComplete = true;
        }
      }
    }
    
    // Reset syncing state if we're done
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

      // Request sync from API - now returns job information
      final syncJob = await _apiService.syncPlaylist(_playlist!.spotifyUrl);
      
      // Save the sync job
      await _storageService.saveSyncJob(syncJob);
      
      // Update the playlist to include the sync job ID
      if (_playlist != null) {
        final updatedPlaylist = Playlist(
          id: _playlist!.id,
          name: syncJob.playlistName, // Use name from API
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
      
      // Start polling for status updates
      _startSyncStatusPolling(syncJob.id);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Syncing "${syncJob.playlistName}" in the background. Check back soon!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      print('Error syncing playlist: $e');
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

  void _playSong(Song song) async {
    // Don't try to play songs with errors
    if (song.hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot play song: ${song.errorMessage ?? "Unknown error"}'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    // Set the playlist if it hasn't been set yet
    _audioPlayerService.setPlaylist(_songs.where((s) => !s.hasError).toList(), 
      startIndex: _songs.indexWhere((s) => s.id == song.id),
      autoPlay: false);
      
    // Now play the selected song
    await _audioPlayerService.playSong(song);
  }

  @override
  void dispose() {
    // We don't dispose the audio player service here since
    // it should continue playing even when leaving this screen
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_playlist?.name ?? 'Playlist'),
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          // Show sync status if actively syncing
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
          
          // Add Sync button
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
          
          // Show error count button if there are errors
          if (_errorCount > 0)
            IconButton(
              icon: Badge(
                label: Text(_errorCount.toString()),
                child: const Icon(Icons.error_outline),
              ),
              tooltip: 'Show song errors',
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Song Errors'),
                    content: SizedBox(
                      width: double.maxFinite,
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _songs.where((s) => s.hasError).length,
                        itemBuilder: (context, index) {
                          final errorSong = _songs.where((s) => s.hasError).toList()[index];
                          return ListTile(
                            title: Text(errorSong.title),
                            subtitle: Text(errorSong.errorMessage ?? 'Unknown error'),
                            leading: const Icon(Icons.error, color: Colors.red),
                          );
                        },
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                );
              },
            ),
          
          // Add shuffle button
          IconButton(
            icon: Icon(
              _playbackMode == PlaybackMode.shuffle 
                ? Icons.shuffle 
                : Icons.sort,
              color: _playbackMode == PlaybackMode.shuffle 
                ? Colors.white 
                : Colors.white70,
            ),
            tooltip: _playbackMode == PlaybackMode.shuffle 
                ? 'Switch to linear playback' 
                : 'Switch to shuffle playback',
            onPressed: () {
              _audioPlayerService.togglePlaybackMode();
              
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _playbackMode == PlaybackMode.linear 
                      ? 'Switched to shuffle mode' 
                      : 'Switched to linear mode'
                  ),
                  duration: Duration(seconds: 1),
                ),
              );
            },
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
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Sync status indicator
          if (_syncJob != null && (_syncJob!.isProcessing || _syncJob!.isQueued))
            LinearProgressIndicator(
              value: _syncJob!.progress > 0 ? _syncJob!.progress : null,
              backgroundColor: Colors.grey[300],
              valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
            ),
            
          // Now playing bar
          if (_currentSong != null)
            NowPlayingBar(
              song: _currentSong!,
              isPlaying: _isPlaying,
              bufferingProgress: _bufferingProgress,
              onTap: () => _audioPlayerService.togglePlayback(),
            ),

          // Playback controls
          if (_currentSong != null)
            PlaybackControls(
              audioPlayerService: _audioPlayerService,
              isPlaying: _isPlaying,
              playbackMode: _playbackMode,
            ),

          // Song list
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
                          return ListTile(
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: song.imageUrl != null
                                  ? Image.network(song.imageUrl!,
                                      fit: BoxFit.cover)
                                  : const Icon(Icons.music_note),
                            ),
                            title: Text(
                              song.title,
                              style: TextStyle(
                                color: song.hasError ? Colors.grey : null,
                                decoration: song.hasError ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            subtitle: Text(song.artist),
                            onTap: () => _playSong(song),
                            trailing: song.hasError
                                ? Tooltip(
                                    message: song.errorMessage ?? 'Unknown error',
                                    child: const Icon(Icons.error_outline, color: Colors.red),
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