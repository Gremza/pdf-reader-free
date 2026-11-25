import {
  PDFArray, PDFDict, PDFName, PDFNumber, PDFRawStream, StandardFontEmbedder, StandardFonts, decodePDFRawStream,
} from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";

/**
 * "Edit Text": the lines of text on a page, read from its content stream, and the same content with one line
 * taken out. A line is the text shown on one baseline without a wide gap; text inside forms, invisible text
 * (as Recognize Text adds) and turned or mirrored text are left alone. The same reading as `TextLines.swift`.
 */

// MARK: Tokens

const WHITESPACE = new Set([0, 9, 10, 12, 13, 32]);
const DELIMITERS = new Set([...'()<>[]{}/%'].map((c) => c.charCodeAt(0)));

const isRegular = (byte) => !WHITESPACE.has(byte) && !DELIMITERS.has(byte);

/**
 * The operators of a content stream with their operands and where they are: { op, operands, start, end }.
 * Operands are numbers, { str: Uint8Array }, { name }, arrays of operands, or null for anything else.
 */
export function parseContent(bytes) {
  const ops = [];
  let operands = [];
  let start = -1;
  let i = 0;
  const n = bytes.length;
  const stack = [];

  const push = (value, at) => {
    if (stack.length) stack[stack.length - 1].push(value);
    else {
      if (start < 0) start = at;
      operands.push(value);
    }
  };

  while (i < n) {
    const c = bytes[i];
    if (WHITESPACE.has(c)) {
      i++;
    } else if (c === 0x25) { // % comment
      while (i < n && bytes[i] !== 10 && bytes[i] !== 13) i++;
    } else if (c === 0x28) { // ( literal string
      const at = i;
      const out = [];
      let depth = 1;
      i++;
      while (i < n && depth > 0) {
        const b = bytes[i++];
        if (b === 0x5c) { // backslash
          const e = bytes[i++];
          const escapes = { 0x6e: 10, 0x72: 13, 0x74: 9, 0x62: 8, 0x66: 12 };
          if (e in escapes) out.push(escapes[e]);
          else if (e >= 0x30 && e <= 0x37) {
            let value = e - 0x30;
            for (let k = 0; k < 2 && bytes[i] >= 0x30 && bytes[i] <= 0x37; k++) value = value * 8 + bytes[i++] - 0x30;
            out.push(value & 0xff);
          } else if (e === 13) {
            if (bytes[i] === 10) i++;
          } else if (e !== 10) out.push(e);
        } else if (b === 0x28) {
          depth++;
          out.push(b);
        } else if (b === 0x29) {
          if (--depth > 0) out.push(b);
        } else out.push(b);
      }
      push({ str: Uint8Array.from(out) }, at);
    } else if (c === 0x3c && bytes[i + 1] === 0x3c) { // << dictionary
      const at = i;
      i = skipDictionary(bytes, i);
      push(null, at);
    } else if (c === 0x3c) { // <hex string>
      const at = i;
      const digits = [];
      i++;
      while (i < n && bytes[i] !== 0x3e) {
        const h = hexValue(bytes[i++]);
        if (h >= 0) digits.push(h);
      }
      i++;
      if (digits.length % 2) digits.push(0);
      const out = new Uint8Array(digits.length / 2);
      for (let k = 0; k < out.length; k++) out[k] = digits[2 * k] * 16 + digits[2 * k + 1];
      push({ str: out }, at);
    } else if (c === 0x5b) { // [
      if (!stack.length && start < 0) start = i;
      stack.push([]);
      i++;
    } else if (c === 0x5d) { // ]
      i++;
      const array = stack.pop();
      if (array) push(array, i);
    } else if (c === 0x2f) { // /name
      const at = i;
      i++;
      const from = i;
      while (i < n && isRegular(bytes[i])) i++;
      push({ name: latin1(bytes.subarray(from, i)) }, at);
    } else if (c === 0x7b || c === 0x7d || c === 0x3e || c === 0x29) {
      i++;
    } else {
      const at = i;
      while (i < n && isRegular(bytes[i])) i++;
      const word = latin1(bytes.subarray(at, i));
      const number = Number(word);
      if (word !== "" && /^[+-]?(\d+\.?\d*|\.\d+)$/.test(word) && Number.isFinite(number)) {
        push(number, at);
      } else if (stack.length) {
        push(null, at); // true, false, null inside an array
      } else if (word === "true" || word === "false" || word === "null") {
        push(null, at);
      } else {
        ops.push({ op: word, operands, start: start < 0 ? at : start, end: i });
        operands = [];
        start = -1;
        // An inline image: its data runs to EI
        if (word === "ID") i = skipInlineImage(bytes, i);
      }
    }
  }
  return ops;
}

