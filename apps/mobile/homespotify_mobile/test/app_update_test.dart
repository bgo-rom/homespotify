import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/core/platform/app_update_installer.dart';
import 'package:homespotify_mobile/src/features/app_update/application/app_update_controller.dart';
import 'package:homespotify_mobile/src/features/app_update/application/app_update_service.dart';
import 'package:homespotify_mobile/src/features/app_update/data/app_update_api.dart';
import 'package:homespotify_mobile/src/features/app_update/domain/app_update_models.dart';
import 'package:homespotify_mobile/src/features/app_update/presentation/app_update_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_app_update.dart';

const _packageName = 'com.homespotify.homespotify_mobile';
const _certSha256 =
    '9d461189865d0d1f3774ae06a4bbf84f13c890c471b3e8d2082887006a5a78d6';
const _latestPath = '/api/app-update/android/latest';

late Directory cacheDir;
late FakeUpdateAdapter adapter;
late FakeAppUpdateInstaller installer;
late FakeStoragePlatform storage;

/// APK factice DÉTERMINISTE : le SHA-256 du manifeste correspond réellement.
final Uint8List apkBytes = Uint8List.fromList(
  List<int>.generate(4096, (index) => index % 251),
);
final String apkSha256 = sha256.convert(apkBytes).toString();

Map<String, Object?> manifest({
  int versionCode = 11,
  String versionName = '1.0.0',
  bool required = false,
  int minSupportedVersionCode = 1,
  int? sizeBytes,
  String? sha,
  String? cert,
  List<String> notes = const ['Test du système de mise à jour HomeSpotify'],
}) {
  return {
    'platform': 'android',
    'packageName': _packageName,
    'versionCode': versionCode,
    'versionName': versionName,
    'required': required,
    'minSupportedVersionCode': minSupportedVersionCode,
    'sizeBytes': sizeBytes ?? apkBytes.length,
    'sha256': sha ?? apkSha256,
    'signingCertSha256': cert ?? _certSha256,
    'releaseNotes': notes,
    'publishedAt': '2026-08-10T12:00:00.000Z',
    'downloadPath': '/api/app-update/android/download/$versionCode',
  };
}

void enqueueLatest(Map<String, Object?>? latest, {bool updateAvailable = true}) {
  adapter.enqueue(
    _latestPath,
    FakeUpdateResponse.json(200, {
      'updateAvailable': latest != null && updateAvailable,
      'latest': latest,
    }),
  );
}

void enqueueApk({
  int versionCode = 11,
  int statusCode = 200,
  Uint8List? bytes,
  int? failAfterBytes,
}) {
  adapter.enqueue(
    '/api/app-update/android/download/$versionCode',
    FakeUpdateResponse.binary(
      statusCode,
      bytes ?? apkBytes,
      failAfterBytes: failAfterBytes,
    ),
  );
}

AppUpdateService buildService({int currentVersionCode = 10}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://update.test'))
    ..httpClientAdapter = adapter;
  return AppUpdateService(
    api: AppUpdateApi(dio),
    installer: installer,
    storage: storage,
    cacheDirProvider: fixedCacheDir(cacheDir),
    currentVersionReader: () async => InstalledAppVersion(
      packageName: _packageName,
      versionName: '1.0.0',
      versionCode: currentVersionCode,
    ),
  );
}

