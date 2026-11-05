import * as pdfjsLib from "../node_modules/pdfjs-dist/build/pdf.mjs";
import { ProtectedPDFError, assertEditable, extractPages, pageEdits, parsePageRanges } from "./editing.js";
import { extractDocument, hasText } from "./word.js";
import { REDUCED_QUALITIES, reduceImages } from "./reduce.js";
import { CancelledError, recognizeText } from "./ocr.js";

// pdf_viewer.mjs reads the core library from this global
globalThis.pdfjsLib = pdfjsLib;
const { EventBus, LinkTarget, PDFFindController, PDFLinkService, PDFViewer, RenderingStates, ScrollMode, SpreadMode } =
  await import("../node_modules/pdfjs-dist/web/pdf_viewer.mjs");

const PDFJS = new URL("../node_modules/pdfjs-dist/", import.meta.url).href;
pdfjsLib.GlobalWorkerOptions.workerSrc = PDFJS + "build/pdf.worker.mjs";

const LAYOUTS = {
  single: { scroll: ScrollMode.PAGE, spread: SpreadMode.NONE, title: "Single Page" },
  continuous: { scroll: ScrollMode.VERTICAL, spread: SpreadMode.NONE, title: "Continuous" },
  twoUp: { scroll: ScrollMode.PAGE, spread: SpreadMode.ODD, title: "Two Pages" },
  twoUpContinuous: { scroll: ScrollMode.VERTICAL, spread: SpreadMode.ODD, title: "Two Pages, Continuous" },
};

const DOC_ICON = '<svg class="doc-icon" viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/></svg>';
const CLOSE_ICON = '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6 6 18"/></svg>';

const PAGE_DRAG = "application/x-pdf-reader-page";
const UNDO_LIMIT = 30;

const MIN_TAB_WIDTH = 110;
const MAX_TAB_WIDTH = 210;
const OVERFLOW_WIDTH = 48;
const ADD_WIDTH = 32;

const $ = (id) => document.getElementById(id);
const el = {
  topbar: $("topbar"),
  toggleThumbs: $("toggle-thumbs"),
  tabstrip: $("tabstrip"),
  tabs: $("tabs"),
  overflowAnchor: $("overflow-anchor"),
  overflowButton: $("overflow-button"),
  overflowMenu: $("overflow-menu"),
  addTab: $("add-tab"),
  controls: $("controls"),
  prevPage: $("prev-page"),
  pageField: $("page-field"),
  pageCount: $("page-count"),
  nextPage: $("next-page"),
  zoomOut: $("zoom-out"),
  zoomIn: $("zoom-in"),
  fitWidth: $("fit-width"),
  fitPage: $("fit-page"),
  exportProgress: $("export-progress"),
  exportBar: $("export-bar"),
  exportLabel: $("export-label"),
  exportCancel: $("export-cancel"),
  documentButton: $("document-button"),
  promptDialog: $("prompt-dialog"),
  promptField: $("prompt-field"),
  fullscreen: $("fullscreen"),
  searchField: $("search-field"),
  searchCount: $("search-count"),
  documents: $("documents"),
  emptyState: $("empty-state"),
  openButton: $("open-button"),
  updatesButton: $("updates-button"),
  updateProgress: $("update-progress"),
  updateBar: $("update-bar"),
};

/** All open PDFs of the window, shown as tabs in the top bar. */
const state = {
  tabs: [],
  selected: null,
  showThumbnails: true,
  // View > Fade Between Pages, on by default
  fadeBetweenPages: readSetting("fadeBetweenPages") !== "false",
  // Full Screen Mode: only the page of the selected tab, like a presentation
  presenting: false,
  // Update settings and whether a check is running, from the main process
  updates: {},
};

let nextID = 1;

/** localStorage can be unavailable; the defaults apply then. */
function readSetting(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function writeSetting(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // The setting lasts until the app quits
  }
}

const FADE_MS = 300;
const PRINT_DPI = 200;

// MARK: - Document tab

class DocumentTab {
  constructor(file, pdfDocument) {
    this.id = nextID++;
    this.path = file.path;
    this.name = file.name;
    this.pdf = pdfDocument;
    // The PDF as it is now, as last saved, and before each edit (for undo)
    this.bytes = file.data;
    this.savedBytes = file.data;
    this.history = [];
    this.fitMode = "width";
    this.layout = "single";
    this.currentPage = 1;
    this.searchText = "";
    this.matches = { current: 0, total: 0 };

    this.element = document.createElement("div");
    this.element.className = "document";
    this.element.hidden = true;
    this.element.innerHTML = '<nav class="thumbnails"></nav><div class="viewer-wrap"><div class="viewer-container" tabindex="-1"><div class="pdfViewer"></div></div></div>';
    el.documents.append(this.element);

    this.thumbnails = this.element.querySelector(".thumbnails");
    this.container = this.element.querySelector(".viewer-container");

    this.eventBus = new EventBus();
    this.linkService = new PDFLinkService({ eventBus: this.eventBus, externalLinkTarget: LinkTarget.BLANK });
    this.findController = new PDFFindController({ eventBus: this.eventBus, linkService: this.linkService });
    this.viewer = new PDFViewer({
      container: this.container,
      eventBus: this.eventBus,
      linkService: this.linkService,
      findController: this.findController,
      removePageBorders: true,
    });
    this.linkService.setViewer(this.viewer);

    this.eventBus.on("pagesinit", () => {
      this.applyLayout();
      this.applyFit();
      // A new document starts without a zoom; keep the one the user chose
      if (this.fitMode === "custom" && this.pendingScale) this.viewer.currentScaleValue = this.pendingScale;
      this.pendingScale = null;
      // After an edit, stay on the page the user was working on
      if (this.pendingPage) {
        this.viewer.currentPageNumber = this.pendingPage;
        this.pendingPage = null;
      }
    });
    this.eventBus.on("pagechanging", ({ pageNumber }) => {
      this.currentPage = pageNumber;
      this.updateCurrentThumbnail();
      if (this === state.selected) updateControls();
    });
    this.eventBus.on("updatefindmatchescount", ({ matchesCount }) => {
      this.matches = matchesCount;
      if (this === state.selected) updateSearchCount();
    });
    this.eventBus.on("updatefindcontrolstate", ({ matchesCount }) => {
      if (matchesCount) this.matches = matchesCount;
      if (this === state.selected) updateSearchCount();
    });

    // Keep "fit width" / "fit page" fitted while the window is resized
    new ResizeObserver(() => {
      if (this.container.clientWidth > 0 && this.fitMode !== "custom") this.applyFit();
    }).observe(this.container);

    // Ctrl + mouse wheel zooms around the pointer
    this.container.addEventListener("wheel", (event) => {
      if (!event.ctrlKey) return;
      event.preventDefault();
      this.fitMode = "custom";
      this.viewer.updateScale({ steps: event.deltaY < 0 ? 1 : -1, origin: [event.clientX, event.clientY] });
      updateControls();
    }, { passive: false });

    this.viewer.setDocument(pdfDocument);
    this.linkService.setDocument(pdfDocument);
    this.buildThumbnails();
  }

  get pageCount() { return this.pdf.numPages; }
  /** Full Screen Mode always shows single pages, whatever the layout. */
  get displayLayout() { return this.presenting ? "single" : this.layout; }
  get isDirty() { return this.bytes !== this.savedBytes; }
  get baseName() { return this.name.replace(/\.pdf$/i, ""); }

  destroy() {
    // A running "Recognize Text" stops without a message
    if (this.exportProgress?.cancellable) this.exportProgress.cancelled = true;
    this.thumbnailObserver?.disconnect();
    this.viewer.setDocument(null);
    this.linkService.setDocument(null);
    this.pdf.loadingTask.destroy();
    this.element.remove();
  }

