import { createReadStream } from 'node:fs';
import type { FastifyInstance, FastifyReply } from 'fastify';
import { parseRangeHeader } from '../lib/range.js';
import {
  AndroidReleaseCatalog,
  AndroidReleaseManifestError,
  parseVersionCodeParam,
  type AndroidReleaseManifest,
} from '../app-update/android-release-catalog.js';

/**
 * Mise à jour automatique privée de l'application Android (TD-AndroidSelfUpdate).
 *
 * PUBLIC, VOLONTAIREMENT ET STRICTEMENT BORNÉ. Ces deux routes sont les seules
 * du backend à ne pas exiger de Bearer, pour une raison de fonctionnement :
 * une version obsolète peut justement être celle dont le contrat d'API ou le
 * format de jeton n'est plus compatible. Exiger une session valide rendrait la
 * mise à jour impossible dans le seul cas où elle est indispensable.
 *
 * Ce qu'elles exposent : le manifeste de la dernière APK HomeSpotify et cette
 * APK — c'est-à-dire exactement ce que le propriétaire copiait auparavant à la
 * main. AUCUNE donnée utilisateur, aucun identifiant, aucun chemin serveur.
 *
 * Ce qu'elles n'exposent pas : rien d'autre. Le seul paramètre accepté est un
 * ENTIER ; le nom de fichier est reconstruit côté serveur.
 */

const APK_CONTENT_TYPE = 'application/vnd.android.package-archive';

/** Vue client du manifeste : ni chemin, ni nom de fichier interne. */
interface AndroidReleaseDto {
  platform: 'android';
  packageName: string;
  versionCode: number;
  versionName: string;
  required: boolean;
  minSupportedVersionCode: number;
  sizeBytes: number;
  sha256: string;
  signingCertSha256: string;
  releaseNotes: string[];
  publishedAt: string;
  /** Chemin d'API — jamais un chemin de système de fichiers. */
  downloadPath: string;
}

function toDto(manifest: AndroidReleaseManifest): AndroidReleaseDto {
  return {
    platform: manifest.platform,
    packageName: manifest.packageName,
    versionCode: manifest.versionCode,
    versionName: manifest.versionName,
    required: manifest.required,
    minSupportedVersionCode: manifest.minSupportedVersionCode,
    sizeBytes: manifest.sizeBytes,
    sha256: manifest.sha256,
    signingCertSha256: manifest.signingCertSha256,
    releaseNotes: manifest.releaseNotes,
    publishedAt: manifest.publishedAt,
    downloadPath: `/api/app-update/android/download/${manifest.versionCode}`,
  };
}

function unconfigured(reply: FastifyReply): FastifyReply {
  return reply.code(503).send({
    statusCode: 503,
    error: 'update_service_unconfigured',
    message: "Le service de mise à jour Android n'est pas configuré sur ce serveur.",
  });
}

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function notFound(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(404).send({ statusCode: 404, error: 'not_found', message });
}

