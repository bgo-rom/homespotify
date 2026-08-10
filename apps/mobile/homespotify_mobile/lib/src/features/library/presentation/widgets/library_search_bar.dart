import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';
import '../library_filters.dart';

/// Barre de recherche de la bibliothèque (titre, artiste, album).
///
/// Écrit dans [librarySearchQueryProvider] : seuls la liste et le bouton
/// d'effacement réagissent, jamais l'AppBar ni le mini-player.
class LibrarySearchBar extends ConsumerStatefulWidget {
  const LibrarySearchBar({super.key, this.autofocus = false, this.onClose});

  final bool autofocus;
  final VoidCallback? onClose;

  @override
  ConsumerState<LibrarySearchBar> createState() => _LibrarySearchBarState();
}

class _LibrarySearchBarState extends ConsumerState<LibrarySearchBar> {
  late final TextEditingController _controller;
  late final LibrarySearchQuery _queryNotifier;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // Reprend la recherche de la session (l'écran peut être reconstruit).
    _controller = TextEditingController(
      text: ref.read(librarySearchQueryProvider),
    );
    _queryNotifier = ref.read(librarySearchQueryProvider.notifier);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 180),
      () => _queryNotifier.set(value),
    );
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    _queryNotifier.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final query = ref.watch(librarySearchQueryProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppLayout.gutter, 4, AppLayout.gutter, 8),
      child: TextField(
        key: const ValueKey('library-search-field'),
        controller: _controller,
        autofocus: widget.autofocus,
        onChanged: _onChanged,
        textInputAction: TextInputAction.search,
        style: theme.textTheme.bodyLarge?.copyWith(color: colors.textPrimary),
        cursorColor: colors.accent,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: colors.surface,
          hintText: 'Rechercher un titre, un artiste, un album',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: colors.textTertiary,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            color: colors.textSecondary,
            size: 20,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (query.isNotEmpty)
                IconButton(
                  tooltip: 'Effacer la recherche',
                  icon: Icon(
                    Icons.backspace_outlined,
                    color: colors.textSecondary,
                    size: 18,
                  ),
                  onPressed: _clear,
                ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: 'Fermer la recherche',
                  icon: Icon(
                    Icons.close_rounded,
                    color: colors.textSecondary,
                    size: 20,
                  ),
                  onPressed: widget.onClose,
                ),
            ],
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: AppRadius.chipRadius,
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