  // MARK: Navigation

  goToPage(number) {
    this.turnPage(() => { this.viewer.currentPageNumber = Math.min(Math.max(number, 1), this.pageCount); });
  }

  previousPage() { this.turnPage(() => this.viewer.previousPage()); }
  nextPage() { this.turnPage(() => this.viewer.nextPage()); }

  /** With "Fade Between Pages", a copy of the old pages fades out once the new page is drawn. */
  turnPage(change) {
    const before = this.viewer.currentPageNumber;
    const overlay = state.fadeBetweenPages ? this.pageSnapshot() : null;
    change();
    const page = this.viewer.currentPageNumber;
    if (!overlay || page === before) return;

    this.fadeOverlay?.remove();
    this.fadeOverlay = overlay;
    this.container.after(overlay);
    let started = false;
    const start = () => {
      if (started) return;
      started = true;
      this.eventBus.off("pagerendered", rendered);
      // Reading the layout first makes the change of opacity a transition
      void overlay.offsetWidth;
      overlay.classList.add("fading");
      setTimeout(() => overlay.remove(), FADE_MS + 100);
    };
    const rendered = ({ pageNumber }) => { if (pageNumber === page) start(); };
    if (this.viewer.getPageView(page - 1)?.renderingState === RenderingStates.FINISHED) {
      start();
    } else {
      this.eventBus.on("pagerendered", rendered);
      // A slow page fades in while it is still being drawn
      setTimeout(start, 200);
    }
  }

  /** The visible page canvases, copied onto a layer over the viewer. */
  pageSnapshot() {
    const area = this.container.getBoundingClientRect();
    const overlay = document.createElement("div");
    overlay.className = "page-fade";
    for (const canvas of this.container.querySelectorAll(".page canvas")) {
      const rect = canvas.getBoundingClientRect();
      if (!canvas.width || rect.bottom <= area.top || rect.top >= area.bottom) continue;
      const copy = document.createElement("canvas");
      copy.width = canvas.width;
      copy.height = canvas.height;
      copy.getContext("2d").drawImage(canvas, 0, 0);
      Object.assign(copy.style, {
        left: `${rect.left - area.left}px`,
        top: `${rect.top - area.top}px`,
        width: `${rect.width}px`,
        height: `${rect.height}px`,
      });
      overlay.append(copy);
    }
    return overlay;
  }

  // MARK: Full Screen Mode

  /** Shows one fitted page at a time on black, without page borders or scroll bars; the layout and zoom come back afterwards. */
  setPresenting(presenting) {
    if (presenting === !!this.presenting) return;
    const page = this.currentPage;
    if (presenting) {
      this.beforePresenting = { fitMode: this.fitMode, scale: this.viewer.currentScaleValue };
      this.fitMode = "page";
    } else {
      this.fitMode = this.beforePresenting.fitMode;
    }
    this.presenting = presenting;
    this.element.classList.toggle("presenting", presenting);
    this.applyLayout();
    if (this.fitMode === "custom") this.viewer.currentScaleValue = this.beforePresenting.scale;
    this.applyFit();
    this.viewer.currentPageNumber = page;
  }

  // MARK: Zoom

  zoomIn() {
    this.fitMode = "custom";
    this.viewer.increaseScale();
  }

  zoomOut() {
    this.fitMode = "custom";
    this.viewer.decreaseScale();
  }

  actualSize() {
    this.fitMode = "custom";
    this.viewer.currentScaleValue = "page-actual";
  }

  fitWidth() {
    this.fitMode = "width";
    this.applyFit();
  }

  fitPage() {
    this.fitMode = "page";
    this.applyFit();
    this.viewer.currentPageNumber = this.currentPage;
  }

  applyFit() {
    if (this.fitMode === "width") this.viewer.currentScaleValue = "page-width";
    else if (this.fitMode === "page") this.fitPageSpread();
  }

  /** pdf.js "page-fit" ignores the second page of a spread, so two-page layouts are fitted by hand. */
  fitPageSpread() {
    const pageView = this.viewer.getPageView(this.currentPage - 1);
    if (LAYOUTS[this.displayLayout].spread === SpreadMode.NONE || !pageView) {
      this.viewer.currentScaleValue = "page-fit";
      return;
    }
    const width = (pageView.viewport.width / pageView.scale) * 2;
    const height = pageView.viewport.height / pageView.scale;
    const margin = 40;
    const available = { width: this.container.clientWidth - margin, height: this.container.clientHeight - margin };
    if (available.width <= 0 || available.height <= 0) return;
    this.viewer.currentScale = Math.min(available.width / width, available.height / height);
  }

  // MARK: Layout & rotation

  setLayout(layout) {
    const page = this.currentPage;
    this.layout = layout;
    this.applyLayout();
    this.applyFit();
    this.viewer.currentPageNumber = page;
  }

  applyLayout() {
    const { scroll, spread } = LAYOUTS[this.displayLayout];
    this.viewer.scrollMode = scroll;
    this.viewer.spreadMode = spread;
  }

  /** Rotates all pages; saved into the file like any other edit. */
  rotate(degrees) {
    this.applyEdit((bytes) => pageEdits.rotateAll(bytes, degrees));
  }

  // MARK: Editing

  get canEdit() { return !this.busy && !this.exportProgress; }

  /**
   * Runs a page operation on the PDF bytes and shows the result; the previous bytes go on the undo stack.
   * Resolves to false when nothing changed.
   */
  async applyEdit(edit, pageAfter = this.currentPage) {
    if (!this.canEdit) return false;
    this.busy = true;
    try {
      const bytes = await edit(this.bytes);
      this.history.push(this.bytes);
      if (this.history.length > UNDO_LIMIT) this.history.shift();
      await this.show(bytes, pageAfter);
      return true;
    } catch (error) {
      showEditError(error);
      return false;
    } finally {
      this.busy = false;
    }
  }

  async undo() {
    if (!this.canEdit || !this.history.length) return;
    this.busy = true;
    try {
      await this.show(this.history.pop(), this.currentPage);
    } finally {
      this.busy = false;
    }
  }

  async show(bytes, page) {
    const pdf = await loadPDF(bytes);
    const previous = this.pdf;
    this.bytes = bytes;
    this.pdf = pdf;
    this.currentPage = this.pendingPage = Math.min(Math.max(page, 1), pdf.numPages);
    this.pendingScale = this.viewer.currentScaleValue;
    this.matches = { current: 0, total: 0 };
    this.viewer.setDocument(pdf);
    this.linkService.setDocument(pdf);
    previous.loadingTask.destroy();
    this.buildThumbnails();
    if (this.searchText.trim()) this.search();
    documentChanged(this);
  }

  // Page numbers below are 1-based, like in the UI

  deletePage(number) {
    if (this.pageCount <= 1) {
      window.host.showError("The page can't be deleted", "A PDF must have at least one page.");
      return;
    }
    this.applyEdit((bytes) => pageEdits.remove(bytes, number - 1), number);
  }

  rotatePage(number, degrees) {
    this.applyEdit((bytes) => pageEdits.rotate(bytes, number - 1, degrees), number);
  }

  /** Moves a page so that it ends up at position `to`. */
  movePage(from, to) {
    if (from === to) return;
    this.applyEdit((bytes) => pageEdits.move(bytes, from - 1, to - 1), to);
  }

  insertBlankPage(after) {
    this.applyEdit((bytes) => pageEdits.insertBlank(bytes, after), after + 1);
  }