function hexValue(b) {
  if (b >= 0x30 && b <= 0x39) return b - 0x30;
  if (b >= 0x41 && b <= 0x46) return b - 0x37;
  if (b >= 0x61 && b <= 0x66) return b - 0x57;
  return -1;
}

function latin1(bytes) {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return s;
}

function skipDictionary(bytes, i) {
  let depth = 0;
  while (i < bytes.length) {
    if (bytes[i] === 0x3c && bytes[i + 1] === 0x3c) {
      depth++;
      i += 2;
    } else if (bytes[i] === 0x3e && bytes[i + 1] === 0x3e) {
      depth--;
      i += 2;
      if (depth === 0) return i;
    } else if (bytes[i] === 0x28) {
      // A string may hold >> of its own
      let d = 0;
      do {
        if (bytes[i] === 0x5c) i++;
        else if (bytes[i] === 0x28) d++;
        else if (bytes[i] === 0x29) d--;
        i++;
      } while (i < bytes.length && d > 0);
    } else i++;
  }
  return i;
}

function skipInlineImage(bytes, i) {
  i++;
  while (i < bytes.length) {
    if (bytes[i] === 0x45 && bytes[i + 1] === 0x49 && WHITESPACE.has(bytes[i - 1])
      && (i + 2 >= bytes.length || WHITESPACE.has(bytes[i + 2]))) return i + 2;
    i++;
  }
  return i;
}

// MARK: Matrices ([a, b, c, d, e, f], as in PDF)

const multiply = (m, n) => [
  m[0] * n[0] + m[1] * n[2], m[0] * n[1] + m[1] * n[3],
  m[2] * n[0] + m[3] * n[2], m[2] * n[1] + m[3] * n[3],
  m[4] * n[0] + m[5] * n[2] + n[4], m[4] * n[1] + m[5] * n[3] + n[5],
];
const apply = (m, [x, y]) => [m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]];

// MARK: Lines

/**
 * The lines of a page: { runs, angle (degrees, counterclockwise), start (baseline start in user space),
 * end, size, color [r, g, b], font, rect [x1, y1, x2, y2] }. `fonts(name)` gives a font of the page's
 * resources, as `fontInfo` makes it. Also returns the operators, for `removeLine`.
 */
