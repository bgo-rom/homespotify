import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    final query = ref.watch(librarySearchQueryProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: const ValueKey('library-search-field'),
        controller: _controller,
        autofocus: widget.autofocus,
        onChanged: _onChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(color: Colors.white, fontSize: 14.5),
        cursorColor: const Color(0xFF1DB954),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF1F1F26),
          hintText: 'Rechercher un titre, un artiste, un album',
          hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
          prefixIcon: const Icon(
            Icons.search_rounded,
            color: Colors.white54,
            size: 20,
          ),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (query.isNotEmpty)
                IconButton(
                  tooltip: 'Effacer la recherche',
                  icon: const Icon(
                    Icons.backspace_outlined,
                    color: Colors.white54,
                    size: 18,
                  ),
                  onPressed: _clear,
                ),
              if (widget.onClose != null)
                IconButton(
                  tooltip: 'Fermer la recherche',
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white54,
                    size: 20,
                  ),
                  onPressed: widget.onClose,
                ),
            ],
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}
