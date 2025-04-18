import 'package:flutter/material.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';
import 'screens/playlist_screen.dart';
import 'widgets/global_playback_bar.dart';

void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Run the app within AudioService for background playback capabilities
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The exact Spotify green color (RGB: 30, 215, 96)
    final spotifyGreen = const Color.fromRGBO(30, 215, 96, 1);
    
    return MaterialApp(
      title: 'Wrapify Music Player',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme(
          brightness: Brightness.light,
          primary: spotifyGreen, // This will be used for the app bar
          onPrimary: Colors.black, // Text/icons on primary color
          secondary: spotifyGreen,
          onSecondary: Colors.white,
          error: Colors.red,
          onError: Colors.white,
          background: Colors.white,
          onBackground: Colors.black,
          surface: Colors.white,
          onSurface: Colors.black,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: spotifyGreen, // Explicitly set app bar background
          foregroundColor: Colors.white, // App bar text/icons color
        ),
      ),
      home: const AudioServiceWidget(child: AppWithPlaybackBar()),
    );
  }
}

class AppWithPlaybackBar extends StatefulWidget {
  const AppWithPlaybackBar({super.key});

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
      title: 'fuck spotify!!1!!11!1!',
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
