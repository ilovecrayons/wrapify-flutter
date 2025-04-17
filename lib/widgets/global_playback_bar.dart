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
  }

  @override
  Widget build(BuildContext context) {
    // Don't show anything if no song is currently playing/loaded
    if (_currentSong == null) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Now playing bar
        GestureDetector(
          onTap: _audioPlayerService.togglePlayback,
          child: Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey[200],
            child: Row(
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
                      const SizedBox(height: 4),
                      // Buffer indicator
                      LinearProgressIndicator(
                        value: _bufferingProgress,
                        backgroundColor: Colors.grey[300],
                        minHeight: 2,
                      ),
                    ],
                  ),
                ),
                // Play/pause button
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  iconSize: 32,
                  onPressed: _audioPlayerService.togglePlayback,
                ),
              ],
            ),
          ),
        ),
        
        // Playback controls
        Container(
          padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 16.0),
          color: Colors.grey[100],
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Previous button
              IconButton(
                icon: const Icon(Icons.skip_previous),
                iconSize: 28,
                onPressed: _audioPlayerService.playPreviousSong,
              ),
              
              // Play/Pause button
              IconButton(
                icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
                iconSize: 36,
                onPressed: _audioPlayerService.togglePlayback,
              ),
              
              // Next button
              IconButton(
                icon: const Icon(Icons.skip_next),
                iconSize: 28,
                onPressed: _audioPlayerService.playNextSong,
              ),
              
              // Mode indicator
              IconButton(
                icon: Icon(
                  _playbackMode == PlaybackMode.shuffle ? Icons.shuffle : Icons.repeat,
                  color: _playbackMode == PlaybackMode.shuffle ? Colors.green : Colors.grey,
                ),
                onPressed: _audioPlayerService.togglePlaybackMode,
              ),
            ],
          ),
        ),
      ],
    );
  }
}