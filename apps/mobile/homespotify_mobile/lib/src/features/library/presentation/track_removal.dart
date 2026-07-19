import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../catalog/data/catalog_api.dart';
import '../application/track_library_membership.dart';
import '../data/library_api.dart';

const Color _card = Color(0xFF1A1A22);

/// Dialogue de confirmation puis retrait d'une piste de la bibliothèque du
/// compte courant, via le contrôleur CENTRAL [trackMembershipProvider].
///
/// Côté serveur, seul l'ACCÈS de ce compte est retiré : le fichier physique et
/// la ligne `tracks` restent, les autres comptes ne sont pas affectés, et la
/// piste reste publiée au catalogue global.
///
/// ⚠️ La LECTURE N'EST JAMAIS INTERROMPUE : retirer une piste de sa
/// bibliothèque ne signifie pas arrêter son écoute depuis le catalogue global.
/// La file, le `currentMediaItem`, la position et l'AudioSource sont intacts.
///
/// Aucun faux succès : le message « retiré » n'apparaît QUE si le backend a
/// réellement supprimé une association (`deleteTrack == true`).
Future<void> confirmAndRemoveTrackFromLibrary(
  BuildContext context,
  WidgetRef ref, {
  required int trackId,
  required String title,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: _card,
      title: const Text(
        'Supprimer de ma bibliothèque ?',
        style: TextStyle(color: Colors.white),
      ),
      content: Text(
        '« $title » sera retiré de ta bibliothèque, de tes favoris et de tes '
        'playlists. Le fichier reste sur le serveur et les autres comptes ne '
        'sont pas affectés.',
        style: const TextStyle(color: Colors.white70),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Garder', style: TextStyle(color: Colors.white54)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE57373),
            foregroundColor: Colors.black,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Supprimer'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  logUi('suppression bibliothèque demandée track=$trackId ("$title")');
  final controller = ref.read(trackLibraryMembershipProvider.notifier);
  try {
    final removed = await controller.removeFromMyLibrary(trackId);
    if (!context.mounted) return;
    if (!removed) {
      // La piste n'était PAS dans la bibliothèque : surtout aucun faux message
      // de suppression. L'état est déjà resynchronisé sur « absente ».
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Supprimé de votre bibliothèque')),
    );
  } on LibraryApiException catch (error) {
    // Échec réel : le contrôleur a déjà restauré l'état (rollback).
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Suppression impossible : ${error.message}')),
    );
  }
}

/// Ajoute une piste (du catalogue global ou d'ailleurs) à la bibliothèque du
/// compte courant, via le même contrôleur central. Idempotent, n'affecte aucun
/// autre compte, ne duplique ni le fichier ni la ligne `tracks`, et
/// n'interrompt jamais la lecture en cours.
Future<void> addTrackToLibraryWithFeedback(
  BuildContext context,
  WidgetRef ref, {
  required int trackId,
  required String title,
}) async {
  logUi('ajout bibliothèque demandé track=$trackId ("$title")');
  final controller = ref.read(trackLibraryMembershipProvider.notifier);
  try {
    await controller.addToMyLibrary(trackId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ajouté à votre bibliothèque')),
    );
  } on CatalogApiException catch (error) {
    // Rollback déjà effectué par le contrôleur : aucun faux succès.
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Ajout impossible : ${error.message}')),
    );
  }
}
