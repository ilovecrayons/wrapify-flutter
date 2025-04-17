import 'dart:async';
import 'dart:math';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'dart:io';
import '../models/song.dart';

enum PlaybackMode {
  linear,
  shuffle
}

class AudioPlayerService {
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
  double bufferingProgress = 0.0;
  int lastBufferPosition = 0;
  int retryCount = 0;
  final int maxRetries = 3;
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
  
  // Stream controllers for external components to listen to
  final _playbackStateController = StreamController<PlaybackState>.broadcast();
  final _currentSongController = StreamController<Song?>.broadcast();
  final _bufferingProgressController = StreamController<double>.broadcast();
  final _playbackModeController = StreamController<PlaybackMode>.broadcast();
  
  // Streams for external components to listen to
  Stream<PlaybackState> get playbackStateStream => _playbackStateController.stream;
  Stream<Song?> get currentSongStream => _currentSongController.stream;
  Stream<double> get bufferingProgressStream => _bufferingProgressController.stream;
  Stream<PlaybackMode> get playbackModeStream => _playbackModeController.stream;
  
  Song? _currentSong;
  Song? get currentSong => _currentSong;
  PlaybackMode get playbackMode => _playbackMode;
  
  void _init() {
    audioPlayer = AudioPlayer();
    _detectEmulator();
    _initAudioPlayer();
  }
  
