import 'package:flutter/material.dart';

import '../../../../app/navigation.dart';
import '../../../../core/theme/home_design.dart';

class LibrarySectionNavigation extends StatelessWidget {
  const LibrarySectionNavigation({super.key});

  @override
  Widget build(BuildContext context) {
    final destinations = <_LibraryDestination>[
      const _LibraryDestination('Titres', Icons.music_note_rounded, null),
      _LibraryDestination('Albums', Icons.album_outlined, () {
        openAlbums(context);
      }),
      _LibraryDestination('Artistes', Icons.people_alt_outlined, () {
        openArtists(context);
      }),
      _LibraryDestination('Favoris', Icons.favorite_border_rounded, () {
        openFavorites(context);
      }),
      _LibraryDestination('Playlists', Icons.queue_music_rounded, () {
        openPlaylists(context);
      }),
    ];
    return SizedBox(
      height: 48,
      child: ListView.separated(
        key: const PageStorageKey<String>('library-section-navigation'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: destinations.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final destination = destinations[index];
          final selected = destination.onTap == null;
          return ChoiceChip(
            selected: selected,
            showCheckmark: false,
            avatar: Icon(
              destination.icon,
              size: 18,
              color: selected ? Colors.black : Colors.white70,
            ),
            label: Text(destination.label),
            labelStyle: TextStyle(
              color: selected ? Colors.black : Colors.white70,
              fontWeight: FontWeight.w600,
            ),
            selectedColor: HomeDesign.accent,
            backgroundColor: HomeDesign.surface,
            side: BorderSide.none,
            onSelected: (_) => destination.onTap?.call(),
          );
        },
      ),
    );
  }
}

class _LibraryDestination {
  const _LibraryDestination(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
}
