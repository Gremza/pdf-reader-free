const { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, net, protocol, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { buildDocx } = require("./docx");

const ROOT = path.join(__dirname, "..");
const BAR_HEIGHT = 40;

// The UI is served from app://app/ so ES modules and the pdf.js worker load like on the web
protocol.registerSchemesAsPrivileged([
  { scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

// "npm start" would otherwise call the app "Electron" in menus and dialogs
app.setName("PDF Reader");

let win = null;
let rendererReady = false;
let pending = [];
// Number of tabs with unsaved changes, reported by the renderer
let dirtyCount = 0;
// The renderer may only overwrite files the user opened or picked in a save dialog
const writablePaths = new Set();

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  pending = pdfArgs(process.argv);

  // "Open with" while already running: open in the existing window
  app.on("second-instance", (_event, argv) => {
    openPaths(pdfArgs(argv));
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
    }
  });

  app.on("open-file", (event, file) => {
    event.preventDefault();
    openPaths([file]);
  });

  app.whenReady().then(() => {
    protocol.handle("app", serveAppFile);
    if (process.platform === "darwin") updateAppMenu();
    else Menu.setApplicationMenu(null);
    createWindow();
  });

  app.on("window-all-closed", () => app.quit());
}

function pdfArgs(argv) {
  return argv.slice(1).filter((arg) => !arg.startsWith("-") && arg.toLowerCase().endsWith(".pdf"));
}

async function serveAppFile(request) {
  const { pathname } = new URL(request.url);
  const file = path.normalize(path.join(ROOT, decodeURIComponent(pathname)));
  if (!file.startsWith(ROOT + path.sep)) return new Response("Not found", { status: 404 });
  return net.fetch(pathToFileURL(file).toString());
}

function overlayColors() {
  return nativeTheme.shouldUseDarkColors
    ? { color: "#202020", symbolColor: "#e8e8e8" }
    : { color: "#f3f3f3", symbolColor: "#1f1f1f" };
}

function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 820,
    minWidth: 860,
    minHeight: 500,
    title: "PDF Reader",
    backgroundColor: overlayColors().color,
    icon: path.join(__dirname, "icon.png"),
    titleBarStyle: "hidden",
    titleBarOverlay: { ...overlayColors(), height: BAR_HEIGHT },
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      sandbox: true,
    },
  });

  win.loadURL("app://app/src/index.html");
  win.once("ready-to-show", () => win.show());
  win.webContents.setVisualZoomLevelLimits(1, 1);

  // Read-only viewer: never navigate away; PDF links open in the default browser
  win.webContents.on("will-navigate", (event) => event.preventDefault());
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^(https?|mailto):/i.test(url)) shell.openExternal(url);
    return { action: "deny" };
  });

  win.on("enter-full-screen", () => win.webContents.send("fullscreen", true));
  win.on("leave-full-screen", () => win.webContents.send("fullscreen", false));
  win.on("close", (event) => {
    if (dirtyCount === 0) return;
    const choice = dialog.showMessageBoxSync(win, {
      type: "warning",
      message: dirtyCount === 1 ? "Një dokument ka ndryshime të paruajtura" : `${dirtyCount} dokumente kanë ndryshime të paruajtura`,
      detail: "Nëse mbyll tani, ndryshimet humbasin.",
      buttons: ["Mbyll pa ruajtur", "Anulo"],
      defaultId: 1,
      cancelId: 1,
    });
    if (choice !== 0) event.preventDefault();
  });
  win.on("closed", () => {
    win = null;
    rendererReady = false;
  });

  nativeTheme.on("updated", () => {
    if (win && process.platform !== "darwin") win.setTitleBarOverlay(overlayColors());
  });
}

/// Reads the files and hands them to the renderer; unreadable ones are reported together.
async function openPaths(paths) {
  if (!paths.length) return;
  if (!win || !rendererReady) {
    pending.push(...paths);
    return;
  }
  const files = [];
  const failed = [];
  for (const file of paths) {
    try {
      const data = await fs.readFile(file);
      files.push({ path: path.resolve(file), name: path.basename(file), data: new Uint8Array(data) });
      writablePaths.add(path.resolve(file));
      app.addRecentDocument(file);
    } catch {
      failed.push(path.basename(file));
    }
  }
  if (files.length) win.webContents.send("open-files", files);
  if (failed.length) showOpenError(failed);
}

function showOpenError(names) {
  dialog.showMessageBox(win, {
    type: "warning",
    message: "Skedari nuk mund të hapet",
    detail: names.join("\n"),
  });
}

ipcMain.on("ready", () => {
  rendererReady = true;
  const paths = pending;
  pending = [];
  openPaths(paths);
});

ipcMain.on("show-open-dialog", async () => {
  const result = await dialog.showOpenDialog(win, {
    filters: [{ name: "PDF", extensions: ["pdf"] }],
    properties: ["openFile", "multiSelections"],
  });
  if (!result.canceled) openPaths(result.filePaths);
});

// MARK: Export to a folder (JPG images, split pages)

// The renderer may only write into folders the user picked for an export
const exportFolders = new Set();

