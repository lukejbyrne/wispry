const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("wispry", {
  toggleDictation: () => ipcRenderer.invoke("dictation-toggle"),
  recordingComplete: (buffer, mimeType) => ipcRenderer.invoke("recording-complete", { buffer, mimeType }),
  recordingError: (message) => ipcRenderer.invoke("recording-error", message),
  getHomeState: () => ipcRenderer.invoke("home-get-state"),
  saveSettings: (patch) => ipcRenderer.invoke("home-save-settings", patch),
  saveLicense: (key) => ipcRenderer.invoke("home-save-license", key),
  saveOpenAIAPIKey: (key) => ipcRenderer.invoke("home-save-openai-key", key),
  transcribeFile: () => ipcRenderer.invoke("home-transcribe-file"),
  openRuntime: () => ipcRenderer.invoke("home-open-runtime"),
  clearHistory: () => ipcRenderer.invoke("home-clear-history"),
  copyText: (text) => ipcRenderer.invoke("home-copy-text", text),
  sendFeedback: () => ipcRenderer.invoke("home-send-feedback"),
  onDictationState: (callback) => {
    ipcRenderer.on("dictation-state", (event, state) => callback(state));
  },
  onRecordingStart: (callback) => {
    ipcRenderer.on("recording-start", (event, options) => callback(options));
  },
  onRecordingStop: (callback) => {
    ipcRenderer.on("recording-stop", () => callback());
  },
  onHomeState: (callback) => {
    ipcRenderer.on("home-state", (event, state) => callback(state));
  }
});