  /** Lets the user pick PDFs and inserts their pages after page `after` (0 = at the start). */
  async insertPDFs(after, title) {
    if (!this.canEdit) return;
    try {
      await assertEditable(this.bytes);
    } catch (error) {
      showEditError(error);
      return;
    }
    const files = await window.host.pickPDFs(title);
    if (!files.length) return;
    this.applyEdit((bytes) => pageEdits.insertPDFs(bytes, after, files.map((file) => file.data)), after + 1);
  }

  /** Asks which pages to keep and saves them as a new PDF. */
  async extractPagesPrompt(defaultValue = `${this.currentPage}`) {
    const text = await askText({
      title: "Extract Pages",
      message: `Enter the pages to save in a new PDF, e.g. 1-3, 5 (${this.pageCount} pages in total).`,
      value: defaultValue,
      confirm: "Extract",
    });
    if (text === null) return;
    const indexes = parsePageRanges(text, this.pageCount);
    if (!indexes) {
      window.host.showError("Invalid pages", `Enter numbers from 1 to ${this.pageCount}, e.g. 1-3, 5`);
      return;
    }
    try {
      const bytes = await extractPages(this.bytes, indexes);
      await window.host.saveAs(`${this.baseName} (pages ${text.replace(/\s+/g, "")}).pdf`, bytes, "Save Extracted Pages");
    } catch (error) {
      showEditError(error);
    }
  }

  /** Saves every page as 1.pdf, 2.pdf, … in a new folder named after the PDF. */
  async splitPages() {
    if (!this.canEdit) return;
    try {
      await assertEditable(this.bytes);
    } catch (error) {
      showEditError(error);
      return;
    }
    await this.exportToFolder("Choose where to create the folder of PDF pages", "Splitting", async (number) => ({
      name: `${number}.pdf`,
      data: await extractPages(this.bytes, [number - 1]),
    }));
  }

  /** Saves a copy of the PDF whose images are stored again as JPEG at a lower resolution and quality. */
  async reduceFileSize() {
    if (!this.canEdit) return;
    try {
      await assertEditable(this.bytes);
    } catch (error) {
      showEditError(error);
      return;
    }
    const choice = await window.host.askReducedQuality(REDUCED_QUALITIES.map((quality) => `${quality.title} (${quality.dpi} dpi)`));
    const quality = REDUCED_QUALITIES[choice];
    if (!quality) return;

    const original = this.bytes;
    this.startProgress("Reducing");
    let reduced;
    try {
      reduced = await reduceImages(original, quality, (n) => this.updateProgress(n));
    } catch (error) {
      if (error instanceof ProtectedPDFError) showEditError(error);
      else window.host.showError("Reducing the file size failed", "The PDF can't be read.");
      return;
    } finally {
      this.endProgress();
    }
    if (reduced.length >= original.length) {
      window.host.showError("This PDF can't be made smaller",
        "Its images are already compressed, or it has no images." + (quality.id === "low" ? "" : " Try a lower quality."));
      return;
    }
    let path;
    try {
      path = await window.host.saveAs(`${this.baseName} (reduced).pdf`, reduced, "Save Reduced Size PDF");
    } catch (error) {
      window.host.showError("The PDF can't be saved", errorMessage(error));
      return;
    }
    if (!path) return;
    const percent = Math.round(100 - (reduced.length * 100) / original.length);
    window.host.showReduced(path, `Reduced from ${formatSize(original.length)} to ${formatSize(reduced.length)} (${percent}% smaller).`);
  }

  /**
   * Finds the text of scanned pages with Tesseract and adds it as an invisible layer over each page,
   * so it can be searched and copied. Pages that already have text are skipped.
   */
  async recognizeText() {
    if (!this.canEdit) return;
    try {
      await assertEditable(this.bytes);
    } catch (error) {
      showEditError(error);
      return;
    }
    const progress = this.startProgress("Recognizing text", { cancellable: true });
    let result;
    try {
      result = await recognizeText(this.bytes, this.pdf, (n) => this.updateProgress(n), () => progress.cancelled);
    } catch (error) {
      if (!(error instanceof CancelledError) && !progress.cancelled) window.host.showError("Recognizing text failed", "The PDF can't be read.");
      return;
    } finally {
      this.endProgress();
    }
    if (progress.cancelled) return;
    const { bytes, pages, skipped } = result;
    if (skipped === this.pageCount) {
      window.host.showError("This PDF already has text", "Every page already has text that can be searched and copied.");
      return;
    }
    if (!pages) {
      window.host.showError("No text was found", "The pages may be blank, or the text may be too small or unclear to read.");
      return;
    }
    if (!(await this.applyEdit(() => bytes))) return;
    window.host.showInfo("Text recognized",
      `The text of ${pages === 1 ? "1 page" : `${pages} pages`} can now be searched and copied. ` +
      (skipped ? "Pages that already had text were skipped. " : "") +
      "Save the PDF to keep it.");
  }

  /** Writes back to the file; returns false when it failed. */
  async save() {
    if (!this.isDirty) return true;
    const bytes = this.bytes;
    try {
      await window.host.saveFile(this.path, bytes);
    } catch (error) {
      window.host.showError("The PDF can't be saved", errorMessage(error));
      return false;
    }
    this.savedBytes = bytes;
    documentChanged(this);
    return true;
  }

  async saveAs() {
    const bytes = this.bytes;
    let path;
    try {
      path = await window.host.saveAs(this.name, bytes, "Save As");
    } catch (error) {
      window.host.showError("The PDF can't be saved", errorMessage(error));
      return false;
    }
    if (!path) return false;
    this.path = path;
    this.name = path.split(/[\\/]/).pop();
    this.savedBytes = bytes;
    documentChanged(this);
    return true;
  }

  // MARK: Search

  search(again = false, previous = false) {
    this.eventBus.dispatch("find", {
      source: this,
      type: again ? "again" : "",
      query: this.searchText.trim(),
      caseSensitive: false,
      entireWord: false,
      highlightAll: true,
      findPrevious: previous,
      matchDiacritics: false,
    });
  }

  // MARK: Export

  /** Saves every page as 1.jpg, 2.jpg, … in a new folder named after the PDF. */
  exportJPEG() {
    return this.exportToFolder("Choose where to create the folder of JPG images", "Exporting", async (number) => ({
      name: `${number}.jpg`,
      data: await this.renderJPEG(number),
    }));
  }

  /** Creates a folder named after the PDF and writes one file per page into it. */
  async exportToFolder(title, label, filePerPage) {
    if (!this.canEdit) return;
    const folder = await window.host.chooseExportFolder(this.name, title);
    if (!folder) return;

    let error = null;
    this.startProgress(label);
    try {
      for (let n = 1; n <= this.pageCount; n++) {
        const file = await filePerPage(n);
        await window.host.writeExportFile(folder, file.name, file.data);
        this.updateProgress(n);
      }
    } catch (failure) {
      error = errorMessage(failure);
    }
    this.endProgress();
    window.host.exportFinished(folder, error);
  }

  /** Saves the text of the PDF as a Word document. */
  async exportWord() {
    if (!this.canEdit) return;
    this.startProgress("Preparing Word");
    let document;
    try {
      document = await extractDocument(this.pdf, (n) => this.updateProgress(n));
    } catch (error) {
      this.endProgress();
      window.host.showError("Word export failed", errorMessage(error));
      return;
    }
    this.endProgress();
    if (!hasText(document)) {
      window.host.showError("This PDF has no text", "The pages are probably scanned images, so there is no text to export to Word.");
      return;
    }
    try {
      await window.host.exportDocx(`${this.baseName}.docx`, document);
    } catch (error) {
      window.host.showError("Word export failed", errorMessage(error));
    }
  }

