import * as pdfjsLib from "../node_modules/pdfjs-dist/build/pdf.mjs";
import { ProtectedPDFError, assertEditable, extractPages, pageEdits, parsePageRanges } from "./editing.js";
import { extractDocument, hasText } from "./word.js";

// pdf_viewer.mjs reads the core library from this global
globalThis.pdfjsLib = pdfjsLib;
const { EventBus, LinkTarget, PDFFindController, PDFLinkService, PDFViewer, ScrollMode, SpreadMode } =
  await import("../node_modules/pdfjs-dist/web/pdf_viewer.mjs");

const PDFJS = new URL("../node_modules/pdfjs-dist/", import.meta.url).href;
pdfjsLib.GlobalWorkerOptions.workerSrc = PDFJS + "build/pdf.worker.mjs";

const LAYOUTS = {
  single: { scroll: ScrollMode.PAGE, spread: SpreadMode.NONE, title: "Një faqe" },
  continuous: { scroll: ScrollMode.VERTICAL, spread: SpreadMode.NONE, title: "E vazhduar" },
  twoUp: { scroll: ScrollMode.PAGE, spread: SpreadMode.ODD, title: "Dy faqe" },
  twoUpContinuous: { scroll: ScrollMode.VERTICAL, spread: SpreadMode.ODD, title: "Dy faqe, e vazhduar" },
};

const LAYOUT_ICONS = {
  single: '<svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/></svg>',
  continuous: '<svg viewBox="0 0 24 24"><path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 12h6M9 16h6"/></svg>',
  twoUp: '<svg viewBox="0 0 24 24"><path d="M12 6c-2-1.5-5-2-9-2v15c4 0 7 .5 9 2 2-1.5 5-2 9-2V4c-4 0-7 .5-9 2zM12 6v15"/></svg>',
  twoUpContinuous: '<svg viewBox="0 0 24 24"><path d="M12 6c-2-1.5-5-2-9-2v15c4 0 7 .5 9 2 2-1.5 5-2 9-2V4c-4 0-7 .5-9 2zM12 6v15M5.5 9h4M5.5 12.5h4M14.5 9h4M14.5 12.5h4"/></svg>',
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
  actualSize: $("actual-size"),
  layoutButton: $("layout-button"),
  layoutMenu: $("layout-menu"),
  exportJPG: $("export-jpg"),
  exportProgress: $("export-progress"),
  exportBar: $("export-bar"),
  exportLabel: $("export-label"),
  documentButton: $("document-button"),
  promptDialog: $("prompt-dialog"),
  promptField: $("prompt-field"),
  fullscreen: $("fullscreen"),
  searchField: $("search-field"),
  searchCount: $("search-count"),
  documents: $("documents"),
  emptyState: $("empty-state"),
  openButton: $("open-button"),
};

/** All open PDFs of the window, shown as tabs in the top bar. */
const state = {
  tabs: [],
  selected: null,
  showThumbnails: true,
};

