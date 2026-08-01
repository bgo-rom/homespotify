import { describe, expect, it } from 'vitest';
import { adaptAntraLine, NdjsonLineSplitter } from './antra-event-adapter.js';
import type { DownloadProviderEvent } from './download-provider.js';

function eventsOf(line: string): DownloadProviderEvent[] {
  return adaptAntraLine(line).events;
}

describe('adaptAntraLine — lignes valides', () => {
  it('traduit un log en événement de journal assaini', () => {
    const events = eventsOf(
      JSON.stringify({
        type: 'log',
        level: 'warning',
        message: 'Retry with ANTRA_API_KEY=sk_live_secret123',
      }),
    );
    expect(events).toHaveLength(1);
    const [event] = events;
    expect(event?.type).toBe('log');
    if (event?.type !== 'log') return;
    expect(event.level).toBe('warn');
    expect(event.message).not.toContain('sk_live_secret123');
  });

  it('traduit playlist_loaded en étape de résolution avec titre et artiste', () => {
    const events = eventsOf(
      JSON.stringify({
        type: 'playlist_loaded',
        title: 'Lifestyles',
        artists_string: 'Guala',
        track_count: 1,
      }),
    );
    expect(events).toHaveLength(1);
    const [event] = events;
    if (event?.type !== 'stage') throw new Error('étape attendue');
    expect(event.stage).toBe('resolving');
    expect(event.track?.title).toBe('Lifestyles');
    expect(event.track?.artist).toBe('Guala');
  });

  it('traduit les événements de piste en étapes et progression', () => {
    const started = eventsOf(
      JSON.stringify({
        type: 'event',
        name: 'track_started',
        payload: { track: 'Lifestyles', artist: 'Guala', track_index: 0, track_total: 2 },
      }),
    );
    expect(started.find((event) => event.type === 'stage')).toMatchObject({
      stage: 'resolving',
    });

    const attempt = eventsOf(
      JSON.stringify({
        type: 'event',
        name: 'track_download_attempt',
        payload: {
          track: 'Lifestyles',
          artist: 'Guala',
          source: 'qobuz',
          track_index: 0,
          track_total: 2,
        },
      }),
    );
    expect(attempt.find((event) => event.type === 'stage')).toMatchObject({
      stage: 'downloading',
    });

    const completed = eventsOf(
      JSON.stringify({
        type: 'event',
        name: 'track_completed',
        payload: {
          track: 'Lifestyles',
          artist: 'Guala',
          source: 'qobuz',
          quality_label: 'FLAC 24-bit/96kHz',
          track_index: 0,
          track_total: 2,
          track_data: { album: 'Lifestyles', duration_ms: 180_000 },
        },
      }),
    );
    const stage = completed.find((event) => event.type === 'stage');
    if (stage?.type !== 'stage') throw new Error('étape attendue');
    expect(stage.track?.quality).toBe('FLAC 24-bit/96kHz');
    expect(stage.track?.source).toBe('qobuz');
    expect(stage.track?.durationSeconds).toBe(180);
    // Une piste terminée sur deux = 50 %.
    expect(completed.find((event) => event.type === 'progress')).toMatchObject({
      percent: 50,
    });
  });

  it('remonte une erreur de piste sous forme d’événement d’erreur', () => {
    const events = eventsOf(
      JSON.stringify({
        type: 'event',
        name: 'track_failed',
        payload: { track: 'X', artist: 'Y', error: 'No source found' },
      }),
    );
    expect(events[0]).toMatchObject({
      type: 'error',
      code: 'ANTRA_TRACK_FAILED',
      message: 'No source found',
    });
  });

  it('traduit progress en pourcentage borné', () => {
    const events = eventsOf(
      JSON.stringify({
        type: 'progress',
        stage: 'downloading',
        tracks_completed: 3,
        tracks_total: 4,
      }),
    );
    expect(events.find((event) => event.type === 'progress')).toMatchObject({
      percent: 75,
    });
  });

  it('extrait le résumé final et son erreur', () => {
    const result = adaptAntraLine(
      JSON.stringify({
        type: 'playlist_summary',
        total: 1,
        downloaded: 1,
        failed: 0,
        skipped: 0,
        error: null,
        title: 'Lifestyles',
      }),
    );
    expect(result.summary).toMatchObject({ downloaded: 1, failed: 0 });

    const failure = adaptAntraLine(
      JSON.stringify({
        type: 'playlist_summary',
        total: 0,
        downloaded: 0,
        failed: 1,
        skipped: 0,
        error: 'Album unavailable in this region',
      }),
    );
    expect(failure.summary?.errorMessage).toBe('Album unavailable in this region');
    expect(failure.events[0]).toMatchObject({ type: 'error' });
  });

  it('reconnaît la fin du moteur', () => {
    expect(adaptAntraLine('{"type":"done"}').done).toBe(true);
  });
});

describe('adaptAntraLine — lignes invalides', () => {
  it('ignore proprement toute ligne non JSON ou inconnue', () => {
    for (const line of [
      '',
      '   ',
      'Antra — Library That Does It All',
      '{ceci n’est pas du json',
      '[1,2,3]',
      '"chaine"',
      'null',
      JSON.stringify({ type: 'type_inconnu', payload: {} }),
    ]) {
      const result = adaptAntraLine(line);
      expect(result.events, line).toEqual([]);
      expect(result.summary, line).toBeUndefined();
    }
  });

  it('n’échoue pas sur une charge utile partielle', () => {
    expect(eventsOf(JSON.stringify({ type: 'event', name: 'track_started' }))).toEqual(
      [{ type: 'stage', stage: 'resolving', message: null }],
    );
  });
});

describe('NdjsonLineSplitter', () => {
  it('recompose une ligne JSON coupée entre deux chunks', () => {
    const splitter = new NdjsonLineSplitter();
    expect(splitter.push('{"type":"log","level":"info",')).toEqual([]);
    expect(splitter.push('"message":"ok"}\n')).toEqual([
      '{"type":"log","level":"info","message":"ok"}',
    ]);
  });

  it('découpe plusieurs événements d’un même chunk, CRLF compris', () => {
    const splitter = new NdjsonLineSplitter();
    expect(splitter.push('{"a":1}\r\n{"b":2}\n{"c":3}')).toEqual([
      '{"a":1}',
      '{"b":2}',
    ]);
    expect(splitter.flush()).toEqual(['{"c":3}']);
  });

  it('abandonne une ligne aberrante au lieu d’accumuler indéfiniment', () => {
    const splitter = new NdjsonLineSplitter(16);
    splitter.push('x'.repeat(64));
    expect(splitter.flush()).toEqual([]);
  });
});
