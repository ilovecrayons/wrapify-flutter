class SyncJob {
  final String id;
  final String playlistId;
  final String playlistName;
  final String status; // 'queued', 'processing', 'completed', 'error'
  final double progress; // 0 to 1
  final String startTime;
  final String? endTime;
  final String? error;
  
  SyncJob({
    required this.id,
    required this.playlistId,
    required this.playlistName,
    required this.status,
    required this.progress,
    required this.startTime,
    this.endTime,
    this.error,
  });
  
  factory SyncJob.fromJson(Map<String, dynamic> json) {
    return SyncJob(
      id: json['jobId'],
      playlistId: json['playlistId'] ?? '',
      playlistName: json['playlistName'] ?? 'Unknown Playlist',
      status: json['status'] ?? 'unknown',
      progress: (json['progress'] is num) ? json['progress'].toDouble() : 0.0,
      startTime: json['startTime'] ?? DateTime.now().toIso8601String(),
      endTime: json['endTime'],
      error: json['error'],
    );
  }
  
  Map<String, dynamic> toJson() {
    return {
      'jobId': id,
      'playlistId': playlistId,
      'playlistName': playlistName,
      'status': status,
      'progress': progress,
      'startTime': startTime,
      'endTime': endTime,
      'error': error,
    };
  }
  
  bool get isComplete => status == 'completed';
  bool get isError => status == 'error';
  bool get isProcessing => status == 'processing';
  bool get isQueued => status == 'queued';
}