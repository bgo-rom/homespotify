import { spawn, type ChildProcess } from 'node:child_process';
import { access, mkdir, rm, writeFile } from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import { join, resolve } from 'node:path';
import type { AntraConfig } from '../config.js';
import {
  adaptAntraLine,
  NdjsonLineSplitter,
  type AntraSummary,
} from './antra-event-adapter.js';
import {
  DownloadProviderError,
  type DownloadHandle,
  type DownloadProvider,
  type DownloadProviderEvent,
  type DownloadRequest,
  type DownloadResult,
  type DownloadTrackInfo,
  type ProviderHealth,
} from './download-provider.js';
import { sanitizeMessage } from './log-sanitizer.js';

/** Délai laissé au processus pour s'arrêter proprement avant `taskkill /T /F`. */
const GRACEFUL_SHUTDOWN_MS = 4_000;

/** Durée maximale du contrôle de santé : il ne doit jamais bloquer le démarrage. */
const HEALTH_CHECK_TIMEOUT_MS = 20_000;

/** Le résultat du contrôle de santé est mis en cache : il est coûteux (spawn). */
const HEALTH_CACHE_TTL_MS = 60_000;

export interface ProcessSpawner {
  spawn(
    command: string,
    args: readonly string[],
    options: {
      cwd: string;
      env: NodeJS.ProcessEnv;
      shell: false;
      windowsHide: true;
    },
  ): ChildProcess;
}

const nodeSpawner: ProcessSpawner = {
  spawn: (command, args, options) => spawn(command, [...args], options),
};

export interface AntraCommand {
  executable: string;
  args: readonly string[];
  cwd: string;
  env: NodeJS.ProcessEnv;
}

/**
 * Construit la commande EXACTE passée à `spawn`.
 *
 * Extraite et pure pour être vérifiable par test : c'est le seul endroit qui
 * décide de ce que le serveur exécute réellement.
 *
 * Choix du point d'entrée : `antra.json_cli` et non `antra`. La CLI humaine
 * appelle `ensure_slskd(cfg)`, qui peut demander une configuration Soulseek
 * interactive, et n'émet aucun événement structuré. La JSON CLI n'appelle
 * jamais `ensure_slskd` et écrit du NDJSON.
 *
 * Choix de la configuration : tout passe par l'environnement du processus.
 * `antra.core.config` charge son `.env` avec `override=False`, donc l'env
 * injecté gagne — SAUF `ANTRA_API_KEY`, volontairement absent ici, qui reste
 * lu depuis `tools/antra/.env` grâce au `cwd`. Aucun secret ne transite par
 * HomeSpotify.
 */
export function buildAntraCommand(
  config: AntraConfig,
  request: DownloadRequest,
  baseEnv: NodeJS.ProcessEnv = process.env,
): AntraCommand {
  const env: NodeJS.ProcessEnv = {
    ...baseEnv,
    PYTHONUNBUFFERED: '1',
    PYTHONIOENCODING: 'utf-8',
    // Soulseek jamais amorcé : sinon le processus attend une configuration
    // interactive qui n'arrivera pas sur un serveur.
    SLSKD_AUTO_BOOTSTRAP: 'false',
    SLSKD_BASE_URL: '',
    SLSKD_API_KEY: '',
    SOULSEEK_SEED_AFTER_DOWNLOAD: 'false',
    // Dossier de sortie DÉDIÉ au job : c'est ce qui rend la détection du
    // fichier produit non ambiguë.
    OUTPUT_DIR: request.outputDir,
    OUTPUT_FORMAT: request.format ?? config.format,
    SOURCE_PREFERENCES: request.source ?? config.source,
    // Les paroles ne sont ni indexées ni utilisées par HomeSpotify.
    FETCH_LYRICS: 'false',
    SAVE_COVER_ART_SIDECAR: 'false',
    // Le staging est vide : la déduplication d'Antra n'a rien à faire ici,
    // celle de HomeSpotify (sha256 / ISRC / titre+artiste+durée) fait foi.
    FILENAME_CONFLICT_BEHAVIOR: 'rename',
  };
  // Jamais transmise par HomeSpotify : le processus la lit dans son propre
  // `.env`. Supprimer une éventuelle valeur héritée évite qu'une variable
  // d'environnement du serveur prenne silencieusement le dessus.
  delete env.ANTRA_API_KEY;

  return {
    executable: config.pythonPath,
    // L'URL est un argument distinct, jamais concaténé : aucun shell n'est
    // impliqué (`shell: false`), donc aucune interpolation possible.
    args: ['-m', 'antra.json_cli', request.url],
    cwd: config.dir,
    env,
  };
}

