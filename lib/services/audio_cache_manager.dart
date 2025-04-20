import 'dart:async';
import 'dart:io';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import '../models/song.dart';
import '../utils/logger.dart';

/// A specialized cache manager for audio files
/// This class handles downloading, storing, and retrieving audio files
/// for improved background playback reliability
class AudioCacheManager {
  // Singleton pattern implementation
  static final AudioCacheManager _instance = AudioCacheManager._internal();
  factory AudioCacheManager() => _instance;
  AudioCacheManager._internal() {
    _init();
  }
  
  // Create a logger
  final Logger _logger = Logger('AudioCacheManager');
  
  // Custom cache manager for audio files with longer cache duration and larger max size
  late final CacheManager _cacheManager;
  
  // Dio instance for HTTP requests with retry capability
  late final Dio _dio;
  
  // Cache configuration
  static const String _cacheKey = 'wrapifyAudioCache';
  static const Duration _maxCacheAge = Duration(days: 7); // Store files for up to 7 days
  
  // Base URL for audio streaming
  final String streamBaseUrl = 'https://wrapifyapi.dedyn.io/stream';
  
  // Track which songs are currently being downloaded to prevent duplicate downloads
  final Map<String, Completer<File>> _activeDownloads = {};
  
  // Track which songs are already cached on disk
  final Set<String> _cachedSongIds = {};
  
  void _init() {
    // Initialize the cache manager with custom config for audio files
    _cacheManager = CacheManager(
      Config(
        _cacheKey,
        stalePeriod: _maxCacheAge,
        maxNrOfCacheObjects: 1000, // Allow many cached files
        repo: JsonCacheInfoRepository(databaseName: _cacheKey),
        fileService: HttpFileService(),
      ),
    );
    
    // Initialize Dio with retry options
    _dio = Dio();
    _dio.options.receiveTimeout = const Duration(minutes: 3); // Longer timeout for audio files
    _dio.options.connectTimeout = const Duration(seconds: 30);
    // Use Map<String, String> for headers to match expected type
    _dio.options.headers = <String, String>{
      'Connection': 'keep-alive',
      'Cache-Control': 'max-age=86400', // 24 hours
    };
    
    // Load the cached song list
    _loadCachedSongs();
  }
  
  // Preload and store information about which songs are already cached
  Future<void> _loadCachedSongs() async {
    try {
      _cachedSongIds.clear(); // Ensure we start with a clean slate
      
      // Get the platform-specific cache directory
      final appDir = await getTemporaryDirectory();
      
      // Construct the cache directory path
      final cacheDirectory = Directory('${appDir.path}/$_cacheKey');
      if (!await cacheDirectory.exists()) {
        _logger.debug('Cache directory does not exist: ${cacheDirectory.path}');
        await cacheDirectory.create(recursive: true);
        _logger.debug('Created cache directory: ${cacheDirectory.path}');
        return;
      }
      
      _logger.debug('Looking for cached files in: ${cacheDirectory.path}');
      
      // Scan the directory for cached files
      try {
        int cacheCount = 0;
        int missingCount = 0;
        
        // Scan the directory for finding files - we don't have a built-in method to access all cached files
        final files = await cacheDirectory.list(recursive: true).toList();
        _logger.debug('Found ${files.length} total files in cache directory');
        
        // Process files and attempt to identify cached songs by examining file paths
        for (var entity in files) {
          if (entity is File) {
            final fileName = path.basename(entity.path);
            final filePath = entity.path;
            
            try {
              // Look for song IDs in the filename or path
              // First check if the path contains our stream URL pattern
              if (filePath.contains('stream_') || fileName.contains('.mp3') || fileName.contains('.m4a')) {
                // Try multiple patterns to be more flexible
                final match = RegExp(r'(stream_|libCachedImageData|)([a-zA-Z0-9-_.]+)').firstMatch(fileName);
                if (match != null) {
                  final matchedId = match.group(2);
                  if (matchedId != null && matchedId.length > 5) {  // Basic validation
                    if (await entity.exists() && await entity.length() > 0) {
                      // Try to extract song ID
                      var songId = matchedId;
                      
                      // Clean up possible URL encoding
                      if (songId.contains('%')) {
                        songId = Uri.decodeComponent(songId);
                      }
                      
                      // Clean up common suffixes
                      if (songId.contains('.')) {
                        songId = songId.substring(0, songId.lastIndexOf('.'));
                      }
                      
                      // Additional verification - try to access file through cache manager
                      final url = '$streamBaseUrl/$songId';
                      final fileInfo = await _cacheManager.getFileFromCache(url);
                      
                      if (fileInfo != null) {
                        _cachedSongIds.add(songId);
                        cacheCount++;
                        _logger.debug('Added verified cached song: $songId');
                      } else if (await entity.length() > 100000) {
                        // If file is reasonably sized (over 100KB) consider it a valid audio file
                        // even if it's not registered in the cache manager
                        _cachedSongIds.add(songId);
                        cacheCount++;
                        _logger.debug('Added cached song from file pattern: $songId');
                      } else {
                        missingCount++;
                      }
                    }
                  }
                }
              }
            } catch (e) {
              _logger.error('Error checking file: $fileName', e);
            }
          }
        }
        
        _logger.debug('Retrieved $cacheCount valid song entries, found $missingCount missing entries');
      } catch (e) {
        _logger.error('Error scanning cache directory', e);
      }
    } catch (e) {
      _logger.error('Error loading cached songs', e);
    }
  }
  