  /** `cancellable` shows a Cancel button, which sets `cancelled` on the returned progress. */
  startProgress(label, { cancellable = false } = {}) {
    this.exportProgress = { label, done: 0, total: this.pageCount, cancellable, cancelled: false };
    if (this === state.selected) updateExportProgress();
    return this.exportProgress;
  }

  updateProgress(done) {
    this.exportProgress.done = done;
    if (this === state.selected) updateExportProgress();
  }

  endProgress() {
    this.exportProgress = null;
    if (this === state.selected) updateExportProgress();
  }

  // MARK: Printing

  /**
   * Prints the pages as they are now, unsaved edits included. Each page is drawn as an image
   * at 200 DPI, like pdf.js prints, and the system print dialog chooses printer, pages and copies.
   */
  async print() {
    if (!this.canEdit) return;
    const permissions = await this.pdf.getPermissions();
    if (permissions && !permissions.includes(pdfjsLib.PermissionFlag.PRINT)) {
      window.host.showError("This PDF can't be printed", "Its author doesn't allow printing.");
      return;
    }
    const container = document.createElement("div");
    container.id = "print-container";
    const style = document.createElement("style");
    const urls = [];
    let landscapeSheet = false;
    this.startProgress("Preparing to print");
    try {
      for (let n = 1; n <= this.pageCount; n++) {
        const page = await this.pdf.getPage(n);
        const { width, height } = page.getViewport({ scale: 1 });
        if (n === 1) {
          // The paper size of the first page, like pdf.js; other sizes are scaled to fit
          style.textContent = `@page { size: ${width}pt ${height}pt; margin: 0; }`;
          landscapeSheet = width > height;
        }
        // Pages of the other orientation are turned counterclockwise to fill the sheet, like auto-rotate on macOS
        const turn = width !== height && (width > height) !== landscapeSheet;
        const url = await this.renderPrintPage(page, turn);
        urls.push(url);
        const sheet = document.createElement("div");
        sheet.className = "print-page";
        const image = new Image();
        image.src = url;
        await image.decode();
        sheet.append(image);
        container.append(sheet);
        this.updateProgress(n);
      }
    } catch {
      urls.forEach((url) => URL.revokeObjectURL(url));
      window.host.showError("Printing failed", "The PDF can't be read.");
      return;
    } finally {
      this.endProgress();
    }
    document.head.append(style);
    document.body.append(container);
    document.body.classList.add("printing");
    // The title is the default name when printing to PDF
    const title = document.title;
    document.title = this.baseName;
    try {
      const { success, failureReason } = await window.host.print();
      if (!success && failureReason !== "cancelled") window.host.showError("Printing failed", failureReason);
    } finally {
      document.title = title;
      document.body.classList.remove("printing");
      container.remove();
      style.remove();
      urls.forEach((url) => URL.revokeObjectURL(url));
    }
  }

  async renderPrintPage(page, turn) {
    const viewport = page.getViewport({ scale: PRINT_DPI / 72, rotation: (page.rotate + (turn ? 270 : 0)) % 360 });
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(viewport.width);
    canvas.height = Math.round(viewport.height);
    try {
      await page.render({
        canvas,
        canvasContext: canvas.getContext("2d"),
        viewport,
        intent: "print",
        annotationMode: pdfjsLib.AnnotationMode.ENABLE_STORAGE,
        background: "#ffffff",
      }).promise;
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
      if (!blob) throw new Error(`Page ${page.pageNumber} can't be printed`);
      return URL.createObjectURL(blob);
    } finally {
      canvas.width = canvas.height = 0;
    }
  }

  /** Renders the page at 144 DPI on white. */
  async renderJPEG(pageNumber) {
    const page = await this.pdf.getPage(pageNumber);
    const viewport = page.getViewport({ scale: 2 });
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(viewport.width);
    canvas.height = Math.round(viewport.height);
    try {
      await page.render({ canvas, canvasContext: canvas.getContext("2d"), viewport, background: "#ffffff" }).promise;
      const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.9));
      if (!blob) throw new Error(`Page ${pageNumber} can't be saved`);
      return new Uint8Array(await blob.arrayBuffer());
    } finally {
      canvas.width = canvas.height = 0;
    }
  }

  // MARK: Thumbnails

  async buildThumbnails() {
    const pdf = this.pdf;
    const first = await pdf.getPage(1);
    // A newer edit replaced the document while waiting
    if (pdf !== this.pdf) return;
    const viewport = first.getViewport({ scale: 1 });
    this.thumbnailObserver?.disconnect();
    this.thumbnails.replaceChildren();
    // Thumbnails near the visible area wait here; ones scrolled away before their turn are dropped
    this.thumbnailQueue = new Set();
    this.thumbnailObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) this.thumbnailQueue.add(entry.target);
        else this.thumbnailQueue.delete(entry.target);
      }
      this.renderThumbnails();
    }, { root: this.thumbnails, rootMargin: "300px 0px" });

    const fragment = document.createDocumentFragment();
    for (let n = 1; n <= this.pageCount; n++) {
      const button = document.createElement("button");
      button.className = "thumb";
      button.dataset.page = n;
      button.title = `Page ${n}`;
      button.draggable = true;
      const canvas = document.createElement("canvas");
      setThumbnailSize(canvas, viewport.width, viewport.height);
      const label = document.createElement("span");
      label.textContent = n;
      button.append(canvas, label);
      button.addEventListener("click", () => this.goToPage(n));
      button.addEventListener("contextmenu", (event) => {
        event.preventDefault();
        this.goToPage(n);
        showPageMenu(this, n, event.clientX, event.clientY);
      });
      button.addEventListener("keydown", (event) => {
        if (event.key === "Delete") this.deletePage(n);
      });
      this.addDragHandlers(button, n);
      this.thumbnailObserver.observe(button);
      fragment.append(button);
    }
    this.thumbnails.append(fragment);
    this.updateCurrentThumbnail();
  }

  /** Thumbnails can be dragged up or down to reorder the pages. */
  addDragHandlers(button, number) {
    const clear = () => button.classList.remove("drop-before", "drop-after");
    button.addEventListener("dragstart", (event) => {
      this.draggedPage = number;
      event.dataTransfer.setData(PAGE_DRAG, String(number));
      event.dataTransfer.effectAllowed = "move";
    });
    button.addEventListener("dragend", () => {
      this.draggedPage = null;
    });
    button.addEventListener("dragover", (event) => {
      if (!this.draggedPage) return;
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      const after = event.offsetY > button.clientHeight / 2;
      button.classList.toggle("drop-after", after);
      button.classList.toggle("drop-before", !after);
    });
    button.addEventListener("dragleave", clear);
    button.addEventListener("drop", (event) => {
      if (!this.draggedPage) return;
      event.preventDefault();
      event.stopPropagation();
      const after = button.classList.contains("drop-after");
      clear();
      const from = this.draggedPage;
      this.draggedPage = null;
      // Position counted before the dragged page is taken out
      const insertAt = after ? number + 1 : number;
      this.movePage(from, insertAt > from ? insertAt - 1 : insertAt);
    });
  }

  /** Renders one thumbnail at a time, so scrolling the sidebar stays smooth. */
  async renderThumbnails() {
    if (this.renderingThumbnails) return;
    this.renderingThumbnails = true;
    while (this.thumbnailQueue.size) {
      const [button] = this.thumbnailQueue;
      this.thumbnailQueue.delete(button);
      if (button.isConnected) await this.renderThumbnail(button);
    }
    this.renderingThumbnails = false;
  }

  async renderThumbnail(button) {
    if (button.dataset.rendered) return;
    button.dataset.rendered = "1";
    try {
      const page = await this.pdf.getPage(Number(button.dataset.page));
      const base = page.getViewport({ scale: 1 });
      const scale = Math.min(110 / base.width, 140 / base.height) * window.devicePixelRatio;
      const viewport = page.getViewport({ scale });
      const canvas = document.createElement("canvas");
      canvas.width = Math.ceil(viewport.width);
      canvas.height = Math.ceil(viewport.height);
      setThumbnailSize(canvas, base.width, base.height);
      await page.render({ canvas, canvasContext: canvas.getContext("2d"), viewport }).promise;
      button.querySelector("canvas").replaceWith(canvas);
    } catch {
      delete button.dataset.rendered;
    }
  }

  updateCurrentThumbnail() {
    this.thumbnails.querySelector(".thumb.current")?.classList.remove("current");
    const button = this.thumbnails.children[this.currentPage - 1];
    if (!button) return;
    button.classList.add("current");
    if (!this.element.hidden) button.scrollIntoView({ block: "nearest" });
  }
}

