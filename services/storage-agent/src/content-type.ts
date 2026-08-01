/**
 * Type MIME déduit de l'extension.
 *
 * Table volontairement CLOSE : un format inconnu est servi en
 * `application/octet-stream` plutôt que deviné. L'agent ne lit jamais le
 * contenu du fichier pour inférer un type (pas de sniffing).
 */
const MIME_BY_EXTENSION: Record<string, string> = {
  '.flac': 'audio/flac',
  '.wav': 'audio/wav',
  '.mp3': 'audio/mpeg',
  '.m4a': 'audio/mp4',
  '.aac': 'audio/aac',
  '.ogg': 'audio/ogg',
  '.opus': 'audio/ogg',
  '.aiff': 'audio/aiff',
  '.aif': 'audio/aiff',
};

export const DEFAULT_CONTENT_TYPE = 'application/octet-stream';

/** `portableRelativePath` n'est utilisé QUE pour son extension. */
export function contentTypeForPath(portableRelativePath: string): string {
  const dot = portableRelativePath.lastIndexOf('.');
  if (dot < 0) return DEFAULT_CONTENT_TYPE;
  const extension = portableRelativePath.slice(dot).toLowerCase();
  return MIME_BY_EXTENSION[extension] ?? DEFAULT_CONTENT_TYPE;
}
