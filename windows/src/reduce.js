import { PDFArray, PDFBool, PDFDict, PDFName, PDFNumber, PDFRawStream, PDFRef, decodePDFRawStream } from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";
import { load } from "./editing.js";

/** Stores the images of a PDF again as JPEG at a lower resolution and quality, for "Reduce File Size". */

/** The image quality of a reduced copy; the same presets as in the macOS app. */
export const REDUCED_QUALITIES = [
  { id: "high", title: "High Quality", dpi: 200, quality: 0.8 },
  { id: "medium", title: "Medium Quality", dpi: 144, quality: 0.6 },
  { id: "low", title: "Low Quality", dpi: 96, quality: 0.4 },
];

const name = (value) => PDFName.of(value);
// Larger images would need too much memory to decode
const MAX_PIXELS = 100_000_000;
const LOSSLESS_FILTERS = new Set(["FlateDecode", "LZWDecode", "ASCII85Decode", "ASCIIHexDecode", "RunLengthDecode"]);

/**
 * Returns the new PDF bytes; `progress` gets the number of pages done.
 * The drawn size of an image is not known without reading the content streams, so an image is
 * scaled down to `dpi` for a full page of the largest page it appears on; one drawn smaller keeps
 * more detail. An image is only replaced when the JPEG is smaller.
 */
export async function reduceImages(bytes, { dpi, quality }, progress) {
  const doc = await load(bytes);
  const { context } = doc;
  const pages = doc.getPages();

  const pageImages = pages.map((page) => [...imagesIn(context, page.node.Resources(), new Set())]);
  const limits = new Map();
  pages.forEach((page, index) => {
    const { width, height } = page.getSize();
    const limit = Math.ceil((Math.max(width, height) / 72) * dpi);
    for (const ref of pageImages[index]) limits.set(ref, Math.max(limits.get(ref) ?? 0, limit));
  });

  const done = new Set();
  for (const [index, refs] of pageImages.entries()) {
    for (const ref of refs) {
      if (done.has(ref)) continue;
      done.add(ref);
      try {
        await reduceImage(context, ref, limits.get(ref), quality);
      } catch {
        // An image that can't be decoded stays as it is
      }
    }
    progress(index + 1);
  }
  return doc.save();
}

/** The image XObjects of a page, including those inside its forms. */
function* imagesIn(context, resources, seen) {
  const xobjects = resources instanceof PDFDict ? context.lookup(resources.get(name("XObject"))) : undefined;
  if (!(xobjects instanceof PDFDict)) return;
  for (const [, ref] of xobjects.entries()) {
    if (!(ref instanceof PDFRef) || seen.has(ref)) continue;
    seen.add(ref);
    const object = context.lookup(ref);
    if (!(object instanceof PDFRawStream)) continue;
    const subtype = object.dict.get(name("Subtype"));
    if (subtype === name("Image")) yield ref;
    else if (subtype === name("Form")) yield* imagesIn(context, context.lookup(object.dict.get(name("Resources"))), seen);
  }
}

async function reduceImage(context, ref, limit, quality) {
  const stream = context.lookup(ref);
  const image = await decodeImage(context, stream);
  if (!image) return;
  const scale = Math.min(1, limit / Math.max(image.width, image.height));
  const width = Math.max(1, Math.round(image.width * scale));
  const height = Math.max(1, Math.round(image.height * scale));
  const jpeg = await encodeJPEG(image.bitmap, width, height, quality);
  image.bitmap.close();
  if (jpeg.length >= stream.contents.length) return;

  const dict = stream.dict.clone(context);
  for (const key of ["Filter", "DecodeParms", "Decode", "Length"]) dict.delete(name(key));
  dict.set(name("Width"), PDFNumber.of(width));
  dict.set(name("Height"), PDFNumber.of(height));
  dict.set(name("BitsPerComponent"), PDFNumber.of(8));
  dict.set(name("Filter"), name("DCTDecode"));
  // A canvas writes color JPEGs, so gray images become RGB
  if (image.components !== 3) dict.set(name("ColorSpace"), name("DeviceRGB"));
  context.assign(ref, PDFRawStream.of(dict, jpeg));
  if (scale < 1) await reduceMask(context, dict.get(name("SMask")), width, height);
}

/** The transparency of an image is scaled down with it; it stays lossless. */
async function reduceMask(context, ref, width, height) {
  if (!(ref instanceof PDFRef)) return;
  const stream = context.lookup(ref);
  if (!(stream instanceof PDFRawStream)) return;
  const mask = await decodeImage(context, stream, 1);
  if (!mask) return;
  if (mask.width <= width && mask.height <= height) {
    mask.bitmap.close();
    return;
  }
  const pixels = drawScaled(mask.bitmap, width, height).getImageData(0, 0, width, height).data;
  mask.bitmap.close();
  const gray = new Uint8Array(width * height);
  for (let i = 0; i < gray.length; i++) gray[i] = pixels[i * 4];
  const reduced = context.flateStream(gray, {
    Type: "XObject", Subtype: "Image", Width: width, Height: height, ColorSpace: "DeviceGray", BitsPerComponent: 8,
  });
  if (reduced.contents.length < stream.contents.length) context.assign(ref, reduced);
}

function drawScaled(bitmap, width, height) {
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext("2d");
  ctx.imageSmoothingQuality = "high";
  ctx.drawImage(bitmap, 0, 0, width, height);
  return ctx;
}

async function encodeJPEG(bitmap, width, height, quality) {
  const blob = await drawScaled(bitmap, width, height).canvas.convertToBlob({ type: "image/jpeg", quality });
  return new Uint8Array(await blob.arrayBuffer());
}

