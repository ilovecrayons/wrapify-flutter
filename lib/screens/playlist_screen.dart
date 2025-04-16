import 'package:flutter/material.dart';
import '../models/song.dart';
import '../models/playlist.dart';
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

      // Try to fetch songs from the API
      final songs = await _apiService.fetchPlaylistSongs(widget.playlistId);

      // Pre-cache the first song for faster playback
      if (songs.isNotEmpty) {
        _audioPlayerService.preCacheSong(songs.first);
      }

      // Save newly fetched songs to storage
      await _storageService.addSongs(songs);

      // Update playlist with song IDs if needed
      if (playlist.songIds.isEmpty && songs.isNotEmpty) {
        final updatedPlaylist = Playlist(
          id: playlist.id,
          name: playlist.name == 'Unknown Playlist' || playlist.name.contains('syncing')
              ? '${songs.length} Songs Playlist'
              : playlist.name,
          spotifyUrl: playlist.spotifyUrl,
          imageUrl: songs.isNotEmpty ? songs.first.imageUrl : null,
          songIds: songs.map((s) => s.id).toList(),
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
          content: Text('Syncing playlist... This may take a while.'),
          duration: Duration(seconds: 3),
        ),
      );

      // Request sync from API
      await _apiService.syncPlaylist(_playlist!.spotifyUrl);
      
      // Wait a moment to allow the server to start processing
      await Future.delayed(const Duration(seconds: 2));
      
      // Reload the playlist
      await _loadPlaylist();
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Playlist sync started! New songs will appear as they are processed.'),
          backgroundColor: Colors.green,
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
    } finally {
      setState(() {
        _isSyncing = false;
      });
    }
  }

  void _playSong(Song song) async {
    // Set the playlist if it hasn't been set yet
    _audioPlayerService.setPlaylist(_songs, 
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
          // Add Sync button
          IconButton(
            icon: _isSyncing 
                ? const SizedBox(
                    width: 20, 
                    height: 20, 
                    child: CircularProgressIndicator(strokeWidth: 2.0, color: Colors.black)
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync playlist',
            onPressed: _isSyncing ? null : _syncPlaylist,
          ),
          // Add shuffle button
          IconButton(
            icon: Icon(
              _playbackMode == PlaybackMode.shuffle 
                ? Icons.shuffle 
                : Icons.sort,
              color: _playbackMode == PlaybackMode.shuffle 
                ? Colors.black 
                : Colors.black54,
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
                            title: Text(song.title),
                            subtitle: Text(song.artist),
                            onTap: () => _playSong(song),
                            trailing: _currentSong?.id == song.id && _isPlaying
                                ? const Icon(Icons.volume_up,
                                    color: Colors.purple)
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