  // Helper method to get the cache directory
  Future<Directory?> _getCacheDirectory() async {
    try {
      // Use path_provider package to get the temporary directory
      final directory = await getTemporaryDirectory();
      return directory;
    } catch (e) {
      _logger.error('Error getting cache directory', e);
      return null;
    }
  }
  
  /// Check if a song is already cached
  /// Always verifies that the file actually exists
  Future<bool> isSongCached(String songId) async {
    // First check our in-memory tracking set
    if (!_cachedSongIds.contains(songId)) {
      return false;
    }
    
    // Always verify the file actually exists
    final cachedFile = await getCachedSongFile(songId);
    if (cachedFile == null || !(await cachedFile.exists())) {
      // File doesn't exist - remove from tracking set
      _logger.debug('Cached song $songId was in tracking set but file not found');
      _cachedSongIds.remove(songId);
      return false;
    }
    
    return true;
  }
  
  /// Get the File for a cached song
  /// Returns null if the song is not cached
  Future<File?> getCachedSongFile(String songId) async {
    try {
      final url = '$streamBaseUrl/$songId';
      final fileInfo = await _cacheManager.getFileFromCache(url);
      return fileInfo?.file;
    } catch (e) {
      _logger.error('Error getting cached file for song $songId', e);
      return null;
    }
  }
  
  /// Download and cache a song
  /// This method will download the song to disk cache
  /// If the song is already being downloaded, it will return the existing download
  /// Returns the cached file when complete
  Future<File?> cacheSong(Song song) async {
    final songId = song.id;
    final url = '$streamBaseUrl/$songId';
    
    // Check if download is already in progress
    if (_activeDownloads.containsKey(songId)) {
      _logger.debug('Download already in progress for ${song.title}');
      return _activeDownloads[songId]!.future;
    }
    
    // Check if already cached
    if (_cachedSongIds.contains(songId)) {
      _logger.debug('Song ${song.title} already cached, retrieving file');
      final cachedFile = await getCachedSongFile(songId);
      if (cachedFile != null && await cachedFile.exists()) {
        return cachedFile;
      }
      // File wasn't found despite being in our list, remove from list
      _cachedSongIds.remove(songId);
    }
    
    // Create a completer to track this download
    final completer = Completer<File>();
    _activeDownloads[songId] = completer;
    
    try {
      // Check network connectivity first
      final connectivityResult = await Connectivity().checkConnectivity();
      if (connectivityResult == ConnectivityResult.none) {
        throw Exception('No network connection available');
      }
      
      _logger.debug('Starting download of ${song.title}');
      
      // Download with Dio for better control and retry
      final file = await _downloadWithRetry(url, song);
      
      if (file != null) {
        _cachedSongIds.add(songId);
        _logger.debug('Successfully cached ${song.title}');
        completer.complete(file);
        return file;
      } else {
        throw Exception('Failed to download file');
      }
    } catch (e) {
      _logger.error('Error caching song ${song.title}', e);
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
      return null;
    } finally {
      _activeDownloads.remove(songId);
    }
  }
  
