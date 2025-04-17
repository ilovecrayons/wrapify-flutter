import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist.dart';
import '../models/sync_job.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/audio_player_service.dart';

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
    
    print('PlaylistScreen initialized for playlist ID: ${widget.playlistId}');
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

      await _checkForSongErrors();

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
        _songs = playlistSongs;
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

      print('【ERROR DEBUG】Raw error data from API: $errorsData');

      _songErrorMessages.clear();

      if (errorsData['errorCount'] > 0 && errorsData['songs'] is List && errorsData['songs'].isNotEmpty) {
        final List<dynamic> errorSongs = errorsData['songs'] as List;
        final errorSongsList = List<Map<String, dynamic>>.from(errorSongs);

        for (final errorSong in errorSongsList) {
          final songId = errorSong['id'].toString();
          final errorMessage = errorSong['errorMessage'] ?? 'Unknown error';
          _songErrorMessages[songId] = errorMessage;
        }

        print('【ERROR DEBUG】Found ${errorSongsList.length} songs with errors: $_songErrorMessages');

        await _storageService.saveSongErrors(widget.playlistId, errorSongsList);

        setState(() {
          _errorCount = _songErrorMessages.length;
        });
      } else {
        print('【ERROR DEBUG】No errors found in the playlist.');
        setState(() {
          _errorCount = 0;
        });
      }
    } catch (e) {
      print('Error checking for song errors: $e');
    }
  }

  bool _songHasError(String songId) {
    return _songErrorMessages.containsKey(songId);
  }

  String? _getErrorMessage(String songId) {
    return _songErrorMessages[songId];
  }

  void _showErrorSongsDialog() {
    print('Opening error dialog with direct access to error songs');
    
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

      print('【ERROR DEBUG】Error songs found for dialog: ${displayErrorSongs.length}');
      for (var song in displayErrorSongs) {
        print('【ERROR DEBUG】Error song in dialog: ${song.title} - ${song.id} - ${song.errorMessage}');
      }

      if (displayErrorSongs.isEmpty) {
        print('No error songs found, displaying a message');
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
          insetPadding: EdgeInsets.all(16.0),
          child: Container(
            width: double.maxFinite,
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8, // 80% of screen height
              maxWidth: 600,
            ),
            padding: EdgeInsets.all(16.0),
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
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close),
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
                    radius: Radius.circular(10.0),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: displayErrorSongs.length,
                      separatorBuilder: (context, index) => Divider(height: 1),
                      itemBuilder: (context, index) {
                        final song = displayErrorSongs[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.error, color: Colors.red, size: 20),
                                  SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      song.title,
                                      style: TextStyle(fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                              Padding(
                                padding: EdgeInsets.only(left: 28.0, top: 4.0),
                                child: Text(
                                  song.errorMessage ?? 'Unknown error',
                                  style: TextStyle(color: Colors.red),
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
        
        print('【ERROR DEBUG】Refreshed error info: ${_songErrorMessages.length} errors');
        
        setState(() {
          _errorCount = _songErrorMessages.length;
        });
      } else {
        setState(() {
          _errorCount = 0;
        });
      }
    } catch (e) {
      print('Error refreshing error information: $e');
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
        SnackBar(
          content: Text('This song is set to be ignored during playback'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    
    _audioPlayerService.setPlaylist(_songs.where((s) => !_songHasError(s.id) && !s.isIgnored).toList(), 
      startIndex: _songs.indexWhere((s) => s.id == song.id),
      autoPlay: false);
      
    await _audioPlayerService.playSong(song);
  }

  void _startSyncStatusPolling(String jobId) async {
    bool isComplete = false;
    int attempts = 0;
    const maxAttempts = 30;
    
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
        print('Error polling sync status: $e');
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

  Future<void> _resyncSong(Song song) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Resyncing "${song.title}"...'),
          duration: Duration(seconds: 1),
        ),
      );
      
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
        
        _audioPlayerService.clearCache(songId: song.id);
        _audioPlayerService.preCacheSong(updatedSong);
      } else {
        throw Exception(result['message'] ?? 'Unknown error');
      }
    } catch (e) {
      print('Error resyncing song: $e');
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
      
      if (newIgnoreState && _currentSong?.id == song.id && _isPlaying) {
        _audioPlayerService.playNextSong();
      }
      
      if (_playlist != null && _playlist!.songIds.contains(song.id)) {
        _audioPlayerService.setPlaylist(
          _songs.where((s) => _playlist!.songIds.contains(s.id)).toList(),
          startIndex: _songs.indexWhere((s) => s.id == _currentSong?.id),
          autoPlay: false,
        );
      }
    } catch (e) {
      print('Error toggling song ignored state: $e');
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
              child: song.imageUrl == null ? Icon(Icons.music_note) : null,
            ),
            title: Text(song.title),
            subtitle: Text(song.artist),
          ),
          Divider(),
          
          ListTile(
            leading: Icon(Icons.refresh),
            title: Text('Resync song'),
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
              leading: Icon(Icons.error_outline, color: Colors.red),
              title: Text('View error details'),
              onTap: () {
                Navigator.pop(context);
                _showErrorDetails(song);
              },
            ),
            
          if (!song.hasError && !song.isIgnored)
            ListTile(
              leading: Icon(Icons.play_circle_filled, color: Theme.of(context).primaryColor),
              title: Text('Play this song'),
              onTap: () {
                Navigator.pop(context);
                _playSong(song);
              },
            ),
            
          SizedBox(height: 8),
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
                  duration: Duration(seconds: 1),
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
                                          fit: BoxFit.cover)
                                      : const Icon(Icons.music_note),
                                ),
                                if (hasError)
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.red,
                                      shape: BoxShape.circle,
                                    ),
                                    width: 16,
                                    height: 16,
                                    child: Center(
                                      child: Icon(
                                        Icons.error,
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
                                color: hasError ? Colors.grey : null,
                                decoration: hasError ? TextDecoration.lineThrough : null,
                              ),
                            ),
                            subtitle: hasError 
                                ? Text(
                                    'Error: ${_getErrorMessage(song.id)}',
                                    style: TextStyle(
                                      color: Colors.red,
                                      fontSize: 12,
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