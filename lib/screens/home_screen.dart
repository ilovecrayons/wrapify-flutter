import 'package:flutter/material.dart';
import '../models/playlist.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import 'playlist_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.title});

  final String title;

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
          content: Text('Syncing playlist... This may take a while.'),
          duration: Duration(seconds: 3),
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

      // Start syncing the playlist (this won't wait for completion)
      await _apiService.syncPlaylist(spotifyUrl);

      // Create a placeholder playlist until we get full details
      final newPlaylist = Playlist(
        id: playlistId,
        name: 'New Playlist (syncing...)',
        spotifyUrl: spotifyUrl,
      );

      // Save and update the UI
      await _storageService.addPlaylist(newPlaylist);
      await _loadPlaylists();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Playlist added! Songs are syncing in the background.'),
          backgroundColor: Colors.green,
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
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => PlaylistScreen(
                              playlistId: playlist.id,
                            ),
                          ),
                        );
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