  Future<void> _detectEmulator() async {
    if (Platform.isAndroid) {
      String osVersion = Platform.operatingSystemVersion.toLowerCase();
      isEmulator = osVersion.contains('sdk') || osVersion.contains('emulator');
      
      isBlueStacks = osVersion.contains('bluestacks') || osVersion.contains('bs');
      
      if (isBlueStacks) {
        print('🎮 BlueStacks detected - using specialized settings');
        isEmulator = true;
        optimizedModeEnabled = true;
      } else if (isEmulator) {
        print('🔍 Standard emulator detected - applying optimized settings');
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
        print('Error setting Android audio params: $e');
      }
    }
    
    // Listen for playback completion to play next song
    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        playNextSong();
      }
    });
    
    // Monitor playback state
    audioPlayer.playbackEventStream.listen((event) {
      final isPlaying = audioPlayer.playing;
      final bufferingTime = event.bufferedPosition;
      
      // Calculate buffering progress as percentage
      if (event.duration != null && event.duration!.inMilliseconds > 0) {
        bufferingProgress = event.bufferedPosition.inMilliseconds / 
                          event.duration!.inMilliseconds;
        _bufferingProgressController.add(bufferingProgress);
      }
      
      // Update playback state
      _playbackStateController.add(PlaybackState(
        isPlaying: isPlaying,
        processingState: _convertProcessingState(audioPlayer.processingState),
      ));
      
    }, onError: (Object e, StackTrace stackTrace) {
      print('Error in playback stream: $e');
      _handlePlaybackError(e);
    }, cancelOnError: false);
    
    // Monitor buffer state for adaptive buffering
    audioPlayer.processingStateStream.listen((state) {
      print('Processing state: $state');
      
      if (state == ProcessingState.buffering) {
        print('Buffering - reducing UI updates');
        
        if (optimizedModeEnabled) {
          _reduceResourceUsage(true);
        }
      }
      
      if (state == ProcessingState.ready) {
        print('Ready to play');
        retryCount = 0;
        
        if (optimizedModeEnabled) {
          _reduceResourceUsage(false);
        }
      }
      
      // Update playback state
      _playbackStateController.add(PlaybackState(
        isPlaying: audioPlayer.playing,
        processingState: _convertProcessingState(state),
      ));
    });
    
    // Add position reporting for diagnosing stutters
    audioPlayer.positionStream.listen((position) {
      if (position.inSeconds % 5 == 0 && position.inSeconds > 0) {
        print('Playback position: $position (buffer: ${bufferingProgress.toStringAsFixed(2)}%)');
      }
    });
  }
  
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
    bufferMonitorTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (audioPlayer.playing) {
        final currentBufferPos = (bufferingProgress * 100).round();
        
        if (currentBufferPos == lastBufferPosition && currentBufferPos < 10) {
          print('⚠️ Buffer stalled at $currentBufferPos% - applying recovery');
          _recoverFromBufferStall();
        }
        
        lastBufferPosition = currentBufferPos;
      }
    });
  }
  
  void _recoverFromBufferStall() {
    if (_currentSong != null && audioPlayer.playing) {
      audioPlayer.pause();
      
      Future.delayed(Duration(milliseconds: 300), () {
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
  
  Future<void> preCacheSong(Song song) async {
    try {
      final streamUrl = '$streamBaseUrl/${song.id}';
      
      if (!cachedSources.containsKey(song.id)) {
        Map<String, String> headers = {
          'Connection': 'keep-alive',
        };
        
        if (isBlueStacks) {
          headers['Cache-Control'] = 'max-age=31536000';
        } else if (isEmulator) {
          headers['Range'] = 'bytes=0-';
          headers['Cache-Control'] = 'no-transform';
          headers['Accept-Encoding'] = 'identity';
        }
        
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
        
        cachedSources[song.id] = audioSource;
      }
      
      print('Pre-caching song: ${song.title}');
    } catch (e) {
      print('Error pre-caching song: $e');
    }
  }
  
  Future<void> clearCache({String? songId}) async {
    try {
      await AudioPlayer.clearAssetCache();
      print('Cleared audio cache');
    } catch (e) {
      print('Error clearing cache: $e');
    }
  }
  
  void _handlePlaybackError(dynamic error) {
    print('Playback error occurred: $error');
    
    // Skip to next song on error instead of retrying the same song
    if (_currentSong != null) {
      print('Skipping problematic song: ${_currentSong!.title}');
      playNextSong();
    }
  }
  
  // Set the current playlist and optionally start playback
  void setPlaylist(List<Song> songs, {int startIndex = 0, bool autoPlay = false}) {
    if (songs.isEmpty) return;
    
    // Store the original playlist
    _currentPlaylist = List.from(songs);
    
    // Create both linear and shuffled queues
    _rebuildQueues();
    
    // Set the current index based on the active queue
    int actualIndex = min(startIndex, _playbackQueue.length - 1);
    _currentIndex = actualIndex;
    
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
    
    print('Queues rebuilt - Linear: ${_linearQueue.length}, Shuffled: ${_shuffledQueue.length}');
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
  
  // Toggle between linear and shuffle modes
  void togglePlaybackMode() {
    // Save current song
    Song? currentSong = _currentSong;
    
    // Toggle mode
    PlaybackMode newMode = _playbackMode == PlaybackMode.linear 
        ? PlaybackMode.shuffle 
        : PlaybackMode.linear;
    
    print('Toggling playback mode from ${_playbackMode.toString()} to ${newMode.toString()}');
    _playbackMode = newMode;
    
    // Notify listeners
    _playbackModeController.add(_playbackMode);
    
    // If we have a current song, find its index in the new active queue
    if (currentSong != null) {
      int newIndex = _playbackQueue.indexWhere((song) => song.id == currentSong.id);
      if (newIndex != -1) {
        _currentIndex = newIndex;
        print('Current song found at position $_currentIndex in the new queue');
      } else {
        print('Current song not found in the new queue, keeping index at $_currentIndex');
      }
    }
  }
  
  // Play the next song in the queue
  Future<void> playNextSong() async {
    // Basic validation
    if (_playbackQueue.isEmpty || _currentIndex < 0) {
      print('Skip prevented: empty queue or invalid index');
      return;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      print('Skip already in progress, ignoring duplicate request');
      return;
    }
    
    _isSkipping = true;
    print('Starting next song operation: _isSkipping = true');
    
    try {
      // Save the next song index and prepare to play
      int nextIndex = (_currentIndex + 1) % _playbackQueue.length;
      Song nextSong = _playbackQueue[nextIndex];
      _currentIndex = nextIndex;
      
      print('Will play next song: ${nextSong.title} (index: $_currentIndex)');
      
      // Use a more direct approach that doesn't call playSong() to avoid recursion
      
      // 1. Update state
      _currentSong = nextSong;
      _currentSongController.add(nextSong);
      bufferingProgress = 0;
      lastBufferPosition = 0;
      
      // 2. Stop current playback synchronously
      audioPlayer.stop();
      
      // 3. Set up and play the new source
      if (!cachedSources.containsKey(nextSong.id)) {
        await preCacheSong(nextSong);
      }
      
      final source = cachedSources[nextSong.id]!;
      
      // Clear all pending operations and force a new audio source
      await audioPlayer.setAudioSource(
        source,
        preload: true,
        initialPosition: Duration.zero,
      );
      
      // Apply playback settings
      await audioPlayer.setVolume(isEmulator ? 0.9 : 1.0);
      
      // Start playback
      audioPlayer.play();
      
      print('Started playback of next song: ${nextSong.title}');
      
      // Preload the next song
      _preloadNextSong();
    } catch (e) {
      print('Error playing next song: $e');
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // Wait a moment before trying the next song to avoid rapid skips
      Future.delayed(Duration(milliseconds: 500), () {
        print('Auto-skipping after error with: ${_currentSong?.title}');
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(Duration(milliseconds: 300), () {
          _isSkipping = false;
          print('Next song operation complete: _isSkipping = false');
        });
      }
    }
  }
  
  // Play the previous song in the queue
  Future<void> playPreviousSong() async {
    // Basic validation
    if (_playbackQueue.isEmpty || _currentIndex < 0) {
      print('Skip prevented: empty queue or invalid index');
      return;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      print('Skip already in progress, ignoring duplicate request');
      return;
    }
    
    _isSkipping = true;
    print('Starting previous song operation: _isSkipping = true');
    
    try {
      // Save the previous song index and prepare to play
      int prevIndex = (_currentIndex - 1 + _playbackQueue.length) % _playbackQueue.length;
      Song prevSong = _playbackQueue[prevIndex];
      _currentIndex = prevIndex;
      
      print('Will play previous song: ${prevSong.title} (index: $_currentIndex)');
      
      // Use a more direct approach that doesn't call playSong() to avoid recursion
      
      // 1. Update state
      _currentSong = prevSong;
      _currentSongController.add(prevSong);
      bufferingProgress = 0;
      lastBufferPosition = 0;
      
      // 2. Stop current playback synchronously
      audioPlayer.stop();
      
      // 3. Set up and play the new source
      if (!cachedSources.containsKey(prevSong.id)) {
        await preCacheSong(prevSong);
      }
      
      final source = cachedSources[prevSong.id]!;
      
      // Clear all pending operations and force a new audio source
      await audioPlayer.setAudioSource(
        source,
        preload: true,
        initialPosition: Duration.zero,
      );
      
      // Apply playback settings
      await audioPlayer.setVolume(isEmulator ? 0.9 : 1.0);
      
      // Start playback
      audioPlayer.play();
      
      print('Started playback of previous song: ${prevSong.title}');
      
      // Preload the next song
      _preloadNextSong();
    } catch (e) {
      print('Error playing previous song: $e');
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // When previous song fails, we should go to the next song (not previous again)
      Future.delayed(Duration(milliseconds: 500), () {
        print('Auto-skipping to next song after error with: ${_currentSong?.title}');
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(Duration(milliseconds: 300), () {
          _isSkipping = false;
          print('Previous song operation complete: _isSkipping = false');
        });
      }
    }
  }
  
  Future<void> playSong(Song song) async {
    try {
      print('Attempting to play song: ${song.title}');
      
      _currentSong = song;
      _currentSongController.add(song);
      bufferingProgress = 0;
      lastBufferPosition = 0;
      
      // Update current index if this song is in the queue
      int songIndex = _playbackQueue.indexWhere((s) => s.id == song.id);
      if (songIndex != -1) {
        _currentIndex = songIndex;
        print('Song index updated to $_currentIndex in active queue');
      } else {
        print('Song not found in the active queue');
      }
      
      final streamUrl = '$streamBaseUrl/${song.id}';
      
      await audioPlayer.stop();
      
      if (!cachedSources.containsKey(song.id)) {
        await preCacheSong(song);
      }
      
      await audioPlayer.setAudioSource(
        cachedSources[song.id]!,
        preload: true,
        initialPosition: Duration.zero,
      );
      
      await audioPlayer.setVolume(isEmulator ? 0.9 : 1.0);
      await audioPlayer.setSpeed(1.0);
      
      if (Platform.isAndroid) {
        await audioPlayer.setSkipSilenceEnabled(false);
        
        if (isEmulator) {
          print('Applying emulator audio optimizations');
        }
      }
      
      await audioPlayer.play();
      
      print('Now streaming: ${song.title} from $streamUrl');
      
      // Pre-cache the next song for smoother playback
      _preloadNextSong();
      
    } catch (e) {
      print('Error playing song: $e');
      _handlePlaybackError(e);
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
  
  void togglePlayback() {
    if (_currentSong == null) return;
    
    if (audioPlayer.playing) {
      audioPlayer.pause();
    } else {
      audioPlayer.play();
    }
  }
  
  bool get isPlaying => audioPlayer.playing;
  
  void setOptimizedMode(bool enabled) {
    optimizedModeEnabled = enabled;
  }
  
  void dispose() {
    bufferMonitorTimer?.cancel();
    audioPlayer.dispose();
    _playbackStateController.close();
    _currentSongController.close();
    _bufferingProgressController.close();
    _playbackModeController.close();
  }
}

// Simple class to represent playback state
class PlaybackState {
  final bool isPlaying;
  final ProcessingStateEnum processingState;
  
  PlaybackState({
    required this.isPlaying,
    required this.processingState,
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