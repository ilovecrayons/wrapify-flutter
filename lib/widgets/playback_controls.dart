import 'package:flutter/material.dart';
import '../services/audio_player_service.dart';

class PlaybackControls extends StatelessWidget {
  final AudioPlayerService audioPlayerService;
  final bool isPlaying;
  final PlaybackMode playbackMode;

  const PlaybackControls({
    super.key,
    required this.audioPlayerService,
    required this.isPlaying,
    required this.playbackMode,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
      color: Colors.grey[100],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Previous button
          IconButton(
            icon: const Icon(Icons.skip_previous),
            iconSize: 36,
            onPressed: audioPlayerService.playPreviousSong,
          ),
          
          // Play/Pause button
          IconButton(
            icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled),
            iconSize: 48,
            onPressed: audioPlayerService.togglePlayback,
          ),
          
          // Next button
          IconButton(
            icon: const Icon(Icons.skip_next),
            iconSize: 36,
            onPressed: audioPlayerService.playNextSong,
          ),
          
          // Mode indicator
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Icon(
              playbackMode == PlaybackMode.shuffle ? Icons.shuffle : Icons.repeat,
              color: playbackMode == PlaybackMode.shuffle ? Colors.green : Colors.grey,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}