/**
 * Decodes 8-bit gray and RGB images, stored as JPEG or with lossless filters, into a bitmap.
 * Returns null for the rest (CMYK, indexed colors, masks, JBIG2, JPEG 2000…), which stay as they are.
 */
async function decodeImage(context, stream, onlyComponents) {
  const dict = stream.dict;
  const width = numberValue(context, dict.get(name("Width")));
  const height = numberValue(context, dict.get(name("Height")));
  const components = colorComponents(context, dict.get(name("ColorSpace")));
  if (!width || !height || width * height > MAX_PIXELS || !components) return null;
  if (onlyComponents && components !== onlyComponents) return null;
  const isMask = context.lookup(dict.get(name("ImageMask"))) === PDFBool.True;
  // Custom decoding and color key masking need the exact original colors
  if (isMask || !isDefaultDecode(context, dict.get(name("Decode")), components)) return null;
  if (context.lookup(dict.get(name("Mask"))) instanceof PDFArray) return null;

  const filters = filterNames(context, dict.get(name("Filter")));
  if (!filters) return null;
  if (filters.length === 1 && filters[0] === "DCTDecode") {
    const bitmap = await createImageBitmap(new Blob([stream.contents], { type: "image/jpeg" }), {
      colorSpaceConversion: "none",
      imageOrientation: "none",
    });
    if (bitmap.width === width && bitmap.height === height) return { bitmap, width, height, components };
    bitmap.close();
    return null;
  }
  if (!filters.every((filter) => LOSSLESS_FILTERS.has(filter))) return null;
  if ((numberValue(context, dict.get(name("BitsPerComponent"))) ?? 8) !== 8) return null;

  let samples = decodePDFRawStream(stream).decode();
  const predictor = predictorParams(context, dict.get(name("DecodeParms")));
  if (predictor.predictor >= 10) samples = unpredictPNG(samples, predictor.columns, predictor.colors);
  else if (predictor.predictor !== 1) return null;
  if (samples.length < width * height * components) return null;

  const rgba = new ImageData(width, height);
  for (let i = 0, j = 0; i < width * height; i++, j += components) {
    const o = i * 4;
    rgba.data[o] = samples[j];
    rgba.data[o + 1] = samples[components === 3 ? j + 1 : j];
    rgba.data[o + 2] = samples[components === 3 ? j + 2 : j];
    rgba.data[o + 3] = 255;
  }
  return { bitmap: await createImageBitmap(rgba), width, height, components };
}

function numberValue(context, value) {
  const number = context.lookup(value);
  return number instanceof PDFNumber ? number.asNumber() : undefined;
}

/** No Decode array, or [0 1 0 1 …], which changes nothing. */
function isDefaultDecode(context, value, components) {
  const decode = context.lookup(value);
  if (decode === undefined) return true;
  if (!(decode instanceof PDFArray) || decode.size() !== components * 2) return false;
  return decode.asArray().every((item, index) => numberValue(context, item) === index % 2);
}

/** 1 for gray, 3 for RGB; undefined for other color spaces. */
function colorComponents(context, value) {
  const space = context.lookup(value);
  if (space === name("DeviceGray")) return 1;
  if (space === name("DeviceRGB")) return 3;
  if (!(space instanceof PDFArray)) return undefined;
  const kind = context.lookup(space.get(0));
  if (kind === name("CalGray")) return 1;
  if (kind === name("CalRGB")) return 3;
  if (kind !== name("ICCBased")) return undefined;
  const profile = context.lookup(space.get(1));
  const count = profile instanceof PDFRawStream ? numberValue(context, profile.dict.get(name("N"))) : undefined;
  return count === 1 || count === 3 ? count : undefined;
}

function filterNames(context, value) {
  const filter = context.lookup(value);
  if (filter === undefined) return [];
  const items = filter instanceof PDFArray ? filter.asArray().map((item) => context.lookup(item)) : [filter];
  return items.every((item) => item instanceof PDFName) ? items.map((item) => item.decodeText()) : null;
}

/** The predictor of the last filter: 1 = none, 2 = TIFF, 10–15 = PNG. */
function predictorParams(context, value) {
  let params = context.lookup(value);
  if (params instanceof PDFArray) params = context.lookup(params.get(params.size() - 1));
  const get = (key, fallback) => (params instanceof PDFDict ? numberValue(context, params.get(name(key))) : undefined) ?? fallback;
  return { predictor: get("Predictor", 1), columns: get("Columns", 1), colors: get("Colors", 1) };
}

/** Undoes the PNG row filters; each row starts with its filter type. */
function unpredictPNG(data, columns, colors) {
  const rowLength = columns * colors;
  const rows = Math.floor(data.length / (rowLength + 1));
  const out = new Uint8Array(rows * rowLength);
  for (let y = 0; y < rows; y++) {
    const type = data[y * (rowLength + 1)];
    const source = y * (rowLength + 1) + 1;
    const row = y * rowLength;
    for (let x = 0; x < rowLength; x++) {
      const left = x >= colors ? out[row + x - colors] : 0;
      const up = y > 0 ? out[row - rowLength + x] : 0;
      const upLeft = y > 0 && x >= colors ? out[row - rowLength + x - colors] : 0;
      let base;
      switch (type) {
        case 0: base = 0; break;
        case 1: base = left; break;
        case 2: base = up; break;
        case 3: base = (left + up) >> 1; break;
        case 4: {
          const p = left + up - upLeft;
          const pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - upLeft);
          base = pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
          break;
        }
        default: throw new Error("Unknown PNG filter");
      }
      out[row + x] = (data[source + x] + base) & 255;
    }
  }
  return out;
}
