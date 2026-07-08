// Fabrique de WAV PCM valides pour les tests (RIFF INFO optionnel). Hors build (tsconfig exclude).

function riffChunk(id: string, body: Buffer): Buffer {
  const padded = body.length % 2 ? Buffer.concat([body, Buffer.alloc(1)]) : body;
  const header = Buffer.alloc(8);
  header.write(id, 0, 4, 'ascii');
  header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, padded]);
}

export function makeWav(
  opts: {
    sampleRate?: number;
    bitDepth?: number;
    seconds?: number;
    title?: string;
    artist?: string;
  } = {},
): Buffer {
  const { sampleRate = 44100, bitDepth = 16, seconds = 0.05, title, artist } = opts;
  const bytesPerSample = bitDepth / 8;
  const data = Buffer.alloc(Math.floor(sampleRate * seconds) * bytesPerSample); // mono, silence
  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(1, 0); // PCM
  fmt.writeUInt16LE(1, 2); // mono
  fmt.writeUInt32LE(sampleRate, 4);
  fmt.writeUInt32LE(sampleRate * bytesPerSample, 8);
  fmt.writeUInt16LE(bytesPerSample, 12);
  fmt.writeUInt16LE(bitDepth, 14);
  const chunks = [Buffer.from('WAVE'), riffChunk('fmt ', fmt), riffChunk('data', data)];
  if (title !== undefined || artist !== undefined) {
    const info: Buffer[] = [Buffer.from('INFO')];
    if (title !== undefined) info.push(riffChunk('INAM', Buffer.from(`${title}\0`, 'latin1')));
    if (artist !== undefined) info.push(riffChunk('IART', Buffer.from(`${artist}\0`, 'latin1')));
    chunks.push(riffChunk('LIST', Buffer.concat(info)));
  }
  const body = Buffer.concat(chunks);
  const riff = Buffer.alloc(8);
  riff.write('RIFF', 0, 4, 'ascii');
  riff.writeUInt32LE(body.length, 4);
  return Buffer.concat([riff, body]);
}
