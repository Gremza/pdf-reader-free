import {
  LineCapStyle, LineJoinStyle, appendBezierCurve, closePath, lineTo, moveTo, popGraphicsState, pushGraphicsState,
  setLineCap, setLineJoin, setLineWidth, setStrokingRgbColor, stroke,
} from "../node_modules/pdf-lib/dist/pdf-lib.esm.min.js";

/**
 * "Draw Shapes": lines, arrows, rectangles and ovals, borders only, to point at something on a page.
 * Until Done draws them into their pages, shapes are kept in points of the page as it is shown, from its top left.
 */

// The same colors and widths as in the macOS app
export const SHAPE_COLORS = {
  red: "#e53935",
  orange: "#fb8c00",
  yellow: "#fdd835",
  green: "#43a047",
  blue: "#1e88e5",
  black: "#000000",
};
export const SHAPE_WIDTHS = { thin: 1, medium: 2, thick: 4 };

const SVG = "http://www.w3.org/2000/svg";
// Distances in pixels on screen, the same at every zoom
const HANDLE_RADIUS = 6;
const GRAB_DISTANCE = 6;
// Control points of a quarter ellipse
const KAPPA = 0.5522847498;

function bounds({ start, end }) {
  return {
    left: Math.min(start[0], end[0]),
    top: Math.min(start[1], end[1]),
    right: Math.max(start[0], end[0]),
    bottom: Math.max(start[1], end[1]),
  };
}

/** The outline as path commands: ["M", x, y], ["L", x, y], ["C", x1, y1, x2, y2, x, y], ["Z"]. */
function outline(shape) {
  const { kind, start, end } = shape;
  switch (kind) {
    case "line":
      return [["M", ...start], ["L", ...end]];
    case "arrow": {
      // The arrowhead grows with the line width, as in the macOS app
      const angle = Math.atan2(end[1] - start[1], end[0] - start[0]);
      const length = 4 * SHAPE_WIDTHS[shape.width] + 6;
      const tip = (side) => [
        end[0] + length * Math.cos(angle + Math.PI + (side * Math.PI) / 6),
        end[1] + length * Math.sin(angle + Math.PI + (side * Math.PI) / 6),
      ];
      return [["M", ...start], ["L", ...end], ["M", ...tip(-1)], ["L", ...end], ["L", ...tip(1)]];
    }
    case "rectangle": {
      const { left, top, right, bottom } = bounds(shape);
      return [["M", left, top], ["L", right, top], ["L", right, bottom], ["L", left, bottom], ["Z"]];
    }
    default: {
      const { left, top, right, bottom } = bounds(shape);
      const cx = (left + right) / 2;
      const cy = (top + bottom) / 2;
      const kx = ((right - left) / 2) * KAPPA;
      const ky = ((bottom - top) / 2) * KAPPA;
      return [
        ["M", right, cy],
        ["C", right, cy + ky, cx + kx, bottom, cx, bottom],
        ["C", cx - kx, bottom, left, cy + ky, left, cy],
        ["C", left, cy - ky, cx - kx, top, cx, top],
        ["C", cx + kx, top, right, cy - ky, right, cy],
        ["Z"],
      ];
    }
  }
}

function handles(shape) {
  if (shape.kind === "line" || shape.kind === "arrow") return [shape.start, shape.end];
  const { left, top, right, bottom } = bounds(shape);
  return [[left, top], [right, top], [left, bottom], [right, bottom]];
}