function setThumbnailSize(canvas, width, height) {
  const scale = Math.min(110 / width, 140 / height);
  canvas.style.width = `${Math.round(width * scale)}px`;
  canvas.style.height = `${Math.round(height * scale)}px`;
}

// MARK: - Opening

/** pdf.js takes ownership of the data it is given, so it gets a copy and the tab keeps the original. */
function loadPDF(bytes) {
  return pdfjsLib.getDocument({
    data: bytes.slice(),
    cMapUrl: PDFJS + "cmaps/",
    cMapPacked: true,
    standardFontDataUrl: PDFJS + "standard_fonts/",
    wasmUrl: PDFJS + "wasm/",
    iccUrl: PDFJS + "iccs/",
    isEvalSupported: false,
  }).promise;
}

async function openFiles(files) {
  const failed = [];
  for (const file of files) {
    const existing = state.tabs.find((tab) => tab.path.toLowerCase() === file.path.toLowerCase());
    if (existing) {
      select(existing);
      continue;
    }
    try {
      const pdf = await loadPDF(file.data);
      const tab = new DocumentTab(file, pdf);
      state.tabs.push(tab);
      select(tab);
    } catch {
      failed.push(file.name);
    }
  }
  if (failed.length) window.host.reportFailed(failed);
}

// MARK: - Tabs

function select(tab) {
  if (state.selected === tab) return;
  closeMenus();
  if (state.selected) state.selected.element.hidden = true;
  // Full Screen Mode moves along to the selected tab and ends when the last tab closes
  if (state.presenting) {
    state.selected?.setPresenting(false);
    if (tab) tab.setPresenting(true);
    else endPresentation();
  }
  state.selected = tab;
  if (tab) {
    tab.element.hidden = false;
    tab.element.classList.toggle("no-thumbs", !state.showThumbnails);
    tab.updateCurrentThumbnail();
    tab.container.focus({ preventScroll: true });
  }
  render();
}

/** Asks to save unsaved changes first; does nothing when the user cancels. */
async function close(tab) {
  if (tab.isDirty) {
    select(tab);
    const choice = await window.host.confirmCloseTab(tab.name);
    if (choice === 2 || (choice === 0 && !(await tab.save()))) return;
  }
  const index = state.tabs.indexOf(tab);
  if (index < 0) return;
  state.tabs.splice(index, 1);
  if (state.selected === tab) {
    state.selected = null;
    select(state.tabs[Math.min(index, state.tabs.length - 1)] ?? null);
  }
  if (!state.selected) endPresentation();
  tab.destroy();
  render();
  updateDirtyCount();
}

/** Ctrl+W closes the current tab, or the window when no tab is open. */
function closeSelected() {
  if (state.selected) close(state.selected);
  else window.host.closeWindow();
}

function selectOffset(offset) {
  if (!state.tabs.length) return;
  const index = Math.max(0, state.tabs.indexOf(state.selected));
  select(state.tabs[(index + offset + state.tabs.length) % state.tabs.length]);
}

/** Called after an edit, undo or save changed a tab's document or file. */
function documentChanged(tab) {
  if (tab === state.selected) {
    renderTabs();
    updateControls();
  }
  updateDirtyCount();
}

function updateDirtyCount() {
  syncMenu();
  window.host.setDirtyCount(state.tabs.filter((tab) => tab.isDirty).length);
}

/** "173 KB", "16.1 MB": the same format as in the macOS app. */
function formatSize(bytes) {
  return bytes < 1_000_000 ? `${Math.max(1, Math.round(bytes / 1000))} KB` : `${(bytes / 1_000_000).toFixed(1)} MB`;
}

function errorMessage(error) {
  return String(error?.message ?? error).replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
}

function showEditError(error) {
  if (error instanceof ProtectedPDFError) {
    window.host.showError("This PDF is protected", "PDFs protected by a password or restrictions can't be edited.");
  } else {
    window.host.showError("Edit failed", errorMessage(error));
  }
}

/** A small modal with one text field; resolves with the text, or null when cancelled. */
function askText({ title, message, value, confirm }) {
  const dialog = el.promptDialog;
  dialog.querySelector("h2").textContent = title;
  dialog.querySelector("p").textContent = message;
  dialog.querySelector("[value=ok]").textContent = confirm;
  el.promptField.value = value;
  dialog.returnValue = "";
  dialog.showModal();
  el.promptField.select();
  return new Promise((resolve) => {
    dialog.addEventListener("close", () => resolve(dialog.returnValue === "ok" ? el.promptField.value : null), { once: true });
  });
}

// MARK: - Rendering

function render() {
  const tab = state.selected;
  el.emptyState.hidden = state.tabs.length > 0;
  el.toggleThumbs.disabled = !tab;
  el.controls.hidden = !tab;
  renderTabs();
  updateControls();
  updateExportProgress();
  if (tab) {
    el.searchField.value = tab.searchText;
    updateSearchCount();
  }
}

/** Shrinks tabs down to MIN_TAB_WIDTH; whatever still doesn't fit goes into the overflow menu. */
function tabLayout(width) {
  const all = state.tabs;
  if (!all.length) return { visible: [], hidden: [], tabWidth: 0 };

  const available = width - ADD_WIDTH;
  if (all.length * MIN_TAB_WIDTH <= available) {
    return { visible: all, hidden: [], tabWidth: Math.min(MAX_TAB_WIDTH, available / all.length - 2) };
  }

  const room = available - OVERFLOW_WIDTH;
  const fit = Math.max(1, Math.floor(room / MIN_TAB_WIDTH));
  const visible = all.slice(0, fit);
  // Keep the selected tab visible
  if (state.selected && !visible.includes(state.selected)) visible[fit - 1] = state.selected;
  const hidden = all.filter((tab) => !visible.includes(tab));
  return { visible, hidden, tabWidth: Math.max(MIN_TAB_WIDTH, room / fit) - 2 };
}

function renderTabs() {
  const layout = tabLayout(el.tabstrip.clientWidth);
  el.tabs.replaceChildren(...layout.visible.map((tab) => tabElement(tab, layout.tabWidth)));

  el.overflowAnchor.hidden = layout.hidden.length === 0;
  el.overflowButton.textContent = `»${layout.hidden.length}`;
  el.overflowMenu.replaceChildren(...layout.hidden.map((tab) => {
    const item = document.createElement("button");
    item.className = "menu-item";
    item.setAttribute("role", "menuitem");
    item.title = tab.path;
    item.innerHTML = `<span class="icon">${DOC_ICON}</span><span class="label"></span>`;
    item.querySelector(".label").textContent = tab.name;
    item.addEventListener("click", () => select(tab));
    return item;
  }));
}