export function readLines(bytes, fonts) {
  const ops = parseContent(bytes);
  const runs = [];
  let gs = {
    ctm: [1, 0, 0, 1, 0, 0], color: [0, 0, 0],
    tc: 0, tw: 0, th: 1, tl: 0, font: null, size: 0, rise: 0, mode: 0,
  };
  const saved = [];
  let tm = [1, 0, 0, 1, 0, 0];
  let tlm = [1, 0, 0, 1, 0, 0];

  const nextLine = (tx, ty) => {
    tlm = multiply([1, 0, 0, 1, tx, ty], tlm);
    tm = tlm;
  };

  /** The advance of a string in unscaled text space, and where its last letter that isn't a space ends (`ink`). */
  const advanceOf = (str) => {
    let advance = 0;
    let ink = 0;
    for (const code of codes(str, gs.font)) {
      const space = code === 32 && !gs.font?.composite;
      const w = gs.font ? gs.font.width(code) : 0.5;
      advance += (w * gs.size + gs.tc + (space ? gs.tw : 0)) * gs.th;
      if (!space) ink = advance;
    }
    return { advance, ink };
  };

  /**
   * A piece of shown text: its start and end on the baseline, in user space, without spaces at the end.
   * `advance` is all of it, for taking it out. Only spaces show nothing.
   */
  const show = (opIndex, elements, advance, ink) => {
    if (ink <= 0) return;
    const m = multiply(tm, gs.ctm);
    const start = apply(m, [0, gs.rise]);
    const end = apply(multiply(multiply([1, 0, 0, 1, ink, 0], tm), gs.ctm), [0, gs.rise]);
    const up = [m[2] * gs.size, m[3] * gs.size];
    const right = [m[0], m[1]];
    runs.push({
      op: opIndex,
      elements,
      advance,
      start,
      end,
      size: Math.hypot(...up),
      angle: (Math.atan2(right[1], right[0]) * 180) / Math.PI,
      mirrored: right[0] * up[1] - right[1] * up[0] < 0,
      invisible: gs.mode === 3 || gs.mode === 7,
      color: gs.color,
      font: gs.font,
      tfs: gs.size,
      th: gs.th,
    });
  };

  ops.forEach(({ op, operands: o }, index) => {
    const num = (k) => (typeof o[k] === "number" ? o[k] : 0);
    switch (op) {
      case "q": saved.push(gs); gs = { ...gs }; break;
      case "Q": if (saved.length) gs = saved.pop(); break;
      case "cm": if (o.length === 6) gs.ctm = multiply(o.map((_, k) => num(k)), gs.ctm); break;
      case "BT": tm = [1, 0, 0, 1, 0, 0]; tlm = tm; break;
      case "Tc": gs.tc = num(0); break;
      case "Tw": gs.tw = num(0); break;
      case "Tz": gs.th = num(0) / 100; break;
      case "TL": gs.tl = num(0); break;
      case "Ts": gs.rise = num(0); break;
      case "Tr": gs.mode = num(0); break;
      case "Tf":
        gs.font = (o[0]?.name !== undefined && fonts(o[0].name)) || null;
        gs.size = num(1);
        break;
      case "Td": nextLine(num(0), num(1)); break;
      case "TD": gs.tl = -num(1); nextLine(num(0), num(1)); break;
      case "Tm": if (o.length === 6) { tm = o.map((_, k) => num(k)); tlm = tm; } break;
      case "T*": nextLine(0, -gs.tl); break;
      case "g": gs.color = gray(num(0)); break;
      case "rg": gs.color = [num(0), num(1), num(2)]; break;
      case "k": gs.color = cmyk(num(0), num(1), num(2), num(3)); break;
      case "cs": {
        const space = o[0]?.name;
        // A new color space starts black
        gs.color = space === "DeviceGray" || space === "DeviceRGB" || space === "DeviceCMYK" ? [0, 0, 0] : gs.color;
        break;
      }
      case "sc":
      case "scn": {
        const values = o.filter((v) => typeof v === "number");
        if (values.length === 1) gs.color = gray(values[0]);
        else if (values.length === 3) gs.color = values;
        else if (values.length === 4) gs.color = cmyk(...values);
        break;
      }
      case "'":
      case '"': {
        if (op === '"') {
          gs.tw = num(0);
          gs.tc = num(1);
        }
        nextLine(0, -gs.tl);
        const str = o[o.length - 1];
        if (!str?.str) break;
        const { advance, ink } = advanceOf(str);
        show(index, null, advance, ink);
        tm = multiply([1, 0, 0, 1, advance, 0], tm);
        break;
      }
      case "Tj": {
        if (!o[0]?.str) break;
        const { advance, ink } = advanceOf(o[0]);
        show(index, null, advance, ink);
        tm = multiply([1, 0, 0, 1, advance, 0], tm);
        break;
      }
      case "TJ": {
        const items = Array.isArray(o[0]) ? o[0] : [];
        // A wide gap inside the array splits it, like the columns of a table
        let first = 0;
        let advance = 0;
        let ink = 0;
        const flush = (to) => {
          if (to > first) show(index, [first, to], advance, ink);
          tm = multiply([1, 0, 0, 1, advance, 0], tm);
          advance = 0;
          ink = 0;
        };
        items.forEach((item, k) => {
          if (typeof item === "number") {
            const shift = (-item / 1000) * gs.size * gs.th;
            if (Math.abs(item) >= 1500 && items.slice(first, k).some((x) => x?.str)) {
              flush(k);
              tm = multiply([1, 0, 0, 1, shift, 0], tm);
              first = k + 1;
            } else if (first === k) {
              tm = multiply([1, 0, 0, 1, shift, 0], tm);
              first = k + 1;
            } else advance += shift;
          } else if (item?.str) {
            const piece = advanceOf(item);
            if (piece.ink > 0) ink = advance + piece.ink;
            advance += piece.advance;
          }
        });
        flush(items.length);
        break;
      }
      default:
    }
  });

  return { ops, lines: groupLines(runs) };
}

