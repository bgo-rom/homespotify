import { Algorithm, hash, verify } from '@node-rs/argon2';

// Argon2id (recommandation OWASP) via @node-rs/argon2 : binaires précompilés,
// aucun script postinstall (cf. LESSONS.md L-007). Paramètres alignés sur les
// minimums OWASP 2024 : m=19 MiB, t=2, p=1.
const ARGON2_OPTIONS = {
  algorithm: Algorithm.Argon2id,
  memoryCost: 19_456,
  timeCost: 2,
  parallelism: 1,
} as const;

export const PASSWORD_MIN_LENGTH = 10;
export const PASSWORD_MAX_LENGTH = 128;

export function hashPassword(password: string): Promise<string> {
  return hash(password, ARGON2_OPTIONS);
}

export async function verifyPassword(passwordHash: string, password: string): Promise<boolean> {
  try {
    return await verify(passwordHash, password);
  } catch {
    // Hash corrompu ou format inconnu : refus, jamais d'exception vers la route.
    return false;
  }
}

// Hash factice vérifié quand l'utilisateur n'existe pas, pour que le temps de
// réponse d'un login échoué ne révèle pas l'existence du compte.
let dummyHashPromise: Promise<string> | null = null;
export async function verifyAgainstDummy(password: string): Promise<void> {
  dummyHashPromise ??= hashPassword('homespotify-dummy-password');
  await verifyPassword(await dummyHashPromise, password);
}

export function validatePassword(password: unknown): string | null {
  if (typeof password !== 'string') return null;
  if (password.length < PASSWORD_MIN_LENGTH || password.length > PASSWORD_MAX_LENGTH) return null;
  return password;
}
