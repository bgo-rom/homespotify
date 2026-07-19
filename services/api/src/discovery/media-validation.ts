/**
 * Pré-validation LÉGÈRE d'un média avant de marquer un candidat MEDIA_READY.
 * On ne télécharge JAMAIS l'extrait : une requête HEAD (repli GET Range 0-0)
 * vérifie seulement que l'URL est https, joignable (2xx) et de type audio.
 * L'artwork est validé sur ses dimensions déclarées par le catalogue (déjà
 * connues) — pas de fetch d'image ici.
 */

export interface PreviewValidationResult {
  ok: boolean;
  /** Raison stable d'échec (diagnostics) : NOT_HTTPS | HTTP_<code> | BAD_MIME | NETWORK. */
  reason: string | null;
  contentType: string | null;
}

export interface ValidatePreviewOptions {
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

const AUDIO_MIME_RE = /^(audio\/|application\/(octet-stream|x-mpegurl|vnd\.apple\.mpegurl))/iu;

/**
 * Vérifie qu'une previewUrl est servie en https avec un type audio. HEAD
 * d'abord ; si le serveur ne supporte pas HEAD (405/501) on retombe sur un GET
 * Range `bytes=0-0` (un seul octet, jamais le fichier entier).
 */
export async function validatePreviewUrl(
  url: string,
  options: ValidatePreviewOptions = {},
): Promise<PreviewValidationResult> {
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = options.timeoutMs ?? 6_000;

  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return { ok: false, reason: 'NOT_HTTPS', contentType: null };
  }
  if (parsed.protocol !== 'https:') {
    return { ok: false, reason: 'NOT_HTTPS', contentType: null };
  }

  const attempt = async (method: 'HEAD' | 'GET'): Promise<Response> => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetchImpl(url, {
        method,
        signal: controller.signal,
        headers: method === 'GET' ? { range: 'bytes=0-0' } : {},
      });
    } finally {
      clearTimeout(timer);
    }
  };

  try {
    let response = await attempt('HEAD');
    if (response.status === 405 || response.status === 501) {
      response = await attempt('GET');
    }
    if (!(response.status >= 200 && response.status < 300) && response.status !== 206) {
      return { ok: false, reason: `HTTP_${response.status}`, contentType: null };
    }
    const contentType = response.headers.get('content-type');
    // Certains CDN audio ne renvoient pas de content-type sur HEAD : on tolère
    // l'absence (status déjà 2xx), on ne rejette que sur un type NON audio explicite.
    if (contentType !== null && contentType.length > 0 && !AUDIO_MIME_RE.test(contentType)) {
      return { ok: false, reason: 'BAD_MIME', contentType };
    }
    return { ok: true, reason: null, contentType };
  } catch {
    return { ok: false, reason: 'NETWORK', contentType: null };
  }
}

/** Artwork suffisant : URL https et ≥ minPx sur les deux dimensions déclarées. */
export function isArtworkSufficient(
  artworkUrl: string | null,
  width: number | null,
  height: number | null,
  minPx: number,
): boolean {
  if (artworkUrl === null) return false;
  try {
    if (new URL(artworkUrl).protocol !== 'https:') return false;
  } catch {
    return false;
  }
  return width !== null && height !== null && width >= minPx && height >= minPx;
}
