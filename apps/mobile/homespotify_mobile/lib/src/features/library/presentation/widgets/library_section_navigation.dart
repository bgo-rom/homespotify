import 'package:flutter/material.dart';

import '../../../../app/navigation.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';

class LibrarySectionNavigation extends StatelessWidget {
  const LibrarySectionNavigation({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
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
        padding: const EdgeInsets.symmetric(horizontal: AppLayout.gutter),
        itemCount: destinations.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final destination = destinations[index];
          final selected = destination.onTap == null;
          final ink = selected ? colors.onAccent : colors.textSecondary;
          return ChoiceChip(
            selected: selected,
            showCheckmark: false,
            avatar: Icon(destination.icon, size: 18, color: ink),
            label: Text(destination.label),
            labelStyle: theme.textTheme.labelLarge?.copyWith(
              color: ink,
              fontWeight: FontWeight.w600,
            ),
            selectedColor: colors.accent,
            backgroundColor: colors.surface,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
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
