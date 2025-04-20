import 'package:flutter/material.dart';
import '../models/song.dart';

class NowPlayingBar extends StatelessWidget {
  final Song song;
  final bool isPlaying;
  final double bufferingProgress;
  final VoidCallback onTap;

  const NowPlayingBar({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.bufferingProgress,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      color: Colors.grey[200],
      child: Row(
        children: [
          // Song image or placeholder
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: Colors.grey[400],
              borderRadius: BorderRadius.circular(4),
            ),
            child: song.imageUrl != null
                ? Image.network(song.imageUrl!, fit: BoxFit.cover)
                : const Icon(Icons.music_note, size: 30),
          ),
          const SizedBox(width: 16),
          // Song info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(song.artist),
                const SizedBox(height: 8),
                // Buffer indicator
                LinearProgressIndicator(
                  value: bufferingProgress,
                  backgroundColor: Colors.grey[300],
                ),
                Text(
                  'Buffered: ${(bufferingProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(fontSize: 10),
                ),
              ],
            ),
          ),
          // Play/pause button
          IconButton(
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow),
            iconSize: 32,
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}