function tabElement(tab, width) {
  const item = document.createElement("div");
  item.className = "tab" + (tab === state.selected ? " selected" : "");
  item.style.width = `${width}px`;
  item.title = tab.path;
  item.tabIndex = 0;
  item.setAttribute("role", "tab");
  item.setAttribute("aria-selected", tab === state.selected);
  item.innerHTML = `${DOC_ICON}<span class="title"></span><button class="close" title="Close Tab (Ctrl+W)">${CLOSE_ICON}</button>`;
  // A dot marks unsaved changes, like in most editors
  item.querySelector(".title").textContent = (tab.isDirty ? "● " : "") + truncateMiddle(tab.name, width - (tab.isDirty ? 14 : 0));
  item.querySelector(".close").setAttribute("aria-label", `Close ${tab.name}`);
  item.querySelector(".close").addEventListener("click", (event) => {
    event.stopPropagation();
    close(tab);
  });
  item.addEventListener("click", () => select(tab));
  // Middle click closes, like in browsers
  item.addEventListener("auxclick", (event) => { if (event.button === 1) close(tab); });
  item.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") select(tab); });
  addTabDrag(item, tab);
  return item;
}

let draggedTab = null;

/** Drag a tab left or right to change the order; dropped on another tab, it takes that tab's place. */
function addTabDrag(item, tab) {
  item.draggable = true;
  item.addEventListener("dragstart", (event) => {
    draggedTab = tab;
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", tab.name);
  });
  item.addEventListener("dragend", () => {
    draggedTab = null;
  });
  item.addEventListener("dragover", (event) => {
    if (!draggedTab) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = "move";
    item.classList.toggle("drop-target", draggedTab !== tab);
  });
  item.addEventListener("dragleave", () => item.classList.remove("drop-target"));
  item.addEventListener("drop", (event) => {
    item.classList.remove("drop-target");
    if (!draggedTab) return;
    event.preventDefault();
    event.stopPropagation();
    const from = state.tabs.indexOf(draggedTab);
    const to = state.tabs.indexOf(tab);
    draggedTab = null;
    if (from < 0 || to < 0 || from === to) return;
    state.tabs.splice(to, 0, ...state.tabs.splice(from, 1));
    renderTabs();
  });
}

const measureContext = document.createElement("canvas").getContext("2d");

/** Shortens long names in the middle so the start and the end stay readable. */
function truncateMiddle(text, tabWidth) {
  measureContext.font = `600 13px ${getComputedStyle(document.body).fontFamily}`;
  const room = tabWidth - 52;
  if (measureContext.measureText(text).width <= room) return text;
  let keep = text.length;
  let result = text;
  while (keep > 2 && measureContext.measureText(result).width > room) {
    keep--;
    const head = Math.ceil(keep / 2);
    result = `${text.slice(0, head)}…${text.slice(text.length - (keep - head))}`;
  }
  return result;
}

function updateControls() {
  syncMenu();
  const tab = state.selected;
  if (!tab) return;
  if (document.activeElement !== el.pageField) el.pageField.value = tab.currentPage;
  el.pageCount.textContent = `/ ${tab.pageCount}`;
  el.prevPage.disabled = tab.currentPage <= 1;
  el.nextPage.disabled = tab.currentPage >= tab.pageCount;
  el.fitWidth.classList.toggle("active", tab.fitMode === "width");
  el.fitPage.classList.toggle("active", tab.fitMode === "page");
}

function updateExportProgress() {
  syncMenu();
  const progress = state.selected?.exportProgress;
  el.exportProgress.hidden = !progress;
  if (!progress) return;
  el.exportBar.max = Math.max(progress.total, 1);
  el.exportBar.value = progress.done;
  el.exportLabel.textContent = `${progress.label} ${progress.done} / ${progress.total}…`;
  el.exportCancel.hidden = !progress.cancellable;
  el.exportCancel.disabled = progress.cancelled;
}

function updateSearchCount() {
  const tab = state.selected;
  const { current, total } = tab?.matches ?? {};
  el.searchCount.textContent = tab?.searchText.trim() ? (total ? `${current}/${total}` : "0") : "";
}

// MARK: - Menus

let lastMenuState = "";

/** Tells the macOS menu bar what is enabled and checked for the selected tab. */
function syncMenu() {
  const tab = state.selected;
  const menuState = {
    hasTab: !!tab,
    tabCount: state.tabs.length,
    showThumbnails: state.showThumbnails,
    presenting: state.presenting,
    canEdit: tab?.canEdit ?? false,
    isDirty: tab?.isDirty ?? false,
    canUndo: (tab?.history.length ?? 0) > 0,
    currentPage: tab?.currentPage,
    pageCount: tab?.pageCount,
    fitMode: tab?.fitMode,
    layout: tab?.layout,
    fadeBetweenPages: state.fadeBetweenPages,
  };
  const json = JSON.stringify(menuState);
  if (json === lastMenuState) return;
  lastMenuState = json;
  window.host.setMenuState(menuState);
}

function toggleMenu(menu) {
  const open = menu.hidden;
  closeMenus();
  menu.hidden = !open;
  if (open) menu.querySelector(".menu-item")?.focus();
}

function closeMenus() {
  el.overflowMenu.hidden = true;
}

document.addEventListener("pointerdown", (event) => {
  if (!event.target.closest(".menu-anchor")) closeMenus();
});

/** Native menus for page editing; `run` maps item ids to actions. */
async function popup(items, x, y, run) {
  const id = await window.host.popupMenu(items, x, y);
  if (!id) return;
  run[id]?.();
  updateControls();
}

/** The "Document" button in the top bar. */
function showDocumentMenu() {
  const tab = state.selected;
  if (!tab) return;
  const n = tab.currentPage;
  const enabled = tab.canEdit;
  const rect = el.documentButton.getBoundingClientRect();
  popup([
    { id: "save", label: "Save", accelerator: "Ctrl+S", enabled: enabled && tab.isDirty },
    { id: "saveAs", label: "Save As…", accelerator: "Ctrl+Shift+S", enabled },
    { id: "undo", label: "Undo", accelerator: "Ctrl+Z", enabled: enabled && tab.history.length > 0 },
    { type: "separator" },
    // The layout only changes the view, so it stays available during an export
    { label: "Layout", enabled: false },
    ...Object.entries(LAYOUTS).map(([id, layout]) => ({ id, label: layout.title, type: "radio", checked: tab.layout === id })),
    { id: "fade", label: "Fade Between Pages", type: "checkbox", checked: state.fadeBetweenPages },
    { id: "rotateAllLeft", label: "Rotate Left", accelerator: "Ctrl+Shift+-", enabled },
    { id: "rotateAllRight", label: "Rotate Right", accelerator: "Ctrl+Shift+=", enabled },
    { type: "separator" },
    { id: "blank", label: `Insert Blank Page After Page ${n}`, enabled },
    { id: "insert", label: `Insert Pages from PDF After Page ${n}…`, accelerator: "Ctrl+Shift+I", enabled },
    { id: "merge", label: "Merge PDFs at End…", enabled },
    { id: "delete", label: `Delete Page ${n}`, accelerator: "Ctrl+Shift+D", enabled: enabled && tab.pageCount > 1 },
    { type: "separator" },
    { id: "rotateLeft", label: `Rotate Page ${n} Left`, enabled },
    { id: "rotateRight", label: `Rotate Page ${n} Right`, enabled },
    { type: "separator" },
    { id: "extract", label: "Extract Pages to New PDF…", enabled },
    { id: "split", label: "Split into Single Pages…", enabled },
    { id: "reduce", label: "Reduce File Size…", enabled },
    { id: "recognize", label: "Recognize Text", enabled },
    { type: "separator" },
    { id: "word", label: "Export to Word…", enabled },
    { id: "jpg", label: "Export as JPG…", accelerator: "Ctrl+E", enabled },
    { type: "separator" },
    { id: "print", label: "Print…", accelerator: "Ctrl+P", enabled },
  ], rect.left, rect.bottom + 4, {
    save: () => tab.save(),
    saveAs: () => tab.saveAs(),
    undo: () => tab.undo(),
    ...Object.fromEntries(Object.keys(LAYOUTS).map((id) => [id, () => tab.setLayout(id)])),
    fade: actions.toggleFadeBetweenPages,
    rotateAllLeft: () => tab.rotate(-90),
    rotateAllRight: () => tab.rotate(90),
    blank: () => tab.insertBlankPage(n),
    insert: () => tab.insertPDFs(n, "Choose the PDFs to insert"),
    merge: () => tab.insertPDFs(tab.pageCount, "Choose the PDFs to merge"),
    delete: () => tab.deletePage(n),
    rotateLeft: () => tab.rotatePage(n, -90),
    rotateRight: () => tab.rotatePage(n, 90),
    extract: () => tab.extractPagesPrompt(),
    split: () => tab.splitPages(),
    reduce: () => tab.reduceFileSize(),
    recognize: () => tab.recognizeText(),
    word: () => tab.exportWord(),
    jpg: () => tab.exportJPEG(),
    print: () => tab.print(),
  });
}