export function registerAppUpdateRoutes(app: FastifyInstance): void {
  const androidDir = app.config.appUpdate?.androidDir;
  const catalog = androidDir === undefined ? null : new AndroidReleaseCatalog(androidDir);

  /**
   * Dernière version publiée. `currentVersionCode` est facultatif : sans lui,
   * le serveur ne prétend pas savoir si une mise à jour s'applique et renvoie
   * `updateAvailable: false` avec le manifeste — le client tranche seul.
   */
  app.get<{ Querystring: { currentVersionCode?: string } }>(
    '/api/app-update/android/latest',
    async (request, reply) => {
      if (catalog === null) return unconfigured(reply);

      const rawCurrent = request.query.currentVersionCode;
      let currentVersionCode: number | null = null;
      if (rawCurrent !== undefined && rawCurrent !== '') {
        currentVersionCode = parseVersionCodeParam(rawCurrent);
        if (currentVersionCode === null) {
          return badRequest(reply, 'currentVersionCode doit être un entier positif.');
        }
      }

      let manifest: AndroidReleaseManifest | null;
      try {
        manifest = await catalog.readLatest();
      } catch (error) {
        if (error instanceof AndroidReleaseManifestError) {
          request.log.error(
            { event: 'android_update_manifest_invalid', reason: error.message },
            'manifeste de mise à jour Android invalide',
          );
          return reply.code(500).send({
            statusCode: 500,
            error: 'manifest_invalid',
            message: 'Le manifeste de mise à jour publié est invalide.',
          });
        }
        throw error;
      }

      const updateAvailable =
        manifest !== null &&
        currentVersionCode !== null &&
        manifest.versionCode > currentVersionCode;

      request.log.info(
        {
          event: 'android_update_check',
          currentVersionCode,
          latestVersionCode: manifest?.versionCode ?? null,
          updateAvailable,
        },
        'vérification de mise à jour Android',
      );

      return reply.send({
        updateAvailable,
        latest: manifest === null ? null : toDto(manifest),
      });
    },
  );

  /**
   * APK d'une version PUBLIÉE. Les anciennes releases restent téléchargeables
   * tant qu'elles sont au catalogue (diagnostic) ; une version inconnue est un
   * 404 propre, jamais une lecture de fichier arbitraire.
   */
  app.get<{ Params: { versionCode: string } }>(
    '/api/app-update/android/download/:versionCode',
    async (request, reply) => {
      if (catalog === null) return unconfigured(reply);

      const versionCode = parseVersionCodeParam(request.params.versionCode);
      if (versionCode === null) {
        return badRequest(reply, 'versionCode doit être un entier positif.');
      }

      let release;
      try {
        release = await catalog.resolve(versionCode);
      } catch (error) {
        if (error instanceof AndroidReleaseManifestError) {
          request.log.error(
            { event: 'android_update_manifest_invalid', versionCode, reason: error.message },
            'métadonnées de release Android invalides',
          );
          return reply.code(500).send({
            statusCode: 500,
            error: 'manifest_invalid',
            message: 'Les métadonnées de cette version sont invalides.',
          });
        }
        throw error;
      }
      if (release === null) {
        return notFound(reply, `Version ${versionCode} absente du catalogue.`);
      }

      // Taille sur disque ≠ taille annoncée : la release est corrompue ou une
      // publication a été interrompue. On refuse de servir un octet.
      if (release.sizeBytes !== release.manifest.sizeBytes) {
        request.log.error(
          {
            event: 'android_update_release_corrupted',
            versionCode,
            expectedBytes: release.manifest.sizeBytes,
            actualBytes: release.sizeBytes,
          },
          'taille de release Android incohérente',
        );
        return reply.code(500).send({
          statusCode: 500,
          error: 'release_corrupted',
          message: 'Le fichier publié ne correspond pas à son manifeste.',
        });
      }

      const total = release.sizeBytes;
      const range = parseRangeHeader(request.headers.range, total);

      reply.header('Accept-Ranges', 'bytes');
      reply.header('Content-Type', APK_CONTENT_TYPE);
      reply.header(
        'Content-Disposition',
        `attachment; filename="homespotify-${versionCode}.apk"`,
      );
      // Le SHA-256 est la véritable identité de la release : un ETag fort.
      reply.header('ETag', `"${release.manifest.sha256}"`);
      reply.header('Cache-Control', 'private, max-age=0, must-revalidate');
      reply.header('X-HomeSpotify-Version-Code', String(versionCode));
      reply.header('X-HomeSpotify-Sha256', release.manifest.sha256);

      request.log.info(
        {
          event: 'android_update_download',
          versionCode,
          partial: range !== 'full',
        },
        'téléchargement de mise à jour Android',
      );

      if (range === 'unsatisfiable') {
        reply.header('Content-Range', `bytes */${total}`);
        return reply.code(416).send();
      }
      if (range === 'full') {
        reply.header('Content-Length', String(total));
        return reply.code(200).send(createReadStream(release.filePath));
      }
      reply.header('Content-Range', `bytes ${range.start}-${range.end}/${total}`);
      reply.header('Content-Length', String(range.end - range.start + 1));
      return reply
        .code(206)
        .send(createReadStream(release.filePath, { start: range.start, end: range.end }));
    },
  );
}
