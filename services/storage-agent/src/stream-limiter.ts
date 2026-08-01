/**
 * Limiteur de flux simultanés.
 *
 * Compteur borné SANS file d'attente : au-delà de la limite, la requête est
 * refusée immédiatement (503 + `Retry-After`). Une file d'attente non bornée
 * transformerait une saturation disque en accumulation mémoire, et un client
 * patient en fuite de ressources.
 *
 * Seuls les GET consomment un emplacement. HEAD et `/health` n'en prennent
 * jamais : ce sont des opérations `stat`, elles doivent rester disponibles même
 * quand le disque est saturé — c'est précisément à ce moment qu'on a besoin de
 * diagnostiquer.
 */
export class StreamLimiter {
  private active = 0;

  constructor(readonly limit: number) {
    if (!Number.isInteger(limit) || limit < 1) {
      throw new Error('StreamLimiter : limite entière >= 1 attendue.');
    }
  }

  get activeStreams(): number {
    return this.active;
  }

  /**
   * Réserve un emplacement. Retourne `null` si la limite est atteinte, sinon
   * une fonction de libération IDEMPOTENTE — elle sera appelée depuis plusieurs
   * chemins (`close`, `error`, `aborted`) et ne doit décrémenter qu'une fois.
   */
  acquire(): (() => void) | null {
    if (this.active >= this.limit) return null;
    this.active += 1;
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active -= 1;
    };
  }
}
