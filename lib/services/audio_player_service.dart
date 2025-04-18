import 'dart:async';
import 'dart:math';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'dart:io';
import '../models/song.dart';

enum PlaybackMode {
  linear,
  shuffle,
  loop // New loop mode for repeating a single song
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
      }
    }
    
    // Listen for playback completion to play next song
    audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        if (_playbackMode == PlaybackMode.loop && _currentSong != null) {
          // If in loop mode, replay the current song instead of moving to next song
          _replayCurrentSong();
        } else {
          // Otherwise proceed to the next song
          playNextSong();
        }
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
      ));
    });
    
    // Add position reporting for diagnosing stutters
    audioPlayer.positionStream.listen((position) {
      if (position.inSeconds % 5 == 0 && position.inSeconds > 0) {
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
      
    } catch (e) {
    }
  }
  
  Future<void> clearCache({String? songId}) async {
    try {
      await AudioPlayer.clearAssetCache();
    } catch (e) {
    }
  }
  
  void _handlePlaybackError(dynamic error) {
    
    // Skip to next song on error instead of retrying the same song
    if (_currentSong != null) {
      playNextSong();
    }
  }
  
  // Set the current playlist and optionally start playback
  void setPlaylist(List<Song> songs, {int startIndex = 0, bool autoPlay = false}) {
    if (songs.isEmpty) return;
    
    // Filter out ignored songs
    final filteredSongs = songs.where((song) => !song.isIgnored).toList();
    
    // If all songs are ignored, keep the original list but don't play anything
    if (filteredSongs.isEmpty) {
      _currentPlaylist = List.from(songs);
      return;
    }
    
    // Store the filtered playlist
    _currentPlaylist = List.from(filteredSongs);
    
    // Create both linear and shuffled queues
    _rebuildQueues();
    
    // Find the appropriate start index if the requested song is not ignored
    int actualIndex = startIndex;
    if (songs[startIndex].isIgnored) {
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
      }
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
      return;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      return;
    }
    
    _isSkipping = true;
    
    try {
      // Save the next song index and prepare to play
      int nextIndex = (_currentIndex + 1) % _playbackQueue.length;
      Song nextSong = _playbackQueue[nextIndex];
      _currentIndex = nextIndex;
      
      
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
      
      
      // Preload the next song
      _preloadNextSong();
    } catch (e) {
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // Wait a moment before trying the next song to avoid rapid skips
      Future.delayed(Duration(milliseconds: 500), () {
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(Duration(milliseconds: 300), () {
          _isSkipping = false;
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
      return;
    }
    
    // Simple direct approach - ignore skip if one is in progress
    if (_isSkipping) {
      return;
    }
    
    _isSkipping = true;
    
    try {
      // Save the previous song index and prepare to play
      int prevIndex = (_currentIndex - 1 + _playbackQueue.length) % _playbackQueue.length;
      Song prevSong = _playbackQueue[prevIndex];
      _currentIndex = prevIndex;
      
      
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
      
      
      // Preload the next song
      _preloadNextSong();
    } catch (e) {
      
      // Reset the skipping flag so we can try the next song
      _isSkipping = false;
      
      // When previous song fails, we should go to the next song (not previous again)
      Future.delayed(Duration(milliseconds: 500), () {
        playNextSong(); // Skip to the next song on error
      });
      
      return; // Exit early to avoid the normal flag reset
    } finally {
      // Only reset flag if we didn't hit an error (otherwise we defer the reset)
      if (_isSkipping) {
        Timer(Duration(milliseconds: 300), () {
          _isSkipping = false;
        });
      }
    }
  }
  
  Future<void> playSong(Song song) async {
    try {
      
      _currentSong = song;
      _currentSongController.add(song);
      bufferingProgress = 0;
      lastBufferPosition = 0;
      
      // Update current index if this song is in the queue
      int songIndex = _playbackQueue.indexWhere((s) => s.id == song.id);
      if (songIndex != -1) {
        _currentIndex = songIndex;
      } else {
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
        }
      }
      
      await audioPlayer.play();
      
      
      // Pre-cache the next song for smoother playback
      _preloadNextSong();
      
    } catch (e) {
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
  
  // New method to replay the current song in loop mode
  Future<void> _replayCurrentSong() async {
    if (_currentSong == null) return;
    
    try {
      // Reset position to beginning
      await audioPlayer.seek(Duration.zero);
      // Start playback again
      await audioPlayer.play();
      
    } catch (e) {
      _handlePlaybackError(e);
    }
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