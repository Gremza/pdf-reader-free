import { EncryptedPDFError, PDFDocument, degrees } from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";
import { drawImageOnPage, insertImagePage, isPDF, readImage } from "./images.js";

/** Page operations. Each takes the PDF bytes and returns new bytes; the input is never modified. */

export class ProtectedPDFError extends Error {}

/** Opens the PDF with pdf-lib; protected PDFs throw ProtectedPDFError. */
export async function load(bytes) {
  try {
    return await PDFDocument.load(bytes, { updateMetadata: false });
  } catch (error) {
    if (error instanceof EncryptedPDFError) throw new ProtectedPDFError();
    throw error;
  }
}

async function edit(bytes, change) {
  const doc = await load(bytes);
  await change(doc);
  return doc.save();
}

function rotatePage(page, by) {
  page.setRotation(degrees((((page.getRotation().angle + by) % 360) + 360) % 360));
}

/** Indexes are 0-based. */
export const pageEdits = {
  rotateAll: (bytes, by) => edit(bytes, (doc) => doc.getPages().forEach((page) => rotatePage(page, by))),

  rotate: (bytes, index, by) => edit(bytes, (doc) => rotatePage(doc.getPage(index), by)),

  remove: (bytes, index) => edit(bytes, (doc) => doc.removePage(index)),

  move: (bytes, from, to) => edit(bytes, (doc) => {
    const page = doc.getPage(from);
    doc.removePage(from);
    doc.insertPage(to, page);
  }),

  /** Inserts an empty page with the size of the page before it. */
  insertBlank: (bytes, index) => edit(bytes, (doc) => {
    const reference = doc.getPage(Math.max(0, index - 1));
    let { width, height } = reference.getSize();
    if (reference.getRotation().angle % 180 !== 0) [width, height] = [height, width];
    doc.insertPage(index, [width, height]);
  }),

  /** Inserts the pages of PDFs, and images as pages of their own, at `index`, in order. */
  insertFiles: (bytes, index, files) => edit(bytes, (doc) => insertFiles(doc, index, files)),

  /** Draws an image of `readImage` over the page; `matrix` maps the unit square, upright as shown, onto the page. */
  addImage: (bytes, index, image, matrix) => edit(bytes, (doc) => drawImageOnPage(doc, index, image, matrix)),
};

/** "New PDF…": a PDF of the given PDFs and images ({ name, data }), in order. */
export async function createPDF(files) {
  const doc = await PDFDocument.create();
  await insertFiles(doc, 0, files);
  return doc.save();
}

/** Files that can't be read throw an error that names them. */
async function insertFiles(doc, index, files) {
  let at = index;
  for (const file of files) {
    if (isPDF(file.data)) {
      let source;
      try {
        source = await load(file.data);
      } catch (error) {
        if (error instanceof ProtectedPDFError) throw error;
        throw new UnreadableFileError(file.name);
      }
      const pages = await doc.copyPages(source, source.getPageIndices());
      for (const page of pages) doc.insertPage(at++, page);
    } else {
      let image;
      try {
        image = await readImage(file.data);
      } catch {
        throw new UnreadableFileError(file.name);
      }
      await insertImagePage(doc, image, at++);
    }
  }
}

export class UnreadableFileError extends Error {}

/** A new PDF with only the given pages (0-based), in that order. */
export async function extractPages(bytes, indexes) {
  const source = await load(bytes);
  const doc = await PDFDocument.create();
  const pages = await doc.copyPages(source, indexes);
  pages.forEach((page) => doc.addPage(page));
  return doc.save();
}

/** Checks that the PDF can be edited, so the user learns it before choosing files. */
export async function assertEditable(bytes) {
  await load(bytes);
}

/**
 * Parses "1-3, 5, 8-" into 0-based page indexes, or returns null when invalid.
 * "8-" means "from page 8 to the end".
 */
export function parsePageRanges(text, pageCount) {
  const indexes = [];
  for (const part of text.split(/[,;\s]+/).filter(Boolean)) {
    const match = part.match(/^(\d+)(?:\s*[-–]\s*(\d*))?$/);
    if (!match) return null;
    const start = Number(match[1]);
    const end = match[2] === undefined ? start : match[2] === "" ? pageCount : Number(match[2]);
    if (start < 1 || end > pageCount || start > end) return null;
    for (let n = start; n <= end; n++) indexes.push(n - 1);
  }
  return indexes.length ? indexes : null;
}
