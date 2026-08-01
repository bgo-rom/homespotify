/**
 * Recherche de pistes par TEXTE, au-dessus du catalogue de découverte déjà
 * présent dans HomeSpotify.
 *
 * Antra ne sait pas rechercher : son contrat qualifié est
 * `python -m antra.json_cli <URL>`. Il faut donc transformer « Guala
 * Lifestyles » en URL(s) exploitables. Aucun provider externe n'est ajouté :
 * `DiscoveryCatalogService` interroge déjà Deezer, iTunes, Spotify et
 * MusicBrainz, fusionne par ISRC/MBID/identité et expose, pour chaque
 * résultat, les URL publiques de chaque catalogue.
 */
import type { DiscoveryCatalogService } from '../discovery/catalog/discovery-catalog-service.js';
import { CatalogProviderError, type CatalogSearchResult } from '../discovery/catalog/types.js';

/** Nombre de résultats catalogue demandés pour un choix de téléchargement. */
export const TRACK_SEARCH_LIMIT = 12;

export interface TrackSearchQuery {
  /** Texte libre (« Guala Lifestyles ») ou champ combiné. */
  query: string;
  /** Marché catalogue ; par défaut celui de la configuration Discovery. */
  market?: string;
  limit?: number;
}

/**
 * Abstraction de recherche. Une seule implémentation réelle aujourd'hui, mais
 * le résolveur et l'orchestrateur ne dépendent que de ce contrat : les tests
 * n'appellent jamais le réseau.
 */
export interface TrackSearchProvider {
  readonly name: string;
  searchTracks(input: TrackSearchQuery): Promise<CatalogSearchResult[]>;
}

export class TrackSearchError extends Error {
  constructor(
    readonly code: 'provider_unavailable' | 'search_failed',
    message: string,
  ) {
    super(message);
    this.name = 'TrackSearchError';
  }
}

/**
 * Implémentation réelle : délègue au service catalogue existant.
 *
 * Aucun credential n'est manipulé ici — Spotify est branché par la
 * configuration Discovery, Deezer et iTunes sont publics et sans clé.
 */
export class DiscoveryTrackSearchProvider implements TrackSearchProvider {
  readonly name = 'discovery_catalog';

  constructor(
    private readonly service: DiscoveryCatalogService,
    private readonly options: { enabled: boolean } = { enabled: true },
  ) {}

  async searchTracks(input: TrackSearchQuery): Promise<CatalogSearchResult[]> {
    if (!this.options.enabled) {
      throw new TrackSearchError(
        'provider_unavailable',
        'La recherche catalogue est désactivée sur ce serveur.',
      );
    }

    try {
      const response = await this.service.search({
        query: input.query,
        type: 'track',
        limit: input.limit ?? TRACK_SEARCH_LIMIT,
        cursor: null,
        ...(input.market === undefined ? {} : { market: input.market }),
      });
      return response.items;
    } catch (error) {
      // `DiscoveryCatalogService` isole déjà chaque provider : une erreur qui
      // remonte jusqu'ici est globale, pas le fait d'un catalogue unique.
      if (error instanceof CatalogProviderError) {
        throw new TrackSearchError(
          error.category === 'DISABLED' ? 'provider_unavailable' : 'search_failed',
          'La recherche catalogue est momentanément indisponible.',
        );
      }
      throw new TrackSearchError(
        'search_failed',
        'La recherche catalogue a échoué.',
      );
    }
  }
}
