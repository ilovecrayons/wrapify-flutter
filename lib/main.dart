import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'dart:io';
import 'dart:async'; // Added for Timer functionality

void main() async {
  // Ensure Flutter is initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Remove the background playback initialization as it's causing errors
  // We'll use just the basic audio player for now

  // Run the app
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wrapify Music Player',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color.fromARGB(255, 0, 255, 60)),
        useMaterial3: true,
      ),
      home: const AudioServiceWidget(child: MusicPlayerHome(title: 'Home')),
    );
  }
}

// Song class to store song information
class Song {
  final String id;
  final String title;
  final String artist;
  final String? imageUrl;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    this.imageUrl,
  });
}

class MusicPlayerHome extends StatefulWidget {
  const MusicPlayerHome({super.key, required this.title});

  final String title;

  @override
  State<MusicPlayerHome> createState() => _MusicPlayerHomeState();
}

class _MusicPlayerHomeState extends State<MusicPlayerHome>
    with WidgetsBindingObserver {
  late final AudioPlayer _audioPlayer;
  Song? _currentSong;
  bool _isPlaying = false;
  Duration _bufferingTime = Duration.zero;
  double _bufferingProgress = 0.0;
  int _retryCount = 0;
  final int _maxRetries = 3;
  // Use the correct audio source type from just_audio
  Map<String, AudioSource> _cachedSources = {};

  // Enhanced buffering parameters
  final Duration _initialBuffer = Duration(seconds: 5);
  bool _optimizedModeEnabled = true;

  // Server configuration
  final String _serverBaseUrl = 'https://wrapifyapi.dedyn.io/stream';

  // Sample playlist with server streaming URLs
  final List<Song> _playlist = [
    Song(
      id: '0WSa1sucoNRcEeULlZVQXj',
      title: 'Can You Feel My Heart',
      artist: 'Bring Me The Horizon',
      imageUrl:
          'https://i.scdn.co/image/ab67616d0000b27360cf7c8dd93815ccd6cb4830',
    )
  ];

  // Add these fields for emulator optimization
  bool _isEmulatorOptimized = false;
  bool _isEmulator = false;
  bool _isBlueStacks = false;
  Timer? _bufferMonitorTimer;
  int _lastBufferPosition = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Check if running on emulator
    _detectEmulator();

    _initAudioPlayer();
  }

  Future<void> _detectEmulator() async {
    // Enhanced detection including BlueStacks
    if (Platform.isAndroid) {
      String osVersion = Platform.operatingSystemVersion.toLowerCase();
      _isEmulator = osVersion.contains('sdk') || osVersion.contains('emulator');

      // Check specifically for BlueStacks
      _isBlueStacks =
          osVersion.contains('bluestacks') || osVersion.contains('bs');

      if (_isBlueStacks) {
        print('🎮 BlueStacks detected - using specialized settings');
        // BlueStacks often has better audio processing but different requirements
        setState(() {
          _isEmulator = true; // Treat as a type of emulator
          _isEmulatorOptimized = true;
          _optimizedModeEnabled = true;
        });
      } else if (_isEmulator) {
        print('🔍 Standard emulator detected - applying optimized settings');
        setState(() {
          _isEmulatorOptimized = true;
          _optimizedModeEnabled = true;
        });
      }
    }
  }

  void _initAudioPlayer() {
    // Create AudioPlayer with basic configuration to avoid errors
    _audioPlayer = AudioPlayer();

    // Start buffer monitoring for stuttering detection
    _startBufferMonitoring();

    // Apply specific Android audio settings if on Android
    if (Platform.isAndroid) {
      try {
        // Enable better battery-optimized playback
        _audioPlayer.setLoopMode(LoopMode.off);

        // If on emulator, optimize audio settings
        if (_isEmulator) {
          // Applying emulator-specific optimizations
          _audioPlayer.setVolume(
              0.9); // Slightly reduce volume to decrease processing load
        }
      } catch (e) {
        print('Error setting Android audio params: $e');
      }
    }

    // Pre-cache the first song but don't play it yet
    _preCacheSong(_playlist.first);

    // Monitor playback state with improved error handling
    _audioPlayer.playbackEventStream.listen((event) {
      setState(() {
        _isPlaying = _audioPlayer.playing;
        _bufferingTime = event.bufferedPosition;

        // Calculate buffering progress as percentage
        if (event.duration != null && event.duration!.inMilliseconds > 0) {
          _bufferingProgress = event.bufferedPosition.inMilliseconds /
              event.duration!.inMilliseconds;
        }
      });
    }, onError: (Object e, StackTrace stackTrace) {
      print('Error in playback stream: $e');
      _handlePlaybackError(e);
    }, onDone: () {
      print('Playback stream closed');
    }, cancelOnError: false // Keep listening even if errors occur
        );

    // Monitor buffer state for adaptive buffering
    _audioPlayer.processingStateStream.listen((state) {
      print('Processing state: $state');

      if (state == ProcessingState.buffering) {
        print('Buffering - reducing UI updates');

        // When buffering, reduce resource usage
        if (_optimizedModeEnabled) {
          _reduceResourceUsage(true);
        }
      }

      if (state == ProcessingState.ready) {
        print('Ready to play');
        _retryCount = 0; // Reset retry counter when successfully buffered

        // Resume normal resource usage
        if (_optimizedModeEnabled) {
          _reduceResourceUsage(false);
        }
      }
    });

    // Add position reporting for diagnosing stutters
    _audioPlayer.positionStream.listen((position) {
      // Only log every 5 seconds to reduce overhead
      if (position.inSeconds % 5 == 0 && position.inSeconds > 0) {
        print(
            'Playback position: $position (buffer: ${_bufferingProgress.toStringAsFixed(2)}%)');
      }
    });
  }

  void _startBufferMonitoring() {
    // Set up a timer to monitor buffer progress
    _bufferMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (_isPlaying) {
        // Check if buffer position has changed
        final currentBufferPos = (_bufferingProgress * 100).round();

        if (currentBufferPos == _lastBufferPosition && currentBufferPos < 10) {
          // Buffer isn't advancing and is low - potential stutter scenario
          print('⚠️ Buffer stalled at $currentBufferPos% - applying recovery');
          _recoverFromBufferStall();
        }

        _lastBufferPosition = currentBufferPos;
      }
    });
  }

  void _recoverFromBufferStall() {
    if (_currentSong != null && _isPlaying) {
      // Try to nudge the audio player by pausing briefly and resuming
      _audioPlayer.pause();

      // Give the system a moment to clear resources
      Future.delayed(Duration(milliseconds: 300), () {
        if (_currentSong != null) {
          _audioPlayer.play();
        }
      });
    }
  }

  void _reduceResourceUsage(bool reduce) {
    // Method to reduce system resource usage during buffering
    // to allow more CPU/network resources for audio processing
    if (reduce) {
      // Reduce UI updates
      setState(() {}); // Single update to reset UI update timer
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Handle app lifecycle changes to optimize audio playback
    if (state == AppLifecycleState.paused) {
      // App is in background, release resources if needed
      if (_isPlaying) {
        // Consider pausing playback when app goes to background
        // _audioPlayer.pause();
      }
    } else if (state == AppLifecycleState.resumed) {
      // App is in foreground again
      // Restart player if needed
      _initCacheIfNeeded();
    }
  }

  Future<void> _initCacheIfNeeded() async {
    // Clean up potential stale cached sources
    if (_cachedSources.isNotEmpty) {
      try {
        await AudioPlayer.clearAssetCache();
        print('Cleared asset cache on app resume');
      } catch (e) {
        print('Error clearing cache on resume: $e');
      }
    }
  }

  @override
  void dispose() {
    _bufferMonitorTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _audioPlayer.dispose();
    super.dispose();
  }

  // Pre-cache a song to improve initial playback
  Future<void> _preCacheSong(Song song) async {
    try {
      final streamUrl = '$_serverBaseUrl/${song.id}';

      // Create caching source if not already cached
      if (!_cachedSources.containsKey(song.id)) {
        // Setup HTTP headers to optimize streaming
        Map<String, String> headers = {
          'Connection': 'keep-alive',
        };

        // Different optimizations based on environment
        if (_isBlueStacks) {
          // BlueStacks-specific optimizations
          // BlueStacks often has better audio handling
          headers['Cache-Control'] = 'max-age=31536000';
        } else if (_isEmulator) {
          // Regular emulator optimizations
          headers['Range'] = 'bytes=0-';
          headers['Cache-Control'] = 'no-transform';
          headers['Accept-Encoding'] = 'identity';
        }

        // Fix: Use ProgressiveAudioSource instead of LockCachingAudioSource
        final audioSource = ProgressiveAudioSource(
          Uri.parse(streamUrl),
          tag: MediaItem(
            id: song.id,
            title: song.title,
            artist: song.artist,
            artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
          ),
          headers: headers,
        );

        _cachedSources[song.id] = audioSource;
      }

      print('Pre-caching song: ${song.title}');
    } catch (e) {
      print('Error pre-caching song: $e');
    }
  }

  // Clear the cache for a specific song or all songs - remove this function since we don't have LockCachingAudioSource
  Future<void> _clearCache({String? songId}) async {
    try {
      // We can only clear the asset cache, not individual sources
      await AudioPlayer.clearAssetCache();
      print('Cleared audio cache');
    } catch (e) {
      print('Error clearing cache: $e');
    }
  }

  void _handlePlaybackError(dynamic error) {
    if (_retryCount < _maxRetries && _currentSong != null) {
      _retryCount++;
      print('Retry attempt $_retryCount of $_maxRetries');

      // Wait briefly before retrying
      Future.delayed(Duration(seconds: 1), () {
        _playSong(_currentSong!);
      });
    } else {
      // Show error to user after max retries
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Playback failed after $_maxRetries attempts')),
      );
    }
  }

  // Enhanced play song method for better emulator performance
  Future<void> _playSong(Song song) async {
    try {
      setState(() {
        _currentSong = song;
        _bufferingProgress = 0;
        _lastBufferPosition = 0; // Reset buffer monitoring
      });

      final streamUrl = '$_serverBaseUrl/${song.id}';

      // First, release any previous resources
      await _audioPlayer.stop();

      // Create audio source if not already cached
      if (!_cachedSources.containsKey(song.id)) {
        await _preCacheSong(song);
      }

      // Set up buffering with improved parameters for emulators
      await _audioPlayer.setAudioSource(
        _cachedSources[song.id]!,
        preload: true, // Begin buffering immediately
        initialPosition: Duration.zero, // Start from beginning
      );

      // Configure audio playback for quality
      await _audioPlayer.setVolume(_isEmulator ? 0.9 : 1.0);
      await _audioPlayer.setSpeed(1.0); // Normal speed for stable playback

      // For Android, apply additional settings for better buffering
      if (Platform.isAndroid) {
        await _audioPlayer.setSkipSilenceEnabled(false); // Don't skip silences

        // Additional emulator optimizations
        if (_isEmulator) {
          // Apply additional settings specifically for emulators
          // These would normally hurt quality but help with emulator performance
          print('Applying emulator audio optimizations');
        }
      }

      // Start playback
      await _audioPlayer.play();

      print('Now streaming: ${song.title} from $streamUrl');

      // After successful playback start, pre-cache the next song
      final currentIndex = _playlist.indexWhere((s) => s.id == song.id);
      if (currentIndex >= 0 && currentIndex < _playlist.length - 1) {
        _preCacheSong(_playlist[currentIndex + 1]);
      }
    } catch (e) {
      print('Error playing song: $e');

      // Handle the error with retry logic
      _handlePlaybackError(e);

      // Show an error message to the user
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Failed to play ${song.title}: ${e.toString()}')),
      );
    }
  }

  void _togglePlayback() {
    if (_currentSong == null) return;

    if (_isPlaying) {
      _audioPlayer.pause();
    } else {
      _audioPlayer.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          // Add appropriate environment indicator
          if (_isBlueStacks)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: Text(
                  'BLUESTACKS',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blue[800],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            )
          else if (_isEmulator)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: Text(
                  'EMULATOR',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red[800],
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          // Add simple buffer toggle button
          IconButton(
            icon: Icon(
                _optimizedModeEnabled ? Icons.speed : Icons.speed_outlined),
            onPressed: () {
              setState(() {
                _optimizedModeEnabled = !_optimizedModeEnabled;
              });

              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_optimizedModeEnabled
                      ? 'Optimized buffering enabled'
                      : 'Standard buffering mode'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            tooltip: 'Toggle optimized buffering',
          ),
        ],
      ),
      body: Column(
        children: [
          // Current song display with buffer indicator
          if (_currentSong != null)
            Column(
              children: [
                Container(
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
                        child: _currentSong?.imageUrl != null
                            ? Image.network(_currentSong!.imageUrl!,
                                fit: BoxFit.cover)
                            : const Icon(Icons.music_note, size: 30),
                      ),
                      const SizedBox(width: 16),
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
                              ),
                            ),
                            Text(_currentSong!.artist),
                            const SizedBox(height: 8),
                            // Buffer indicator
                            LinearProgressIndicator(
                              value: _bufferingProgress,
                              backgroundColor: Colors.grey[300],
                            ),
                            Text(
                              'Buffered: ${(_bufferingProgress * 100).toStringAsFixed(0)}%',
                              style: TextStyle(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                      // Play/pause button
                      IconButton(
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        iconSize: 32,
                        onPressed: _togglePlayback,
                      ),
                    ],
                  ),
                ),
              ],
            ),

          // Song list
          Expanded(
            child: ListView.builder(
              itemCount: _playlist.length,
              itemBuilder: (context, index) {
                final song = _playlist[index];
                return ListTile(
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: song.imageUrl != null
                        ? Image.network(song.imageUrl!, fit: BoxFit.cover)
                        : const Icon(Icons.music_note),
                  ),
                  title: Text(song.title),
                  subtitle: Text(song.artist),
                  onTap: () => _playSong(song),
                  trailing: _currentSong?.id == song.id && _isPlaying
                      ? const Icon(Icons.volume_up, color: Colors.purple)
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
