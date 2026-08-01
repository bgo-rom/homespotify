import { mkdtempSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { StorageAgentError } from './errors.js';
import { parseStorageIndex, StorageIndexStore, type IndexEvent } from './storage-index.js';

function documentWith(entries: unknown, extra: Record<string, unknown> = {}): string {
  return JSON.stringify({
    version: 1,
    generatedAt: '2026-07-26T10:00:00.000Z',
    entries,
    ...extra,
  });
}

describe('parseStorageIndex — document valide', () => {
  it('accepte un index conforme et normalise les séparateurs', () => {
    const parsed = parseStorageIndex(
      documentWith({
        1: { relativePath: 'Artiste/Album/Piste.flac' },
        42: { relativePath: 'Artiste\\Album\\Autre.flac' },
      }),
    );
    expect(parsed.version).toBe(1);
    expect(parsed.generatedAt).toBe('2026-07-26T10:00:00.000Z');
    expect(parsed.entries.get(1)).toBe('Artiste/Album/Piste.flac');
    expect(parsed.entries.get(42)).toBe('Artiste/Album/Autre.flac');
    expect(parsed.entries.size).toBe(2);
  });

  it('accepte un index vide', () => {
    expect(parseStorageIndex(documentWith({})).entries.size).toBe(0);
  });
});

describe('parseStorageIndex — rejets', () => {
  function expectRejected(raw: string, pattern: RegExp): void {
    let captured: unknown;
    try {
      parseStorageIndex(raw);
    } catch (error) {
      captured = error;
    }
    expect(captured).toBeInstanceOf(StorageAgentError);
    expect((captured as StorageAgentError).code).toBe('INDEX_INVALID');
    expect((captured as StorageAgentError).detail).toMatch(pattern);
  }

  it('JSON invalide', () => {
    expectRejected('{ ceci n’est pas du JSON', /JSON illisible/);
  });

  it('racine non objet', () => {
    expectRejected('[]', /racine JSON non objet/);
  });

  it('version inconnue', () => {
    expectRejected(
      JSON.stringify({ version: 2, generatedAt: '2026-07-26T10:00:00.000Z', entries: {} }),
      /version non supportée/,
    );
  });

  it('clé racine inconnue', () => {
    expectRejected(documentWith({}, { musicRoot: 'F:\\music' }), /clé racine inconnue/);
  });

  it('generatedAt absent ou non ISO', () => {
    expectRejected(
      JSON.stringify({ version: 1, generatedAt: 'hier', entries: {} }),
      /generatedAt/,
    );
  });

  it('entries absent', () => {
    expectRejected(JSON.stringify({ version: 1, generatedAt: '2026-07-26T10:00:00.000Z' }), /entries/);
  });

  it('entrée non objet', () => {
    expectRejected(documentWith({ 1: 'Artiste/Piste.flac' }), /entrée #1 non objet/);
  });

  it('champ d’entrée inconnu', () => {
    expectRejected(
      documentWith({ 1: { relativePath: 'a.flac', absolutePath: 'F:\\a.flac' } }),
      /champ inconnu/,
    );
  });

  it('identifiant non canonique (alias « 01 » de la piste 1)', () => {
    expectRejected(documentWith({ '01': { relativePath: 'a.flac' } }), /non canonique/);
    expectRejected(documentWith({ '0': { relativePath: 'a.flac' } }), /non canonique/);
    expectRejected(documentWith({ '-1': { relativePath: 'a.flac' } }), /non canonique/);
    expectRejected(documentWith({ 'abc': { relativePath: 'a.flac' } }), /non canonique/);
  });

  it('doublon d’identifiant après canonicalisation', () => {
    // JSON.parse écrase silencieusement une clé littéralement dupliquée ; le
    // seul doublon OBSERVABLE est l'alias non canonique, refusé ci-dessus.
    // Ce test verrouille la garantie côté structure.
    const parsed = parseStorageIndex(documentWith({ 1: { relativePath: 'a.flac' } }));
    expect(parsed.entries.size).toBe(1);
    expectRejected(documentWith({ 1: { relativePath: 'a.flac' }, '01': { relativePath: 'b.flac' } }), /non canonique/);
  });

  it('chemin traversal', () => {
    expectRejected(
      documentWith({ 7: { relativePath: '../secret.txt' } }),
      /entrée #7 : chemin refusé \(TRAVERSAL\)/,
    );
  });

  it('chemin absolu Windows', () => {
    expectRejected(
      documentWith({ 7: { relativePath: 'C:\\Windows\\notepad.exe' } }),
      /chemin refusé \(WINDOWS_ABSOLUTE\)/,
    );
  });

  it('chemin absolu Unix', () => {
    expectRejected(
      documentWith({ 7: { relativePath: '/etc/passwd' } }),
      /chemin refusé \(ABSOLUTE\)/,
    );
  });

  it('chemin UNC', () => {
    expectRejected(
      documentWith({ 7: { relativePath: '\\\\serveur\\partage\\x.flac' } }),
      /chemin refusé \(UNC\)/,
    );
  });

  it('chemin vide ou non textuel', () => {
    expectRejected(documentWith({ 7: { relativePath: '' } }), /chemin refusé \(EMPTY\)/);
    expectRejected(documentWith({ 7: { relativePath: 42 } }), /chemin refusé \(NOT_A_STRING\)/);
    expectRejected(documentWith({ 7: {} }), /chemin refusé \(NOT_A_STRING\)/);
  });

  it('une seule entrée dangereuse invalide TOUT l’index', () => {
    let captured: unknown;
    try {
      parseStorageIndex(
        documentWith({
          1: { relativePath: 'Artiste/Album/Bon.flac' },
          2: { relativePath: '../../secret.txt' },
        }),
      );
    } catch (error) {
      captured = error;
    }
    expect(captured).toBeInstanceOf(StorageAgentError);
  });

  it('le motif d’erreur ne contient jamais le chemin fautif', () => {
    try {
      parseStorageIndex(documentWith({ 7: { relativePath: '../Musique secrète/x.flac' } }));
      expect.unreachable('doit lever');
    } catch (error) {
      expect((error as StorageAgentError).detail).not.toContain('Musique secrète');
    }
  });
});

describe('StorageIndexStore', () => {
  let root: string;
  let indexPath: string;
  let events: IndexEvent[];

  beforeEach(() => {
    root = mkdtempSync(join(tmpdir(), 'hs-index-store-'));
    indexPath = join(root, 'index.json');
    events = [];
  });

  afterEach(() => {
    rmSync(root, { recursive: true, force: true });
  });

  function store(): StorageIndexStore {
    return new StorageIndexStore({
      indexPath,
      pollIntervalMs: 0,
      onEvent: (event) => events.push(event),
    });
  }

  it('charge un index valide au démarrage', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    expect(subject.reloadIfChanged()).toBe(true);
    expect(subject.current?.entries.size).toBe(1);
    expect(subject.lookup(1)).toBe('a/b.flac');
    expect(events[0]).toMatchObject({ event: 'STORAGE_AGENT_INDEX_LOADED', entryCount: 1 });
  });

  it('fichier d’index absent : aucun index, motif journalisé', () => {
    const subject = store();
    expect(subject.reloadIfChanged()).toBe(false);
    expect(subject.current).toBeNull();
    expect(subject.lookup(1)).toBeUndefined();
    expect(events[0]).toMatchObject({
      event: 'STORAGE_AGENT_INDEX_REJECTED',
      keptPreviousIndex: false,
    });
  });

  it('ne recharge pas un fichier inchangé', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    expect(subject.reloadIfChanged()).toBe(true);
    expect(subject.reloadIfChanged()).toBe(false);
    expect(events.filter((e) => e.event === 'STORAGE_AGENT_INDEX_LOADED')).toHaveLength(1);
  });

  it('recharge un index modifié', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    subject.reloadIfChanged();
    const firstLoadedAt = subject.current?.loadedAt;

    writeFileSync(
      indexPath,
      documentWith({ 1: { relativePath: 'a/b.flac' }, 2: { relativePath: 'c/d.flac' } }),
    );
    expect(subject.reloadIfChanged()).toBe(true);
    expect(subject.current?.entries.size).toBe(2);
    expect(subject.lookup(2)).toBe('c/d.flac');
    expect(subject.current?.loadedAt.getTime()).toBeGreaterThanOrEqual(
      firstLoadedAt?.getTime() ?? 0,
    );
  });

  it('un index invalide ne remplace JAMAIS l’index valide en place', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    subject.reloadIfChanged();

    writeFileSync(indexPath, '{ cassé');
    expect(subject.reloadIfChanged()).toBe(false);
    expect(subject.current?.entries.size).toBe(1);
    expect(subject.lookup(1)).toBe('a/b.flac');
    expect(events.at(-1)).toMatchObject({
      event: 'STORAGE_AGENT_INDEX_REJECTED',
      keptPreviousIndex: true,
    });
  });

  it('une entrée dangereuse fait rejeter le rechargement entier', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    subject.reloadIfChanged();

    writeFileSync(
      indexPath,
      documentWith({ 1: { relativePath: 'a/b.flac' }, 2: { relativePath: '../secret.txt' } }),
    );
    expect(subject.reloadIfChanged()).toBe(false);
    expect(subject.current?.entries.size).toBe(1);
  });

  it('réessaie un fichier corrigé sur place', () => {
    writeFileSync(indexPath, '{ cassé');
    const subject = store();
    expect(subject.reloadIfChanged()).toBe(false);
    writeFileSync(indexPath, documentWith({ 5: { relativePath: 'x.flac' } }));
    expect(subject.reloadIfChanged()).toBe(true);
    expect(subject.lookup(5)).toBe('x.flac');
  });

  it('suit un remplacement atomique par renommage', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    subject.reloadIfChanged();

    // Écriture dans un temporaire puis `rename` : c'est exactement ce que fait
    // le CLI d'export de l'API.
    const temporary = `${indexPath}.tmp`;
    writeFileSync(temporary, documentWith({ 9: { relativePath: 'neuf.flac' } }));
    renameSync(temporary, indexPath);

    expect(subject.reloadIfChanged()).toBe(true);
    expect(subject.lookup(1)).toBeUndefined();
    expect(subject.lookup(9)).toBe('neuf.flac');
  });

  it('start() sans scrutation charge une fois et ne retient pas de timer', () => {
    writeFileSync(indexPath, documentWith({ 1: { relativePath: 'a/b.flac' } }));
    const subject = store();
    subject.start();
    expect(subject.current?.entries.size).toBe(1);
    subject.stop();
  });
});
