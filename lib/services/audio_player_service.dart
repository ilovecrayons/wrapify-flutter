import 'dart:async';
import 'dart:math';
import 'dart:io';
import 'package:flutter/services.dart'; // Add this import for MethodChannel
import 'package:flutter/widgets.dart'; // Add this import for WidgetsBindingObserver
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/song.dart';
import '../utils/logger.dart';
import 'audio_cache_manager.dart';

enum PlaybackMode {
  linear,
  shuffle,
  loop // Loop mode for repeating a single song
}

class AudioPlayerService with WidgetsBindingObserver {
  // Create a logger instance
  final Logger _logger = Logger('AudioPlayerService');
  
  // Singleton instance
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  
  // Factory constructor to return the singleton instance
  factory AudioPlayerService() {
    return _instance;
  }
  
  // Private constructor for singleton implementation
  AudioPlayerService._internal() {
    _init();
  }

  late final AudioPlayer audioPlayer;
  final String streamBaseUrl = 'https://wrapifyapi.dedyn.io/stream';
  Map<String, AudioSource> cachedSources = {};
  bool isEmulator = false;
  bool isBlueStacks = false;
  Timer? bufferMonitorTimer;
  Timer? _connectivityCheckTimer;
  Timer? _periodicCacheTimer;
  Timer? _backgroundPlaybackWatchdog;
  Timer? _skipResetTimer; // Add this timer to clear skip flag if stuck
  bool _playbackNeedsRestart = false;
  
  // Reference to the audio cache manager
  final AudioCacheManager _audioCacheManager = AudioCacheManager();
  
  double bufferingProgress = 0.0;
  int lastBufferPosition = 0;
  int retryCount = 0;
  final int maxRetries = 5;
  bool optimizedModeEnabled = true;
  
  // Playback queue variables
  List<Song> _currentPlaylist = [];
  
  // Maintain separate queues for linear and shuffle modes
  List<Song> _linearQueue = [];
  List<Song> _shuffledQueue = [];
  
  // Active queue based on current mode
  List<Song> get _playbackQueue => _playbackMode == PlaybackMode.linear 
      ? _linearQueue 
      : _shuffledQueue;
      
  int _currentIndex = -1;
  PlaybackMode _playbackMode = PlaybackMode.linear;
  final Random _random = Random();
  
  // Flag to prevent multiple skip operations at once
  bool _isSkipping = false;
  // Track when skip operation started to detect stuck flags
  DateTime _skipOperationStartTime = DateTime.now();
  
  // Define how many songs to pre-cache
  int _preCacheCount = 10; // Increased from 3 to 10 with disk caching
  
  // Keep track of network status
  bool _wasNetworkError = false;
  
  // Track if app is in background mode
  bool _isInBackgroundMode = false;
  
  // Stream controllers for external components to listen to
  final _playbackStateController = StreamController<PlaybackState>.broadcast();
  final _currentSongController = StreamController<Song?>.broadcast();
  final _bufferingProgressController = StreamController<double>.broadcast();
  final _playbackModeController = StreamController<PlaybackMode>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  
  // Streams for external components to listen to
  Stream<PlaybackState> get playbackStateStream => _playbackStateController.stream;
  Stream<Song?> get currentSongStream => _currentSongController.stream;
  Stream<double> get bufferingProgressStream => _bufferingProgressController.stream;
  Stream<PlaybackMode> get playbackModeStream => _playbackModeController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  
  Song? _currentSong;
  Song? get currentSong => _currentSong;
  PlaybackMode get playbackMode => _playbackMode;
  
  void _init() {
    audioPlayer = AudioPlayer();
    _detectEmulator();
    _setupAudioSession();
    _initAudioPlayer();
    _startConnectivityCheck();
    _startPeriodicCaching();
    
    // Register for app lifecycle events
    WidgetsBinding.instance.addObserver(this);
    _logger.debug('App lifecycle observer registered');
    
    // Handle any external audio control requests (like from notification)
    _setupAudioServiceHandler();
  }