ProviderContainer buildContainer({int currentVersionCode = 10}) {
  final container = ProviderContainer(
    overrides: [
      appUpdateServiceProvider.overrideWithValue(
        buildService(currentVersionCode: currentVersionCode),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Identité renvoyée par le PackageManager simulé.
ApkIdentity identity({
  int versionCode = 11,
  String packageName = _packageName,
  String cert = _certSha256,
}) {
  return ApkIdentity(
    packageName: packageName,
    versionCode: versionCode,
    versionName: '1.0.0',
    signingCertSha256: [cert],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    cacheDir = Directory.systemTemp.createTempSync('homespotify-update-test-');
    adapter = FakeUpdateAdapter();
    installer = FakeAppUpdateInstaller(
      identityBuilder: (_) => identity(),
    );
    storage = FakeStoragePlatform();
  });

  tearDown(() {
    if (cacheDir.existsSync()) cacheDir.deleteSync(recursive: true);
  });

  group('vérification', () {
    test('1. aucune version publiée : rien à installer', () async {
      enqueueLatest(null);
      final check = await buildService().check();
      expect(check.latest, isNull);
      expect(check.updateAvailable, isFalse);
      expect(check.mandatory, isFalse);
    });

    test('2. une version plus récente est disponible', () async {
      enqueueLatest(manifest(versionCode: 11));
      final check = await buildService(currentVersionCode: 10).check();
      expect(check.updateAvailable, isTrue);
      expect(check.latest!.versionCode, 11);
      expect(check.latest!.releaseNotes, isNotEmpty);
      expect(check.mandatory, isFalse);
    });

    test('3. version identique : aucune mise à jour', () async {
      enqueueLatest(manifest(versionCode: 11));
      final check = await buildService(currentVersionCode: 11).check();
      expect(check.updateAvailable, isFalse);
    });

    test('4. serveur en retard sur l’appareil : aucune mise à jour', () async {
      enqueueLatest(manifest(versionCode: 9));
      final check = await buildService(currentVersionCode: 11).check();
      expect(check.updateAvailable, isFalse);
      expect(check.mandatory, isFalse);
    });

    test('5. mise à jour déclarée obligatoire', () async {
      enqueueLatest(manifest(versionCode: 11, required: true));
      final check = await buildService(currentVersionCode: 10).check();
      expect(check.mandatory, isTrue);
    });

    test('6. version installée sous minSupportedVersionCode', () async {
      enqueueLatest(manifest(versionCode: 11, minSupportedVersionCode: 11));
      final check = await buildService(currentVersionCode: 10).check();
      expect(check.mandatory, isTrue);
    });

    test('7. réponse malformée : refusée, jamais interprétée', () async {
      adapter.enqueue(
        _latestPath,
        FakeUpdateResponse.json(200, {
          'updateAvailable': true,
          'latest': {'versionCode': 'onze'},
        }),
      );
      await expectLater(
        buildService().check(),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('8. backend injoignable : exception présentable', () async {
      adapter.enqueue(
        _latestPath,
        FakeUpdateResponse.networkFailure(
          DioException.connectionError(
            requestOptions: RequestOptions(path: _latestPath),
            reason: 'DNS',
          ),
        ),
      );
      await expectLater(
        buildService().check(),
        throwsA(isA<AppUpdateException>()),
      );
    });

    test('9. serveur sans service de mise à jour (503) : silencieux', () async {
      adapter.enqueue(_latestPath, FakeUpdateResponse.json(503, {}));
      final check = await buildService().check();
      expect(check.latest, isNull);
      expect(check.updateAvailable, isFalse);
    });
  });

  group('téléchargement', () {
    test('10. progression jusqu’à la copie complète et vérifiée', () async {
      final service = buildService();
      enqueueApk();
      final progress = <int>[];
      final release = AndroidRelease.tryParse(manifest())!;

      final file = await service.download(
        release,
        onProgress: (received, _) => progress.add(received),
      );

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), apkBytes.length);
      expect(progress, isNotEmpty);
      expect(progress.last, apkBytes.length);
      expect(File('${file.path}.part').existsSync(), isFalse);
      await service.verify(file, release);
    });

    test('11. coupure réseau : .part conservé, aucune APK publiée', () async {
      final service = buildService();
      enqueueApk(failAfterBytes: 1500);
      final release = AndroidRelease.tryParse(manifest())!;

      await expectLater(
        service.download(release),
        throwsA(isA<DioException>()),
      );

      final target = service.apkFile(await service.updateDirectory(), 11);
      expect(target.existsSync(), isFalse);
      final part = File('${target.path}.part');
      expect(part.existsSync(), isTrue);
      expect(part.lengthSync(), 1500);
    });

    test('12. reprise : la seconde tentative demande un Range', () async {
      final service = buildService();
      enqueueApk(failAfterBytes: 1500);
      final release = AndroidRelease.tryParse(manifest())!;
      await expectLater(
        service.download(release),
        throwsA(isA<DioException>()),
      );

      // Le serveur répond maintenant correctement à la reprise.
      adapter.responses.remove('/api/app-update/android/download/11');
      adapter.enqueue(
        '/api/app-update/android/download/11',
        FakeUpdateResponse.binary(
          206,
          Uint8List.sublistView(apkBytes, 1500),
        ),
      );
      final file = await service.download(release);

      expect(file.lengthSync(), apkBytes.length);
      expect(sha256.convert(file.readAsBytesSync()).toString(), apkSha256);
      expect(adapter.requests.last.headers['Range'], 'bytes=1500-');
    });

    test('13. espace disque insuffisant : refus avant tout octet', () async {
      storage.free = 1024;
      final service = buildService();
      enqueueApk();
      await expectLater(
        service.download(AndroidRelease.tryParse(manifest())!),
        throwsA(
          isA<AppUpdateException>().having(
            (error) => error.canRetry,
            'canRetry',
            isFalse,
          ),
        ),
      );
    });

    test('14. anciennes APK et .part obsolètes sont nettoyés', () async {
      final service = buildService();
      final directory = await service.updateDirectory();
      File('${directory.path}/homespotify-9.apk').writeAsStringSync('vieux');
      File('${directory.path}/homespotify-10.apk.part').writeAsStringSync('x');

      enqueueApk();
      await service.download(AndroidRelease.tryParse(manifest())!);

      final remaining = directory
          .listSync()
          .map((entity) => entity.uri.pathSegments.last)
          .toList();
      expect(remaining, ['homespotify-11.apk']);
    });
  });

  group('vérification de l’APK', () {
    test('15. SHA-256 incorrect : fichier supprimé, jamais installé', () async {
      final service = buildService();
      enqueueApk();
      final release = AndroidRelease.tryParse(manifest())!;
      final file = await service.download(release);

      final falsified = AndroidRelease.tryParse(manifest(sha: 'b' * 64))!;
      await expectLater(
        service.verify(file, falsified),
        throwsA(isA<AppUpdateException>()),
      );
      expect(file.existsSync(), isFalse);
      expect(installer.installCalls, 0);
    });

    test('16. taille incorrecte : rejet immédiat', () async {
      final service = buildService();
      enqueueApk();
      final release = AndroidRelease.tryParse(manifest())!;
      final file = await service.download(release);

      final falsified = AndroidRelease.tryParse(manifest(sizeBytes: 999))!;
      await expectLater(
        service.verify(file, falsified),
        throwsA(isA<AppUpdateException>()),
      );
      expect(file.existsSync(), isFalse);
    });

    test('17. signature ou paquet inattendus : rejet', () async {
      final release = AndroidRelease.tryParse(manifest())!;

      installer.identityBuilder = (_) => identity(cert: 'a' * 64);
      var service = buildService();
      enqueueApk();
      var file = await service.download(release);
      await expectLater(
        service.verify(file, release),
        throwsA(isA<AppUpdateException>()),
      );
      expect(file.existsSync(), isFalse);

      installer.identityBuilder = (_) => identity(packageName: 'com.autre.app');
      service = buildService();
      enqueueApk();
      file = await service.download(release);
      await expectLater(
        service.verify(file, release),
        throwsA(isA<AppUpdateException>()),
      );
      expect(installer.installCalls, 0);
    });
  });

  group('contrôleur et installation', () {
    test('18. parcours complet : téléchargement → installateur ouvert', () async {
      final container = buildContainer();
      enqueueLatest(manifest());
      enqueueApk();
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkManually();
      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.available,
      );

      await controller.downloadAndInstall();
      final state = container.read(appUpdateControllerProvider);
      expect(state.phase, AppUpdatePhase.installing);
      expect(installer.installCalls, 1);
      expect(installer.lastInstalledPath, endsWith('homespotify-11.apk'));
    });

    test('19. autorisation Android absente : état permissionRequired', () async {
      installer.installAllowed = false;
      final container = buildContainer();
      enqueueLatest(manifest());
      enqueueApk();
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkManually();
      await controller.downloadAndInstall();

      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.permissionRequired,
      );
      expect(installer.installCalls, 0);

      await controller.openInstallSettings();
      expect(installer.settingsCalls, 1);
    });

    test('20. autorisation accordée puis retour : installation reprise', () async {
      installer.installAllowed = false;
      final container = buildContainer();
      enqueueLatest(manifest());
      enqueueApk();
      final controller = container.read(appUpdateControllerProvider.notifier);
      await controller.checkManually();
      await controller.downloadAndInstall();
      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.permissionRequired,
      );

      installer.installAllowed = true;
      await controller.handleAppResumed();

      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.installing,
      );
      expect(installer.installCalls, 1);
    });

    test('21. « Plus tard » masque l’assistant, jamais si obligatoire', () async {
      final container = buildContainer();
      enqueueLatest(manifest());
      final controller = container.read(appUpdateControllerProvider.notifier);
      await controller.checkManually();

      controller.postpone();
      expect(container.read(appUpdateControllerProvider).postponed, isTrue);
      expect(container.read(appUpdateControllerProvider).shouldPrompt, isFalse);

      final mandatory = buildContainer();
      adapter.responses.clear();
      enqueueLatest(manifest(required: true));
      final mandatoryController = mandatory.read(
        appUpdateControllerProvider.notifier,
      );
      await mandatoryController.checkManually();
      mandatoryController.postpone();
      expect(mandatory.read(appUpdateControllerProvider).postponed, isFalse);
      expect(mandatory.read(appUpdateControllerProvider).shouldPrompt, isTrue);
    });

    test('22. backend indisponible : l’application reste utilisable', () async {
      final container = buildContainer();
      adapter.enqueue(
        _latestPath,
        FakeUpdateResponse.networkFailure(
          DioException.connectionTimeout(
            timeout: const Duration(seconds: 1),
            requestOptions: RequestOptions(path: _latestPath),
          ),
        ),
      );

      await container
          .read(appUpdateControllerProvider.notifier)
          .checkAutomatically();

      final state = container.read(appUpdateControllerProvider);
      expect(state.phase, AppUpdatePhase.idle);
      expect(state.shouldPrompt, isFalse);
      // Vérification automatique : aucune erreur n'est imposée à l'écran.
      expect(state.message, isNull);
    });

    test('23. JSON invalide en vérification automatique : silencieux', () async {
      final container = buildContainer();
      adapter.enqueue(
        _latestPath,
        FakeUpdateResponse.rawJson(200, '{"latest": {"versionCode": '),
      );

      await container
          .read(appUpdateControllerProvider.notifier)
          .checkAutomatically();

      final state = container.read(appUpdateControllerProvider);
      expect(state.phase, AppUpdatePhase.idle);
      expect(state.shouldPrompt, isFalse);
    });

    test('24. throttling : une seule vérification automatique', () async {
      final container = buildContainer();
      enqueueLatest(manifest());
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkAutomatically();
      await controller.checkAutomatically();
      await controller.checkAutomatically();

      expect(
        adapter.requests.where((r) => r.path == _latestPath).length,
        1,
      );
    });

    test('25. la vérification manuelle ignore le throttling', () async {
      final container = buildContainer();
      enqueueLatest(manifest());
      final controller = container.read(appUpdateControllerProvider.notifier);

      await controller.checkAutomatically();
      await controller.checkManually();

      expect(
        adapter.requests.where((r) => r.path == _latestPath).length,
        2,
      );
    });

    test('26. plus de mise à jour : les fichiers locaux sont nettoyés', () async {
      final container = buildContainer(currentVersionCode: 11);
      final service = container.read(appUpdateServiceProvider);
      final directory = await service.updateDirectory();
      File('${directory.path}/homespotify-11.apk').writeAsStringSync('ancien');

      enqueueLatest(manifest(versionCode: 11), updateAvailable: false);
      await container
          .read(appUpdateControllerProvider.notifier)
          .checkManually();

      expect(
        container.read(appUpdateControllerProvider).phase,
        AppUpdatePhase.upToDate,
      );
      expect(directory.listSync(), isEmpty);
    });
  });

  group('interface', () {
    testWidgets('27. l’assistant se superpose sans démonter l’application', (
      tester,
    ) async {
      final container = buildContainer();
      enqueueLatest(manifest());
      // `testWidgets` fige l'horloge : toute E/S réelle doit passer par
      // runAsync, sinon l'attente ne se résout jamais (L-123).
      await tester.runAsync(
        () => container.read(appUpdateControllerProvider.notifier).checkManually(),
      );
      expect(container.read(appUpdateControllerProvider).shouldPrompt, isTrue);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AppUpdateShell(
              child: Scaffold(body: Text('contenu HomeSpotify')),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('contenu HomeSpotify'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-overlay')), findsOneWidget);
      expect(find.text('Mise à jour disponible'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-later')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('app-update-later')));
      await tester.pump();
      expect(find.byKey(const ValueKey('app-update-overlay')), findsNothing);
      expect(find.text('contenu HomeSpotify'), findsOneWidget);
    });

    testWidgets('28. mise à jour obligatoire : pas de « Plus tard »', (
      tester,
    ) async {
      final container = buildContainer();
      enqueueLatest(manifest(required: true));
      await tester.runAsync(
        () => container.read(appUpdateControllerProvider.notifier).checkManually(),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: AppUpdateShell(child: Scaffold(body: SizedBox.shrink())),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Mise à jour requise'), findsOneWidget);
      expect(find.byKey(const ValueKey('app-update-later')), findsNothing);
      expect(
        find.byKey(const ValueKey('app-update-primary-action')),
        findsOneWidget,
      );
    });
  });

  group('manifeste', () {
    test('29. un manifeste incomplet ou hostile n’est jamais accepté', () {
      expect(AndroidRelease.tryParse(null), isNull);
      expect(AndroidRelease.tryParse('texte'), isNull);
      expect(AndroidRelease.tryParse(manifest(sha: 'court')), isNull);
      expect(AndroidRelease.tryParse(manifest(cert: 'zz')), isNull);
      expect(
        AndroidRelease.tryParse(
          jsonDecode(
            jsonEncode({
              ...manifest(),
              'downloadPath': 'https://ailleurs.example/malveillant.apk',
            }),
          ),
        ),
        isNull,
        reason: 'le chemin de téléchargement doit rester une route HomeSpotify',
      );
      expect(
        AndroidRelease.tryParse({...manifest(), 'sizeBytes': 0}),
        isNull,
      );
    });
  });
}