  /// Download a file with retry logic
  Future<File?> _downloadWithRetry(String url, Song song) async {
    int retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      try {
        // Convert Dio headers to String type
        Map<String, String> stringHeaders = {};
        _dio.options.headers.forEach((key, value) {
          if (value != null) {
            stringHeaders[key] = value.toString();
          }
        });
        
        // Use the cache manager for the actual download
        final fileInfo = await _cacheManager.downloadFile(
          url,
          key: url,
          authHeaders: stringHeaders,
        );
        return fileInfo.file;
      } catch (e) {
        retries++;
        if (retries >= maxRetries) {
          _logger.error('Max retries reached for ${song.title}', e);
          return null;
        }
        
        _logger.debug('Retry $retries for ${song.title}');
        // Exponential backoff
        await Future.delayed(Duration(seconds: 1 << retries));
      }
    }
    return null;
  }
  
  /// Pre-cache a list of songs for background playback
  /// This will download songs in order, with priority given to earlier songs
  Future<void> preCachePlaylist(List<Song> songs, {int maxSongs = 10}) async {
    if (songs.isEmpty) return;
    
    _logger.debug('Pre-caching ${songs.length} songs (up to $maxSongs)');
    
    // Limit to max songs
    final songsToCache = songs.take(maxSongs).toList();
    
    // Start downloading songs in sequence
    for (var song in songsToCache) {
      try {
        // Check network connectivity first
        final connectivityResult = await Connectivity().checkConnectivity();
        if (connectivityResult == ConnectivityResult.none) {
          _logger.debug('No network connection, pausing pre-cache operation');
          break;
        }
        
        // Fixed: properly await the Future<bool> returned by isSongCached
        if (!(await isSongCached(song.id))) {
          _logger.debug('Pre-caching song: ${song.title}');
          await cacheSong(song);
        } else {
          _logger.debug('Song already cached: ${song.title}');
        }
      } catch (e) {
        _logger.error('Error pre-caching song ${song.title}', e);
        // Continue with next song if one fails
      }
    }
  }
  
  /// Clean up old cached files to free space
  Future<void> cleanCache() async {
    try {
      await _cacheManager.emptyCache();
      _cachedSongIds.clear();
      _logger.debug('Cache cleaned');
    } catch (e) {
      _logger.error('Error cleaning cache', e);
    }
  }
  
  /// Get the total size of the cache in bytes
  Future<int> getCacheSize() async {
    try {
      int totalSize = 0;
      final cacheDir = await _getCacheDirectory();
      if (cacheDir == null) return 0;
      
      final cacheFolder = Directory('${cacheDir.path}/$_cacheKey');
      if (!await cacheFolder.exists()) return 0;
      
      // Calculate size by reading all files in the cache directory
      final entities = await cacheFolder.list(recursive: true).toList();
      for (var entity in entities) {
        if (entity is File) {
          try {
            final length = await entity.length();
            totalSize += length;
          } catch (e) {
            // Ignore errors for individual files
            _logger.debug('Error getting size for file: ${entity.path}');
          }
        }
      }
      
      _logger.debug('Total cache size: ${totalSize / (1024 * 1024)} MB');
      return totalSize;
    } catch (e) {
      _logger.error('Error calculating cache size', e);
      return 0;
    }
  }
}