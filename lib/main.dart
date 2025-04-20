import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart' as audio_service;
import 'screens/home_screen.dart';
import 'screens/playlist_screen.dart';
import 'widgets/global_playback_bar.dart';
import 'services/audio_player_service.dart';
import 'utils/logger.dart';

// Create a logger for this file
final _logger = Logger('Main');

// This class implements the AudioHandler interface for audio_service
// It handles communication between the audio_service background process and your app
class WrapifyAudioHandler extends audio_service.BaseAudioHandler with audio_service.QueueHandler, audio_service.SeekHandler {
  final AudioPlayerService _playerService;
  
  WrapifyAudioHandler(this._playerService) {
    // Listen to playback events from our custom player service
    _playerService.currentSongStream.listen((song) {
      if (song != null) {
        // Update notification/lockscreen with current song info
        mediaItem.add(audio_service.MediaItem(
          id: song.id,
          title: song.title,
          artist: song.artist,
          artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
          playable: true, // Add this property for iOS
          duration: _playerService.audioPlayer.duration, // Add duration for iOS progress
          // Add album for iOS display
          album: 'Wrapify Playlist',
        ));
      }
    });
    
    // Set up initial player state for iOS
    playbackState.add(audio_service.PlaybackState(
      controls: [
        audio_service.MediaControl.skipToPrevious,
        audio_service.MediaControl.play,
        audio_service.MediaControl.skipToNext,
      ],
      systemActions: const {
        audio_service.MediaAction.seek,
        audio_service.MediaAction.skipToPrevious,
        audio_service.MediaAction.skipToNext,
        audio_service.MediaAction.play,
        audio_service.MediaAction.pause,
      },
      processingState: audio_service.AudioProcessingState.ready,
      playing: false,
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
    ));

    _playerService.playbackStateStream.listen((state) {
      // Update playback state for notification/lockscreen
      playbackState.add(audio_service.PlaybackState(
        controls: [
          audio_service.MediaControl.skipToPrevious,
          state.isPlaying ? audio_service.MediaControl.pause : audio_service.MediaControl.play,
          audio_service.MediaControl.skipToNext,
        ],
        systemActions: const {
          audio_service.MediaAction.seek,
          audio_service.MediaAction.skipToPrevious,
          audio_service.MediaAction.skipToNext,
          audio_service.MediaAction.play,
          audio_service.MediaAction.pause,
        },
        processingState: state.isBuffering || state.isLoading 
            ? audio_service.AudioProcessingState.buffering
            : audio_service.AudioProcessingState.ready,
        playing: state.isPlaying,
        updatePosition: state.position,
        // Set a reasonable buffer position to mimic streaming
        bufferedPosition: state.position + const Duration(seconds: 10),
      ));
    });
    
    // Listen to duration changes for iOS progress display
    _playerService.audioPlayer.durationStream.listen((duration) {
      if (duration != null && _playerService.currentSong != null) {
        mediaItem.add(audio_service.MediaItem(
          id: _playerService.currentSong!.id,
          title: _playerService.currentSong!.title,
          artist: _playerService.currentSong!.artist,
          artUri: _playerService.currentSong!.imageUrl != null ? 
              Uri.parse(_playerService.currentSong!.imageUrl!) : null,
          duration: duration,
          album: 'Wrapify Playlist',
          playable: true,
        ));
      }
    });
  }
  
  // Implement play control
  @override
  Future<void> play() async {
    _logger.debug("AudioHandler: play() called");
    await _playerService.resumePlayback();
  }
  
  // Implement pause control
  @override
  Future<void> pause() async {
    _logger.debug("AudioHandler: pause() called");
    await _playerService.pausePlayback();
  }
  
  // Implement skip to next control
  @override
  Future<void> skipToNext() async {
    _logger.debug("AudioHandler: skipToNext() called");
    await _playerService.playNextSong();
  }
  
  // Implement skip to previous control
  @override
  Future<void> skipToPrevious() async {
    _logger.debug("AudioHandler: skipToPrevious() called");
    await _playerService.playPreviousSong();
  }
  
  // Implement stop control
  @override
  Future<void> stop() async {
    _logger.debug("AudioHandler: stop() called");
    await _playerService.stopPlayback();
    await super.stop();
  }
}

void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();
  
  // Create our AudioPlayerService first
  final playerService = AudioPlayerService();
  
  // Initialize audio_service with our custom handler
  await audio_service.AudioService.init(
    builder: () => WrapifyAudioHandler(playerService),
    config: const audio_service.AudioServiceConfig(
      androidNotificationChannelId: 'com.yourcompany.wrapifyflutter.audio',
      androidNotificationChannelName: 'Wrapify Audio Playback',
      // Keep foreground service active even when paused for better background reliability
      androidStopForegroundOnPause: false,
      // Add iOS notification settings
      notificationColor: Color.fromRGBO(30, 215, 96, 1),
      artDownscaleWidth: 300,
      artDownscaleHeight: 300,
      // Enable fast forwarding through notification on iOS
      fastForwardInterval: Duration(seconds: 30),
      rewindInterval: Duration(seconds: 30),
    ),
  );

  // Run the app
  runApp(MyApp(playerService: playerService));
}

class MyApp extends StatelessWidget {
  final AudioPlayerService playerService;
  
  const MyApp({super.key, required this.playerService});

  @override
  Widget build(BuildContext context) {
    // The exact Spotify green color (RGB: 30, 215, 96)
    const spotifyGreen = Color.fromRGBO(30, 215, 95, 0.878);
    
    return MaterialApp(
      title: 'Home',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme(
          brightness: Brightness.light,
          primary: Color.fromRGBO(30, 215, 96, 1), // This will be used for the app bar
          onPrimary: Colors.white, // Text/icons on primary color (fixed to white for better contrast)
          secondary: Color.fromRGBO(30, 215, 96, 1),
          onSecondary: Colors.white,
          error: Colors.red,
          onError: Colors.white,
          background: Colors.white,
          onBackground: Colors.black,
          surface: Colors.white,
          onSurface: Colors.black,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: spotifyGreen, // Explicitly set app bar background
          foregroundColor: Colors.white, // App bar text/icons color
        ),
      ),
      home: audio_service.AudioServiceWidget(child: AppWithPlaybackBar(playerService: playerService)),
    );
  }
}

class AppWithPlaybackBar extends StatefulWidget {
  final AudioPlayerService playerService;
  
  const AppWithPlaybackBar({super.key, required this.playerService});

  @override
  State<AppWithPlaybackBar> createState() => _AppWithPlaybackBarState();
}

class _AppWithPlaybackBarState extends State<AppWithPlaybackBar> {
  late Widget _currentScreen;
  
  @override
  void initState() {
    super.initState();
    // Initialize with the HomeScreen and provide the navigation callback
    _currentScreen = HomeScreen(
      title: 'Home',
      onPlaylistSelected: (playlistId) => navigateToPlaylist(playlistId),
    );
  }
  
  // Method to navigate to the playlist screen
  void navigateToPlaylist(String playlistId) {
    setState(() {
      _currentScreen = PlaylistScreen(
        playlistId: playlistId,
        onBack: () => navigateToHome(),
      );
    });
  }
  
  // Method to navigate back to home
  void navigateToHome() {
    setState(() {
      _currentScreen = HomeScreen(
        title: 'Home',
        onPlaylistSelected: (playlistId) => navigateToPlaylist(playlistId),
      );
    });
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Main content area (takes up all available space)
          Expanded(
            child: _currentScreen,
          ),
          // Global playback bar (only takes the space it needs)
          const GlobalPlaybackBar(),
        ],
      ),
    );
  }
}