interface RunningProcess {
  child: ChildProcess;
  killTimer: NodeJS.Timeout | null;
  cancelled: boolean;
}

/**
 * Moteur de téléchargement Antra.
 *
 * Un processus Python par job, jamais de shell, jamais de secret journalisé.
 */
export class AntraDownloadProvider implements DownloadProvider {
  readonly name = 'antra';

  private readonly processes = new Map<string, RunningProcess>();
  private cachedHealth: { value: ProviderHealth; expiresAt: number } | null = null;
  private healthInFlight: Promise<ProviderHealth> | null = null;

  constructor(
    private readonly config: AntraConfig,
    private readonly options: {
      spawner?: ProcessSpawner;
      /** Injectable pour les tests : évite d'attendre 4 s réelles. */
      gracefulShutdownMs?: number;
      baseEnv?: NodeJS.ProcessEnv;
      logger?: {
        debug(context: Record<string, unknown>, message: string): void;
        warn(context: Record<string, unknown>, message: string): void;
      };
    } = {},
  ) {}

  async start(request: DownloadRequest): Promise<DownloadHandle> {
    if (this.processes.has(request.jobId)) {
      throw new DownloadProviderError(
        'ALREADY_RUNNING',
        'Un processus est déjà actif pour ce téléchargement.',
      );
    }

    await mkdir(request.outputDir, { recursive: true });

    const command = buildAntraCommand(
      this.config,
      request,
      this.options.baseEnv ?? process.env,
    );
    const spawner = this.options.spawner ?? nodeSpawner;
    const child = spawner.spawn(command.executable, command.args, {
      cwd: command.cwd,
      env: command.env,
      shell: false,
      windowsHide: true,
    });

    const running: RunningProcess = { child, killTimer: null, cancelled: false };
    this.processes.set(request.jobId, running);

    const listeners = new Set<(event: DownloadProviderEvent) => void>();
    const emit = (event: DownloadProviderEvent): void => {
      for (const listener of listeners) {
        try {
          listener(event);
        } catch {
          // Un consommateur défaillant ne doit jamais interrompre la lecture
          // du flux moteur.
        }
      }
    };

    const completion = this.consume(request.jobId, running, emit);

    return {
      processId: child.pid ?? 0,
      completion,
      onEvent: (callback) => {
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
    };
  }

  private consume(
    jobId: string,
    running: RunningProcess,
    emit: (event: DownloadProviderEvent) => void,
  ): Promise<DownloadResult> {
    const { child } = running;
    const splitter = new NdjsonLineSplitter();
    let summary: AntraSummary | null = null;
    let lastError: { code: string; message: string } | null = null;
    const track: DownloadTrackInfo = {};
    const reportedFiles: string[] = [];

    const handleLine = (line: string): void => {
      const result = adaptAntraLine(line);
      for (const event of result.events) {
        if (event.type === 'error') lastError = { code: event.code, message: event.message };
        if (event.type === 'file') reportedFiles.push(event.absolutePath);
        if ('track' in event && event.track) Object.assign(track, prune(event.track));
        if (event.type === 'log' && !this.config.verbose && event.level === 'debug') {
          continue;
        }
        emit(event);
      }
      if (result.summary) summary = result.summary;
    };

    child.stdout?.setEncoding('utf-8');
    child.stdout?.on('data', (chunk: string) => {
      for (const line of splitter.push(chunk)) handleLine(line);
    });

    // stderr n'est JAMAIS relayé tel quel : Python y écrit des traces qui
    // peuvent contenir des chemins locaux. Seul un extrait assaini est
    // journalisé côté serveur, en debug.
    child.stderr?.setEncoding('utf-8');
    child.stderr?.on('data', (chunk: string) => {
      const message = sanitizeMessage(chunk);
      if (message !== null) {
        this.options.logger?.debug({ jobId }, `antra stderr: ${message}`);
      }
    });

    return new Promise<DownloadResult>((resolvePromise) => {
      const finish = (code: number | null, signal: NodeJS.Signals | null): void => {
        for (const line of splitter.flush()) handleLine(line);
        if (running.killTimer !== null) clearTimeout(running.killTimer);
        this.processes.delete(jobId);

        const finalSummary: AntraSummary | null = summary;
        const failure: { code: string; message: string } | null = lastError;

        if (running.cancelled) {
          resolvePromise({
            ok: false,
            downloaded: 0,
            skipped: 0,
            failed: 0,
            track,
            reportedFiles,
            errorCode: 'CANCELLED',
            errorMessage: 'Téléchargement annulé.',
          });
          return;
        }

        const exitedCleanly = code === 0 && signal === null;
        const downloaded = finalSummary?.downloaded ?? 0;
        const ok = exitedCleanly && finalSummary !== null && downloaded > 0;

        resolvePromise({
          ok,
          downloaded,
          skipped: finalSummary?.skipped ?? 0,
          failed: finalSummary?.failed ?? 0,
          track,
          reportedFiles,
          errorCode: ok
            ? null
            : (failure?.code ??
              (exitedCleanly ? 'NO_TRACK_DOWNLOADED' : 'ENGINE_EXIT_ERROR')),
          errorMessage: ok
            ? null
            : (finalSummary?.errorMessage ??
              failure?.message ??
              (exitedCleanly
                ? 'Le moteur n’a produit aucun fichier pour cette adresse.'
                : 'Le moteur de téléchargement s’est interrompu.')),
        });
      };

      child.on('error', (error: Error) => {
        const message = sanitizeMessage(error.message) ?? 'Processus illisible.';
        if (running.killTimer !== null) clearTimeout(running.killTimer);
        this.processes.delete(jobId);
        emit({ type: 'error', code: 'SPAWN_FAILED', message });
        resolvePromise({
          ok: false,
          downloaded: 0,
          skipped: 0,
          failed: 0,
          track,
          reportedFiles,
          errorCode: 'SPAWN_FAILED',
          errorMessage:
            'Le moteur de téléchargement n’a pas pu être démarré sur le serveur.',
        });
      });

      child.on('close', finish);
    });
  }

  /**
   * Annulation idempotente : arrêt normal, puis suppression de l'ARBRE de
   * processus Windows. Antra lance des enfants (ffmpeg, yt-dlp) qui survivent
   * à un simple `kill` du parent.
   */
  async cancel(jobId: string): Promise<void> {
    const running = this.processes.get(jobId);
    if (!running || running.cancelled) return;
    running.cancelled = true;

    const pid = running.child.pid;
    try {
      running.child.kill();
    } catch {
      // Processus déjà mort : rien à faire.
    }

    if (pid === undefined) return;
    const delayMs = this.options.gracefulShutdownMs ?? GRACEFUL_SHUTDOWN_MS;
    running.killTimer = setTimeout(() => {
      this.killProcessTree(pid);
    }, delayMs);
    running.killTimer.unref();
  }

  /**
   * Termine l'arbre de processus. Sous Windows, `taskkill /T /F` est le SEUL
   * moyen fiable ; ailleurs, `SIGKILL` sur le groupe.
   */
  private killProcessTree(pid: number): void {
    if (process.platform === 'win32') {
      try {
        // `shell: false` : `taskkill` reçoit ses arguments tels quels, le PID
        // est un entier issu du système, jamais une valeur utilisateur.
        spawn('taskkill', ['/PID', String(pid), '/T', '/F'], {
          shell: false,
          windowsHide: true,
          stdio: 'ignore',
        }).on('error', () => {
          // taskkill absent ou processus déjà disparu.
        });
      } catch {
        // Rien de plus à tenter.
      }
      return;
    }
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // Processus déjà terminé.
    }
  }

