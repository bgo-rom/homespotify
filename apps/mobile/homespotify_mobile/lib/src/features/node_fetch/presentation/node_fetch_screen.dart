import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../application/node_fetch_controller.dart';

const Color _background = Color(0xFF0D0D10);
const Color _card = Color(0xFF1A1A22);
const Color _accent = Color(0xFF1DB954);

class NodeFetchScreen extends ConsumerStatefulWidget {
  const NodeFetchScreen({super.key});

  @override
  ConsumerState<NodeFetchScreen> createState() => _NodeFetchScreenState();
}

class _NodeFetchScreenState extends ConsumerState<NodeFetchScreen> {
  final TextEditingController _urlController = TextEditingController();
  String? _fieldError;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _urlController.text.trim();
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty) {
      setState(() {
        _fieldError = 'Saisis une URL HTTPS valide sans identifiants intégrés.';
      });
      return;
    }
    final user = ref.read(authControllerProvider).user;
    if (user == null) {
      setState(() => _fieldError = 'Authentification requise.');
      return;
    }
    setState(() => _fieldError = null);
    await ref
        .read(nodeFetchControllerProvider.notifier)
        .submit(url: value, userId: user.id);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nodeFetchControllerProvider);
    final user = ref.watch(
      authControllerProvider.select((authState) => authState.user),
    );
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        title: const Text(
          'Importer depuis un nœud',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          const Text(
            'URL du fichier audio',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Le serveur accepte uniquement les origines HTTPS configurées. '
            'Le fichier est déposé dans ton inbox puis vérifié par le watcher.',
            style: TextStyle(color: Colors.white54, height: 1.4),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const ValueKey('node-fetch-url-field'),
            controller: _urlController,
            enabled: !state.isActive,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.send,
            autocorrect: false,
            enableSuggestions: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'https://audio.exemple.fr/piste.flac',
              labelStyle: const TextStyle(color: Colors.white54),
              errorText: _fieldError,
              prefixIcon: const Icon(Icons.link_rounded, color: _accent),
              filled: true,
              fillColor: _card,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Colors.white12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: _accent),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Colors.white10),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFE57373)),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: const BorderSide(color: Color(0xFFE57373)),
              ),
            ),
            onSubmitted: state.isActive ? null : (_) => _submit(),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              key: const ValueKey('node-fetch-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
                disabledBackgroundColor: _accent.withValues(alpha: 0.35),
              ),
              onPressed: state.isActive || user == null ? null : _submit,
              icon: state.phase == NodeFetchPhase.submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.black54,
                      ),
                    )
                  : const Icon(Icons.cloud_download_rounded),
              label: const Text('Envoyer au serveur'),
            ),
          ),
          if (state.phase != NodeFetchPhase.idle) ...[
            const SizedBox(height: 20),
            _NodeFetchStatusCard(state: state),
          ],
          if (state.phase == NodeFetchPhase.monitoringPaused) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('node-fetch-resume-monitoring'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _accent,
                side: const BorderSide(color: _accent),
              ),
              onPressed: () => ref
                  .read(nodeFetchControllerProvider.notifier)
                  .resumeMonitoring(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Reprendre le suivi'),
            ),
          ],
          if (state.phase == NodeFetchPhase.readyForImport ||
              state.phase == NodeFetchPhase.failed) ...[
            const SizedBox(height: 12),
            TextButton.icon(
              key: const ValueKey('node-fetch-reset'),
              onPressed: () {
                ref.read(nodeFetchControllerProvider.notifier).reset();
                _urlController.clear();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nouvel import'),
            ),
          ],
        ],
      ),
    );
  }
}

class _NodeFetchStatusCard extends StatelessWidget {
  const _NodeFetchStatusCard({required this.state});

  final NodeFetchState state;

  @override
  Widget build(BuildContext context) {
    final failed = state.phase == NodeFetchPhase.failed;
    final complete = state.phase == NodeFetchPhase.readyForImport;
    final color = failed
        ? const Color(0xFFE57373)
        : complete
        ? _accent
        : const Color(0xFF64B5F6);
    return DecoratedBox(
      key: const ValueKey('node-fetch-status-card'),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.phase == NodeFetchPhase.submitting ||
                state.phase == NodeFetchPhase.queued ||
                state.phase == NodeFetchPhase.fetching)
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              Icon(
                failed
                    ? Icons.error_outline_rounded
                    : complete
                    ? Icons.check_circle_outline_rounded
                    : Icons.cloud_sync_rounded,
                color: color,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    state.message ?? 'Traitement en cours…',
                    key: const ValueKey('node-fetch-status-message'),
                    style: const TextStyle(color: Colors.white, height: 1.35),
                  ),
                  if (state.filename != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      state.filename!,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                  if (state.bytesReceived > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      _formatBytes(state.bytesReceived),
                      style: const TextStyle(color: Colors.white38),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} Mo reçus';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} Ko reçus';
    return '$bytes octets reçus';
  }
}