/** Right click on a thumbnail. */
function showPageMenu(tab, n, x, y) {
  const enabled = tab.canEdit;
  popup([
    { id: "rotateLeft", label: "Rotate Left", enabled },
    { id: "rotateRight", label: "Rotate Right", enabled },
    { type: "separator" },
    { id: "blank", label: "Insert Blank Page After This", enabled },
    { id: "insert", label: "Insert Pages from PDF After This…", enabled },
    { id: "extract", label: "Save This Page as PDF…", enabled },
    { type: "separator" },
    { id: "delete", label: "Delete Page", accelerator: "Delete", enabled: enabled && tab.pageCount > 1 },
  ], x, y, {
    rotateLeft: () => tab.rotatePage(n, -90),
    rotateRight: () => tab.rotatePage(n, 90),
    blank: () => tab.insertBlankPage(n),
    insert: () => tab.insertPDFs(n, "Choose the PDFs to insert"),
    extract: () => tab.extractPagesPrompt(`${n}`),
    delete: () => tab.deletePage(n),
  });
}

/** The "Updates" button; on macOS the same items are in the app menu. */
function showUpdatesMenu() {
  const rect = el.updatesButton.getBoundingClientRect();
  const updates = state.updates;
  popup([
    { id: "check", label: updates.checkingForUpdates ? "Checking for Updates…" : "Check for Updates…", enabled: !updates.checkingForUpdates },
    { type: "separator" },
    { id: "auto", label: "Check for Updates Automatically", type: "checkbox", checked: updates.checkForUpdates },
    { id: "install", label: "Install Updates Automatically", type: "checkbox", checked: updates.installUpdatesAutomatically, enabled: updates.checkForUpdates },
  ], rect.left, rect.bottom + 4, {
    check: actions.checkForUpdates,
    auto: actions.toggleCheckForUpdates,
    install: actions.toggleInstallUpdates,
  });
}

// MARK: - Full Screen Mode

function startPresentation() {
  const tab = state.selected;
  if (state.presenting || !tab) return;
  closeMenus();
  state.presenting = true;
  document.body.classList.add("presenting", "hide-cursor");
  tab.setPresenting(true);
  tab.container.focus({ preventScroll: true });
  window.host.setPresenting(true);
  syncMenu();
}

function endPresentation() {
  if (!state.presenting) return;
  state.presenting = false;
  document.body.classList.remove("presenting", "hide-cursor");
  state.selected?.setPresenting(false);
  window.host.setPresenting(false);
  updateControls();
}

/** Keys of Full Screen Mode, like a presentation; shortcuts with Ctrl still work. */
const presentationKeys = {
  "ArrowRight": "nextPage",
  "ArrowDown": "nextPage",
  "PageDown": "nextPage",
  "Enter": "nextPage",
  " ": "nextPage",
  "ArrowLeft": "previousPage",
  "ArrowUp": "previousPage",
  "PageUp": "previousPage",
  "Backspace": "previousPage",
  "Shift+ ": "previousPage",
  "Home": "firstPage",
  "End": "lastPage",
  "Escape": "fullScreen",
};

// A click goes to the next page and a right click to the previous one; links still work
el.documents.addEventListener("click", (event) => {
  if (!state.presenting || event.target.closest("a")) return;
  actions.nextPage();
  document.body.classList.add("hide-cursor");
});
el.documents.addEventListener("contextmenu", (event) => {
  if (!state.presenting) return;
  event.preventDefault();
  actions.previousPage();
  document.body.classList.add("hide-cursor");
});
// The pointer hides while presenting and comes back when the mouse moves
document.addEventListener("mousemove", (event) => {
  if (event.movementX || event.movementY) document.body.classList.remove("hide-cursor");
});

// MARK: - Actions

function withTab(action) {
  return () => {
    const tab = state.selected;
    if (!tab) return;
    action(tab);
    updateControls();
  };
}

const actions = {
  open: () => window.host.showOpenDialog(),
  closeTab: closeSelected,
  nextTab: () => selectOffset(1),
  previousTab: () => selectOffset(-1),
  previousPage: withTab((tab) => tab.previousPage()),
  nextPage: withTab((tab) => tab.nextPage()),
  firstPage: withTab((tab) => tab.goToPage(1)),
  lastPage: withTab((tab) => tab.goToPage(tab.pageCount)),
  goToPage: withTab(() => {
    if (state.presenting) return;
    el.pageField.focus();
    el.pageField.select();
  }),
  zoomIn: withTab((tab) => tab.zoomIn()),
  zoomOut: withTab((tab) => tab.zoomOut()),
  fitWidth: withTab((tab) => tab.fitWidth()),
  fitPage: withTab((tab) => tab.fitPage()),
  actualSize: withTab((tab) => tab.actualSize()),
  rotateLeft: withTab((tab) => tab.rotate(-90)),
  rotateRight: withTab((tab) => tab.rotate(90)),
  exportJPG: withTab((tab) => tab.exportJPEG()),
  save: withTab((tab) => tab.save()),
  saveAs: withTab((tab) => tab.saveAs()),
  undo: withTab((tab) => tab.undo()),
  fullScreen: () => (state.presenting ? endPresentation() : startPresentation()),
  focusSearch: withTab(() => {
    if (state.presenting) return;
    el.searchField.focus();
    el.searchField.select();
  }),
  findNext: withTab((tab) => tab.search(true, false)),
  findPrevious: withTab((tab) => tab.search(true, true)),
  toggleFadeBetweenPages: () => {
    state.fadeBetweenPages = !state.fadeBetweenPages;
    writeSetting("fadeBetweenPages", String(state.fadeBetweenPages));
    syncMenu();
  },
  toggleThumbnails: () => {
    if (!state.selected || state.presenting) return;
    state.showThumbnails = !state.showThumbnails;
    state.selected?.element.classList.toggle("no-thumbs", !state.showThumbnails);
    syncMenu();
  },
  // Also in the document menu of the top bar, for the current page
  insertBlankPage: withTab((tab) => tab.insertBlankPage(tab.currentPage)),
  insertPDFs: withTab((tab) => tab.insertPDFs(tab.currentPage, "Choose the PDFs to insert")),
  mergePDFs: withTab((tab) => tab.insertPDFs(tab.pageCount, "Choose the PDFs to merge")),
  deletePage: withTab((tab) => tab.deletePage(tab.currentPage)),
  rotatePageLeft: withTab((tab) => tab.rotatePage(tab.currentPage, -90)),
  rotatePageRight: withTab((tab) => tab.rotatePage(tab.currentPage, 90)),
  extractPages: withTab((tab) => tab.extractPagesPrompt()),
  splitPages: withTab((tab) => tab.splitPages()),
  reduceFileSize: withTab((tab) => tab.reduceFileSize()),
  recognizeText: withTab((tab) => tab.recognizeText()),
  exportWord: withTab((tab) => tab.exportWord()),
  print: withTab((tab) => tab.print()),
  checkForUpdates: () => window.host.checkForUpdates(),
  toggleCheckForUpdates: () => window.host.setUpdateSetting("checkForUpdates", !state.updates.checkForUpdates),
  toggleInstallUpdates: () => window.host.setUpdateSetting("installUpdatesAutomatically", !state.updates.installUpdatesAutomatically),
};

