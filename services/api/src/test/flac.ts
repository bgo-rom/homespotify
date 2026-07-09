// Fabrique de FLAC minimal valide (marqueur fLaC + bloc STREAMINFO) pour les tests.
// music-metadata lit le STREAMINFO → container/codec/lossless/sampleRate/bitDepth/durée.
// Hors build (tsconfig exclude). Aucun vrai fichier audio versionné.

export function makeFlac(
  opts: {
    sampleRate?: number;
    bitDepth?: number;
    channels?: number;
    seconds?: number;
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

  const blockHeader = Buffer.from([0x80, 0x00, 0x00, 0x22]); // dernier bloc, type 0, longueur 34
  return Buffer.concat([Buffer.from('fLaC', 'ascii'), blockHeader, streaminfo]);
}
