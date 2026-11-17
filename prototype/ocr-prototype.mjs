// Prototype OCR numéro de carte Pokémon — pipeline de référence CardVault
// Pré-requis : npm i tesseract.js jimp@0.22.12
// Fonctionnement : fenêtre (viseur) → gris/contraste ou binarisation Otsu →
// upscaling ×4 nearest → Tesseract (whitelist 0-9/, psm 7) → regex num/total
// Testé : swsh1-44 OK ("44/202"), base1-4 lu "94/102" (artefact → résolu en
// bases : "94" n'existe pas avant résolution par liste de candidats),
// neo1-9 : composantes "9" et "111" lues en passes séparées (combinaison).
import { createWorker } from 'tesseract.js';
import Jimp from 'jimp';

function otsu(img) {
  const hist = new Array(256).fill(0);
  const d = img.bitmap.data, n = img.bitmap.width * img.bitmap.height;
  for (let i = 0; i < n; i++) hist[d[i * 4]]++;
  let sum = 0; for (let t = 0; t < 256; t++) sum += t * hist[t];
  let sumB = 0, wB = 0, maxVar = 0, thr = 128;
  for (let t = 0; t < 256; t++) {
    wB += hist[t]; if (!wB) continue;
    const wF = n - wB; if (!wF) break;
    sumB += t * hist[t];
    const v = wB * wF * ((sumB / wB) - ((sum - sumB) / wF)) ** 2;
    if (v > maxVar) { maxVar = v; thr = t; }
  }
  return thr;
}

function prepare(img, W, H, win, mode) {
  const crop = img.clone().crop(
    Math.round(W * Math.min(win[0], win[1])), Math.round(H * win[2]),
    Math.round(W * Math.abs(win[1] - win[0])), Math.round(H * Math.min(win[3] - win[2], 1 - win[2] - 0.002)));
  crop.greyscale();
  if (mode === 'gray') crop.contrast(0.4);
  else {
    const thr = otsu(crop);
    let blacks = 0; const n = crop.bitmap.width * crop.bitmap.height;
    crop.scan(0, 0, crop.bitmap.width, crop.bitmap.height, (x, y, i) => { if (crop.bitmap.data[i] <= thr) blacks++; });
    const textDark = blacks < n / 2;
    crop.scan(0, 0, crop.bitmap.width, crop.bitmap.height, function (x, y, i) {
      const v = crop.bitmap.data[i];
      const b = (textDark ? v <= thr : v > thr) ? 0 : 255;
      crop.bitmap.data[i] = crop.bitmap.data[i + 1] = crop.bitmap.data[i + 2] = b;
    });
  }
  crop.resize(crop.bitmap.width * 4, crop.bitmap.height * 4, Jimp.RESIZE_NEAREST);
  const pad = 60;
  const padded = new Jimp(crop.bitmap.width + pad * 2, crop.bitmap.height + pad * 2, 0xffffffff);
  padded.composite(crop, pad, pad);
  return padded;
}

// Positions du numéro selon l'ère : bas-gauche (SC/SV), bas-droite (WotC Base/Neo…)
const VIEWS = {
  modern: { left: [[0.02, 0.30, 0.92, 0.975], [0.02, 0.30, 0.94, 0.985], [0.02, 0.34, 0.90, 0.96]], right: [] },
  legacy: { left: [], right: [[0.70, 0.99, 0.945, 1.0], [0.72, 0.985, 0.93, 0.985], [0.75, 0.99, 0.92, 0.975]] },
};

async function readCardNumber(imageBuffer) {
  const img = await Jimp.read(imageBuffer);
  const W = img.bitmap.width, H = img.bitmap.height;
  const worker = await createWorker('eng', 1, { logger: () => {} });
  await worker.setParameters({ tessedit_char_whitelist: '0123456789/', tessedit_pageseg_mode: '7' });
  const candidates = new Set();
  for (const era of Object.values(VIEWS)) {
    for (const win of [...era.left, ...era.right]) {
      for (const mode of ['gray', 'bin']) {
        const { data } = await worker.recognize(await prepare(img, W, H, win, mode).getBufferAsync(Jimp.MIME_PNG));
        const text = (data.text || '').replace(/\s+/g, '');
        for (const m of text.matchAll(/(\d{1,4})\/(\d{1,4})/g)) candidates.add(`${+m[1]}/${+m[2]}`);
        for (const m of text.matchAll(/\b(\d{1,3})\b/g)) candidates.add(m[1]);
      }
    }
  }
  await worker.terminate();
  return [...candidates]; // à résoudre en base : prioriser paires num/total existantes
}

export { readCardNumber };

// Démo CLI : node ocr-prototype.mjs <imageUrl ou chemin local>
if (process.argv[1].endsWith('ocr-prototype.mjs') && process.argv[2]) {
  const src = process.argv[2];
  const buf = src.startsWith('http')
    ? Buffer.from(await (await fetch(src)).arrayBuffer())
    : (await import('fs')).readFileSync(src);
  console.log('Candidats numéros :', await readCardNumber(buf));
}