ipcMain.handle("choose-export-folder", async (_event, pdfName, title) => {
  const result = await dialog.showOpenDialog(win, {
    title,
    buttonLabel: "Eksporto",
    properties: ["openDirectory", "createDirectory"],
  });
  if (result.canceled) return null;

  // Creates "name", or "name 2", "name 3", … when that folder already exists
  const parent = result.filePaths[0];
  const name = path.parse(pdfName).name.replace(/[<>:"/\\|?*]/g, "_") || "PDF";
  for (let number = 1; ; number++) {
    const folder = path.join(parent, number === 1 ? name : `${name} ${number}`);
    try {
      await fs.mkdir(folder);
      exportFolders.add(folder);
      return folder;
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
  }
});

ipcMain.handle("write-export-file", async (_event, folder, fileName, data) => {
  if (!exportFolders.has(folder) || !/^[1-9]\d*\.(jpg|pdf)$/.test(fileName)) throw new Error("Invalid export");
  await fs.writeFile(path.join(folder, fileName), data);
});

ipcMain.on("export-finished", (_event, folder, error) => {
  if (!exportFolders.delete(folder)) return;
  if (error) {
    dialog.showMessageBox(win, { type: "warning", message: "Eksportimi dështoi", detail: error });
  } else {
    shell.openPath(folder);
  }
});

// MARK: Editing

/** Writes next to the target first, so a failed save never leaves a half-written PDF. */
async function writeFileSafely(file, data) {
  const temporary = `${file}.${process.pid}.tmp`;
  try {
    await fs.writeFile(temporary, data);
    await fs.rename(temporary, file);
  } catch (error) {
    await fs.rm(temporary, { force: true });
    throw error;
  }
}

function saveFilters(kind) {
  return kind === "docx" ? [{ name: "Dokument Word", extensions: ["docx"] }] : [{ name: "PDF", extensions: ["pdf"] }];
}

async function askSavePath(defaultName, kind, title) {
  const result = await dialog.showSaveDialog(win, { title, defaultPath: defaultName, filters: saveFilters(kind) });
  return result.canceled ? null : result.filePath;
}

ipcMain.handle("save-file", async (_event, file, data) => {
  if (!writablePaths.has(file)) throw new Error("Invalid save");
  await writeFileSafely(file, data);
});

/** Returns the chosen path, or null when cancelled. */
ipcMain.handle("save-as", async (_event, defaultName, data, title) => {
  const file = await askSavePath(defaultName, "pdf", title);
  if (!file) return null;
  await writeFileSafely(file, data);
  writablePaths.add(file);
  app.addRecentDocument(file);
  return file;
});

ipcMain.handle("export-docx", async (_event, defaultName, document) => {
  const file = await askSavePath(defaultName, "docx", "Eksporto në Word");
  if (!file) return null;
  await writeFileSafely(file, buildDocx(document));
  shell.openPath(file);
  return file;
});

/** PDFs to insert into the current document. */
ipcMain.handle("pick-pdfs", async (_event, title) => {
  const result = await dialog.showOpenDialog(win, {
    title,
    filters: [{ name: "PDF", extensions: ["pdf"] }],
    properties: ["openFile", "multiSelections"],
  });
  if (result.canceled) return [];
  return Promise.all(result.filePaths.map(async (file) => ({ name: path.basename(file), data: new Uint8Array(await fs.readFile(file)) })));
});

/** 0 = save, 1 = don't save, 2 = cancel */
ipcMain.handle("confirm-close-tab", async (_event, name) => {
  const { response } = await dialog.showMessageBox(win, {
    type: "warning",
    message: `Të ruhen ndryshimet në "${name}"?`,
    detail: "Nëse nuk i ruan, ndryshimet humbasin.",
    buttons: ["Ruaj", "Mos ruaj", "Anulo"],
    defaultId: 0,
    cancelId: 2,
  });
  return response;
});

ipcMain.on("show-error", (_event, message, detail) => {
  dialog.showMessageBox(win, { type: "warning", message, detail });
});

ipcMain.on("set-dirty-count", (_event, count) => {
  dirtyCount = count;
});

/** Shows a native menu at (x, y) and resolves with the id of the chosen item, or null. */
ipcMain.handle("popup-menu", (_event, items, x, y) => new Promise((resolve) => {
  const build = (item) => item.type === "separator"
    ? { type: "separator" }
    : {
        label: item.label,
        enabled: item.enabled !== false,
        accelerator: item.accelerator,
        registerAccelerator: false,
        click: () => resolve(item.id),
      };
  Menu.buildFromTemplate(items.map(build)).popup({
    window: win,
    x: Math.round(x),
    y: Math.round(y),
    // A click is delivered right after the menu closes
    callback: () => setTimeout(() => resolve(null), 100),
  });
}));

// MARK: macOS menu bar

const LAYOUTS = [
  ["single", "Një faqe"],
  ["continuous", "E vazhduar"],
  ["twoUp", "Dy faqe"],
  ["twoUpContinuous", "Dy faqe, e vazhduar"],
];

// What the selected tab allows right now, reported by the renderer
let menuState = {};

/** The same actions as the top bar buttons; each item runs an action of the renderer. */
function updateAppMenu() {
  const s = menuState;
  const doc = !!s.hasTab;
  const edit = doc && s.canEdit;
  const page = s.currentPage ?? 1;
  const run = (action) => () => win?.webContents.send("menu-action", action);
  const item = (label, action, options = {}) => ({ label, click: run(action), ...options });
  const separator = { type: "separator" };

  const template = [
    { role: "appMenu" },
    {
      label: "File",
      submenu: [
        item("Hap…", "open", { accelerator: "CmdOrCtrl+O" }),
        { role: "recentDocuments", submenu: [{ role: "clearRecentDocuments" }] },
        item("Mbyll tab-in", "closeTab", { accelerator: "CmdOrCtrl+W" }),
        separator,
        item("Ruaj", "save", { accelerator: "CmdOrCtrl+S", enabled: edit && s.isDirty }),
        item("Ruaj si…", "saveAs", { accelerator: "CmdOrCtrl+Shift+S", enabled: edit }),
        separator,
        item("Nxirr faqet në PDF të ri…", "extractPages", { enabled: edit }),
        item("Ndaj në faqe të veçanta…", "splitPages", { enabled: edit }),
        separator,
        item("Eksporto në Word…", "exportWord", { enabled: edit }),
        item("Eksporto si JPG…", "exportJPG", { accelerator: "CmdOrCtrl+E", enabled: edit }),
      ],
    },
    {
      label: "Edit",
      submenu: [
        item("Zhbëj", "undo", { accelerator: "CmdOrCtrl+Z" }),
        separator,
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" },
        separator,
        item("Kërko", "focusSearch", { accelerator: "CmdOrCtrl+F", enabled: doc }),
      ],
    },
    {
      label: "View",
      submenu: [
        item("Miniaturat", "toggleThumbnails", { type: "checkbox", checked: !!s.showThumbnails, accelerator: "Ctrl+Cmd+S", enabled: doc }),
        separator,
        item("Zmadho", "zoomIn", { accelerator: "CmdOrCtrl+Plus", enabled: doc }),
        item("Zvogëlo", "zoomOut", { accelerator: "CmdOrCtrl+-", enabled: doc }),
        item("Madhësia reale", "actualSize", { accelerator: "CmdOrCtrl+0", enabled: doc }),
        separator,
        item("Gjerësia e plotë", "fitWidth", { type: "checkbox", checked: s.fitMode === "width", accelerator: "CmdOrCtrl+1", enabled: doc }),
        item("Faqja e plotë", "fitPage", { type: "checkbox", checked: s.fitMode === "page", accelerator: "CmdOrCtrl+2", enabled: doc }),
        separator,
        ...LAYOUTS.map(([layout, label]) =>
          item(label, `layout:${layout}`, { type: "radio", checked: s.layout === layout, enabled: doc })),
        separator,
        item("Rrotullo majtas", "rotateLeft", { accelerator: "CmdOrCtrl+L", enabled: doc }),
        item("Rrotullo djathtas", "rotateRight", { accelerator: "CmdOrCtrl+R", enabled: doc }),
        separator,
        item("Faqja e mëparshme", "previousPage", { accelerator: "CmdOrCtrl+Up", enabled: doc && page > 1 }),
        item("Faqja tjetër", "nextPage", { accelerator: "CmdOrCtrl+Down", enabled: doc && page < s.pageCount }),
        separator,
        { role: "togglefullscreen" },
      ],
    },
    {
      label: "Faqet",
      submenu: [
        item(`Shto faqe bosh pas faqes ${page}`, "insertBlankPage", { enabled: edit }),
        item(`Shto faqe nga PDF pas faqes ${page}…`, "insertPDFs", { enabled: edit }),
        item("Bashko PDF në fund…", "mergePDFs", { enabled: edit }),
        separator,
        item(`Rrotullo faqen ${page} majtas`, "rotatePageLeft", { enabled: edit }),
        item(`Rrotullo faqen ${page} djathtas`, "rotatePageRight", { enabled: edit }),
        separator,
        item(`Fshi faqen ${page}`, "deletePage", { enabled: edit && s.pageCount > 1 }),
      ],
    },
    {
      role: "windowMenu",
      submenu: [
        { role: "minimize" },
        { role: "zoom" },
        separator,
        item("Tab-i tjetër", "nextTab", { accelerator: "CmdOrCtrl+Shift+]", enabled: s.tabCount > 1 }),
        item("Tab-i i mëparshëm", "previousTab", { accelerator: "CmdOrCtrl+Shift+[", enabled: s.tabCount > 1 }),
        separator,
        { role: "front" },
      ],
    },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

ipcMain.on("menu-state", (_event, state) => {
  menuState = state;
  if (process.platform === "darwin") updateAppMenu();
});

ipcMain.on("open-paths", (_event, paths) => openPaths(paths));
ipcMain.on("open-failed", (_event, names) => showOpenError(names));
ipcMain.on("close-window", () => win?.close());
ipcMain.on("toggle-fullscreen", () => win?.setFullScreen(!win.isFullScreen()));
