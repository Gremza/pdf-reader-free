const { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, net, protocol, shell } = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");

const ROOT = path.join(__dirname, "..");
const BAR_HEIGHT = 40;

// The UI is served from app://app/ so ES modules and the pdf.js worker load like on the web
protocol.registerSchemesAsPrivileged([
  { scheme: "app", privileges: { standard: true, secure: true, supportFetchAPI: true } },
]);

let win = null;
let rendererReady = false;
let pending = [];

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
    if (process.platform !== "darwin") Menu.setApplicationMenu(null);
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

ipcMain.on("open-paths", (_event, paths) => openPaths(paths));
ipcMain.on("open-failed", (_event, names) => showOpenError(names));
ipcMain.on("close-window", () => win?.close());
ipcMain.on("toggle-fullscreen", () => win?.setFullScreen(!win.isFullScreen()));
