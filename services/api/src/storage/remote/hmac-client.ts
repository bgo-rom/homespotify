import { createHash, createHmac, randomBytes } from 'node:crypto';

export const EMPTY_BODY_SHA256 =
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

export interface HmacCanonicalParts {
  method: string;
  pathWithQuery: string;
  timestamp: number;
  nonce: string;
  contentSha256: string;
}

export function canonicalString(parts: HmacCanonicalParts): string {
  return [
    parts.method.toUpperCase(),
    parts.pathWithQuery,
    String(parts.timestamp),
    parts.nonce,
    parts.contentSha256.toLowerCase(),
  ].join('\n');
}

export function sha256Hex(body: Buffer | string): string {
  return createHash('sha256').update(body).digest('hex');
}

export function signCanonical(
  secret: string,
  parts: HmacCanonicalParts,
): string {
  return createHmac('sha256', secret)
    .update(canonicalString(parts), 'utf8')
    .digest('hex');
}

export function generateNonce(): string {
  return randomBytes(32).toString('base64url');
}

export function buildSignedHeaders(options: {
  secret: string;
  method: string;
  pathWithQuery: string;
  timestamp?: number;
  nonce?: string;
  requestId?: string;
}): Record<string, string> {
  const timestamp = options.timestamp ?? Math.floor(Date.now() / 1_000);
  const nonce = options.nonce ?? generateNonce();
  const signature = signCanonical(options.secret, {
    method: options.method,
    pathWithQuery: options.pathWithQuery,
    timestamp,
    nonce,
    contentSha256: EMPTY_BODY_SHA256,
  });
  return {
    'x-hs-timestamp': String(timestamp),
    'x-hs-nonce': nonce,
    'x-hs-content-sha256': EMPTY_BODY_SHA256,
    'x-hs-signature': signature,
    ...(options.requestId === undefined
      ? {}
      : { 'x-request-id': options.requestId }),
  };
}
