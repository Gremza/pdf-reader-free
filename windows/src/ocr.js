import Tesseract from "../node_modules/tesseract.js/dist/tesseract.esm.min.js";
import {
  StandardFonts, TextRenderingMode, beginText, endText, popGraphicsState, pushGraphicsState,
  setFontAndSize, setTextMatrix, setTextRenderingMode, showText,
} from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";
import { load } from "./editing.js";

/**
 * "Recognize Text": finds the text of scanned pages with Tesseract and adds it as an invisible
 * layer over each page, so it can be searched and copied. Pages that already have text are skipped.
 */

export class CancelledError extends Error {}

// Everything is bundled with the app, so recognizing works offline
const APP = new URL("../", import.meta.url).href;
const TESSERACT_OPTIONS = {
  workerPath: APP + "node_modules/tesseract.js/dist/worker.min.js",
  workerBlobURL: false,
  // Electron's Chromium has WebAssembly SIMD; the other builds of the core are left out of the installer
  corePath: APP + "node_modules/tesseract.js-core/tesseract-core-simd-lstm.wasm.js",
  // The "fast" models of tessdata_fast, gzipped
  langPath: APP + "src/tessdata",
  gzip: true,
  cacheMethod: "none",
};
const LANGUAGES = "sqi+eng";
// Scanned pages are read at 300 DPI, but never larger than this many pixels on a side
const OCR_DPI = 300;
const MAX_SIDE = 6000;

/**
 * `pdf` is the pdf.js document of `bytes`. Returns { bytes, pages, skipped }: the new PDF, the number
 * of pages that got text and the number that already had text. `progress` gets the pages done so far;
 * when `isCancelled()` turns true, it throws CancelledError.
 */
export async function recognizeText(bytes, pdf, progress, isCancelled) {
  const doc = await load(bytes);
  const worker = await Tesseract.createWorker(LANGUAGES, Tesseract.OEM.LSTM_ONLY, TESSERACT_OPTIONS);
  try {
    let font = null;
    let pages = 0;
    let skipped = 0;
    for (let n = 1; n <= pdf.numPages; n++) {
      if (isCancelled()) throw new CancelledError();
      const page = await pdf.getPage(n);
      if (await hasText(page)) {
        skipped++;
      } else {
        const { lines, viewport } = await recognizeLines(worker, page);
        if (lines.length) {
          font ??= await doc.embedFont(StandardFonts.Helvetica);
          drawInvisible(doc.getPage(n - 1), font, lines, viewport);
          pages++;
        }
      }
      progress(n);
    }
    return { bytes: pages ? await doc.save() : bytes, pages, skipped };
  } finally {
    await worker.terminate();
  }
}

async function hasText(page) {
  const { items } = await page.getTextContent();
  return items.some((item) => item.str?.trim());
}

/** Draws the page upright, like it is shown, and reads its lines of text, in pixels of that image. */
async function recognizeLines(worker, page) {
  const { width, height } = page.getViewport({ scale: 1 });
  const viewport = page.getViewport({ scale: Math.min(OCR_DPI / 72, MAX_SIDE / Math.max(width, height, 1)) });
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(viewport.width);
  canvas.height = Math.round(viewport.height);
  try {
    await page.render({
      canvas,
      canvasContext: canvas.getContext("2d"),
      viewport,
      // Only the page content, like on macOS; form fields and notes are not part of the scan
      annotationMode: globalThis.pdfjsLib.AnnotationMode.DISABLE,
      background: "#ffffff",
    }).promise;
    const { data } = await worker.recognize(canvas, {}, { text: false, tsv: true });
    return { lines: linesOf(data.tsv), viewport };
  } finally {
    canvas.width = canvas.height = 0;
  }
}

/** Tesseract's TSV has a row per line (level 4) with its box, then a row per word (level 5). */
function linesOf(tsv) {
  const lines = new Map();
  for (const row of tsv.split("\n")) {
    const [level, , block, paragraph, line, , left, top, width, height, , text = ""] = row.split("\t");
    const key = `${block}.${paragraph}.${line}`;
    if (level === "4") {
      lines.set(key, { box: { x: +left, y: +top, width: +width, height: +height }, words: [] });
    } else if (level === "5" && text.trim()) {
      lines.get(key)?.words.push(text.trim());
    }
  }
  return [...lines.values()].filter((line) => line.words.length && line.box.width > 0 && line.box.height > 0)
    .map((line) => ({ text: line.words.join(" "), box: line.box }));
}

/**
 * Each line is stretched over the width Tesseract found for it, so selections match the scan.
 * The viewport maps the image's pixels back to the page, whatever its rotation.
 */
function drawInvisible(page, font, lines, viewport) {
  const fontKey = page.node.newFontDictionary(font.name, font.ref);
  const height = font.heightAtSize(1);
  const descent = height - font.heightAtSize(1, { descender: false });
  const characters = new Set(font.getCharacterSet());
  const operators = [pushGraphicsState(), beginText(), setFontAndSize(fontKey, 1), setTextRenderingMode(TextRenderingMode.Invisible)];
  for (const { text, box } of lines) {
    // Helvetica can only show the characters of WinAnsi; the others are left out
    const shown = [...text].filter((char) => characters.has(char.codePointAt(0))).join("");
    const width = font.widthOfTextAtSize(shown, 1);
    if (!shown.trim() || width <= 0) continue;
    const size = box.height / height;
    const baseline = box.y + box.height - descent * size;
    const [ox, oy] = viewport.convertToPdfPoint(box.x, baseline);
    const [rx, ry] = viewport.convertToPdfPoint(box.x + box.width, baseline);
    const [ux, uy] = viewport.convertToPdfPoint(box.x, baseline - size);
    operators.push(
      setTextMatrix((rx - ox) / width, (ry - oy) / width, ux - ox, uy - oy, ox, oy),
      showText(font.encodeText(shown)),
    );
  }
  operators.push(endText(), popGraphicsState());
  page.pushOperators(...operators);
}
