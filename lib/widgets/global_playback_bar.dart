import 'package:flutter/material.dart';
import '../models/song.dart';
import '../services/audio_player_service.dart';

class GlobalPlaybackBar extends StatefulWidget {
  const GlobalPlaybackBar({super.key});

  @override
  State<GlobalPlaybackBar> createState() => _GlobalPlaybackBarState();
}

class _GlobalPlaybackBarState extends State<GlobalPlaybackBar> {
  final AudioPlayerService _audioPlayerService = AudioPlayerService();
  Song? _currentSong;
  bool _isPlaying = false;
  double _bufferingProgress = 0.0;
  PlaybackMode _playbackMode = PlaybackMode.linear;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
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

    // Listen for position updates
    _audioPlayerService.audioPlayer.positionStream.listen((position) {
      if (mounted) {
        setState(() {
          _currentPosition = position;
        });
      }
    });

    // Listen for duration updates
    _audioPlayerService.audioPlayer.durationStream.listen((duration) {
      if (mounted && duration != null) {
        setState(() {
          _totalDuration = duration;
        });
      }
    });
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String minutes = twoDigits(duration.inMinutes.remainder(60));
    String seconds = twoDigits(duration.inSeconds.remainder(60));
    return "$minutes:$seconds";
  }

  // Helper to get the appropriate icon for the current playback mode
  Widget _getPlaybackModeIcon() {
    switch (_playbackMode) {
      case PlaybackMode.linear:
        return Icon(
          Icons.format_list_numbered, // Changed to list icon for linear mode
          color: Colors.grey[600],
        );
      case PlaybackMode.shuffle:
        return const Icon(
          Icons.shuffle,
          color: Colors.green,
        );
      case PlaybackMode.loop:
        return const Icon(
          Icons.repeat_one,
          color: Colors.blue,
        );
    }
  }

  // Helper to get tooltip text for the current playback mode
  String _getPlaybackModeTooltip() {
    switch (_playbackMode) {
      case PlaybackMode.linear:
        return 'Linear mode (tap to change)';
      case PlaybackMode.shuffle:
        return 'Shuffle mode (tap to change)';
      case PlaybackMode.loop:
        return 'Loop current song (tap to change)';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Don't show anything if no song is currently playing/loaded
    if (_currentSong == null) {
      return const SizedBox.shrink();
    }

    final double progressValue = _totalDuration.inMilliseconds > 0 
        ? _currentPosition.inMilliseconds / _totalDuration.inMilliseconds 
        : 0.0;

    // Determine if skip buttons should be disabled (when in loop mode)
    final bool isLoopMode = _playbackMode == PlaybackMode.loop;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0), // Add bottom padding to move up from screen edge
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Skip controls above the playback bar
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8.0), // Increased vertical padding
            color: Colors.grey[100],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Previous button - disabled in loop mode
                IconButton(
                  icon: Icon(
                    Icons.skip_previous,
                    color: isLoopMode ? Colors.grey[400] : null,
                  ),
                  iconSize: 28, // Slightly larger icons
                  onPressed: isLoopMode ? null : _audioPlayerService.playPreviousSong,
                  tooltip: isLoopMode ? 'Skip disabled in loop mode' : 'Previous song',
                ),
                
                // Play/pause button moved here between prev and next
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                  iconSize: 42, // Larger size for the play/pause button
                  onPressed: _audioPlayerService.togglePlayback,
                  tooltip: _isPlaying ? 'Pause' : 'Play',
                ),
                
                // Next button - disabled in loop mode
                IconButton(
                  icon: Icon(
                    Icons.skip_next,
                    color: isLoopMode ? Colors.grey[400] : null,
                  ),
                  iconSize: 28, // Slightly larger icons
                  onPressed: isLoopMode ? null : _audioPlayerService.playNextSong,
                  tooltip: isLoopMode ? 'Skip disabled in loop mode' : 'Next song',
                ),
              ],
            ),
          ),
          
          // Now playing bar with progress - play/pause button removed from here
          GestureDetector(
            onTap: _audioPlayerService.togglePlayback,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.grey[200],
              child: Column(
                children: [
                  Row(
                    children: [
                      // Song image or placeholder
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: _currentSong!.imageUrl != null
                            ? Image.network(_currentSong!.imageUrl!, fit: BoxFit.cover)
                            : const Icon(Icons.music_note, size: 24),
                      ),
                      const SizedBox(width: 12),
                      // Song info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentSong!.title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                overflow: TextOverflow.ellipsis,
                              ),
                              maxLines: 1,
                            ),
                            Text(
                              _currentSong!.artist,
                              style: const TextStyle(
                                fontSize: 12,
                                overflow: TextOverflow.ellipsis,
                              ),
                              maxLines: 1,
                            ),
                          ],
                        ),
                      ),
                      // Playback mode toggle icon - moved to right side
                      IconButton(
                        icon: _getPlaybackModeIcon(),
                        onPressed: _audioPlayerService.togglePlaybackMode,
                        tooltip: _getPlaybackModeTooltip(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Progress indicator row
                  Row(
                    children: [
                      Text(
                        _formatDuration(_currentPosition),
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          children: [
                            // Playback progress
                            LinearProgressIndicator(
                              value: progressValue,
                              backgroundColor: Colors.grey[300],
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.primary,
                              ),
                              minHeight: 3,
                            ),
                            const SizedBox(height: 2),
                            // Buffer indicator
                            LinearProgressIndicator(
                              value: _bufferingProgress,
                              backgroundColor: Colors.transparent,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.grey[400]!,
                              ),
                              minHeight: 2,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatDuration(_totalDuration),
                        style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}