const gray = (g) => [g, g, g];
const cmyk = (c, m, y, k) => [(1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k)];

/** Character codes: one byte each in simple fonts, two in composite fonts. */
function codes({ str }, font) {
  if (!font?.composite) return [...str];
  const out = [];
  for (let k = 0; k + 1 < str.length; k += 2) out.push(str[k] * 256 + str[k + 1]);
  return out;
}

function groupLines(runs) {
  // Only upright, unmirrored, visible text, turned by a multiple of 90°
  const usable = runs.filter((r) => !r.invisible && !r.mirrored && r.size > 0.5
    && Math.abs(r.angle - Math.round(r.angle / 90) * 90) < 0.5);
  for (const r of usable) {
    r.angle = ((Math.round(r.angle / 90) * 90) % 360 + 360) % 360;
    const rad = (r.angle * Math.PI) / 180;
    const u = [Math.cos(rad), Math.sin(rad)];
    const v = [-u[1], u[0]];
    r.along = r.start[0] * u[0] + r.start[1] * u[1];
    r.alongEnd = r.end[0] * u[0] + r.end[1] * u[1];
    r.offset = r.start[0] * v[0] + r.start[1] * v[1];
  }
  usable.sort((a, b) => a.angle - b.angle || a.offset - b.offset || a.along - b.along);

  // Runs on one baseline, then split where the gap is wide
  const lines = [];
  let k = 0;
  while (k < usable.length) {
    const first = usable[k];
    const baseline = [];
    while (k < usable.length && usable[k].angle === first.angle && usable[k].offset - first.offset <= 0.3 * first.size) {
      baseline.push(usable[k++]);
    }
    baseline.sort((a, b) => a.along - b.along);
    let current = null;
    for (const run of baseline) {
      if (current && run.along <= current.alongEnd + 1.5 * current.size && run.along >= current.along - current.size) {
        current.runs.push(run);
        current.alongEnd = Math.max(current.alongEnd, run.alongEnd);
      } else {
        current = { runs: [run], along: run.along, alongEnd: run.alongEnd, size: run.size };
        lines.push(current);
      }
    }
  }

  return lines.map(({ runs: lineRuns, alongEnd }) => {
    const first = lineRuns[0];
    const rad = (first.angle * Math.PI) / 180;
    const u = [Math.cos(rad), Math.sin(rad)];
    const v = [-u[1], u[0]];
    const length = alongEnd - first.along;
    const end = [first.start[0] + u[0] * length, first.start[1] + u[1] * length];
    // Room for capitals above the baseline and descenders below
    const corners = [first.start, end].flatMap((p) => [
      [p[0] - v[0] * 0.25 * first.size, p[1] - v[1] * 0.25 * first.size],
      [p[0] + v[0] * 0.85 * first.size, p[1] + v[1] * 0.85 * first.size],
    ]);
    const xs = corners.map((p) => p[0]);
    const ys = corners.map((p) => p[1]);
    return {
      runs: lineRuns,
      angle: first.angle,
      start: first.start,
      end,
      size: first.size,
      color: first.color,
      font: first.font,
      rect: [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)],
    };
  });
}

/**
 * The text of a line from pdf.js text items ({ str, transform, width }, in user space): the items that start
 * on its baseline, within its length, in order.
 */
