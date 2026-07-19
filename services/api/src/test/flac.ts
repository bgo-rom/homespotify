// Fabrique de FLAC minimal valide (marqueur fLaC + bloc STREAMINFO) pour les tests.
// music-metadata lit le STREAMINFO → container/codec/lossless/sampleRate/bitDepth/durée.
// Hors build (tsconfig exclude). Aucun vrai fichier audio versionné.

export function makeFlac(
  opts: {
    sampleRate?: number;
    bitDepth?: number;
    channels?: number;
    seconds?: number;
    tags?: Record<string, string>;
    picture?: {
      mimeType?: 'image/jpeg' | 'image/png';
      data: Buffer;
      width?: number;
      height?: number;
    };
  } = {},
): Buffer {
  const { sampleRate = 44100, bitDepth = 16, channels = 2, seconds = 0.5 } = opts;
  const totalSamples = Math.floor(sampleRate * seconds);

  const streaminfo = Buffer.alloc(34);
  streaminfo.writeUInt16BE(4096, 0); // min block size
  streaminfo.writeUInt16BE(4096, 2); // max block size
  // min/max frame size (u24) restent à 0
  const packed =
    (BigInt(sampleRate) << 44n) |
    (BigInt(channels - 1) << 41n) |
    (BigInt(bitDepth - 1) << 36n) |
    BigInt(totalSamples);
  streaminfo.writeBigUInt64BE(packed, 10);
  // MD5 (16 octets) reste à 0

  const extraBlocks: Buffer[] = [];
  if (opts.tags !== undefined) {
    const vendor = Buffer.from('HomeSpotify test fixture', 'utf8');
    const comments = Object.entries(opts.tags).map(([key, value]) =>
      Buffer.from(`${key.toUpperCase()}=${value}`, 'utf8')
    );
    const vendorLength = Buffer.alloc(4);
    vendorLength.writeUInt32LE(vendor.length);
    const count = Buffer.alloc(4);
    count.writeUInt32LE(comments.length);
    const fields = comments.flatMap((comment) => {
      const length = Buffer.alloc(4);
      length.writeUInt32LE(comment.length);
      return [length, comment];
    });
    extraBlocks.push(metadataBlock(4, Buffer.concat([
      vendorLength,
      vendor,
      count,
      ...fields,
    ])));
  }
  if (opts.picture !== undefined) {
    const mime = Buffer.from(opts.picture.mimeType ?? 'image/jpeg', 'ascii');
    const description = Buffer.from('Front cover', 'utf8');
    const fixed = Buffer.alloc(4 * 8);
    fixed.writeUInt32BE(3, 0); // front cover
    fixed.writeUInt32BE(mime.length, 4);
    fixed.writeUInt32BE(description.length, 8);
    fixed.writeUInt32BE(opts.picture.width ?? 2, 12);
    fixed.writeUInt32BE(opts.picture.height ?? 2, 16);
    fixed.writeUInt32BE(24, 20);
    fixed.writeUInt32BE(0, 24);
    fixed.writeUInt32BE(opts.picture.data.length, 28);
    extraBlocks.push(metadataBlock(6, Buffer.concat([
      fixed.subarray(0, 8),
      mime,
      fixed.subarray(8, 12),
      description,
      fixed.subarray(12),
      opts.picture.data,
    ])));
  }

  const streamInfoHeader = metadataHeader(0, streaminfo.length, extraBlocks.length === 0);
  if (extraBlocks.length > 0) {
    const last = extraBlocks.length - 1;
    extraBlocks[last]![0] |= 0x80;
  }
  return Buffer.concat([
    Buffer.from('fLaC', 'ascii'),
    streamInfoHeader,
    streaminfo,
    ...extraBlocks,
  ]);
}

function metadataHeader(type: number, length: number, isLast: boolean): Buffer {
  const header = Buffer.alloc(4);
  header[0] = type | (isLast ? 0x80 : 0);
  header.writeUIntBE(length, 1, 3);
  return header;
}

function metadataBlock(type: number, payload: Buffer): Buffer {
  return Buffer.concat([metadataHeader(type, payload.length, false), payload]);
}