  // Modified to start periodic caching
  void _startPeriodicCaching() {
    // Schedule periodic pre-caching every 30 minutes
    _periodicCacheTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      _performPeriodicCaching();
    });
  }

  // New method to perform periodic caching for improved playback reliability
  Future<void> _performPeriodicCaching() async {
    if (_playbackQueue.isEmpty || _currentIndex < 0) return;

    // Check connectivity before attempting caching
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult == ConnectivityResult.none) {
      _logger.debug('Skipping periodic caching - no network connection');
      return;
    }

    _logger.debug('Performing periodic caching of upcoming songs');

    // Get next songs to cache
    int remainingTracks = 0;
    List<Song> songsToCache = [];

    // If we're at the end of the playlist, we'll roll back to the beginning
    if (_currentIndex + 1 >= _playbackQueue.length) {
      remainingTracks = _playbackQueue.length;
    } else {
      remainingTracks = _playbackQueue.length - (_currentIndex + 1);
    }

    // Calculate how many songs we should cache
    // Either pre-cache count or remaining tracks, whichever is smaller
    int cachingCount = min(_preCacheCount, remainingTracks);

    // Add upcoming songs
    for (int i = 1; i <= cachingCount; i++) {
      int nextIndex = (_currentIndex + i) % _playbackQueue.length;
      songsToCache.add(_playbackQueue[nextIndex]);
    }

    // Trigger disk caching of these songs
    await _audioCacheManager.preCachePlaylist(songsToCache);
  }
  
  // New method to start a periodic connectivity check
  void _startConnectivityCheck() {
    _connectivityCheckTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_wasNetworkError && _currentSong != null) {
        _logger.debug('Attempting to restore connectivity after network error');
        _attemptNetworkRecovery();
      }
    });
  }
  
  // New method to attempt recovery after a network error
  Future<void> _attemptNetworkRecovery() async {
    if (_currentSong == null) return;
    
    try {
      // Check connectivity status
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        _logger.debug('Network still unavailable');
        return;
      }
      
      // Try to ping the server with a minimal request
      final socket = await Socket.connect('wrapifyapi.dedyn.io', 443)
        .timeout(const Duration(seconds: 5));
      socket.destroy();
      
      _logger.debug('Network connectivity restored');
      _wasNetworkError = false;
      
      // If we were in the middle of playback, try to resume
      if (_currentSong != null) {
        _logger.debug('Attempting to resume playback after network recovery');
        // Try to continue with the current song or move to the next
        if (audioPlayer.processingState == ProcessingState.completed) {
          playNextSong();
        } else {
          // Try to replay current song
          playSong(_currentSong!);
        }
      }
    } catch (e) {
      _logger.debug('Network still unavailable: $e');
      // Still no connectivity, we'll try again on next timer tick
    }
  }
  
  // Configure the audio session for proper background playback
  Future<void> _setupAudioSession() async {
    try {
      _logger.debug('Setting up audio session');
      final session = await AudioSession.instance;
      
      // Configure the audio session for music playback
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.duckOthers,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
      
      // Handle audio interruptions (phone calls, other audio apps)
      session.interruptionEventStream.listen((event) {
        if (event.begin) {
          // Audio was interrupted (e.g., by a phone call)
          _logger.debug('Audio interrupted: ${event.type}');
          if (audioPlayer.playing) {
            // Remember that we were playing
            _wasInterrupted = true;
            // Pause playback
            audioPlayer.pause();
          }
        } else {
          // Interruption ended
          _logger.debug('Audio interruption ended: ${event.type}');
          // If we were playing before the interruption and the user wants us to resume...
          if (_wasInterrupted && event.type == AudioInterruptionType.pause) {
            // Resume playback
            audioPlayer.play();
          }
          _wasInterrupted = false;
        }
      });
      
      // Handle audio becomingNoisy event (headphones unplugged)
      session.becomingNoisyEventStream.listen((_) {
        _logger.debug('Audio becoming noisy (headphones unplugged)');
        if (audioPlayer.playing) {
          audioPlayer.pause();
        }
      });
    } catch (e) {
      _logger.error('Error setting up audio session', e);
    }
  }
  
  bool _wasInterrupted = false;
  
  Future<void> _detectEmulator() async {
    if (Platform.isAndroid) {
      String osVersion = Platform.operatingSystemVersion.toLowerCase();
      isEmulator = osVersion.contains('sdk') || osVersion.contains('emulator');
      
      isBlueStacks = osVersion.contains('bluestacks') || osVersion.contains('bs');
      
      if (isBlueStacks) {
        isEmulator = true;
        optimizedModeEnabled = true;
      } else if (isEmulator) {
        optimizedModeEnabled = true;
      }
    }
  }
  
  void _initAudioPlayer() {
    // Start buffer monitoring for stuttering detection
    _startBufferMonitoring();
    
    // Apply specific Android audio settings if on Android
    if (Platform.isAndroid) {
      try {
        audioPlayer.setLoopMode(LoopMode.off);
        
        if (isEmulator) {
          audioPlayer.setVolume(0.9);
        }
      } catch (e) {
        _logger.error('Error configuring audio player on Android', e);
      }
    }
    
    // Listen for playback completion to play next song
    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        _logger.debug('Playback completed detected (${_isInBackgroundMode ? "background" : "foreground"} mode)');
        if (_playbackMode == PlaybackMode.loop && _currentSong != null) {
          // If in loop mode, replay the current song instead of moving to next song
          _replayCurrentSong();
        } else {
          // Otherwise proceed to the next song
          _playbackNeedsRestart = false;  // Reset flag as we're handling it properly
          playNextSong();
        }
      }
    });
    
    // Monitor playback state
    audioPlayer.playbackEventStream.listen((event) {
      final isPlaying = audioPlayer.playing;
      
      // Calculate buffering progress as percentage
      if (event.duration != null && event.duration!.inMilliseconds > 0) {
        bufferingProgress = event.bufferedPosition.inMilliseconds / 
                          event.duration!.inMilliseconds;
        _bufferingProgressController.add(bufferingProgress);
      }
      
      // Update position stream with current position
      _positionController.add(audioPlayer.position);
      
      // Update playback state
      _playbackStateController.add(PlaybackState(
        isPlaying: isPlaying,
        processingState: _convertProcessingState(audioPlayer.processingState),
        position: audioPlayer.position,
      ));
      
    }, onError: (Object e, StackTrace stackTrace) {
      _logger.error('Error in playback event stream', e, stackTrace);
      
      // Check for network errors
      if (e.toString().contains('Failed host lookup') || 
          e.toString().contains('SocketException') ||
          e.toString().contains('No address associated with hostname')) {
        _wasNetworkError = true;
        _logger.debug('Detected network connectivity issue');
      }
      
      _handlePlaybackError(e);
    }, cancelOnError: false);
    
    // Monitor buffer state for adaptive buffering
    audioPlayer.processingStateStream.listen((state) {
      
      if (state == ProcessingState.buffering) {
        if (optimizedModeEnabled) {
          _reduceResourceUsage(true);
        }
      }
      
      if (state == ProcessingState.ready) {
        retryCount = 0;
        
        if (optimizedModeEnabled) {
          _reduceResourceUsage(false);
        }
      }
      
      // Update playback state
      _playbackStateController.add(PlaybackState(
        isPlaying: audioPlayer.playing,
        processingState: _convertProcessingState(state),
        position: audioPlayer.position,
      ));
    });
    
    // Add position reporting for diagnosing stutters
    audioPlayer.positionStream.listen((position) {
      _positionController.add(position);
      
      // When position updates normally, we can assume network is working
      if (_wasNetworkError && position.inSeconds > 3) {
        _wasNetworkError = false;
      }
      
      // Pre-cache more songs when we're halfway through the current song
      if (audioPlayer.duration != null && 
          position > (audioPlayer.duration! * 0.5) &&
          !_hasPreCachedQueue) {
        _preloadMultipleNextSongs();
        _hasPreCachedQueue = true;
      }
    });
  }
  
  bool _hasPreCachedQueue = false;
  
  // Convert Just Audio's processing state to our own format
  ProcessingStateEnum _convertProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return ProcessingStateEnum.idle;
      case ProcessingState.loading:
        return ProcessingStateEnum.loading;
      case ProcessingState.buffering:
        return ProcessingStateEnum.buffering;
      case ProcessingState.ready:
        return ProcessingStateEnum.ready;
      case ProcessingState.completed:
        return ProcessingStateEnum.completed;
      default:
        return ProcessingStateEnum.idle;
    }
  }
  
  void _startBufferMonitoring() {
    bufferMonitorTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (audioPlayer.playing) {
        final currentBufferPos = (bufferingProgress * 100).round();
        
        if (currentBufferPos == lastBufferPosition && currentBufferPos < 10) {
          _recoverFromBufferStall();
        }
        
        lastBufferPosition = currentBufferPos;
      }
    });
  }
  
  void _recoverFromBufferStall() {
    if (_currentSong != null && audioPlayer.playing) {
      _logger.debug('Attempting to recover from buffer stall');
      audioPlayer.pause();
      
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_currentSong != null) {
          audioPlayer.play();
        }
      });
    }
  }
  
  void _reduceResourceUsage(bool reduce) {
    // Method to reduce system resource usage during buffering
    // Placeholder for actual resource optimization
  }
  
  // New method to download and save audio files for offline use
  Future<void> _saveForOffline(Song song) async {
    // This would be implemented to save the audio file locally
    // Not fully implemented in this update but could be added later
  }
  
  // Modified to use disk cache
  Future<AudioSource> _createAudioSource(Song song) async {
    final songId = song.id;
    final streamUrl = '$streamBaseUrl/$songId';
    
    if (cachedSources.containsKey(songId)) {
      return cachedSources[songId]!;
    }
    
    // First check if we have this song in disk cache
    final cachedFile = await _audioCacheManager.getCachedSongFile(songId);
    
    // If we have a disk cached version, use it directly
    if (cachedFile != null && await cachedFile.exists()) {
      _logger.debug('Using disk-cached file for ${song.title}');
      
      final fileSource = AudioSource.file(
        cachedFile.path,
        tag: MediaItem(
          id: song.id,
          title: song.title,
          artist: song.artist,
          artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
        ),
      );
      
      cachedSources[songId] = fileSource;
      return fileSource;
    } else {
      // Fall back to streaming from URL with HTTP headers
      _logger.debug('No disk cache available for ${song.title}, using network URL');
      
      Map<String, String> headers = {
        'Connection': 'keep-alive',
        'Cache-Control': 'max-age=86400', // 24 hours
      };
      
      if (isBlueStacks || isEmulator) {
        headers['Cache-Control'] = 'max-age=31536000'; // Longer cache for emulators
      }
      
      final urlSource = ProgressiveAudioSource(
        Uri.parse(streamUrl),
        tag: MediaItem(
          id: song.id,
          title: song.title,
          artist: song.artist,
          artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
        ),
        headers: headers,
      );
      
      cachedSources[songId] = urlSource;
      
      // Start downloading this to disk cache for next time
      _audioCacheManager.cacheSong(song).then((_) {
        _logger.debug('Background caching completed for ${song.title}');
      }).catchError((e) {
        _logger.error('Background caching failed for ${song.title}', e);
      });
      
      return urlSource;
    }
  }

  // Modified to use disk cache
  Future<void> preCacheSong(Song song) async {
    try {
      // First check if this song is already disk-cached
      if (await _audioCacheManager.isSongCached(song.id)) {
        _logger.debug('Song ${song.title} already disk-cached');
        return;
      }

      // Actively start disk caching this song
      _logger.debug('Pre-caching song to disk: ${song.title}');
      await _audioCacheManager.cacheSong(song);
      
    } catch (e) {
      _logger.error('Error pre-caching song: ${e.toString()}', e);
      
      if (e.toString().contains('Failed host lookup') || 
          e.toString().contains('SocketException')) {
        _wasNetworkError = true;
      }
    }
  }

  // Modified to work with disk cache with optional priority and count
  void _preloadMultipleNextSongs({bool priority = false, int? count}) {
    if (_playbackQueue.isEmpty || _currentIndex < 0) return;
    
    _logger.debug('Pre-caching multiple upcoming songs for background playback');
    
    final cachingCount = count ?? _preCacheCount;
    
    List<Song> songsToCache = [];
    for (int i = 1; i <= cachingCount; i++) {
      if (_currentIndex + i < _playbackQueue.length) {
        songsToCache.add(_playbackQueue[(_currentIndex + i) % _playbackQueue.length]);
      }
    }
    
    // Use the audioCache manager to cache these songs to disk
    // If priority is true, use a higher max songs count
    _audioCacheManager.preCachePlaylist(
      songsToCache, 
      maxSongs: priority ? cachingCount : _preCacheCount
    );
  }

  // Helper to wake lock during playback to prevent the OS from killing our process
  Future<void> _acquireWakeLock() async {
    // Only acquire wake lock if we're actually playing audio
    // or we're in background mode to conserve battery
    if (_isInBackgroundMode || audioPlayer.playing) {
      try {
        if (Platform.isAndroid) {
          const MethodChannel channel = MethodChannel('com.example.wrapifyflutter/audio');
          await channel.invokeMethod('acquireWakeLock');
          _logger.debug('Acquired wake lock for background playback');
        } else if (Platform.isIOS) {
          // iOS doesn't need explicit wake locks - the AVAudioSession 
          // configured in AppDelegate.swift handles keeping the device awake
          _logger.debug('iOS using native audio session for background playback');
        }
      } catch (e) {
        _logger.error('Error acquiring wake lock', e);
      }
    }
  }
  
  // Release the wake lock when not needed
  Future<void> _releaseWakeLock() async {
    // Don't release if we're still playing in background
    if (_isInBackgroundMode && audioPlayer.playing) {
      _logger.debug('Skipping wake lock release due to active background playback');
      return;
    }
    
    try {
      if (Platform.isAndroid) {
        const MethodChannel channel = MethodChannel('com.example.wrapifyflutter/audio');
        await channel.invokeMethod('releaseWakeLock');
        _logger.debug('Released wake lock');
      }
      // iOS doesn't need explicit wake lock management
    } catch (e) {
      _logger.error('Error releasing wake lock', e);
    }
  }

  // Modified playSong method to ensure proper background playback
  Future<void> playSong(Song song) async {
    try {
      _logger.debug('Attempting to play song: ${song.title}');
      
      // Acquire wake lock to prevent device sleep during initial buffering
      await _acquireWakeLock();
      
      _currentSong = song;
      _currentSongController.add(song);
      bufferingProgress = 0;
      lastBufferPosition = 0;
      
      // Update current index if this song is in the queue
      int songIndex = _playbackQueue.indexWhere((s) => s.id == song.id);
      if (songIndex != -1) {
        _currentIndex = songIndex;
        _logger.debug('Song index updated to $_currentIndex in active queue');
      } else {
        _logger.debug('Song not found in the active queue');
      }
      
      // Stop current playback
      await audioPlayer.stop();
      
      // Aggressively pre-cache next songs before starting playback of this one
      // This ensures we have files ready for background playback
      if (!_isInBackgroundMode) {
        _preloadMultipleNextSongs(priority: true);
      }
      
      // Check if song is already cached
      final bool isCached = await _audioCacheManager.isSongCached(song.id);
      _logger.debug('Is song ${song.title} cached? $isCached');
      
      // Get the appropriate audio source
      final audioSource = await _createAudioSource(song);
      
      // Set audio source with increased timeout for reliability
      try {
        await audioPlayer.setAudioSource(
          audioSource,
          preload: true,
          initialPosition: Duration.zero,
        ).timeout(const Duration(seconds: 15));
      } catch (timeoutError) {
        _logger.error('Timeout setting audio source', timeoutError);
        if (_wasNetworkError) {
          _retryWithBackoff();
          return;
        } else {
          rethrow;  // Let the outer try/catch handle it
        }
      }
      
      // Apply playback settings
      await audioPlayer.setVolume(isEmulator ? 0.9 : 1.0);
      await audioPlayer.setSpeed(1.0);
      
      if (Platform.isAndroid) {
        await audioPlayer.setSkipSilenceEnabled(false);
      }
      
      await audioPlayer.play();
      
      _logger.debug('Now playing: ${song.title}');
      
      // Pre-cache next few songs to disk for smoother background playback
      _preloadMultipleNextSongs();
      
    } catch (e) {
      _logger.error('Error playing song', e);
      
      if (e.toString().contains('Failed host lookup') || 
          e.toString().contains('SocketException')) {
        _wasNetworkError = true;
        _retryWithBackoff();
      } else {
        _handlePlaybackError(e);
      }
    } finally {
      // Release wake lock after a delay to ensure playback has started properly
      Future.delayed(Duration(seconds: 5), () {
        _releaseWakeLock();
      });
    }
  }

  // Play the next song in the queue
  Future<void> playNextSong() async {
    // If in loop mode, just restart the current song
    if (_playbackMode == PlaybackMode.loop && _currentSong != null) {
      await _replayCurrentSong();
      return;
    }
    
    // Basic validation
    if (_playbackQueue.isEmpty || _currentIndex < 0) {
      _logger.debug('Skip prevented: empty queue or invalid index');
      return;
    }
    
    // Check if skip flag is stuck (more than 3 seconds old) - safety mechanism
    if (_isSkipping && DateTime.now().difference(_skipOperationStartTime).inSeconds > 3) {
      _logger.debug('Skip flag appears stuck, forcing reset');
      _isSkipping = false;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      _logger.debug('Skip already in progress, ignoring duplicate request');
      return;
    }
    
    _isSkipping = true;
    _skipOperationStartTime = DateTime.now();
    _logger.debug('Starting next song operation: _isSkipping = true');
    
    // Cancel any existing skip reset timer
    _skipResetTimer?.cancel();
    
    try {
      // Save the next song index and prepare to play
      int nextIndex = (_currentIndex + 1) % _playbackQueue.length;
      Song nextSong = _playbackQueue[nextIndex];
      _currentIndex = nextIndex;
      
      _logger.debug('Will play next song: ${nextSong.title} (index: $_currentIndex)');
      
      // The playSong method now handles disk caching and source selection
      await playSong(nextSong);
      
    } catch (e) {
      _logger.error('Error playing next song', e);
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // Wait a moment before trying the next song to avoid rapid skips
      Future.delayed(const Duration(milliseconds: 500), () {
        _logger.debug('Auto-skipping after error with: ${_currentSong?.title}');
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Always set a backup timer to release the skip lock in case the normal release doesn't happen
      _skipResetTimer = Timer(const Duration(seconds: 3), () {
        if (_isSkipping) {
          _logger.debug('Safety release of skip lock after timeout');
          _isSkipping = false;
        }
      });
      
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(const Duration(milliseconds: 300), () {
          _isSkipping = false;
          _logger.debug('Next song operation complete: _isSkipping = false');
        });
      }
    }
  }
  
  // Play the previous song in the queue
  Future<void> playPreviousSong() async {
    // If in loop mode, just restart the current song
    if (_playbackMode == PlaybackMode.loop && _currentSong != null) {
      await _replayCurrentSong();
      return;
    }
    
    // Basic validation
    if (_playbackQueue.isEmpty || _currentIndex < 0) {
      _logger.debug('Skip prevented: empty queue or invalid index');
      return;
    }
    
    // Check if skip flag is stuck (more than 3 seconds old) - safety mechanism
    if (_isSkipping && DateTime.now().difference(_skipOperationStartTime).inSeconds > 3) {
      _logger.debug('Skip flag appears stuck, forcing reset');
      _isSkipping = false;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      _logger.debug('Skip already in progress, ignoring duplicate request');
      return;
    }
    
    _isSkipping = true;
    _skipOperationStartTime = DateTime.now();
    _logger.debug('Starting previous song operation: _isSkipping = true');
    
    // Cancel any existing skip reset timer
    _skipResetTimer?.cancel();
    
    try {
      // Save the previous song index and prepare to play
      int prevIndex = (_currentIndex - 1 + _playbackQueue.length) % _playbackQueue.length;
      Song prevSong = _playbackQueue[prevIndex];
      _currentIndex = prevIndex;
      
      _logger.debug('Will play previous song: ${prevSong.title} (index: $_currentIndex)');
      
      // The playSong method now handles disk caching and source selection
      await playSong(prevSong);
      
    } catch (e) {
      _logger.error('Error playing previous song', e);
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // Wait a moment before trying the next song to avoid rapid skips
      Future.delayed(const Duration(milliseconds: 500), () {
        _logger.debug('Auto-skipping after error with: ${_currentSong?.title}');
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Always set a backup timer to release the skip lock in case the normal release doesn't happen
      _skipResetTimer = Timer(const Duration(seconds: 3), () {
        if (_isSkipping) {
          _logger.debug('Safety release of skip lock after timeout');
          _isSkipping = false;
        }
      });
      
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(const Duration(milliseconds: 300), () {
          _isSkipping = false;
          _logger.debug('Previous song operation complete: _isSkipping = false');
        });
      }
    }
  }
  
  // Set the current playlist and optionally start playback
  void setPlaylist(List<Song> songs, {int startIndex = 0, bool autoPlay = false}) {
    if (songs.isEmpty) return;
    
    // Filter out ignored songs
    final filteredSongs = songs.where((song) => !song.isIgnored).toList();
    
    // If all songs are ignored, keep the original list but don't play anything
    if (filteredSongs.isEmpty) {
      _logger.debug('All songs in playlist are ignored');
      _currentPlaylist = List.from(songs);
      return;
    }
    
    // Store the filtered playlist
    _currentPlaylist = List.from(filteredSongs);
    
    // Create both linear and shuffled queues
    _rebuildQueues();
    
    // Find the appropriate start index if the requested song is not ignored
    int actualIndex = startIndex;
    if (startIndex >= songs.length || songs[startIndex].isIgnored) {
      // Find the first non-ignored song
      final firstNonIgnoredIndex = songs.indexWhere((song) => !song.isIgnored);
      if (firstNonIgnoredIndex >= 0) {
        actualIndex = 0; // Use the first song in the filtered list
      } else {
        return; // No playable songs
      }
    } else {
      // Find the position of the requested song in the filtered list
      actualIndex = filteredSongs.indexWhere((s) => s.id == songs[startIndex].id);
      if (actualIndex < 0) actualIndex = 0;
    }
    
    // Set the current index based on the active queue
    actualIndex = min(actualIndex, _playbackQueue.length - 1);
    _currentIndex = actualIndex;
    
    _logger.debug('Playlist set with ${filteredSongs.length} songs, starting at index $actualIndex');
    
    // When setting a new playlist, immediately begin disk caching the upcoming songs
    _preloadMultipleNextSongs();
    
    if (autoPlay) {
      playSong(_playbackQueue[_currentIndex]);
    }
  }
  
  // Rebuild both linear and shuffled queues
  void _rebuildQueues() {
    // Always rebuild the linear queue from the current playlist
    _linearQueue = List.from(_currentPlaylist);
    
    // Create a new shuffled queue
    _shuffledQueue = List.from(_currentPlaylist);
    _shuffleQueue(_shuffledQueue);
    
    _logger.debug('Queues rebuilt - Linear: ${_linearQueue.length}, Shuffled: ${_shuffledQueue.length}');
  }
  
  // Shuffle a queue using Fisher-Yates algorithm
  void _shuffleQueue(List<Song> queue) {
    for (int i = queue.length - 1; i > 0; i--) {
      int j = _random.nextInt(i + 1);
      // Swap
      Song temp = queue[i];
      queue[i] = queue[j];
      queue[j] = temp;
    }
  }
  
  // Cycle through playback modes (linear -> shuffle -> loop -> linear)
  void togglePlaybackMode() {
    // Save current song
    Song? currentSong = _currentSong;
    
    // Cycle through modes
    PlaybackMode newMode;
    switch (_playbackMode) {
      case PlaybackMode.linear:
        newMode = PlaybackMode.shuffle;
        break;
      case PlaybackMode.shuffle:
        newMode = PlaybackMode.loop;
        break;
      case PlaybackMode.loop:
        newMode = PlaybackMode.linear;
        break;
    }
    
    _playbackMode = newMode;
    _logger.debug('Playback mode changed to: $_playbackMode');
    
    // If switching to loop mode, set the loop mode in the player
    if (_playbackMode == PlaybackMode.loop) {
      audioPlayer.setLoopMode(LoopMode.one);
    } else {
      audioPlayer.setLoopMode(LoopMode.off);
    }
    
    // Notify listeners
    _playbackModeController.add(_playbackMode);
    
    // If we have a current song and not in loop mode, find its index in the new active queue
    if (currentSong != null && _playbackMode != PlaybackMode.loop) {
      int newIndex = _playbackQueue.indexWhere((song) => song.id == currentSong.id);
      if (newIndex != -1) {
        _currentIndex = newIndex;
      } else {
        _logger.debug('Current song not found in new active queue');
      }
    }
  }
  
  // Preload the next song to avoid buffering delays
  void _preloadNextSong() {
    if (_playbackQueue.isEmpty || _currentIndex < 0) return;
    
    int nextIndex = (_currentIndex + 1) % _playbackQueue.length;
    Song nextSong = _playbackQueue[nextIndex];
    
    // Pre-cache the next song
    preCacheSong(nextSong);
  }
  
  // New method to replay the current song in loop mode
  Future<void> _replayCurrentSong() async {
    if (_currentSong == null) return;
    
    try {
      // Reset position to beginning
      await audioPlayer.seek(Duration.zero);
      // Start playback again
      await audioPlayer.play();
      _logger.debug('Replaying current song in loop mode');
    } catch (e) {
      _logger.error('Error replaying song', e);
      _handlePlaybackError(e);
    }
  }
  
  // Public methods that can be called from the AudioHandler
  Future<void> resumePlayback() async {
    if (_currentSong == null) {
      _logger.debug('Cannot resume playback: no current song');
      return;
    }
    
    try {
      await audioPlayer.play();
      _logger.debug('Playback resumed');
    } catch (e) {
      _logger.error('Error resuming playback', e);
    }
  }
  
  Future<void> pausePlayback() async {
    try {
      await audioPlayer.pause();
      _logger.debug('Playback paused');
    } catch (e) {
      _logger.error('Error pausing playback', e);
    }
  }
  
  Future<void> stopPlayback() async {
    try {
      await audioPlayer.stop();
      _logger.debug('Playback stopped');
    } catch (e) {
      _logger.error('Error stopping playback', e);
    }
  }
  
  Future<void> seekTo(Duration position) async {
    try {
      await audioPlayer.seek(position);
      _logger.debug('Seeked to position: ${position.inSeconds}s');
    } catch (e) {
      _logger.error('Error seeking to position', e);
    }
  }
  
  void togglePlayback() {
    if (_currentSong == null) return;
    
    if (audioPlayer.playing) {
      _logger.debug('Toggle: pausing playback');
      audioPlayer.pause();
    } else {
      _logger.debug('Toggle: resuming playback');
      audioPlayer.play();
    }
  }
  
  bool get isPlaying => audioPlayer.playing;
  
  void setOptimizedMode(bool enabled) {
    optimizedModeEnabled = enabled;
    _logger.debug('Optimized mode set to: $enabled');
  }

  // Display information about the disk cache
  Future<String> getCacheStats() async {
    final size = await _audioCacheManager.getCacheSize();
    final sizeInMB = size / (1024 * 1024);
    return 'Disk cache size: ${sizeInMB.toStringAsFixed(2)} MB';
  }

  // Clear the disk cache
  Future<void> clearDiskCache() async {
    await _audioCacheManager.cleanCache();
    _logger.debug('Disk cache cleared');
  }
  
  void dispose() {
    _logger.debug('Disposing AudioPlayerService');
    
    // Make sure we release the wake lock
    _releaseWakeLock();
    
    // Stop background watchdog
    _stopBackgroundPlaybackWatchdog();
    
    // Unregister lifecycle observer
    WidgetsBinding.instance.removeObserver(this);
    
    // Cancel timers
    bufferMonitorTimer?.cancel();
    _connectivityCheckTimer?.cancel();
    _periodicCacheTimer?.cancel();
    _skipResetTimer?.cancel(); // Cancel the skip reset timer
    
    // Dispose player and streams
    audioPlayer.dispose();
    _playbackStateController.close();
    _currentSongController.close();
    _bufferingProgressController.close();
    _playbackModeController.close();
    _positionController.close();
  }

  // Handle errors during playback
  void _handlePlaybackError(dynamic error) {
    _logger.error('Playback error occurred', error);
    
    // Check if it's a network-related error
    if (error.toString().contains('Failed host lookup') || 
        error.toString().contains('SocketException') ||
        error.toString().contains('HttpException') ||
        error.toString().contains('Connection refused') ||
        error.toString().contains('Network is unreachable')) {
      
      _wasNetworkError = true;
      _logger.debug('Network error detected in playback');
      
      // Try to recover with backoff if we're not at max retries
      if (retryCount < maxRetries) {
        _retryWithBackoff();
      }
    } else {
      // For other errors, skip to next song
      if (_currentSong != null) {
        _logger.debug('Skipping problematic song: ${_currentSong!.title}');
        playNextSong();
      }
    }
  }
  
  // Retry playback with exponential backoff
  void _retryWithBackoff() {
    if (_currentSong == null) return;
    
    retryCount++;
    final backoffSeconds = 1 << retryCount; // Exponential backoff: 2, 4, 8, 16, 32...
    
    _logger.debug('Retry attempt $retryCount for ${_currentSong!.title} after $backoffSeconds seconds');
    
    Future.delayed(Duration(seconds: backoffSeconds), () {
      if (_currentSong != null) {
        _logger.debug('Attempting retry playback after backoff');
        playSong(_currentSong!);
      }
    });
  }

  /// Load and prepare an audio source for the given song
  Future<AudioSource> _loadAudioSource(Song song) async {
    final songId = song.id;
    String streamUrl = 'https://wrapifyapi.dedyn.io/stream/$songId';
    
    try {
      // First, check if the song is cached
      final cacheManager = AudioCacheManager();
      final isCached = await cacheManager.isSongCached(songId);
      
      if (isCached) {
        final cachedFile = await cacheManager.getCachedSongFile(songId);
        
        // Double-check file exists and is not empty before using it
        if (cachedFile != null && await cachedFile.exists() && await cachedFile.length() > 0) {
          _logger.debug('Using cached file for: ${song.title}');
          return AudioSource.uri(
            Uri.file(cachedFile.path),
            tag: MediaItem(
              id: songId,
              title: song.title,
              artist: song.artist,
              artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
            ),
          );
        } else {
          _logger.debug('Cached file invalid for: ${song.title}, falling back to streaming');
          // Remove from cache tracking since file is invalid
        }
      }
      
      // Fall back to streaming if not cached
      _logger.debug('Streaming (not using cache) for: ${song.title}');
      return AudioSource.uri(
        Uri.parse(streamUrl),
        tag: MediaItem(
          id: songId,
          title: song.title,
          artist: song.artist,
          artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
        ),
      );
    } catch (e) {
      _logger.error('Error loading audio source for ${song.title}', e);
      // Fall back to streaming in case of any errors
      return AudioSource.uri(
        Uri.parse(streamUrl),
        tag: MediaItem(
          id: songId,
          title: song.title,
          artist: song.artist,
          artUri: song.imageUrl != null ? Uri.parse(song.imageUrl!) : null,
        ),
      );
    }
  }

  // Add a method to detect application lifecycle changes
  void _setupAppLifecycleListener() {
    WidgetsBinding.instance.addObserver(this);
    _logger.debug('App lifecycle observer registered');
  }
  
  // Public method to notify the service when app goes to background
  void setBackgroundMode(bool isBackground) {
    bool wasInBackground = _isInBackgroundMode;
    _isInBackgroundMode = isBackground;
    _logger.debug('App background mode set to: $isBackground');
    
    if (isBackground) {
      // When going to background
      if (_currentSong != null) {
        // Aggressively pre-cache more songs in background
        _preloadMultipleNextSongs(priority: true, count: 15);
        
        if (audioPlayer.playing) {
          // Check if we're using a network source and we don't have the next song cached
          _ensureBackgroundPlayback();
          
          // Start the background playback watchdog
          _startBackgroundPlaybackWatchdog();
        }
      }
    } else if (wasInBackground) {
      // Coming back to foreground from background
      _stopBackgroundPlaybackWatchdog();
      
      // Reset any background-specific optimizations
      _hasPreCachedQueue = false;
      
      // Maybe refresh the current playback state
      if (_currentSong != null) {
        _currentSongController.add(_currentSong);
        
        // Check if playback stalled in the background and needs restart
        if (_playbackNeedsRestart && !audioPlayer.playing && 
            audioPlayer.processingState == ProcessingState.completed) {
          _logger.debug('Detected stalled playback after returning from background - restarting');
          _playbackNeedsRestart = false;
          playNextSong();
        }
      }
    }
  }

  // New method to ensure background playback continues
  void _ensureBackgroundPlayback() {
    if (_currentSong == null) return;
    
    _logger.debug('Ensuring background playback for: ${_currentSong!.title}');
    
    // Acquire wake lock explicitly for background playback
    _acquireWakeLock();
    
    // If we're currently streaming (not playing from cache), try to cache upcoming songs with high priority
    _audioCacheManager.isSongCached(_currentSong!.id).then((isCached) {
      if (!isCached) {
        _logger.debug('Current song not cached. Adding to high priority cache queue.');
        _audioCacheManager.cacheSong(_currentSong!);
      }
      
      // Also cache next song with high priority
      if (_currentIndex >= 0 && _playbackQueue.isNotEmpty) {
        int nextIndex = (_currentIndex + 1) % _playbackQueue.length;
        Song nextSong = _playbackQueue[nextIndex];
        _audioCacheManager.cacheSong(nextSong);
      }
    });
  }

  // Override didChangeAppLifecycleState with more robust handling
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // App is in background or about to go to background
        _logger.debug('App going to background - preparing for background playback');
        setBackgroundMode(true);
        
        // Immediately acquire wake lock if we're playing to prevent interruption
        if (audioPlayer.playing && _currentSong != null) {
          _acquireWakeLock();
          // Ensure we have enough songs cached for uninterrupted playback
          _preloadMultipleNextSongs(priority: true, count: 20);
        }
        break;
        
      case AppLifecycleState.resumed:
        // App is in foreground
        _logger.debug('App resumed to foreground');
        setBackgroundMode(false);
        
        // We can release wake lock if we're in foreground
        if (!audioPlayer.playing) {
          _releaseWakeLock();
        }
        
        // Check if we're still playing and if status needs to be updated
        if (_currentSong != null) {
          _playbackStateController.add(PlaybackState(
            isPlaying: audioPlayer.playing,
            processingState: _convertProcessingState(audioPlayer.processingState),
            position: audioPlayer.position,
          ));
        }
        break;
        
      default:
        break;
    }
  }
  
  // New method to set up audio service handler
  void _setupAudioServiceHandler() {
    // This can be expanded to handle external controls better
    _logger.debug('Setting up audio service for background controls');
  }

  // Add a watchdog timer to monitor background playback
  void _startBackgroundPlaybackWatchdog() {
    _stopBackgroundPlaybackWatchdog(); // Stop any existing timer
    
    // Create a watchdog that checks playback status every 15 seconds while in background
    _backgroundPlaybackWatchdog = Timer.periodic(const Duration(seconds: 15), (timer) {
      if (!_isInBackgroundMode) {
        _stopBackgroundPlaybackWatchdog();
        return;
      }
      
      if (_currentSong != null) {
        _logger.debug('Background playback watchdog: state=${audioPlayer.processingState}, playing=${audioPlayer.playing}');
        
        // Check if we're in a completed state but haven't automatically moved to the next song
        if (audioPlayer.processingState == ProcessingState.completed) {
          _logger.debug('Detected completed song in background that did not auto-advance');
          
          // Flag that playback needs attention, either now or when returning to foreground
          _playbackNeedsRestart = true;
          
          // Try to advance to next song
          if (_playbackMode == PlaybackMode.loop) {
            _replayCurrentSong();
          } else {
            playNextSong();
          }
        }
        
        // Re-acquire wake lock periodically to prevent it from being released
        if (audioPlayer.playing) {
          _acquireWakeLock();
        }
      } else {
        _stopBackgroundPlaybackWatchdog();
      }
    });
  }

  void _stopBackgroundPlaybackWatchdog() {
    _backgroundPlaybackWatchdog?.cancel();
    _backgroundPlaybackWatchdog = null;
  }
}

// Class to represent playback state
class PlaybackState {
  final bool isPlaying;
  final ProcessingStateEnum processingState;
  final Duration position;
  final bool isBuffering;
  final bool isLoading;
  
  PlaybackState({
    required this.isPlaying,
    required this.processingState,
    this.position = Duration.zero,
    this.isBuffering = false,
    this.isLoading = false,
  });
}

// Enum to represent processing states
enum ProcessingStateEnum {
  idle,
  loading,
  buffering,
  ready,
  completed,
}