  stopAll(): void {
    for (const [jobId] of this.processes) {
      void this.cancel(jobId);
    }
  }

  /**
   * Contrôle de santé NON bloquant et sans téléchargement.
   *
   * Le résultat est mis en cache : chaque appel lance un interpréteur Python,
   * ce qui n'a pas à se produire à chaque requête HTTP.
   */
  async healthCheck(): Promise<ProviderHealth> {
    const now = Date.now();
    if (this.cachedHealth !== null && this.cachedHealth.expiresAt > now) {
      return this.cachedHealth.value;
    }
    if (this.healthInFlight !== null) return this.healthInFlight;

    const run = this.runHealthCheck()
      .then((value) => {
        this.cachedHealth = { value, expiresAt: Date.now() + HEALTH_CACHE_TTL_MS };
        return value;
      })
      .finally(() => {
        this.healthInFlight = null;
      });
    this.healthInFlight = run;
    return run;
  }

  private async runHealthCheck(): Promise<ProviderHealth> {
    const checkedAt = new Date().toISOString();
    const problems: string[] = [];

    const pythonFound = await exists(this.config.pythonPath);
    if (!pythonFound) problems.push('interpréteur Python introuvable');

    const dirFound = await exists(this.config.dir);
    if (!dirFound) problems.push('dossier du moteur introuvable');

    const outputWritable = await this.checkOutputWritable();
    if (!outputWritable) problems.push('dossier de sortie non accessible en écriture');

    // Vérifié indépendamment du dossier : la clé peut aussi venir de
    // l'environnement du serveur, auquel cas elle n'est simplement pas
    // supprimée de l'env transmis… mais elle reste hors de toute réponse.
    const premiumKeyConfigured = await this.premiumKeyLooksConfigured(dirFound);
    if (!premiumKeyConfigured) problems.push('clé Premium absente');

    const antraImportable =
      pythonFound && dirFound ? await this.checkImportable() : false;
    if (pythonFound && dirFound && !antraImportable) {
      problems.push('module du moteur non importable');
    }

    return {
      available:
        pythonFound && dirFound && outputWritable && antraImportable,
      pythonFound,
      antraImportable,
      outputWritable,
      premiumKeyConfigured,
      // Toujours vrai : la configuration refuse tout autre réglage (cf. config.ts).
      soulseekDisabled: !this.config.slskdAutoBootstrap,
      detail: problems.length === 0 ? null : problems.join(', '),
      checkedAt,
    };
  }

