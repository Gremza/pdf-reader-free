import * as pdfjsLib from "../node_modules/pdfjs-dist/build/pdf.mjs";

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

  destroy() {
    this.thumbnailObserver?.disconnect();
    this.viewer.setDocument(null);
    this.linkService.setDocument(null);
    this.pdf.destroy();
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

  rotate(degrees) {
    const page = this.currentPage;
    this.viewer.pagesRotation = (this.viewer.pagesRotation + degrees + 360) % 360;
    this.applyFit();
    this.viewer.currentPageNumber = page;
    this.resetThumbnails();
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

  // MARK: Thumbnails

  async buildThumbnails() {
    const first = await this.pdf.getPage(1);
    const viewport = first.getViewport({ scale: 1 });
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
      const canvas = document.createElement("canvas");
      setThumbnailSize(canvas, viewport.width, viewport.height);
      const label = document.createElement("span");
      label.textContent = n;
      button.append(canvas, label);
      button.addEventListener("click", () => this.goToPage(n));
      this.thumbnailObserver.observe(button);
      fragment.append(button);
    }
    this.thumbnails.append(fragment);
    this.updateCurrentThumbnail();
  }

  async renderThumbnail(button) {
    if (button.dataset.rendered) return;
    button.dataset.rendered = "1";
    try {
      const page = await this.pdf.getPage(Number(button.dataset.page));
      const rotation = (page.rotate + this.viewer.pagesRotation) % 360;
      const base = page.getViewport({ scale: 1, rotation });
      const scale = Math.min(110 / base.width, 140 / base.height) * window.devicePixelRatio;
      const viewport = page.getViewport({ scale, rotation });
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

  resetThumbnails() {
    for (const button of this.thumbnails.children) {
      delete button.dataset.rendered;
      this.thumbnailObserver.unobserve(button);
      this.thumbnailObserver.observe(button);
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

async function openFiles(files) {
  const failed = [];
  for (const file of files) {
    const existing = state.tabs.find((tab) => tab.path.toLowerCase() === file.path.toLowerCase());
    if (existing) {
      select(existing);
      continue;
    }
    try {
      const pdf = await pdfjsLib.getDocument({
        data: file.data,
        cMapUrl: PDFJS + "cmaps/",
        cMapPacked: true,
        standardFontDataUrl: PDFJS + "standard_fonts/",
        wasmUrl: PDFJS + "wasm/",
        iccUrl: PDFJS + "iccs/",
        isEvalSupported: false,
      }).promise;
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

function close(tab) {
  const index = state.tabs.indexOf(tab);
  if (index < 0) return;
  state.tabs.splice(index, 1);
  if (state.selected === tab) {
    state.selected = null;
    select(state.tabs[Math.min(index, state.tabs.length - 1)] ?? null);
  }
  tab.destroy();
  render();
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

// MARK: - Rendering

function render() {
  const tab = state.selected;
  el.emptyState.hidden = state.tabs.length > 0;
  el.toggleThumbs.disabled = !tab;
  el.controls.hidden = !tab;
  renderTabs();
  updateControls();
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
  item.querySelector(".title").textContent = truncateMiddle(tab.name, width);
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

function updateSearchCount() {
  const tab = state.selected;
  const { current, total } = tab?.matches ?? {};
  el.searchCount.textContent = tab?.searchText.trim() ? (total ? `${current}/${total}` : "0") : "";
}

// MARK: - Menus

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
  fullScreen: () => window.host.toggleFullScreen(),
  focusSearch: withTab(() => {
    el.searchField.focus();
    el.searchField.select();
  }),
  toggleThumbnails: () => {
    state.showThumbnails = !state.showThumbnails;
    state.selected?.element.classList.toggle("no-thumbs", !state.showThumbnails);
  },
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
  "F11": "fullScreen",
  "Ctrl+f": "focusSearch",
};

document.addEventListener("keydown", (event) => {
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const combo = [event.ctrlKey && "Ctrl", event.shiftKey && "Shift", event.altKey && "Alt", key].filter(Boolean).join("+");
  const action = shortcuts[combo];
  if (action) {
    event.preventDefault();
    closeMenus();
    actions[action]();
  } else if (event.key === "Escape") {
    if (!el.layoutMenu.hidden || !el.overflowMenu.hidden) closeMenus();
    else if (document.body.classList.contains("fullscreen")) actions.fullScreen();
  }
});

// MARK: - Drag & drop

let dragDepth = 0;

document.addEventListener("dragenter", (event) => {
  event.preventDefault();
  if (++dragDepth === 1) document.body.classList.add("dragging");
});
document.addEventListener("dragleave", () => {
  if (--dragDepth === 0) document.body.classList.remove("dragging");
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
