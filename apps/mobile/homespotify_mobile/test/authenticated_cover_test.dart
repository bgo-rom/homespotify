import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/core/network/authenticated_artwork_cache.dart';
import 'package:homespotify_mobile/src/core/network/authenticated_network_image.dart';
import 'package:homespotify_mobile/src/features/auth/data/token_store.dart';

import 'support/fake_auth.dart';

void main() {
  test('la résolution du cache local termine son Future', () async {
    final root = await Directory.systemTemp.createTemp(
      'homespotify_artwork_test_',
    );
    addTearDown(() => root.delete(recursive: true));
    final directory = Directory('${root.path}/homespotify_artwork');
    await directory.create();
    final file = File('${directory.path}/user_3_track_68_cover-v1.jpg');
    await file.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9], flush: true);
    final cache = AuthenticatedArtworkCache(
      Dio(),
      cacheDirectory: () async => root,
    );

    final resolved = await cache
        .resolve(
          userId: 3,
          trackId: 68,
          coverUri: Uri.parse('https://homespotify.test/api/tracks/68/cover'),
          coverIdentity: 'cover-v1',
        )
        .timeout(const Duration(seconds: 1));

    expect(resolved, file.uri);
  });

  testWidgets('la cover protégée suit le token courant après renouvellement', (
    tester,
  ) async {
    final store = FakeTokenStore();
    final session = FakeSessionManager(store: store);
    await session.storeSession(
      const AuthTokens(accessToken: 'first', refreshToken: 'refresh-1'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: authOverrides(tokenStore: store, sessionManager: session),
        child: const MaterialApp(
          home: AuthenticatedNetworkImage(
            'https://homespotify.test/api/tracks/67/cover',
            errorBuilder: _placeholder,
          ),
        ),
      ),
    );

    NetworkImage imageProvider() =>
        tester.widget<Image>(find.byType(Image)).image as NetworkImage;
    expect(imageProvider().headers, const {'Authorization': 'Bearer first'});

    await session.storeSession(
      const AuthTokens(accessToken: 'second', refreshToken: 'refresh-2'),
    );
    await tester.pump();
    expect(imageProvider().headers, const {'Authorization': 'Bearer second'});
    expect(imageProvider().url, isNot(contains('Bearer')));
  });
}

Widget _placeholder(
  BuildContext context,
  Object error,
  StackTrace? stackTrace,
) => const SizedBox.shrink();
