const { contextBridge, ipcRenderer, webUtils } = require("electron");

contextBridge.exposeInMainWorld("host", {
  platform: process.platform,
  ready: () => ipcRenderer.send("ready"),
  showOpenDialog: () => ipcRenderer.send("show-open-dialog"),
  openFiles: (files) => ipcRenderer.send("open-paths", files.map((file) => webUtils.getPathForFile(file))),
  reportFailed: (names) => ipcRenderer.send("open-failed", names),
  closeWindow: () => ipcRenderer.send("close-window"),
  toggleFullScreen: () => ipcRenderer.send("toggle-fullscreen"),
  onOpenFiles: (callback) => ipcRenderer.on("open-files", (_event, files) => callback(files)),
  onFullScreen: (callback) => ipcRenderer.on("fullscreen", (_event, value) => callback(value)),
});
