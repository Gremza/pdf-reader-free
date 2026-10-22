// Finds newer releases on GitHub and installs them. The installer build runs the new setup silently
// after the app quits; the portable build swaps its own .exe. Other builds open the download page.
const { app, dialog, net, shell } = require("electron");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const RELEASES_PAGE = "https://github.com/Gremza/pdf-reader-free/releases/latest";
const LATEST_RELEASE = "https://api.github.com/repos/Gremza/pdf-reader-free/releases/latest";
const DAY = 24 * 60 * 60 * 1000;

const settingsFile = () => path.join(app.getPath("userData"), "settings.json");
const settings = { checkForUpdates: true, installUpdatesAutomatically: false };

let getWindow = () => null;
let onChange = () => {};
let busy = false;
// A downloaded update waiting for the app to quit: { version, file }
let pendingUpdate = null;
// Set by "Restart Now"; cleared again when the user cancels quitting
let restartAfterUpdate = false;

const portableExe = process.env.PORTABLE_EXECUTABLE_FILE;
const installerBuild = () => app.isPackaged && process.platform === "win32" && !portableExe
  && fs.existsSync(path.join(path.dirname(process.execPath), `Uninstall ${app.getName()}.exe`));
const canInstall = () => installerBuild() || (app.isPackaged && !!portableExe);

/** Starts the automatic checks; `window` returns the main window, `changed` refreshes the menus. */
function startUpdater(window, changed) {
  getWindow = window;
  onChange = changed;
  try {
    Object.assign(settings, JSON.parse(fs.readFileSync(settingsFile(), "utf8")));
  } catch {
    // First launch: keep the defaults
  }
  if (portableExe) fs.rm(`${portableExe}.old`, { force: true }, () => {});
  setTimeout(checkInBackground, 5000);
  setInterval(checkInBackground, DAY);
  app.on("will-quit", installPendingUpdate);
}

function updateState() {
  return { ...settings, checkingForUpdates: busy };
}

function setUpdateSetting(key, value) {
  if (!(key in settings)) return;
  settings[key] = !!value;
  fs.promises.writeFile(settingsFile(), JSON.stringify(settings, null, 2)).catch(() => {});
  onChange();
}

function setBusy(value) {
  busy = value;
  onChange();
}

function checkInBackground() {
  if (settings.checkForUpdates && !busy && !pendingUpdate) check(false);
}

/** "Check for Updates…": unlike the automatic check, it also reports "up to date" and errors. */
function checkForUpdates() {
  if (!busy) check(true);
}

async function check(manual) {
  setBusy(true);
  try {
    let release;
    try {
      release = await fetchLatestRelease();
    } catch (error) {
      if (manual) await message("Can't check for updates", error.message);
      return;
    }

    const current = app.getVersion();
    if (pendingUpdate && !isNewer(release.version, pendingUpdate.version)) {
      if (manual) await askToRestart(pendingUpdate.version);
      return;
    }
    if (!isNewer(release.version, current)) {
      if (manual) await message("PDF Reader is up to date", `Version ${current} is the newest version.`);
      return;
    }

    const asset = release.assets.find((item) => assetPattern().test(item.name));
    if (!canInstall() || !asset) {
      const choice = await message("A new version of PDF Reader is available",
        `PDF Reader ${release.version} is available. You have ${current}.`, ["Open Download Page", "Later"]);
      if (choice === 0) shell.openExternal(RELEASES_PAGE);
      return;
    }
    if (settings.installUpdatesAutomatically && !manual) {
      if (await download(release.version, asset)) await askToRestart(release.version);
    } else {
      const choice = await message("A new version of PDF Reader is available",
        `PDF Reader ${release.version} is available. You have ${current}. Would you like to install it now?`,
        ["Install and Restart", "Later"]);
      if (choice === 0 && await download(release.version, asset)) restart();
    }
  } finally {
    setBusy(false);
  }
}

async function fetchLatestRelease() {
  const response = await net.fetch(LATEST_RELEASE, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) throw new Error("GitHub sent an unexpected answer.");
  const json = await response.json();
  return { version: String(json.tag_name).replace(/^v/i, ""), assets: json.assets ?? [] };
}

