import { load } from "./editing.js";
import { lineText, pageContent, readLines, standardFont } from "./textlines.js";

/**
 * "Edit Text": a layer over each page shows the line under the pointer; a click opens a field over it.
 * Return (or clicking elsewhere) hands the new text to `onCommit(pageNumber, lineIndex, text, bytes)`, with the bytes
 * the line was read from; Esc closes it.
 */

const FAMILIES = {
  Helvetica: "Helvetica, Arial, sans-serif",
  Times: '"Times New Roman", Times, serif',
  Courier: '"Courier New", Courier, monospace',
};

export class TextEditing {
  constructor(viewer, onCommit) {
    this.viewer = viewer;
    this.onCommit = onCommit;
    this.layers = new Map();
    this.field = null;
  }

  /** The document the lines are read from; again after every edit. */
  setDocument(bytes, pdf) {
    this.closeField();
    this.bytes = bytes;
    this.doc = load(bytes);
    this.pdf = pdf;
    this.pages = new Map();
    for (const layer of this.layers.values()) layer.remove();
    this.layers.clear();
  }

  /** The lines of a page that are upright on screen, with their text; read once. */
  linesOf(number) {
    if (!this.pages.has(number)) {
      this.pages.set(number, (async () => {
        const doc = await this.doc;
        const page = doc.getPage(number - 1);
        const { bytes, fonts } = pageContent(page);
        const { lines } = readLines(bytes, fonts);
        const items = (await (await this.pdf.getPage(number)).getTextContent()).items;
        const rotation = page.getRotation().angle;
        return lines
          // One space between words, as on macOS
          .map((line, index) => ({ ...line, index, text: lineText(line, items).replace(/\s+/g, " ").trim() }))
          .filter((line) => ((line.angle - rotation) % 360 + 360) % 360 === 0);
      })());
    }
    return this.pages.get(number);
  }

  /** Puts the layers (back) on the pages; pdf.js empties a page when it draws it again. */
  attach() {
    for (let index = 0; index < this.viewer.pagesCount; index++) {
      const view = this.viewer.getPageView(index);
      if (!view?.div) continue;
      const number = index + 1;
      let layer = this.layers.get(number);
      if (!layer) {
        layer = document.createElement("div");
        layer.className = "text-edit-layer";
        const hover = document.createElement("div");
        hover.className = "text-edit-hover";
        hover.hidden = true;
        layer.append(hover);
        layer.addEventListener("pointermove", (event) => this.hover(event, number, layer));
        layer.addEventListener("pointerleave", () => { hover.hidden = true; });
        layer.addEventListener("pointerdown", (event) => this.click(event, number, layer));
        layer.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          event.stopPropagation();
        });
        this.layers.set(number, layer);
      }
      if (layer.parentNode !== view.div) view.div.append(layer);
      if (this.field?.number === number && this.field.element.parentNode !== view.div) view.div.append(this.field.element);
    }
  }

  remove() {
    this.closeField();
    for (const layer of this.layers.values()) layer.remove();
    this.layers.clear();
  }

  /** The line under the pointer, and its place on the page in pixels. */
  async lineAt(event, number, layer) {
    const { viewport } = this.viewer.getPageView(number - 1);
    const box = layer.getBoundingClientRect();
    const scale = viewport.width / box.width;
    const [x, y] = viewport.convertToPdfPoint((event.clientX - box.left) * scale, (event.clientY - box.top) * scale);
    const lines = await this.linesOf(number);
    const line = lines.find(({ rect }) => x >= rect[0] && x <= rect[2] && y >= rect[1] && y <= rect[3]);
    if (!line) return null;
    const [x1, y1] = viewport.convertToViewportPoint(line.rect[0], line.rect[1]);
    const [x2, y2] = viewport.convertToViewportPoint(line.rect[2], line.rect[3]);
    const frame = {
      left: Math.min(x1, x2) / viewport.width,
      top: Math.min(y1, y2) / viewport.height,
      width: Math.abs(x2 - x1) / viewport.width,
      height: Math.abs(y2 - y1) / viewport.height,
    };
    return { line, frame, viewport };
  }

  async hover(event, number, layer) {
    const hover = layer.firstChild;
    const found = await this.lineAt(event, number, layer);
    hover.hidden = !found || this.field?.line === found.line;
    if (found) place(hover, found.frame);
  }

  async click(event, number, layer) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    const found = await this.lineAt(event, number, layer);
    // A click beside the lines puts the new text of an open field in place
    if (!found) return this.commitField();
    if (this.field?.line === found.line) return;
    if (!(await this.commitField())) return this.openField(number, found);
    // The edit read the page again: once it is drawn with a new layer, the click finds its line there
    let again = null;
    for (let tries = 0; tries < 40 && !again; tries++) {
      const candidate = this.layers.get(number);
      if (candidate?.isConnected && candidate.getBoundingClientRect().width > 0) again = candidate;
      else await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const fresh = again && (await this.lineAt(event, number, again));
    if (fresh && !this.field) this.openField(number, fresh);
  }

  openField(number, { line, frame, viewport }) {
    const input = document.createElement("input");
    input.className = "text-edit-field";
    input.value = line.text;
    input.spellcheck = false;
    const fontName = standardFont(line.font);
    const style = {
      family: FAMILIES[fontName.split("-")[0]],
      weight: fontName.includes("Bold") ? "bold" : "normal",
      italic: /Italic|Oblique/.test(fontName),
      size: line.size * viewport.scale,
    };
    Object.assign(input.style, {
      fontFamily: style.family,
      fontWeight: style.weight,
      fontStyle: style.italic ? "italic" : "normal",
      fontSize: `${style.size}px`,
      color: `rgb(${line.color.map((c) => Math.round(c * 255)).join(",")})`,
    });
    place(input, frame);
    // The field grows with its text, never narrower than the line
    const measure = document.createElement("canvas").getContext("2d");
    measure.font = `${style.italic ? "italic " : ""}${style.weight} ${style.size}px ${style.family}`;
    const fit = () => {
      input.style.width = `max(${frame.width * 100}%, ${measure.measureText(input.value).width + style.size}px)`;
    };
    input.addEventListener("input", fit);
    input.addEventListener("keydown", (keyEvent) => {
      if (keyEvent.key === "Enter") {
        keyEvent.preventDefault();
        this.commitField();
      } else if (keyEvent.key === "Escape") {
        keyEvent.preventDefault();
        keyEvent.stopPropagation();
        this.closeField();
      }
    });
    input.addEventListener("blur", () => this.commitField());
    input.addEventListener("pointerdown", (pointerEvent) => pointerEvent.stopPropagation());
    fit();
    this.field = { number, line, element: input };
    this.viewer.getPageView(number - 1).div.append(input);
    this.layers.get(number).firstChild.hidden = true;
    input.focus();
    input.select();
  }

  /** Hands over the new text when it changed, and closes the field; resolves to true once a change is in place. */
  async commitField() {
    const field = this.field;
    if (!field) return false;
    const text = field.element.value;
    this.closeField();
    if (text === field.line.text) return false;
    await this.onCommit(field.number, field.line.index, text, this.bytes);
    return true;
  }

  closeField() {
    const field = this.field;
    if (!field) return;
    this.field = null;
    field.element.remove();
  }
}

/** Places an element over a page by fractions of it. */
function place(element, { left, top, width, height }) {
  Object.assign(element.style, {
    left: `${left * 100}%`,
    top: `${top * 100}%`,
    width: `${width * 100}%`,
    height: `${height * 100}%`,
  });
}
