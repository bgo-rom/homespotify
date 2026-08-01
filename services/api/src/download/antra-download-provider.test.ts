import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { ChildProcess } from 'node:child_process';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { AntraConfig } from '../config.js';
import {
  AntraDownloadProvider,
  buildAntraCommand,
  type ProcessSpawner,
} from './antra-download-provider.js';
import type { DownloadProviderEvent } from './download-provider.js';

let root: string;

function makeConfig(overrides: Partial<AntraConfig> = {}): AntraConfig {
  return {
    dir: join(root, 'antra'),
    pythonPath: join(root, 'antra', '.venv', 'Scripts', 'python.exe'),
    outputDir: join(root, 'imports'),
    source: 'auto',
    format: 'flac',
    allowedExtensions: ['.flac'],
    maxConcurrent: 2,
    jobTimeoutMs: 900_000,
    slskdAutoBootstrap: false,
    verbose: false,
    ...overrides,
  };
}

/** Faux processus enfant : aucun interpréteur Python n'est lancé par les tests. */
class FakeChild extends EventEmitter {
  readonly stdout = new Readable({ read() {} });
  readonly stderr = new Readable({ read() {} });
  readonly pid = 4242;
  killed = false;
  killSignal: string | undefined;

  kill(signal?: string): boolean {
    this.killed = true;
    this.killSignal = signal;
    return true;
  }

  emitLine(line: string): void {
    this.stdout.push(`${line}\n`);
  }

  /**
   * Ferme le processus comme le ferait Node : `close` n'arrive qu'APRÈS que
   * stdout a été entièrement consommé. Émettre `close` immédiatement ferait
   * passer le test là où le vrai flux aurait encore des lignes en attente.
   */
  finish(code: number): void {
    this.stdout.push(null);
    this.stderr.push(null);
    this.stdout.once('end', () => this.emit('close', code, null));
    this.stdout.resume();
  }
}

interface RecordedSpawn {
  command: string;
  args: readonly string[];
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    shell: false;
    windowsHide: true;
  };
}

class FakeSpawner implements ProcessSpawner {
  readonly calls: RecordedSpawn[] = [];
  readonly children: FakeChild[] = [];
  /** Code de sortie automatique du process `-c "import antra"`. */
  importExitCode = 0;
  importStdout = 'ok\n';

  spawn(
    command: string,
    args: readonly string[],
    options: RecordedSpawn['options'],
  ): ChildProcess {
    this.calls.push({ command, args, options });
    const child = new FakeChild();
    this.children.push(child);

    if (args[0] === '-c') {
      // Sonde d'import du contrôle de santé : réponse immédiate.
      queueMicrotask(() => {
        child.stdout.push(this.importStdout);
        child.finish(this.importExitCode);
      });
    }
    return child as unknown as ChildProcess;
  }
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-antra-'));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

describe('buildAntraCommand', () => {
  it('construit exactement les arguments attendus, sans shell', () => {
    const command = buildAntraCommand(
      makeConfig(),
      {
        jobId: 'job-1',
        url: 'https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka',
        outputDir: join(root, 'staging', 'job-1'),
      },
      {},
    );

    expect(command.executable).toBe(makeConfig().pythonPath);
    // Interface JSON : la CLI humaine appellerait `ensure_slskd` et n'émettrait
    // aucun événement structuré.
    expect(command.args).toEqual([
      '-m',
      'antra.json_cli',
      'https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka',
    ]);
    // L'URL est un argument DISTINCT : jamais concaténée dans une commande.
    expect(command.args.join(' ')).not.toContain('--output');
    expect(command.cwd).toBe(makeConfig().dir);
  });

  it('impose l’environnement de sûreté et n’expose jamais la clé Premium', () => {
    const command = buildAntraCommand(
      makeConfig(),
      { jobId: 'job-1', url: 'https://open.spotify.com/track/1', outputDir: '/out' },
      { ANTRA_API_KEY: 'sk_live_ne_doit_pas_fuiter', PATH: '/usr/bin' },
    );

    expect(command.env.PYTHONUNBUFFERED).toBe('1');
    expect(command.env.PYTHONIOENCODING).toBe('utf-8');
    expect(command.env.SLSKD_AUTO_BOOTSTRAP).toBe('false');
    expect(command.env.FETCH_LYRICS).toBe('false');
    expect(command.env.OUTPUT_DIR).toBe('/out');
    expect(command.env.OUTPUT_FORMAT).toBe('flac');
    expect(command.env.SOURCE_PREFERENCES).toBe('auto');
    // L'environnement hérité est conservé…
    expect(command.env.PATH).toBe('/usr/bin');
    // …mais la clé Premium n'est JAMAIS transmise par HomeSpotify : le
    // processus la lit dans son propre .env grâce au cwd.
    expect(command.env.ANTRA_API_KEY).toBeUndefined();
    expect(JSON.stringify(command)).not.toContain('sk_live_ne_doit_pas_fuiter');
  });
});

describe('AntraDownloadProvider — exécution', () => {
  it('passe shell:false et windowsHide:true à spawn', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), { spawner, baseEnv: {} });

    const handle = await provider.start({
      jobId: 'job-1',
      url: 'https://open.spotify.com/track/1',
      outputDir: join(root, 'staging', 'job-1'),
    });
    expect(spawner.calls[0]?.options.shell).toBe(false);
    expect(spawner.calls[0]?.options.windowsHide).toBe(true);
    expect(handle.processId).toBe(4242);

    spawner.children[0]?.finish(0);
    await handle.completion;
  });

  it('lit le NDJSON ligne par ligne et ignore une ligne invalide', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), { spawner, baseEnv: {} });
    const handle = await provider.start({
      jobId: 'job-1',
      url: 'https://open.spotify.com/track/1',
      outputDir: join(root, 'staging', 'job-1'),
    });

    const events: DownloadProviderEvent[] = [];
    handle.onEvent((event) => events.push(event));

    const child = spawner.children[0]!;
    child.emitLine('Bannière humaine non JSON');
    child.emitLine('{json invalide');
    child.emitLine(
      JSON.stringify({
        type: 'playlist_loaded',
        title: 'Lifestyles',
        artists_string: 'Guala',
      }),
    );
    child.emitLine(
      JSON.stringify({
        type: 'event',
        name: 'track_download_attempt',
        payload: { track: 'Lifestyles', artist: 'Guala', source: 'qobuz' },
      }),
    );
    child.emitLine(
      JSON.stringify({
        type: 'playlist_summary',
        total: 1,
        downloaded: 1,
        failed: 0,
        skipped: 0,
        error: null,
      }),
    );
    child.emitLine('{"type":"done"}');
    child.finish(0);

    const result = await handle.completion;
    expect(result.ok).toBe(true);
    expect(result.downloaded).toBe(1);
    expect(result.track.title).toBe('Lifestyles');
    expect(result.track.source).toBe('qobuz');
    expect(events.some((event) => event.type === 'stage')).toBe(true);
  });

  it('propage une erreur du moteur au lieu de la masquer', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), { spawner, baseEnv: {} });
    const handle = await provider.start({
      jobId: 'job-1',
      url: 'https://open.spotify.com/track/1',
      outputDir: join(root, 'staging', 'job-1'),
    });

    const child = spawner.children[0]!;
    child.emitLine(
      JSON.stringify({
        type: 'playlist_summary',
        total: 0,
        downloaded: 0,
        failed: 1,
        skipped: 0,
        error: 'Album unavailable',
      }),
    );
    child.finish(1);

    const result = await handle.completion;
    expect(result.ok).toBe(false);
    expect(result.errorMessage).toBe('Album unavailable');
  });

  it('signale un échec quand le moteur sort proprement sans rien produire', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), { spawner, baseEnv: {} });
    const handle = await provider.start({
      jobId: 'job-1',
      url: 'https://open.spotify.com/track/1',
      outputDir: join(root, 'staging', 'job-1'),
    });

    spawner.children[0]!.emitLine(
      JSON.stringify({
        type: 'playlist_summary',
        total: 0,
        downloaded: 0,
        failed: 0,
        skipped: 0,
        error: null,
      }),
    );
    spawner.children[0]!.finish(0);

    const result = await handle.completion;
    expect(result.ok).toBe(false);
    expect(result.errorCode).toBe('NO_TRACK_DOWNLOADED');
  });
});

