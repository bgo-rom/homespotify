/**
 * Contrat interne d'un moteur de téléchargement.
 *
 * Le reste de HomeSpotify ne dépend QUE de ce contrat : jamais du texte humain,
 * des emojis ni de la langue des logs du moteur. Remplacer Antra par un autre
 * moteur n'impose que d'écrire une nouvelle implémentation de
 * [DownloadProvider].
 */

/** Étape normalisée, indépendante du vocabulaire du moteur. */
export type DownloadStage =
  | 'queued'
  | 'resolving'
  | 'selecting_source'
  | 'downloading'
  | 'processing'
  | 'importing'
  | 'completed'
  | 'failed'
  | 'cancelled';

export interface DownloadTrackInfo {
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  source?: string | null;
  quality?: string | null;
  durationSeconds?: number | null;
}

export type DownloadProviderEvent =
  | {
      type: 'stage';
      stage: DownloadStage;
      message?: string | null;
      track?: DownloadTrackInfo;
    }
  | {
      type: 'progress';
      /** Entier 0-100 déjà borné par l'adaptateur. */
      percent: number;
      stage?: DownloadStage;
      message?: string | null;
      track?: DownloadTrackInfo;
    }
  | {
      type: 'track';
      track: DownloadTrackInfo;
    }
  | {
      /** Ligne de journal du moteur, DÉJÀ assainie. */
      type: 'log';
      level: 'debug' | 'info' | 'warn' | 'error';
      message: string;
    }
  | {
      type: 'error';
      code: string;
      message: string;
    }
  | {
      /** Le moteur affirme avoir produit un fichier à ce chemin absolu. */
      type: 'file';
      absolutePath: string;
    };

export interface DownloadResult {
  /** Le moteur s'est terminé sans erreur signalée. */
  ok: boolean;
  /** Nombre de pistes que le moteur déclare avoir téléchargées. */
  downloaded: number;
  /** Nombre de pistes déjà présentes côté moteur (ignorées). */
  skipped: number;
  failed: number;
  /** Métadonnées finales connues, si le moteur les a émises. */
  track: DownloadTrackInfo;
  /** Chemins absolus explicitement annoncés par le moteur (souvent vide). */
  reportedFiles: readonly string[];
  errorCode: string | null;
  errorMessage: string | null;
}

export interface DownloadHandle {
  /** PID du processus moteur — journalisé, jamais exposé à l'application. */
  processId: number;
  completion: Promise<DownloadResult>;
  onEvent(callback: (event: DownloadProviderEvent) => void): () => void;
}

export interface DownloadRequest {
  jobId: string;
  url: string;
  /** Dossier de sortie DÉDIÉ au job : c'est lui qui donne le contexte de détection. */
  outputDir: string;
  source?: string;
  format?: string;
}

export interface ProviderHealth {
  available: boolean;
  pythonFound: boolean;
  antraImportable: boolean;
  outputWritable: boolean;
  /**
   * Vrai si une clé Premium SEMBLE configurée. Booléen strict : ni la valeur,
   * ni sa longueur, ni son préfixe ne sortent d'ici.
   */
  premiumKeyConfigured: boolean;
  soulseekDisabled: boolean;
  /** Diagnostic déjà assaini, affichable. `null` quand tout va bien. */
  detail: string | null;
  checkedAt: string;
}

export interface DownloadProvider {
  readonly name: string;
  start(request: DownloadRequest): Promise<DownloadHandle>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<ProviderHealth>;
  /** Arrête tout processus encore vivant (arrêt du serveur). */
  stopAll(): void;
}

export class DownloadProviderError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'DownloadProviderError';
  }
}
