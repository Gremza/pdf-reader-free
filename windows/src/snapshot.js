/**
 * "Take a Snapshot", like Acrobat's: the pointer becomes a crosshair, and the part of a page dragged over
 * is saved as a JPG (and copied to the clipboard by the main process).
 */

// Snapshots are rendered at 300 DPI, but never larger than this many pixels on a side
const SNAPSHOT_DPI = 300;
const MAX_SIDE = 6000;

/**
 * Lays a layer over the pages of `container`. A drag stays within the page where it started;
 * `onSelect(pageNumber, part)` gets that page and the part of it as fractions { x, y, width, height }.
 * Returns a function that removes the layer.
 */
export function startSnapshot(container, onSelect) {
  const layer = document.createElement("div");
  layer.className = "snapshot-layer";
  const box = document.createElement("div");
  box.className = "snapshot-selection";
  box.hidden = true;
  layer.append(box);
  container.parentElement.append(layer);

  let drag = null;
  layer.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    // A drag that starts beside the pages takes nothing
    const page = pageAt(container, event.clientX, event.clientY);
    if (!page) return;
    drag = { page, bounds: page.getBoundingClientRect(), x: event.clientX, y: event.clientY, rect: null };
    layer.setPointerCapture(event.pointerId);
  });
  layer.addEventListener("pointermove", (event) => {
    if (!drag) return;
    const { bounds } = drag;
    const clampX = (x) => Math.min(Math.max(x, bounds.left), bounds.right);
    const clampY = (y) => Math.min(Math.max(y, bounds.top), bounds.bottom);
    const rect = {
      left: clampX(Math.min(drag.x, event.clientX)),
      right: clampX(Math.max(drag.x, event.clientX)),
      top: clampY(Math.min(drag.y, event.clientY)),
      bottom: clampY(Math.max(drag.y, event.clientY)),
    };
    drag.rect = rect;
    const origin = layer.getBoundingClientRect();
    Object.assign(box.style, {
      left: `${rect.left - origin.left}px`,
      top: `${rect.top - origin.top}px`,
      width: `${rect.right - rect.left}px`,
      height: `${rect.bottom - rect.top}px`,
    });
    box.hidden = false;
  });
  layer.addEventListener("pointerup", () => {
    if (!drag) return;
    const { page, bounds, rect } = drag;
    drag = null;
    box.hidden = true;
    // A click without a drag keeps waiting for one
    if (!rect || rect.right - rect.left < 4 || rect.bottom - rect.top < 4) return;
    onSelect(Number(page.dataset.pageNumber), {
      x: (rect.left - bounds.left) / bounds.width,
      y: (rect.top - bounds.top) / bounds.height,
      width: (rect.right - rect.left) / bounds.width,
      height: (rect.bottom - rect.top) / bounds.height,
    });
  });
  // Scrolling still moves the pages underneath
  layer.addEventListener("wheel", (event) => {
    if (!event.ctrlKey) container.scrollBy(event.deltaX, event.deltaY);
  }, { passive: true });
  layer.addEventListener("contextmenu", (event) => event.preventDefault());

  return () => layer.remove();
}

function pageAt(container, x, y) {
  return [...container.querySelectorAll(".page")].find((page) => {
    const rect = page.getBoundingClientRect();
    return x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom;
  }) ?? null;
}

/** Renders `part` of a page, upright as it is shown, on white, as JPEG bytes. */
export async function renderSnapshot(pdf, pageNumber, part) {
  const page = await pdf.getPage(pageNumber);
  const { width, height } = page.getViewport({ scale: 1 });
  const scale = Math.min(SNAPSHOT_DPI / 72, MAX_SIDE / Math.max(part.width * width, part.height * height, 1));
  const viewport = page.getViewport({ scale, offsetX: -part.x * width * scale, offsetY: -part.y * height * scale });
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(part.width * width * scale));
  canvas.height = Math.max(1, Math.round(part.height * height * scale));
  try {
    await page.render({ canvas, canvasContext: canvas.getContext("2d"), viewport, background: "#ffffff" }).promise;
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.9));
    if (!blob) throw new Error("The snapshot can't be saved");
    return new Uint8Array(await blob.arrayBuffer());
  } finally {
    canvas.width = canvas.height = 0;
  }
}