  private async checkOutputWritable(): Promise<boolean> {
    const probe = join(this.config.outputDir, `.antra-health-${process.pid}`);
    try {
      await mkdir(this.config.outputDir, { recursive: true });
      await writeFile(probe, '');
      return true;
    } catch {
      return false;
    } finally {
      await rm(probe, { force: true }).catch(() => undefined);
    }
  }

  /**
   * Vérifie qu'une clé Premium SEMBLE présente, sans jamais la lire ailleurs
   * qu'en mémoire locale ni la renvoyer. Seul un booléen sort de cette méthode.
   */
  private async premiumKeyLooksConfigured(dirFound: boolean): Promise<boolean> {
    const envValue = (this.options.baseEnv ?? process.env).ANTRA_API_KEY ?? '';
    if (envValue.trim().length > 0) return true;
    if (!dirFound) return false;

    try {
      const { readFile } = await import('node:fs/promises');
      const content = await readFile(resolve(this.config.dir, '.env'), 'utf-8');
      return content
        .split(/\r?\n/)
        .some((line) => /^\s*ANTRA_API_KEY\s*=\s*\S+/.test(line));
    } catch {
      return false;
    }
  }

  private async checkImportable(): Promise<boolean> {
    return new Promise<boolean>((resolvePromise) => {
      let settled = false;
      const done = (value: boolean): void => {
        if (settled) return;
        settled = true;
        resolvePromise(value);
      };

      let child: ChildProcess;
      try {
        const spawner = this.options.spawner ?? nodeSpawner;
        child = spawner.spawn(
          this.config.pythonPath,
          ['-c', "import antra; print('ok')"],
          {
            cwd: this.config.dir,
            env: {
              ...(this.options.baseEnv ?? process.env),
              PYTHONUNBUFFERED: '1',
              PYTHONIOENCODING: 'utf-8',
              SLSKD_AUTO_BOOTSTRAP: 'false',
            },
            shell: false,
            windowsHide: true,
          },
        );
      } catch {
        done(false);
        return;
      }

      const timer = setTimeout(() => {
        try {
          child.kill();
        } catch {
          // Déjà terminé.
        }
        done(false);
      }, HEALTH_CHECK_TIMEOUT_MS);
      timer.unref();

      let stdout = '';
      child.stdout?.setEncoding('utf-8');
      child.stdout?.on('data', (chunk: string) => {
        stdout += chunk;
      });
      child.on('error', () => {
        clearTimeout(timer);
        done(false);
      });
      child.on('close', (code) => {
        clearTimeout(timer);
        done(code === 0 && stdout.includes('ok'));
      });
    });
  }
}

function prune(track: DownloadTrackInfo): DownloadTrackInfo {
  return Object.fromEntries(
    Object.entries(track).filter(([, value]) => value !== null && value !== undefined),
  ) as DownloadTrackInfo;
}

async function exists(path: string): Promise<boolean> {
  try {
    await access(path, fsConstants.F_OK);
    return true;
  } catch {
    return false;
  }
}
