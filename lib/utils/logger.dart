import 'package:flutter/foundation.dart';

/// A simple logging utility that only prints in debug mode
class Logger {
  /// The tag used to identify the source of a log message
  final String tag;
  
  /// Creates a new Logger with the specified tag
  Logger(this.tag);
  
  /// Logs an information message
  void info(String message) {
    _log('INFO', message);
  }
  
  /// Logs an error message
  void error(String message, [Object? error, StackTrace? stackTrace]) {
    _log('ERROR', message);
    
    // Only print the error and stack trace in debug mode
    if (kDebugMode && error != null) {
      print('$tag ERROR: $error');
      if (stackTrace != null) {
        print('$tag STACK TRACE: $stackTrace');
      }
    }
  }
  
  /// Logs a debug message
  void debug(String message) {
    _log('DEBUG', message);
  }
  
  /// Logs a warning message
  void warning(String message) {
    _log('WARNING', message);
  }
  
  /// Internal logging method that only prints in debug mode
  void _log(String level, String message) {
    if (kDebugMode) {
      print('$tag $level: $message');
    }
  }
}