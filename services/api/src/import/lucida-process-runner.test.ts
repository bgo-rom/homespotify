import { EventEmitter } from 'node:events';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { PassThrough } from 'node:stream';
import {
  join,
  resolve,
} from 'node:path';
import type {
  ChildProcess,
  SpawnOptions,
} from 'node:child_process';
import {
  afterEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';
import {
  LucidaProcessRunner,
  type LucidaSpawn,
} from './lucida-process-runner.js';

class FakeChildProcess extends EventEmitter {
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  readonly stdin = null;
  readonly stdio = [null, this.stdout, this.stderr] as const;
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  killed = false;
  readonly kill = vi.fn((signal: NodeJS.Signals = 'SIGTERM') => {
    this.killed = true;
    this.signalCode = signal;
    return true;
  });

  writeStdout(value: string | Buffer): void {
    this.stdout.write(value);
  }

  writeStderr(value: string | Buffer): void {
    this.stderr.write(value);
  }

  async close(
    code: number | null,
    signal: NodeJS.Signals | null = null,
  ): Promise<void> {
    this.exitCode = code;
    this.signalCode = signal;
    this.stdout.end();
    this.stderr.end();
    await new Promise<void>((resolvePromise) => setImmediate(resolvePromise));
    this.emit('close', code, signal);
  }

  fail(error: Error): void {
    this.emit('error', error);
  }

  asChildProcess(): ChildProcess {
    return this as unknown as ChildProcess;
  }
}

const temporaryRoots: string[] = [];

interface SetupResult {
  runner: LucidaProcessRunner;
  child: FakeChildProcess;
  spawnMock: ReturnType<typeof vi.fn<LucidaSpawn>>;
  importRoot: string;
  outputDir: string;
  scriptPath: string;
}

function setup(options: {
  timeoutMs?: number;
  stderrLimitBytes?: number;
} = {}): SetupResult {
  const child = new FakeChildProcess();
  const spawnMock = vi.fn<LucidaSpawn>(
    (
      _command: string,
      _args: readonly string[],
      _spawnOptions: SpawnOptions,
    ) => child.asChildProcess(),
  );

  const temporaryRoot = mkdtempSync(
    join(tmpdir(), 'homespotify-lucida-runner-'),
  );
  temporaryRoots.push(temporaryRoot);
  const importRoot = join(temporaryRoot, 'imports');
  const outputDir = join(importRoot, '1_alice', 'inbox');
  mkdirSync(outputDir, { recursive: true });
  const scriptPath = resolve(
    'tools',
    'spotify-auth-spoof',
    'lucida_dl_final.py',
  );

  const runner = new LucidaProcessRunner({
    scriptPath,
    importRoot,
    pythonPath: 'python-test',
    processTimeoutMs: options.timeoutMs ?? 5_000,
    stderrLimitBytes: options.stderrLimitBytes ?? 4_096,
    spawnImpl: spawnMock,
  });

  return {
    runner,
    child,
    spawnMock,
    importRoot,
    outputDir,
    scriptPath,
  };
}

function eventLine(event: Record<string, unknown>): string {
  return `${JSON.stringify(event)}\n`;
}

afterEach(() => {
  vi.useRealTimers();
  delete process.env.HOMESPOTIFY_RUNNER_SECRET_TEST;
  delete process.env.PLAYWRIGHT_BROWSERS_PATH;
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe('LucidaProcessRunner', () => {
  it('lance Python avec le script en premier argument et sans shell', async () => {
    const {
      runner,
      child,
      spawnMock,
      outputDir,
      scriptPath,
    } = setup();

    process.env.HOMESPOTIFY_RUNNER_SECRET_TEST = 'ne-doit-pas-fuiter';
    process.env.PLAYWRIGHT_BROWSERS_PATH = resolve(
      'storage',
      'playwright-browsers',
    );

    const promise = runner.run({
      mode: 'download',
      query: 'Luther Creeper',
      resultIndex: 0,
      outputDir,
    });

    const [command, args, options] = spawnMock.mock.calls[0]!;
    expect(command).toBe('python-test');
    expect(args[0]).toBe(scriptPath);
    expect(args).toEqual(
      expect.arrayContaining([
        'Luther Creeper',
        '--service',
        'Qobuz',
        '--json',
        '--index',
        '0',
        '--output',
        outputDir,
      ]),
    );
    expect(args).not.toContain('--visible');
    expect(args).not.toContain('--interactive-verification');
    expect(args).not.toContain('--verification-timeout');
    expect(options).toMatchObject({
      cwd: resolve('tools', 'spotify-auth-spoof'),
      shell: false,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    expect(options.env).toMatchObject({
      PYTHONIOENCODING: 'utf-8',
      PYTHONUTF8: '1',
      PLAYWRIGHT_BROWSERS_PATH: resolve(
        'storage',
        'playwright-browsers',
      ),
    });
    expect(options.env).not.toHaveProperty(
      'HOMESPOTIFY_RUNNER_SECRET_TEST',
    );

    writeFileSync(join(outputDir, 'creeper.flac'), 'FLAC-test');
    child.writeStdout(
      eventLine({
        type: 'success',
        filepath: join(outputDir, 'creeper.flac'),
        title: 'creeper',
        artist: 'Luther',
        album: 'creeper + seed',
        duration: 160,
      }),
    );
    await child.close(0);
    await expect(promise).resolves.toMatchObject({
      mode: 'download',
      relativeFilePath: 'creeper.flac',
    });
  });

  it('parse plusieurs lignes et une ligne fragmentée entre plusieurs chunks', async () => {
    const { runner, child } = setup();
    const events: string[] = [];

    const promise = runner.run({
      mode: 'search',
      query: 'Luther Creeper',
      onEvent: (event) => events.push(event.type),
    });

    const first = eventLine({
      type: 'stage',
      stage: 'searching',
      message: 'Recherche du morceau',
    });
    const second = eventLine({
      type: 'search_result',
      index: 0,
      title: 'creeper',
      artist: 'Luther',
      album: 'creeper + seed',
      duration: 160,
    });
    const complete = eventLine({
      type: 'complete',
      mode: 'list',
      count: 1,
    });

    child.writeStdout(first + second.slice(0, 17));
    child.writeStdout(second.slice(17) + complete);
    await child.close(0);

    await expect(promise).resolves.toMatchObject({
      mode: 'search',
      count: 1,
      results: [
        {
          index: 0,
          title: 'creeper',
          artist: 'Luther',
        },
      ],
    });
    expect(events).toEqual(['stage', 'search_result', 'complete']);
  });

  it('décode correctement un caractère UTF-8 coupé entre deux chunks', async () => {
    const { runner, child } = setup();
    const messages: string[] = [];

    const promise = runner.run({
      mode: 'search',
      query: 'Test',
      onEvent: (event) => {
        if (event.type === 'stage') messages.push(event.message);
      },
    });

    const stage = Buffer.from(
      eventLine({
        type: 'stage',
        stage: 'verifying',
        message: 'Vérification précise',
      }),
      'utf8',
    );
    const accentIndex = stage.indexOf(Buffer.from('é', 'utf8'));
    child.writeStdout(stage.subarray(0, accentIndex + 1));
    child.writeStdout(stage.subarray(accentIndex + 1));
    child.writeStdout(
      eventLine({
        type: 'complete',
        mode: 'list',
        count: 0,
      }),
    );
    await child.close(0);

    await expect(promise).resolves.toMatchObject({
      mode: 'search',
      count: 0,
    });
    expect(messages).toEqual(['Vérification précise']);
  });

  it('rejette une ligne JSON invalide et termine le processus', async () => {
    const { runner, child } = setup();
    const promise = runner.run({
      mode: 'search',
      query: 'Test',
    });

    child.writeStdout('{json invalide}\n');

    await expect(promise).rejects.toMatchObject({
      code: 'PROTOCOL_ERROR',
    });
    expect(child.kill).toHaveBeenCalledWith('SIGTERM');
  });

  it('rejette un type d’événement inconnu', async () => {
    const { runner, child } = setup();
    const promise = runner.run({
      mode: 'search',
      query: 'Test',
    });

    child.writeStdout(
      eventLine({
        type: 'unknown_event',
      }),
    );

    await expect(promise).rejects.toMatchObject({
      code: 'PROTOCOL_ERROR',
    });
  });

  it('propage l’événement error lors d’un code de sortie non nul', async () => {
    const { runner, child, outputDir } = setup();
    const promise = runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir,
    });

    child.writeStdout(
      eventLine({
        type: 'error',
        code: 'NO_EXACT_MATCH',
        message: 'Aucune correspondance exacte',
      }),
    );
    child.writeStderr('diagnostic interne');
    await child.close(4);

    await expect(promise).rejects.toMatchObject({
      code: 'NO_EXACT_MATCH',
      message: 'Aucune correspondance exacte',
      details: {
        exitCode: 4,
        stderr: 'diagnostic interne',
      },
    });
  });

  it('retourne PROCESS_FAILED si Python échoue sans événement error', async () => {
    const { runner, child } = setup();
    const promise = runner.run({
      mode: 'search',
      query: 'Test',
    });

    child.writeStderr('échec sans événement structuré');
    await child.close(5);

    await expect(promise).rejects.toMatchObject({
      code: 'PROCESS_FAILED',
      details: {
        exitCode: 5,
      },
    });
  });

  it('valide et propage uniquement les champs fournisseur sûrs', async () => {
    const { runner, child } = setup();
    const promise = runner.run({ mode: 'search', query: 'Test' });
    child.writeStdout(
      eventLine({
        type: 'error',
        code: 'PROVIDER_RATE_LIMITED',
        message: 'Le fournisseur limite temporairement les requêtes.',
        provider: 'Lucida',
        retryable: false,
        retryAfterSeconds: 1_200,
        html: '<html>secret</html>',
        unsafeDetail: 'secret',
      }),
    );
    await child.close(4);

    await expect(promise).rejects.toMatchObject({
      code: 'PROVIDER_RATE_LIMITED',
      details: {
        provider: 'Lucida',
        retryable: false,
        retryAfterSeconds: 1_200,
      },
    });
    await expect(promise).rejects.not.toMatchObject({
      details: { html: expect.anything(), unsafeDetail: expect.anything() },
    });
  });

  it('gère l’erreur de démarrage du processus', async () => {
    const child = new FakeChildProcess();
    const spawnMock = vi.fn<LucidaSpawn>(() => child.asChildProcess());
    const temporaryRoot = mkdtempSync(
      join(tmpdir(), 'homespotify-lucida-stop-'),
    );
    temporaryRoots.push(temporaryRoot);
    const runner = new LucidaProcessRunner({
      scriptPath: resolve('tools', 'spotify-auth-spoof', 'lucida_dl_final.py'),
      importRoot: join(temporaryRoot, 'imports'),
      spawnImpl: spawnMock,
    });

    const promise = runner.run({
      mode: 'search',
      query: 'Test',
    });
    child.fail(new Error('python introuvable'));

    await expect(promise).rejects.toMatchObject({
      code: 'SPAWN_ERROR',
    });
    expect(runner.activeProcessCount()).toBe(0);
  });

  it('annule avant spawn lorsque le signal est déjà aborté', async () => {
    const { runner, spawnMock } = setup();
    const controller = new AbortController();
    controller.abort();

    await expect(
      runner.run({
        mode: 'search',
        query: 'Test',
        signal: controller.signal,
      }),
    ).rejects.toMatchObject({
      code: 'CANCELLED',
    });
    expect(spawnMock).not.toHaveBeenCalled();
  });

  it('annule un processus actif avec SIGTERM', async () => {
    const { runner, child } = setup();
    const controller = new AbortController();

    const promise = runner.run({
      mode: 'search',
      query: 'Test',
      signal: controller.signal,
    });
    controller.abort();

    await expect(promise).rejects.toMatchObject({
      code: 'CANCELLED',
    });
    expect(child.kill).toHaveBeenCalledWith('SIGTERM');
  });

  it('applique le timeout global et termine le processus', async () => {
    vi.useFakeTimers();
    const { runner, child } = setup({ timeoutMs: 100 });

    const promise = runner.run({
      mode: 'search',
      query: 'Test',
    });
    const expectation = expect(promise).rejects.toMatchObject({
      code: 'TIMEOUT',
    });

    await vi.advanceTimersByTimeAsync(100);
    await expectation;
    expect(child.kill).toHaveBeenCalledWith('SIGTERM');
  });

  it('refuse un dossier de sortie hors de importRoot avant spawn', async () => {
    const { runner, spawnMock } = setup();

    await expect(
      runner.run({
        mode: 'download',
        query: 'Test',
        resultIndex: 0,
        outputDir: resolve('outside'),
      }),
    ).rejects.toMatchObject({
      code: 'INVALID_REQUEST',
    });
    expect(spawnMock).not.toHaveBeenCalled();
  });

  it('refuse un filepath success hors du dossier de sortie', async () => {
    const { runner, child, outputDir } = setup();

    const promise = runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir,
    });

    child.writeStdout(
      eventLine({
        type: 'success',
        filepath: resolve('outside', 'evil.flac'),
        title: 'Test',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      }),
    );
    await child.close(0);

    await expect(promise).rejects.toMatchObject({
      code: 'OUTPUT_PATH_VIOLATION',
    });
  });

  it('refuse un success dont le fichier n’existe pas réellement', async () => {
    const { runner, child, outputDir } = setup();

    const promise = runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir,
    });

    child.writeStdout(
      eventLine({
        type: 'success',
        filepath: join(outputDir, 'missing.flac'),
        title: 'Test',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      }),
    );
    await child.close(0);

    await expect(promise).rejects.toMatchObject({
      code: 'OUTPUT_FILE_INVALID',
    });
  });

  it('refuse un type de fichier non accepté même s’il existe', async () => {
    const { runner, child, outputDir } = setup();
    const filePath = join(outputDir, 'track.mp3');
    writeFileSync(filePath, 'fake-mp3');

    const promise = runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir,
    });

    child.writeStdout(
      eventLine({
        type: 'success',
        filepath: filePath,
        title: 'Test',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      }),
    );
    await child.close(0);

    await expect(promise).rejects.toMatchObject({
      code: 'OUTPUT_FILE_INVALID',
    });
  });

  it('refuse un fichier vide malgré un événement success', async () => {
    const { runner, child, outputDir } = setup();
    const filePath = join(outputDir, 'empty.flac');
    writeFileSync(filePath, '');

    const promise = runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir,
    });

    child.writeStdout(
      eventLine({
        type: 'success',
        filepath: filePath,
        title: 'Test',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      }),
    );
    await child.close(0);

    await expect(promise).rejects.toMatchObject({
      code: 'OUTPUT_FILE_INVALID',
    });
  });

  it('exige complete en recherche et success en téléchargement', async () => {
    const search = setup();
    const searchPromise = search.runner.run({
      mode: 'search',
      query: 'Test',
    });
    await search.child.close(0);
    await expect(searchPromise).rejects.toMatchObject({
      code: 'MISSING_TERMINAL_EVENT',
    });

    const download = setup();
    const downloadPromise = download.runner.run({
      mode: 'download',
      query: 'Test',
      resultIndex: 0,
      outputDir: download.outputDir,
    });
    await download.child.close(0);
    await expect(downloadPromise).rejects.toMatchObject({
      code: 'MISSING_TERMINAL_EVENT',
    });
  });

  it('stopAll termine chaque processus actif', async () => {
    const childA = new FakeChildProcess();
    const childB = new FakeChildProcess();
    const children = [childA, childB];
    const spawnMock = vi.fn<LucidaSpawn>(
      () => children.shift()!.asChildProcess(),
    );
    const runner = new LucidaProcessRunner({
      scriptPath: resolve('tools', 'spotify-auth-spoof', 'lucida_dl_final.py'),
      importRoot: resolve('test-data', 'imports'),
      spawnImpl: spawnMock,
    });

    const first = runner.run({ mode: 'search', query: 'Premier' });
    const second = runner.run({ mode: 'search', query: 'Deuxième' });

    // Attache immédiatement les handlers de rejet avant de simuler la fermeture.
    // Sinon Node peut signaler un rejet non géré entre close() et expect(...).
    const firstExpectation = expect(first).rejects.toMatchObject({
      code: 'CANCELLED',
      message: 'Arrêt serveur',
    });
    const secondExpectation = expect(second).rejects.toMatchObject({
      code: 'CANCELLED',
      message: 'Arrêt serveur',
    });

    expect(runner.activeProcessCount()).toBe(2);

    runner.stopAll();

    expect(childA.kill).toHaveBeenCalledWith('SIGTERM');
    expect(childB.kill).toHaveBeenCalledWith('SIGTERM');

    childA.writeStdout(
      eventLine({
        type: 'error',
        code: 'CANCELLED',
        message: 'Arrêt serveur',
      }),
    );
    childB.writeStdout(
      eventLine({
        type: 'error',
        code: 'CANCELLED',
        message: 'Arrêt serveur',
      }),
    );
    await childA.close(4);
    await childB.close(4);

    await firstExpectation;
    await secondExpectation;
    expect(runner.activeProcessCount()).toBe(0);
  });
});
