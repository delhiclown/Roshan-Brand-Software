import { mkdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const require = createRequire(import.meta.url);
const QRCode = require('qrcode');
const jsQR = require('jsqr');
const { PNG } = require('pngjs');
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outputDirectory = join(projectRoot, 'public', 'qr');
const entries = [
  ['whatsapp-group', 'whatsappGroup', 'WhatsApp Group'],
  ['whatsapp-channel', 'whatsappChannel', 'WhatsApp Channel'],
  ['telegram-channel', 'telegramChannel', 'Telegram Channel']
];

await mkdir(outputDirectory, { recursive: true });

for (const [fileName, linkKey, label] of entries) {
  const url = require('../public/community-links.js')[linkKey];
  const options = {
    errorCorrectionLevel: 'Q',
    version: 5,
    margin: 2,
    width: 168,
    color: { dark: '#050816', light: '#f5f7fa' }
  };
  const svg = await QRCode.toString(url, { ...options, type: 'svg' });
  const pngBuffer = await QRCode.toBuffer(url, options);
  const png = PNG.sync.read(pngBuffer);
  const decoded = jsQR(png.data, png.width, png.height, {
    inversionAttempts: 'dontInvert'
  });

  if (!decoded || decoded.data !== url) {
    throw new Error(`${label} QR decode mismatch: ${decoded?.data ?? 'no QR detected'}`);
  }

  await writeFile(join(outputDirectory, `${fileName}.svg`), svg, 'utf8');
  console.log(`${label}: decoded link matches configured destination`);
}