function segmentDistance([px, py], [ax, ay], [bx, by]) {
  const dx = bx - ax;
  const dy = by - ay;
  const lengthSquared = dx * dx + dy * dy;
  const t = lengthSquared ? Math.min(Math.max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1) : 0;
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/** How far `point` is from the outline. */
function distance(shape, point) {
  const [x, y] = point;
  const { left, top, right, bottom } = bounds(shape);
  if (shape.kind === "rectangle") {
    if (x >= left && x <= right && y >= top && y <= bottom) return Math.min(x - left, right - x, y - top, bottom - y);
    return Math.hypot(Math.max(left - x, 0, x - right), Math.max(top - y, 0, y - bottom));
  }
  const rx = (right - left) / 2;
  const ry = (bottom - top) / 2;
  if (shape.kind === "oval" && rx > 0 && ry > 0) {
    const d = Math.hypot((x - (left + right) / 2) / rx, (y - (top + bottom) / 2) / ry);
    return Math.abs(d - 1) * Math.min(rx, ry);
  }
  return segmentDistance(point, shape.start, shape.end);
}

/** With Shift, lines keep to 45° steps, and rectangles and ovals stay square or round. */
function constrain(point, anchor, kind) {
  const dx = point[0] - anchor[0];
  const dy = point[1] - anchor[1];
  if (kind === "line" || kind === "arrow") {
    const angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
    const length = Math.hypot(dx, dy);
    return [anchor[0] + length * Math.cos(angle), anchor[1] + length * Math.sin(angle)];
  }
  const side = Math.max(Math.abs(dx), Math.abs(dy));
  return [anchor[0] + (dx < 0 ? -side : side), anchor[1] + (dy < 0 ? -side : side)];
}

/** Moves handle `index` of the shape to `point`. */
function reshape(shape, index, point, constrained) {
  if (shape.kind === "line" || shape.kind === "arrow") {
    const other = index === 0 ? shape.end : shape.start;
    const moved = constrained ? constrain(point, other, shape.kind) : point;
    if (index === 0) shape.start = moved;
    else shape.end = moved;
    return;
  }
  const { left, top, right, bottom } = bounds(shape);
  const [cx, cy] = handles(shape)[index];
  const fixed = [left + right - cx, top + bottom - cy];
  shape.start = fixed;
  shape.end = constrained ? constrain(point, fixed, shape.kind) : point;
}

/**
 * Lays a layer over each page of the viewer while shapes are drawn. Dragging on a page draws a shape with the
 * chosen tool; clicking a shape selects it: dragging moves it, its handles reshape it, the color and width change it,
 * Delete removes it. `style` is { kind, color, width }, shared with the bar.
 */
export class ShapeDrawing {
  constructor(viewer, style) {
    this.viewer = viewer;
    this.style = style;
    this.shapes = [];
    this.selected = null;
    this.layers = new Map();
    // A click beside the pages deselects, as on macOS
    this.deselect = (event) => {
      if (!event.target.closest?.(".shape-layer")) this.select(null);
    };
    viewer.container.addEventListener("pointerdown", this.deselect);
  }

  /** Puts the layers (back) on the pages; pdf.js empties a page when it draws it again. */
  attach() {
    for (let index = 0; index < this.viewer.pagesCount; index++) {
      const view = this.viewer.getPageView(index);
      if (!view?.div) continue;
      const number = index + 1;
      let layer = this.layers.get(number);
      if (!layer) {
        layer = document.createElementNS(SVG, "svg");
        layer.classList.add("shape-layer");
        layer.setAttribute("preserveAspectRatio", "none");
        layer.addEventListener("pointerdown", (event) => this.pointerDown(event, number, layer));
        layer.addEventListener("contextmenu", (event) => {
          event.preventDefault();
          event.stopPropagation();
        });
        this.layers.set(number, layer);
      }
      if (layer.parentNode !== view.div) view.div.append(layer);
      this.render(number);
    }
  }

  remove() {
    this.viewer.container.removeEventListener("pointerdown", this.deselect);
    for (const layer of this.layers.values()) layer.remove();
    this.layers.clear();
  }

  /** The page's size in points, as it is shown, and the viewport of its page view. */
  pageSize(number) {
    const { viewport } = this.viewer.getPageView(number - 1);
    return { width: viewport.width / viewport.scale, height: viewport.height / viewport.scale, viewport };
  }

  /** Changes the selected shape to the chosen color or width. */
  restyleSelected() {
    const shape = this.shapes[this.selected];
    if (!shape) return;
    shape.color = this.style.color;
    shape.width = this.style.width;
    this.render(shape.page);
  }

  deleteSelected() {
    const shape = this.shapes[this.selected];
    if (!shape) return false;
    this.shapes.splice(this.selected, 1);
    this.selected = null;
    this.render(shape.page);
    return true;
  }

  select(index) {
    const before = this.shapes[this.selected]?.page;
    this.selected = index;
    if (before) this.render(before);
    const now = this.shapes[index]?.page;
    if (now && now !== before) this.render(now);
  }

  pointerDown(event, number, layer) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    document.activeElement?.blur();
    const { width, height } = this.pageSize(number);
    const box = layer.getBoundingClientRect();
    const perPixel = width / box.width;
    const toPoint = (e) => [
      Math.min(Math.max(((e.clientX - box.left) / box.width) * width, 0), width),
      Math.min(Math.max(((e.clientY - box.top) / box.height) * height, 0), height),
    ];
    const point = toPoint(event);
    let drag;
    const selected = this.shapes[this.selected];
    const handle = selected?.page === number
      ? handles(selected).findIndex((h) => Math.hypot(h[0] - point[0], h[1] - point[1]) / perPixel <= HANDLE_RADIUS + 2)
      : -1;
    if (handle >= 0) {
      drag = { type: "reshape", handle };
    } else {
      // The shape drawn last is on top
      const hit = this.shapes.findLastIndex((shape) => shape.page === number
        && distance(shape, point) <= GRAB_DISTANCE * perPixel + SHAPE_WIDTHS[shape.width] / 2);
      if (hit >= 0) {
        this.select(hit);
        drag = { type: "move", last: point };
        layer.classList.add("moving");
      } else {
        this.select(null);
        this.shapes.push({ page: number, kind: this.style.kind, color: this.style.color, width: this.style.width, start: point, end: point });
        this.selected = this.shapes.length - 1;
        drag = { type: "draw" };
      }
    }
    const shape = this.shapes[this.selected];
    layer.setPointerCapture(event.pointerId);

    const move = (moveEvent) => {
      const at = toPoint(moveEvent);
      if (drag.type === "draw") {
        shape.end = moveEvent.shiftKey ? constrain(at, shape.start, shape.kind) : at;
      } else if (drag.type === "move") {
        // The whole shape stays on its page
        const r = bounds(shape);
        const dx = Math.min(Math.max(at[0] - drag.last[0], -r.left), width - r.right);
        const dy = Math.min(Math.max(at[1] - drag.last[1], -r.top), height - r.bottom);
        shape.start = [shape.start[0] + dx, shape.start[1] + dy];
        shape.end = [shape.end[0] + dx, shape.end[1] + dy];
        drag.last = [drag.last[0] + dx, drag.last[1] + dy];
      } else {
        reshape(shape, drag.handle, at, moveEvent.shiftKey);
        // A rectangle's corners are renumbered when it turns inside out; keep dragging the same one
        const corners = handles(shape);
        drag.handle = corners.reduce((best, h, i) =>
          (Math.hypot(h[0] - at[0], h[1] - at[1]) < Math.hypot(corners[best][0] - at[0], corners[best][1] - at[1]) ? i : best), 0);
      }
      this.render(number);
    };
    const end = () => {
      layer.classList.remove("moving");
      layer.removeEventListener("pointermove", move);
      layer.removeEventListener("pointerup", end);
      layer.removeEventListener("pointercancel", end);
      if (drag.type !== "draw") return;
      // A click without a drag draws nothing
      if (Math.hypot(shape.end[0] - shape.start[0], shape.end[1] - shape.start[1]) / perPixel < 3) this.shapes.splice(this.selected, 1);
      // A color chosen next is for the next shape; clicking a shape selects it to change it
      this.selected = null;
      this.render(number);
    };
    layer.addEventListener("pointermove", move);
    layer.addEventListener("pointerup", end);
    layer.addEventListener("pointercancel", end);
  }

  render(number) {
    const layer = this.layers.get(number);
    if (!layer) return;
    const { width, height } = this.pageSize(number);
    layer.setAttribute("viewBox", `0 0 ${width} ${height}`);
    const pixel = width / Math.max(layer.getBoundingClientRect().width || width, 1);
    const elements = [];
    this.shapes.forEach((shape, index) => {
      if (shape.page !== number) return;
      const path = document.createElementNS(SVG, "path");
      path.setAttribute("d", outline(shape).flat().join(" "));
      path.setAttribute("fill", "none");
      path.setAttribute("stroke", SHAPE_COLORS[shape.color]);
      path.setAttribute("stroke-width", SHAPE_WIDTHS[shape.width]);
      path.setAttribute("stroke-linecap", "round");
      path.setAttribute("stroke-linejoin", shape.kind === "rectangle" ? "miter" : "round");
      elements.push(path);
      if (index !== this.selected) return;
      for (const [x, y] of handles(shape)) {
        const square = document.createElementNS(SVG, "rect");
        square.classList.add("shape-handle");
        square.setAttribute("x", x - 4 * pixel);
        square.setAttribute("y", y - 4 * pixel);
        square.setAttribute("width", 8 * pixel);
        square.setAttribute("height", 8 * pixel);
        square.setAttribute("stroke-width", pixel);
        elements.push(square);
      }
    });
    layer.replaceChildren(...elements);
  }

  /**
   * The shapes in PDF points of each page, for `drawShapesOnPage`: [{ index, shapes: [{ commands, color, width, join }] }].
   * The viewport maps the page as it is shown back to the PDF, whatever its rotation.
   */
  pdfShapes() {
    const pages = new Map();
    for (const shape of this.shapes) {
      const { viewport } = this.pageSize(shape.page);
      const toPDF = (x, y) => viewport.convertToPdfPoint(x * viewport.scale, y * viewport.scale);
      const commands = outline(shape).map(([op, ...xy]) => {
        const points = [];
        for (let i = 0; i < xy.length; i += 2) points.push(...toPDF(xy[i], xy[i + 1]));
        return [op, ...points];
      });
      const hex = SHAPE_COLORS[shape.color];
      const color = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
      if (!pages.has(shape.page)) pages.set(shape.page, []);
      pages.get(shape.page).push({ commands, color, width: SHAPE_WIDTHS[shape.width], join: shape.kind === "rectangle" ? "miter" : "round" });
    }
    return [...pages].map(([page, shapes]) => ({ index: page - 1, shapes }));
  }
}

/** Strokes shapes of `pdfShapes` over a page of pdf-lib. */
export function drawShapesOnPage(page, shapes) {
  for (const { commands, color, width, join } of shapes) {
    const path = commands.map(([op, ...xy]) => {
      if (op === "M") return moveTo(...xy);
      if (op === "L") return lineTo(...xy);
      if (op === "C") return appendBezierCurve(...xy);
      return closePath();
    });
    page.pushOperators(
      pushGraphicsState(),
      setStrokingRgbColor(...color),
      setLineWidth(width),
      setLineCap(LineCapStyle.Round),
      setLineJoin(join === "miter" ? LineJoinStyle.Miter : LineJoinStyle.Round),
      ...path,
      stroke(),
      popGraphicsState(),
    );
  }
}