describe('AntraDownloadProvider — annulation', () => {
  it('arrête le processus puis termine l’arbre, de façon idempotente', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), {
      spawner,
      baseEnv: {},
      gracefulShutdownMs: 5,
    });
    const handle = await provider.start({
      jobId: 'job-1',
      url: 'https://open.spotify.com/track/1',
      outputDir: join(root, 'staging', 'job-1'),
    });

    await provider.cancel('job-1');
    // Deuxième appel : aucun effet, aucune exception.
    await provider.cancel('job-1');
    expect(spawner.children[0]?.killed).toBe(true);

    spawner.children[0]?.finish(1);
    const result = await handle.completion;
    expect(result.errorCode).toBe('CANCELLED');
  });

  it('annuler un job inconnu ne lève jamais', async () => {
    const provider = new AntraDownloadProvider(makeConfig(), {
      spawner: new FakeSpawner(),
      baseEnv: {},
    });
    await expect(provider.cancel('inexistant')).resolves.toBeUndefined();
  });
});

describe('AntraDownloadProvider — contrôle de santé', () => {
  it('signale un Python absent sans faire échouer le serveur', async () => {
    const provider = new AntraDownloadProvider(
      makeConfig({ pythonPath: join(root, 'python-absent.exe') }),
      { spawner: new FakeSpawner(), baseEnv: {} },
    );

    const health = await provider.healthCheck();
    expect(health.available).toBe(false);
    expect(health.pythonFound).toBe(false);
    expect(health.antraImportable).toBe(false);
    expect(health.detail).toContain('Python');
  });

  it('ne renvoie qu’un booléen pour la clé Premium', async () => {
    const provider = new AntraDownloadProvider(makeConfig(), {
      spawner: new FakeSpawner(),
      baseEnv: { ANTRA_API_KEY: 'sk_live_secret_absolu' },
    });

    const health = await provider.healthCheck();
    expect(health.premiumKeyConfigured).toBe(true);
    expect(JSON.stringify(health)).not.toContain('sk_live');
    expect(JSON.stringify(health)).not.toContain('sk_');
  });

  it('confirme que Soulseek reste désactivé', async () => {
    const provider = new AntraDownloadProvider(makeConfig(), {
      spawner: new FakeSpawner(),
      baseEnv: {},
    });
    expect((await provider.healthCheck()).soulseekDisabled).toBe(true);
  });

  it('ne lance aucun téléchargement pendant le contrôle', async () => {
    const spawner = new FakeSpawner();
    const provider = new AntraDownloadProvider(makeConfig(), { spawner, baseEnv: {} });
    await provider.healthCheck();
    for (const call of spawner.calls) {
      expect(call.args).not.toContain('antra.json_cli');
    }
  });
});
