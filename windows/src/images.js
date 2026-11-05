import {
  concatTransformationMatrix, drawObject, popGraphicsState, pushGraphicsState,
} from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";

/**
 * Images for PDF pages: as pages of their own ("New PDF…", inserting files) and over a page ("Add Image to Page").
 * JPEG and PNG go into the PDF as they are; other images are drawn into a PNG first.
 */

const A4 = [595, 842];

export function isPDF(bytes) {
  return new TextDecoder("latin1").decode(bytes.subarray(0, 1024)).includes("%PDF-");
}

/**
 * { kind, bytes, orientation, width, height }: the image to embed, its EXIF orientation (1 = upright)
 * and its size as it is shown, in pixels. Throws when the bytes are no image that can be read.
 */
export async function readImage(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    const { width, height, orientation } = jpegInfo(bytes);
    const turned = orientation >= 5;
    return { kind: "jpg", bytes, orientation, width: turned ? height : width, height: turned ? width : height };
  }
  if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return { kind: "png", bytes, orientation: 1, width: view.getUint32(16), height: view.getUint32(20) };
  }
  // GIF, BMP, WebP…: the browser decodes it, already turned upright
  const bitmap = await createImageBitmap(new Blob([bytes]));
  try {
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    canvas.getContext("2d").drawImage(bitmap, 0, 0);
    const png = new Uint8Array(await (await canvas.convertToBlob({ type: "image/png" })).arrayBuffer());
    return { kind: "png", bytes: png, orientation: 1, width: bitmap.width, height: bitmap.height };
  } finally {
    bitmap.close();
  }
}

/** The size from the SOF marker and the orientation from the EXIF block of a JPEG. */
function jpegInfo(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let width = 0;
  let height = 0;
  let orientation = 1;
  let at = 2;
  while (at + 4 <= bytes.length && bytes[at] === 0xff) {
    const marker = bytes[at + 1];
    const length = view.getUint16(at + 2);
    if (marker === 0xe1 && length > 16) {
      orientation = exifOrientation(view, at + 4, length - 2) ?? orientation;
    } else if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      height = view.getUint16(at + 5);
      width = view.getUint16(at + 7);
      break;
    }
    at += 2 + length;
  }
  if (!width || !height) throw new Error("The JPEG can't be read.");
  return { width, height, orientation };
}

function exifOrientation(view, start, length) {
  // "Exif\0\0", then a TIFF header
  if (view.getUint32(start) !== 0x45786966) return null;
  const tiff = start + 6;
  const little = view.getUint16(tiff) === 0x4949;
  const entries = tiff + view.getUint32(tiff + 4, little);
  if (entries + 2 > start + length) return null;
  const count = view.getUint16(entries, little);
  for (let i = 0; i < count; i++) {
    const entry = entries + 2 + i * 12;
    if (entry + 12 > start + length) return null;
    if (view.getUint16(entry, little) === 0x0112) {
      const value = view.getUint16(entry + 8, little);
      return value >= 1 && value <= 8 ? value : null;
    }
  }
  return null;
}

/** Turns the stored image in the unit square the way its EXIF orientation says (as on macOS). */
const ORIENTATIONS = {
  1: [1, 0, 0, 1, 0, 0],
  2: [-1, 0, 0, 1, 1, 0],
  3: [-1, 0, 0, -1, 1, 1],
  4: [1, 0, 0, -1, 0, 1],
  5: [0, -1, -1, 0, 1, 1],
  6: [0, -1, 1, 0, 0, 1],
  7: [0, 1, 1, 0, 0, 0],
  8: [0, 1, -1, 0, 1, 0],
};

async function embed(doc, image) {
  return image.kind === "jpg" ? doc.embedJpg(image.bytes) : doc.embedPng(image.bytes);
}

/** `matrix` maps the unit square, upright as the page is shown, onto the page. */
function drawImage(page, embedded, orientation, matrix) {
  const name = page.node.newXObject("Image", embedded.ref);
  page.pushOperators(
    pushGraphicsState(),
    concatTransformationMatrix(...matrix),
    concatTransformationMatrix(...ORIENTATIONS[orientation]),
    drawObject(name),
    popGraphicsState(),
  );
}

/** Inserts an A4 page at `index`, turned like the image, with the image as large as it fits. */
export async function insertImagePage(doc, image, index) {
  const [pageWidth, pageHeight] = image.width > image.height ? [A4[1], A4[0]] : A4;
  const scale = Math.min(pageWidth / image.width, pageHeight / image.height);
  const width = image.width * scale;
  const height = image.height * scale;
  const page = doc.insertPage(index, [pageWidth, pageHeight]);
  drawImage(page, await embed(doc, image), image.orientation, [width, 0, 0, height, (pageWidth - width) / 2, (pageHeight - height) / 2]);
}

/** Draws the image over the page at `index`; `matrix` as for `drawImage`. */
export async function drawImageOnPage(doc, index, image, matrix) {
  drawImage(doc.getPage(index), await embed(doc, image), image.orientation, matrix);
}