let nextID = 1;

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
    this.layout = "continuous";
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
  get isDirty() { return this.bytes !== this.savedBytes; }
  get baseName() { return this.name.replace(/\.pdf$/i, ""); }

  destroy() {
    this.thumbnailObserver?.disconnect();
    this.viewer.setDocument(null);
    this.linkService.setDocument(null);
    this.pdf.loadingTask.destroy();
    this.element.remove();
  }

  // MARK: Navigation

  goToPage(number) {
    this.viewer.currentPageNumber = Math.min(Math.max(number, 1), this.pageCount);
  }

  previousPage() { this.viewer.previousPage(); }
  nextPage() { this.viewer.nextPage(); }

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
    if (LAYOUTS[this.layout].spread === SpreadMode.NONE || !pageView) {
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
    const { scroll, spread } = LAYOUTS[this.layout];
    this.viewer.scrollMode = scroll;
    this.viewer.spreadMode = spread;
  }

  /** Rotates all pages; saved into the file like any other edit. */
  rotate(degrees) {
    this.applyEdit((bytes) => pageEdits.rotateAll(bytes, degrees));
  }

  // MARK: Editing

  get canEdit() { return !this.busy && !this.exportProgress; }

  /** Runs a page operation on the PDF bytes and shows the result; the previous bytes go on the undo stack. */
  async applyEdit(edit, pageAfter = this.currentPage) {
    if (!this.canEdit) return;
    this.busy = true;
    try {
      const bytes = await edit(this.bytes);
      this.history.push(this.bytes);
      if (this.history.length > UNDO_LIMIT) this.history.shift();
      await this.show(bytes, pageAfter);
    } catch (error) {
      showEditError(error);
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
      window.host.showError("Faqja nuk mund të fshihet", "PDF-ja duhet të ketë të paktën një faqe.");
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
      title: "Nxirr faqet",
      message: `Shkruaj faqet që do të ruhen në një PDF të ri, p.sh. 1-3, 5 (gjithsej ${this.pageCount} faqe).`,
      value: defaultValue,
      confirm: "Nxirr",
    });
    if (text === null) return;
    const indexes = parsePageRanges(text, this.pageCount);
    if (!indexes) {
      window.host.showError("Faqet nuk janë të sakta", `Shkruaj numra nga 1 deri në ${this.pageCount}, p.sh. 1-3, 5`);
      return;
    }
    try {
      const bytes = await extractPages(this.bytes, indexes);
      await window.host.saveAs(`${this.baseName} (faqet ${text.replace(/\s+/g, "")}).pdf`, bytes, "Ruaj faqet e nxjerra");
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
    await this.exportToFolder("Zgjidh ku të krijohet dosja me faqet PDF", "Duke ndarë", async (number) => ({
      name: `${number}.pdf`,
      data: await extractPages(this.bytes, [number - 1]),
    }));
  }

  /** Writes back to the file; returns false when it failed. */
  async save() {
    if (!this.isDirty) return true;
    const bytes = this.bytes;
    try {
      await window.host.saveFile(this.path, bytes);
    } catch (error) {
      window.host.showError("PDF-ja nuk mund të ruhet", errorMessage(error));
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
      path = await window.host.saveAs(this.name, bytes, "Ruaj si");
    } catch (error) {
      window.host.showError("PDF-ja nuk mund të ruhet", errorMessage(error));
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
    return this.exportToFolder("Zgjidh ku të krijohet dosja me imazhet JPG", "Duke eksportuar", async (number) => ({
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
    this.startProgress("Duke përgatitur Word");
    let document;
    try {
      document = await extractDocument(this.pdf, (n) => this.updateProgress(n));
    } catch (error) {
      this.endProgress();
      window.host.showError("Eksportimi në Word dështoi", errorMessage(error));
      return;
    }
    this.endProgress();
    if (!hasText(document)) {
      window.host.showError("Ky PDF nuk ka tekst", "Faqet janë ndoshta imazhe të skanuara, prandaj nuk ka tekst për ta kaluar në Word.");
      return;
    }
    try {
      await window.host.exportDocx(`${this.baseName}.docx`, document);
    } catch (error) {
      window.host.showError("Eksportimi në Word dështoi", errorMessage(error));
    }
  }

  startProgress(label) {
    this.exportProgress = { label, done: 0, total: this.pageCount };
    if (this === state.selected) updateExportProgress();
  }

  updateProgress(done) {
    this.exportProgress.done = done;
    if (this === state.selected) updateExportProgress();
  }

  endProgress() {
    this.exportProgress = null;
    if (this === state.selected) updateExportProgress();
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
      if (!blob) throw new Error(`Faqja ${pageNumber} nuk mund të ruhet`);
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
    this.thumbnailObserver = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) this.renderThumbnail(entry.target);
      }
    }, { root: this.thumbnails, rootMargin: "300px 0px" });

    const fragment = document.createDocumentFragment();
    for (let n = 1; n <= this.pageCount; n++) {
      const button = document.createElement("button");
      button.className = "thumb";
      button.dataset.page = n;
      button.title = `Faqja ${n}`;
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

function errorMessage(error) {
  return String(error?.message ?? error).replace(/^Error invoking remote method '[^']+': (Error: )?/, "");
}

function showEditError(error) {
  if (error instanceof ProtectedPDFError) {
    window.host.showError("Ky PDF është i mbrojtur", "PDF-të e mbrojtura me fjalëkalim ose me kufizime nuk mund të ndryshohen.");
  } else {
    window.host.showError("Ndryshimi dështoi", errorMessage(error));
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
  item.innerHTML = `${DOC_ICON}<span class="title"></span><button class="close" title="Mbyll tab-in (Ctrl+W)">${CLOSE_ICON}</button>`;
  // A dot marks unsaved changes, like in most editors
  item.querySelector(".title").textContent = (tab.isDirty ? "● " : "") + truncateMiddle(tab.name, width - (tab.isDirty ? 14 : 0));
  item.querySelector(".close").setAttribute("aria-label", `Mbyll ${tab.name}`);
  item.querySelector(".close").addEventListener("click", (event) => {
    event.stopPropagation();
    close(tab);
  });
  item.addEventListener("click", () => select(tab));
  // Middle click closes, like in browsers
  item.addEventListener("auxclick", (event) => { if (event.button === 1) close(tab); });
  item.addEventListener("keydown", (event) => { if (event.key === "Enter" || event.key === " ") select(tab); });
  return item;
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
  el.layoutButton.innerHTML = LAYOUT_ICONS[tab.layout];
  for (const item of el.layoutMenu.querySelectorAll("[data-layout]")) {
    item.setAttribute("aria-checked", item.dataset.layout === tab.layout);
  }
}

function updateExportProgress() {
  syncMenu();
  const progress = state.selected?.exportProgress;
  el.exportJPG.disabled = !!progress;
  el.exportProgress.hidden = !progress;
  if (!progress) return;
  el.exportBar.max = Math.max(progress.total, 1);
  el.exportBar.value = progress.done;
  el.exportLabel.textContent = `${progress.label} ${progress.done} / ${progress.total}…`;
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
    canEdit: tab?.canEdit ?? false,
    isDirty: tab?.isDirty ?? false,
    currentPage: tab?.currentPage,
    pageCount: tab?.pageCount,
    fitMode: tab?.fitMode,
    layout: tab?.layout,
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
  el.layoutMenu.hidden = true;
  el.overflowMenu.hidden = true;
}

document.addEventListener("pointerdown", (event) => {
  if (!event.target.closest(".menu-anchor")) closeMenus();
});

for (const item of el.layoutMenu.querySelectorAll("[data-icon]")) {
  item.innerHTML = LAYOUT_ICONS[item.dataset.icon];
}

/** Native menus for page editing; `run` maps item ids to actions. */
async function popup(items, x, y, run) {
  const id = await window.host.popupMenu(items, x, y);
  if (id) run[id]?.();
}

/** The "Dokumenti" button in the top bar. */
function showDocumentMenu() {
  const tab = state.selected;
  if (!tab) return;
  const n = tab.currentPage;
  const enabled = tab.canEdit;
  const rect = el.documentButton.getBoundingClientRect();
  popup([
    { id: "save", label: "Ruaj", accelerator: "Ctrl+S", enabled: enabled && tab.isDirty },
    { id: "saveAs", label: "Ruaj si…", accelerator: "Ctrl+Shift+S", enabled },
    { id: "undo", label: "Zhbëj", accelerator: "Ctrl+Z", enabled: enabled && tab.history.length > 0 },
    { type: "separator" },
    { id: "blank", label: `Shto faqe bosh pas faqes ${n}`, enabled },
    { id: "insert", label: `Shto faqe nga PDF pas faqes ${n}…`, enabled },
    { id: "merge", label: "Bashko PDF në fund…", enabled },
    { id: "delete", label: `Fshi faqen ${n}`, accelerator: "Delete", enabled: enabled && tab.pageCount > 1 },
    { type: "separator" },
    { id: "rotateLeft", label: `Rrotullo faqen ${n} majtas`, enabled },
    { id: "rotateRight", label: `Rrotullo faqen ${n} djathtas`, enabled },
    { type: "separator" },
    { id: "extract", label: "Nxirr faqet në PDF të ri…", enabled },
    { id: "split", label: "Ndaj në faqe të veçanta…", enabled },
    { type: "separator" },
    { id: "word", label: "Eksporto në Word…", enabled },
    { id: "jpg", label: "Eksporto si JPG…", accelerator: "Ctrl+E", enabled },
  ], rect.left, rect.bottom + 4, {
    save: () => tab.save(),
    saveAs: () => tab.saveAs(),
    undo: () => tab.undo(),
    blank: () => tab.insertBlankPage(n),
    insert: () => tab.insertPDFs(n, "Zgjidh PDF-të që do të shtohen"),
    merge: () => tab.insertPDFs(tab.pageCount, "Zgjidh PDF-të që do të bashkohen"),
    delete: () => tab.deletePage(n),
    rotateLeft: () => tab.rotatePage(n, -90),
    rotateRight: () => tab.rotatePage(n, 90),
    extract: () => tab.extractPagesPrompt(),
    split: () => tab.splitPages(),
    word: () => tab.exportWord(),
    jpg: () => tab.exportJPEG(),
  });
}

/** Right click on a thumbnail. */
function showPageMenu(tab, n, x, y) {
  const enabled = tab.canEdit;
  popup([
    { id: "rotateLeft", label: "Rrotullo majtas", enabled },
    { id: "rotateRight", label: "Rrotullo djathtas", enabled },
    { type: "separator" },
    { id: "blank", label: "Shto faqe bosh pas kësaj", enabled },
    { id: "insert", label: "Shto faqe nga PDF pas kësaj…", enabled },
    { id: "extract", label: "Ruaj këtë faqe si PDF…", enabled },
    { type: "separator" },
    { id: "delete", label: "Fshi faqen", accelerator: "Delete", enabled: enabled && tab.pageCount > 1 },
  ], x, y, {
    rotateLeft: () => tab.rotatePage(n, -90),
    rotateRight: () => tab.rotatePage(n, 90),
    blank: () => tab.insertBlankPage(n),
    insert: () => tab.insertPDFs(n, "Zgjidh PDF-të që do të shtohen"),
    extract: () => tab.extractPagesPrompt(`${n}`),
    delete: () => tab.deletePage(n),
  });
}

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
  fullScreen: () => window.host.toggleFullScreen(),
  focusSearch: withTab(() => {
    el.searchField.focus();
    el.searchField.select();
  }),
  toggleThumbnails: () => {
    state.showThumbnails = !state.showThumbnails;
    state.selected?.element.classList.toggle("no-thumbs", !state.showThumbnails);
    syncMenu();
  },
  // Also in the document menu of the top bar, for the current page
  insertBlankPage: withTab((tab) => tab.insertBlankPage(tab.currentPage)),
  insertPDFs: withTab((tab) => tab.insertPDFs(tab.currentPage, "Zgjidh PDF-të që do të shtohen")),
  mergePDFs: withTab((tab) => tab.insertPDFs(tab.pageCount, "Zgjidh PDF-të që do të bashkohen")),
  deletePage: withTab((tab) => tab.deletePage(tab.currentPage)),
  rotatePageLeft: withTab((tab) => tab.rotatePage(tab.currentPage, -90)),
  rotatePageRight: withTab((tab) => tab.rotatePage(tab.currentPage, 90)),
  extractPages: withTab((tab) => tab.extractPagesPrompt()),
  splitPages: withTab((tab) => tab.splitPages()),
  exportWord: withTab((tab) => tab.exportWord()),
};

el.openButton.addEventListener("click", actions.open);
el.addTab.addEventListener("click", actions.open);
el.toggleThumbs.addEventListener("click", actions.toggleThumbnails);
el.prevPage.addEventListener("click", actions.previousPage);
el.nextPage.addEventListener("click", actions.nextPage);
el.zoomIn.addEventListener("click", actions.zoomIn);
el.zoomOut.addEventListener("click", actions.zoomOut);
el.fitWidth.addEventListener("click", actions.fitWidth);
el.fitPage.addEventListener("click", actions.fitPage);
el.actualSize.addEventListener("click", actions.actualSize);
el.exportJPG.addEventListener("click", actions.exportJPG);
el.documentButton.addEventListener("click", showDocumentMenu);
el.fullscreen.addEventListener("click", actions.fullScreen);
el.layoutButton.addEventListener("click", () => toggleMenu(el.layoutMenu));
el.overflowButton.addEventListener("click", () => toggleMenu(el.overflowMenu));

el.layoutMenu.addEventListener("click", (event) => {
  const item = event.target.closest(".menu-item");
  const tab = state.selected;
  if (!item || !tab) return;
  if (item.dataset.layout) tab.setLayout(item.dataset.layout);
  if (item.dataset.rotate) tab.rotate(Number(item.dataset.rotate));
  closeMenus();
  updateControls();
});

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

const shortcuts = {
  "Ctrl+o": "open",
  "Ctrl+w": "closeTab",
  "Ctrl+F4": "closeTab",
  "Ctrl+Tab": "nextTab",
  "Ctrl+Shift+Tab": "previousTab",
  "Ctrl+PageDown": "nextTab",
  "Ctrl+PageUp": "previousTab",
  "Ctrl+Shift+]": "nextTab",
  "Ctrl+Shift+[": "previousTab",
  "Ctrl+ArrowUp": "previousPage",
  "Ctrl+ArrowDown": "nextPage",
  "Ctrl+=": "zoomIn",
  "Ctrl++": "zoomIn",
  "Ctrl+Shift++": "zoomIn",
  "Ctrl+-": "zoomOut",
  "Ctrl+1": "fitWidth",
  "Ctrl+2": "fitPage",
  "Ctrl+0": "actualSize",
  "Ctrl+l": "rotateLeft",
  "Ctrl+r": "rotateRight",
  "Ctrl+e": "exportJPG",
  "Ctrl+s": "save",
  "Ctrl+Shift+s": "saveAs",
  "Ctrl+z": "undo",
  "F11": "fullScreen",
  "Ctrl+f": "focusSearch",
};

document.addEventListener("keydown", (event) => {
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const combo = [event.ctrlKey && "Ctrl", event.shiftKey && "Shift", event.altKey && "Alt", key].filter(Boolean).join("+");
  const action = shortcuts[combo];
  // Text fields keep their own undo
  const inField = event.target instanceof HTMLInputElement;
  if (action && !(inField && action === "undo") && !el.promptDialog.open) {
    event.preventDefault();
    closeMenus();
    actions[action]();
  } else if (event.key === "Escape") {
    if (!el.layoutMenu.hidden || !el.overflowMenu.hidden) closeMenus();
    else if (document.body.classList.contains("fullscreen")) actions.fullScreen();
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
window.host.onFullScreen((value) => {
  document.body.classList.toggle("fullscreen", value);
  el.fullscreen.title = value ? "Dil nga ekrani i plotë (F11)" : "Ekran i plotë (F11)";
});
document.body.classList.add(window.host.platform);
new ResizeObserver(renderTabs).observe(el.tabstrip);

render();
window.host.ready();