export function lineText(line, items) {
  const rad = (line.angle * Math.PI) / 180;
  const u = [Math.cos(rad), Math.sin(rad)];
  const v = [-u[1], u[0]];
  const along = (p) => p[0] * u[0] + p[1] * u[1];
  const offset = (p) => p[0] * v[0] + p[1] * v[1];
  const from = along(line.start) - 0.5;
  const to = along(line.end) + 0.5;
  const base = offset(line.start);
  const picked = items
    .filter((item) => item.str && item.transform)
    .map((item) => ({ item, at: along([item.transform[4], item.transform[5]]), off: offset([item.transform[4], item.transform[5]]) }))
    .filter(({ at, off }) => at >= from && at < to && Math.abs(off - base) <= 0.3 * line.size)
    .sort((a, b) => a.at - b.at);
  let text = "";
  let end = -Infinity;
  for (const { item, at } of picked) {
    if (text && at - end > 0.2 * line.size && !text.endsWith(" ") && !item.str.startsWith(" ")) text += " ";
    text += item.str;
    end = at + (item.width ?? 0);
  }
  return text;
}

// MARK: Taking a line out

/**
 * The content with the text of `line` taken out. Each piece is replaced by a move of the same length,
 * so whatever follows stays where it was.
 */
export function removeLine(bytes, ops, line) {
  const byOp = new Map();
  for (const run of line.runs) {
    if (!byOp.has(run.op)) byOp.set(run.op, []);
    byOp.get(run.op).push(run);
  }
  const edits = [...byOp].map(([index, runs]) => {
    const { op, operands, start, end } = ops[index];
    const move = (run) => formatNumber(run.tfs * run.th ? (-run.advance / (run.tfs * run.th)) * 1000 : 0);
    let text;
    if (op === "TJ") {
      const items = Array.isArray(operands[0]) ? operands[0] : [];
      const parts = [];
      for (let k = 0; k < items.length; k++) {
        const run = runs.find((r) => r.elements[0] === k);
        if (run) {
          parts.push(move(run));
          k = run.elements[1] - 1;
        } else parts.push(formatOperand(items[k]));
      }
      text = `[${parts.join(" ")}] TJ`;
    } else if (op === "Tj") {
      text = `[${move(runs[0])}] TJ`;
    } else if (op === "'") {
      text = `T* [${move(runs[0])}] TJ`;
    } else {
      text = `${formatNumber(operands[0])} Tw ${formatNumber(operands[1])} Tc T* [${move(runs[0])}] TJ`;
    }
    return { start, end, text };
  });
  edits.sort((a, b) => b.start - a.start);

  let out = bytes;
  for (const { start, end, text } of edits) {
    const inserted = new TextEncoder().encode(text);
    const next = new Uint8Array(out.length - (end - start) + inserted.length);
    next.set(out.subarray(0, start), 0);
    next.set(inserted, start);
    next.set(out.subarray(end), start + inserted.length);
    out = next;
  }
  return out;
}

function formatNumber(value) {
  const n = typeof value === "number" && Number.isFinite(value) ? value : 0;
  return String(Math.round(n * 1000) / 1000);
}

function formatOperand(value) {
  if (typeof value === "number") return formatNumber(value);
  if (value?.str) return `<${[...value.str].map((b) => b.toString(16).padStart(2, "0")).join("")}>`;
  return "0";
}

// MARK: The style of the new text

/** The standard font closest to the line's font: Helvetica, Times or Courier, bold and italic as it is. */
export function standardFont(font) {
  const name = (font?.baseFont ?? "").replace(/^[A-Z]{6}\+/, "").toLowerCase();
  const flags = font?.flags ?? 0;
  const family = /courier|mono|consol|monaco|menlo/.test(name) || (flags & 1) ? "Courier"
    : /times|georgia|garamond|cambria|minion|palatino|antiqua|roman|serif/.test(name.replaceAll("sans", "")) || ((flags & 2) && !name.includes("sans"))
      ? "Times" : "Helvetica";
  const bold = /bold|black|heavy|semibold|demi/.test(name) || (flags & 262144) !== 0;
  const italic = /italic|oblique/.test(name) || (flags & 64) !== 0;
  if (family === "Times") return `Times-${bold && italic ? "BoldItalic" : bold ? "Bold" : italic ? "Italic" : "Roman"}`;
  return `${family}${bold || italic ? "-" : ""}${bold ? "Bold" : ""}${italic ? "Oblique" : ""}`;
}

