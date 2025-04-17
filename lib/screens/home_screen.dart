import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

class HomeScreen extends StatefulWidget {
  final String title;
  final Function(String)? onPlaylistSelected;

  const HomeScreen({
    super.key, 
    required this.title, 
    this.onPlaylistSelected,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ApiService _apiService = ApiService();
  final StorageService _storageService = StorageService();
  List<Playlist> _playlists = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  Future<void> _loadPlaylists() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final playlists = await _storageService.loadPlaylists();
      setState(() {
        _playlists = playlists;
        _isLoading = false;
      });
    } catch (e) {
      print('Error loading playlists: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _addPlaylist(String spotifyUrl) async {
    try {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Starting playlist sync...'),
          duration: Duration(seconds: 2),
        ),
      );

      // Extract playlist ID from the Spotify URL
      final playlistId = ApiService.extractPlaylistId(spotifyUrl);
      
      if (playlistId.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Invalid Spotify playlist URL'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Check if playlist already exists
      if (_playlists.any((p) => p.id == playlistId)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist already exists'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // Start syncing the playlist (this returns immediately with job details)
      final syncJob = await _apiService.syncPlaylist(spotifyUrl);
      
      // Create a placeholder playlist with the name from the API
      final newPlaylist = Playlist(
        id: playlistId,
        name: syncJob.playlistName,
        spotifyUrl: spotifyUrl,
        syncJobId: syncJob.id,
      );

      // Save and update the UI
      await _storageService.addPlaylist(newPlaylist);
      await _storageService.saveSyncJob(syncJob);
      await _loadPlaylists();

      // Start polling for status updates in the background
      _pollSyncStatus(syncJob.id, playlistId);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Added "${syncJob.playlistName}". Songs are syncing in the background.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    } catch (e) {
      print('Error adding playlist: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error adding playlist: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  // Poll for sync status updates
  void _pollSyncStatus(String jobId, String playlistId) async {
    bool isComplete = false;
    int attempts = 0;
    const maxAttempts = 30; // Poll for a maximum of 5 minutes (10 seconds * 30)
    
    while (!isComplete && attempts < maxAttempts) {
      try {
        await Future.delayed(Duration(seconds: 10));
        final syncJob = await _apiService.getSyncStatus(jobId);
        await _storageService.saveSyncJob(syncJob);
        
        print('Sync status: ${syncJob.status}, Progress: ${syncJob.progress}');
        
        // If the job is complete or has an error, stop polling
        if (syncJob.isComplete || syncJob.isError) {
          isComplete = true;
          
          // Update the playlist with the final information
          if (syncJob.isComplete) {
            // Reload playlists to get the updated one
            if (mounted) {
              await _loadPlaylists();
              
              // Check for any song errors
              await _checkForSongErrors(playlistId);
            }
          } else if (syncJob.isError && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error syncing playlist: ${syncJob.error ?? "Unknown error"}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        
        attempts++;
      } catch (e) {
        print('Error polling sync status: $e');
        attempts++;
        
        // If too many errors, just stop polling
        if (attempts > 5) {
          isComplete = true;
        }
      }
    }
  }
  
  // Check for song errors and update storage
  Future<void> _checkForSongErrors(String playlistId) async {
    try {
      final errorsData = await _apiService.getPlaylistErrors(playlistId);
      
      if (errorsData['errorCount'] > 0 && errorsData['songs'] is List && errorsData['songs'].isNotEmpty) {
        // Save the error information
        await _storageService.saveSongErrors(
          playlistId, 
          List<Map<String, dynamic>>.from(errorsData['songs'])
        );
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sync completed with ${errorsData['errorCount']} song errors'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Playlist sync completed successfully!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('Error checking for song errors: $e');
    }
  }

  void _showAddPlaylistDialog() {
    final TextEditingController controller = TextEditingController();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add Spotify Playlist'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://open.spotify.com/playlist/...',
              labelText: 'Spotify Playlist URL',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                if (controller.text.isNotEmpty) {
                  _addPlaylist(controller.text);
                }
              },
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        title: Text(widget.title),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _playlists.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'No playlists yet',
                        style: TextStyle(fontSize: 18),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _showAddPlaylistDialog,
                        child: const Text('Add a Spotify Playlist'),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = _playlists[index];
                    return ListTile(
                      leading: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: playlist.imageUrl != null
                            ? Image.network(playlist.imageUrl!, fit: BoxFit.cover)
                            : const Icon(Icons.music_note),
                      ),
                      title: Text(playlist.name),
                      subtitle: Text('${playlist.songIds.length} songs'),
                      onTap: () {
                        // Use the callback for navigation instead of Navigator.push
                        if (widget.onPlaylistSelected != null) {
                          widget.onPlaylistSelected!(playlist.id);
                        }
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Delete Playlist'),
                              content: const Text(
                                'Are you sure you want to remove this playlist? '
                                'This will only remove it from your device.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(context).pop(true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );

                          if (confirmed == true) {
                            await _storageService.removePlaylist(playlist.id);
                            await _loadPlaylists();
                          }
                        },
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddPlaylistDialog,
        tooltip: 'Add Playlist',
        child: const Icon(Icons.add),
      ),
    );
  }
}