el.openButton.addEventListener("click", actions.open);
el.exportCancel.addEventListener("click", () => {
  const progress = state.selected?.exportProgress;
  if (progress?.cancellable) progress.cancelled = true;
  updateExportProgress();
});
el.addTab.addEventListener("click", actions.open);
el.toggleThumbs.addEventListener("click", actions.toggleThumbnails);
el.prevPage.addEventListener("click", actions.previousPage);
el.nextPage.addEventListener("click", actions.nextPage);
el.zoomIn.addEventListener("click", actions.zoomIn);
el.zoomOut.addEventListener("click", actions.zoomOut);
el.fitWidth.addEventListener("click", actions.fitWidth);
el.fitPage.addEventListener("click", actions.fitPage);
el.documentButton.addEventListener("click", showDocumentMenu);
el.fullscreen.addEventListener("click", actions.fullScreen);
el.updatesButton.addEventListener("click", showUpdatesMenu);
el.overflowButton.addEventListener("click", () => toggleMenu(el.overflowMenu));

el.pageField.addEventListener("keydown", (event) => {
  if (event.key !== "Enter") return;
  const tab = state.selected;
  const number = parseInt(el.pageField.value, 10);
  if (tab && Number.isFinite(number)) tab.goToPage(number);
  el.pageField.blur();
});
el.pageField.addEventListener("focus", () => el.pageField.select());
el.pageField.addEventListener("blur", updateControls);

el.searchField.addEventListener("input", () => {
  const tab = state.selected;
  if (!tab) return;
  tab.searchText = el.searchField.value;
  tab.search();
  updateSearchCount();
});
el.searchField.addEventListener("keydown", (event) => {
  if (event.key === "Enter") state.selected?.search(true, event.shiftKey);
  if (event.key === "Escape") state.selected?.container.focus();
});

// MARK: - Keyboard shortcuts

// The same as Adobe Acrobat Reader
const shortcuts = {
  "Ctrl+o": "open",
  "Ctrl+w": "closeTab",
  "Ctrl+F4": "closeTab",
  "Ctrl+Tab": "nextTab",
  "Ctrl+Shift+Tab": "previousTab",
  "Ctrl+F6": "nextTab",
  "Ctrl+Shift+F6": "previousTab",
  // Shift turns "]" into "}" and "[" into "{"
  "Ctrl+Shift+}": "nextTab",
  "Ctrl+Shift+{": "previousTab",
  "ArrowLeft": "previousPage",
  "ArrowRight": "nextPage",
  "ArrowUp": "previousPage",
  "ArrowDown": "nextPage",
  "Ctrl+PageUp": "previousPage",
  "Ctrl+PageDown": "nextPage",
  // Presentation remotes send Page Down / Page Up
  "PageUp": "previousPage",
  "PageDown": "nextPage",
  "Home": "firstPage",
  "End": "lastPage",
  "Ctrl+Shift+n": "goToPage",
  "Ctrl+=": "zoomIn",
  "Ctrl++": "zoomIn",
  "Ctrl+-": "zoomOut",
  "Ctrl+1": "actualSize",
  "Ctrl+0": "fitPage",
  "Ctrl+2": "fitWidth",
  // Shift turns "=" into "+" and "-" into "_"
  "Ctrl+Shift++": "rotateRight",
  "Ctrl+Shift+_": "rotateLeft",
  "Ctrl+Shift+-": "rotateLeft",
  "Ctrl+e": "exportJPG",
  "Ctrl+p": "print",
  "Ctrl+s": "save",
  "Ctrl+Shift+s": "saveAs",
  "Ctrl+z": "undo",
  "Ctrl+Shift+i": "insertPDFs",
  "Ctrl+Shift+d": "deletePage",
  "F4": "toggleThumbnails",
  "Ctrl+l": "fullScreen",
  "F11": "fullScreen",
  "Ctrl+f": "focusSearch",
  "Ctrl+g": "findNext",
  "Ctrl+Shift+g": "findPrevious",
  "F3": "findNext",
  "Shift+F3": "findPrevious",
};

// Text fields keep these keys for themselves
const fieldKeys = new Set(["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "Ctrl+z"]);

document.addEventListener("keydown", (event) => {
  if (el.promptDialog.open) return;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const combo = [event.ctrlKey && "Ctrl", event.shiftKey && "Shift", event.altKey && "Alt", key].filter(Boolean).join("+");
  const action = (state.presenting && presentationKeys[combo]) || shortcuts[combo];
  const inField = event.target instanceof HTMLInputElement;
  if (action && !(inField && fieldKeys.has(combo))) {
    event.preventDefault();
    closeMenus();
    actions[action]();
    if (state.presenting) document.body.classList.add("hide-cursor");
  } else if (event.key === "Escape") {
    closeMenus();
  }
});

// The macOS menu bar
window.host.onMenuAction((action) => {
  if (el.promptDialog.open) return;
  closeMenus();
  if (action.startsWith("layout:")) {
    withTab((tab) => tab.setLayout(action.slice("layout:".length)))();
  } else if (action === "undo" && document.activeElement instanceof HTMLInputElement) {
    // Text fields keep their own undo
    document.execCommand("undo");
  } else {
    actions[action]?.();
  }
});

// MARK: - Drag & drop

let dragDepth = 0;

// Only files dragged in from outside; thumbnails dragged to reorder pages are handled by the tab
const isFileDrag = (event) => event.dataTransfer.types.includes("Files");

document.addEventListener("dragenter", (event) => {
  event.preventDefault();
  if (isFileDrag(event) && ++dragDepth === 1) document.body.classList.add("dragging");
});
document.addEventListener("dragleave", (event) => {
  if (isFileDrag(event) && --dragDepth === 0) document.body.classList.remove("dragging");
});
document.addEventListener("dragover", (event) => event.preventDefault());
document.addEventListener("drop", (event) => {
  event.preventDefault();
  dragDepth = 0;
  document.body.classList.remove("dragging");
  const pdfs = [...event.dataTransfer.files].filter((file) => file.name.toLowerCase().endsWith(".pdf"));
  if (pdfs.length) window.host.openFiles(pdfs);
});

// MARK: - Window

window.host.onOpenFiles(openFiles);
window.host.onUpdateState((updates) => {
  state.updates = updates;
});
window.host.onUpdateProgress((fraction) => {
  el.updateProgress.hidden = fraction === null;
  el.updateBar.value = fraction ?? 0;
});
window.host.onFullScreen((value) => {
  document.body.classList.toggle("fullscreen", value);
  // Leaving full screen some other way also leaves Full Screen Mode
  if (!value) endPresentation();
});
document.body.classList.add(window.host.platform);
new ResizeObserver(renderTabs).observe(el.tabstrip);

render();
window.host.ready();