// MARK: Pages of pdf-lib

/** The content of a page, its streams one after the other, and its fonts by resource name. */
export function pageContent(page) {
  const { context } = page.doc;
  const contents = page.node.Contents();
  const streams = contents instanceof PDFArray
    ? contents.asArray().map((ref) => context.lookup(ref))
    : contents ? [contents] : [];
  const parts = streams.filter((s) => s instanceof PDFRawStream).map((s) => decodePDFRawStream(s).decode());
  const length = parts.reduce((sum, p) => sum + p.length + 1, 0);
  const bytes = new Uint8Array(length);
  let at = 0;
  for (const p of parts) {
    bytes.set(p, at);
    bytes[at + p.length] = 10;
    at += p.length + 1;
  }

  const fontDict = page.node.Resources()?.lookupMaybe(PDFName.of("Font"), PDFDict);
  const cache = new Map();
  const fonts = (name) => {
    if (!cache.has(name)) {
      const dict = fontDict?.lookupMaybe(PDFName.of(name), PDFDict);
      cache.set(name, dict ? fontInfo(dict) : null);
    }
    return cache.get(name);
  };
  return { bytes, fonts };
}

const STANDARD = new Set(Object.values(StandardFonts));

/** What the lines need of a font: its widths (in em), name and flags. */
function fontInfo(dict) {
  const get = (d, key, type) => d?.lookupMaybe(PDFName.of(key), type);
  const number = (obj) => (obj instanceof PDFNumber ? obj.asNumber() : undefined);
  const baseFont = get(dict, "BaseFont", PDFName)?.decodeText() ?? "";
  const subtype = get(dict, "Subtype", PDFName)?.decodeText();

  if (subtype === "Type0") {
    const descendant = get(dict, "DescendantFonts", PDFArray)?.lookupMaybe(0, PDFDict);
    const dw = number(descendant?.lookup(PDFName.of("DW"))) ?? 1000;
    const widths = new Map();
    const w = get(descendant, "W", PDFArray)?.asArray().map((x) => descendant.context.lookup(x)) ?? [];
    for (let k = 0; k < w.length;) {
      const first = number(w[k]);
      if (w[k + 1] instanceof PDFArray) {
        w[k + 1].asArray().forEach((x, j) => widths.set(first + j, number(descendant.context.lookup(x)) ?? dw));
        k += 2;
      } else {
        const last = number(w[k + 1]);
        const value = number(w[k + 2]) ?? dw;
        for (let c = first; c <= last && c - first < 65536; c++) widths.set(c, value);
        k += 3;
      }
    }
    const flags = number(get(descendant, "FontDescriptor", PDFDict)?.lookup(PDFName.of("Flags"))) ?? 0;
    return { composite: true, baseFont, flags, width: (code) => (widths.get(code) ?? dw) / 1000 };
  }

  const firstChar = number(dict.lookup(PDFName.of("FirstChar"))) ?? 0;
  const widths = get(dict, "Widths", PDFArray)?.asArray().map((x) => number(dict.context.lookup(x)) ?? 0);
  const descriptor = get(dict, "FontDescriptor", PDFDict);
  const flags = number(descriptor?.lookup(PDFName.of("Flags"))) ?? 0;
  const missing = number(descriptor?.lookup(PDFName.of("MissingWidth")));
  // Type 3 glyphs are measured by their font matrix
  const scale = subtype === "Type3" ? (number(get(dict, "FontMatrix", PDFArray)?.lookup(0)) ?? 0.001) : 0.001;
  const standard = !widths && STANDARD.has(baseFont) ? StandardFontEmbedder.for(baseFont) : null;
  return {
    composite: false,
    baseFont,
    flags,
    width: (code) => {
      const w = widths?.[code - firstChar];
      if (w !== undefined) return w * scale;
      if (standard) {
        try {
          return standard.widthOfTextAtSize(String.fromCharCode(code), 1);
        } catch {
          return 0.5;
        }
      }
      return missing !== undefined ? missing * scale : 0.5;
    },
  };
}