function assetPattern() {
  const kind = portableExe ? "Portable" : "Setup";
  return new RegExp(`^PDF-Reader-${kind}-[\\d.]+-${process.arch}\\.exe$`);
}

/** Compares dotted versions number by number, so "1.10" is newer than "1.9" and "1.2" equals "1.2.0". */
function isNewer(version, other) {
  const a = version.split(".").map((part) => parseInt(part, 10) || 0);
  const b = other.split(".").map((part) => parseInt(part, 10) || 0);
  for (let index = 0; index < Math.max(a.length, b.length); index++) {
    const x = a[index] ?? 0;
    const y = b[index] ?? 0;
    if (x !== y) return x > y;
  }
  return false;
}

// MARK: Installing

/** Downloads the setup or portable .exe into the temp folder, with progress on the taskbar. */
async function download(version, asset) {
  const win = getWindow();
  const file = path.join(app.getPath("temp"), "PDF Reader Update", asset.name);
  try {
    await fs.promises.mkdir(path.dirname(file), { recursive: true });
    const response = await net.fetch(asset.browser_download_url);
    if (!response.ok) throw new Error(`The download failed (${response.status}).`);
    const total = Number(response.headers.get("content-length")) || asset.size || 0;
    const out = fs.createWriteStream(file);
    let done = 0;
    for await (const chunk of response.body) {
      done += chunk.length;
      if (!out.write(chunk)) await new Promise((resolve) => out.once("drain", resolve));
      if (total) {
        win?.setProgressBar(done / total);
        win?.webContents.send("update-progress", done / total);
      }
    }
    await new Promise((resolve, reject) => out.end((error) => (error ? reject(error) : resolve())));
    if (asset.size && done !== asset.size) throw new Error("The download is incomplete.");
    pendingUpdate = { version, file };
    return true;
  } catch (error) {
    fs.rm(file, { force: true }, () => {});
    const choice = await message("The update can't be installed", error.message, ["Open Download Page", "Cancel"], "warning");
    if (choice === 0) shell.openExternal(RELEASES_PAGE);
    return false;
  } finally {
    win?.setProgressBar(-1);
    win?.webContents.send("update-progress", null);
  }
}

/** Quits through the usual unsaved-changes check; the update is installed in "will-quit". */
function restart() {
  restartAfterUpdate = true;
  app.quit();
}

/** The window's close was cancelled, so the app keeps running. */
function quitCancelled() {
  restartAfterUpdate = false;
}

function installPendingUpdate() {
  if (!pendingUpdate) return;
  const { file } = pendingUpdate;
  pendingUpdate = null;
  try {
    if (portableExe) {
      // A running .exe can be renamed but not overwritten; the old one is removed on the next launch
      fs.renameSync(portableExe, `${portableExe}.old`);
      fs.copyFileSync(file, portableExe);
      fs.rmSync(file, { force: true });
      if (restartAfterUpdate) spawn(portableExe, [], { detached: true, stdio: "ignore" }).unref();
    } else {
      // The same switches electron-updater uses: silent, into the current install folder
      const args = ["--updated", "/S", ...(restartAfterUpdate ? ["--force-run"] : [])];
      spawn(file, args, { detached: true, stdio: "ignore" }).unref();
    }
  } catch {
    // The old version keeps working; the next check offers the update again
  }
}

function askToRestart(version) {
  return message(`PDF Reader ${version} is ready`, "The update will be used after you restart PDF Reader.", ["Restart Now", "Later"])
    .then((choice) => { if (choice === 0) restart(); });
}

async function message(text, detail, buttons = ["OK"], type = "info") {
  const options = { type, message: text, detail, buttons, defaultId: 0, cancelId: buttons.length - 1 };
  const win = getWindow();
  const { response } = win ? await dialog.showMessageBox(win, options) : await dialog.showMessageBox(options);
  return response;
}

module.exports = { startUpdater, updateState, setUpdateSetting, checkForUpdates, quitCancelled };
