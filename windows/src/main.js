const { app, BrowserWindow, Tray, Menu, clipboard, dialog, globalShortcut, ipcMain, nativeImage, safeStorage, shell } = require("electron");
const childProcess = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { displayPlan, isValid, payloadFor } = require("./license");
const { SettingsStore } = require("./settings");
const { TransformStyle, processText } = require("./text-pipeline");

const APP_NAME = "i don't type";
const SpeechModel = Object.freeze({
  localWhisper: "localWhisper",
  openaiCloud: "openaiCloud"
});
const OpenAICloudMode = Object.freeze({
  service: "service",
  apiKey: "apiKey"
});
const CLOUD_TRANSCRIBE_URL = process.env.IDONTTYPE_CLOUD_TRANSCRIBE_URL || "https://idonttype.com/.netlify/functions/cloud-transcribe";

let settings;
let tray;
let bubbleWindow;
let homeWindow;
let runtimeStatus = null;
let dictationState = {
  mode: "idle",
  message: "Ready.",
  partial: "",
  lastText: ""
};

app.setName(APP_NAME);
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");

const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
}

app.on("second-instance", () => {
  showHome();
});

app.whenReady().then(() => {
  settings = new SettingsStore(app.getPath("userData"));
  runtimeStatus = inspectRuntime();
  createTray();
  createBubble();
  if (!settings.all().bubbleVisible) {
    bubbleWindow.hide();
  }
  registerShortcut(settings.all().shortcut);
  broadcastState();
});

app.on("window-all-closed", () => {
  // Keep the tray app alive after the Home window closes.
});

app.on("will-quit", () => {
  globalShortcut.unregisterAll();
});

function createTray() {
  tray = new Tray(createTrayImage());
  tray.setToolTip(APP_NAME);
  updateTrayMenu();
}

function updateTrayMenu() {
  if (!tray) {
    return;
  }
  const licensePayload = payloadFor(settings?.all().licenseKey);
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: APP_NAME, enabled: false },
    { label: licensePayload ? `License: ${displayPlan(licensePayload)}` : "Activate License...", click: showHome },
    { type: "separator" },
    { label: dictationState.mode === "listening" ? "Stop and Paste" : "Start Dictation", click: toggleDictation },
    { label: "Home", click: showHome },
    { label: "Send Feedback...", click: openFeedbackEmail },
    {
      label: settings?.all().bubbleVisible === false ? "Show Bubble" : "Hide Bubble",
      click: () => {
        const visible = settings.all().bubbleVisible === false;
        settings.update({ bubbleVisible: visible });
        visible ? bubbleWindow.showInactive() : bubbleWindow.hide();
        updateTrayMenu();
      }
    },
    { type: "separator" },
    { label: "Quit", click: () => app.exit(0) }
  ]));
}

function createBubble() {
  bubbleWindow = new BrowserWindow({
    width: 64,
    height: 64,
    frame: false,
    resizable: false,
    transparent: true,
    alwaysOnTop: true,
    skipTaskbar: true,
    focusable: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });

  bubbleWindow.setAlwaysOnTop(true, "screen-saver");
  bubbleWindow.loadFile(path.join(__dirname, "bubble.html"));
  bubbleWindow.once("ready-to-show", () => {
    positionBubble();
    bubbleWindow.showInactive();
  });
}

function showHome() {
  if (homeWindow && !homeWindow.isDestroyed()) {
    homeWindow.show();
    homeWindow.focus();
    sendHomeState();
    return;
  }

  homeWindow = new BrowserWindow({
    width: 960,
    height: 720,
    minWidth: 860,
    minHeight: 640,
    title: APP_NAME,
    backgroundColor: "#11130f",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  homeWindow.loadFile(path.join(__dirname, "home.html"));
  homeWindow.once("ready-to-show", () => {
    homeWindow.show();
    sendHomeState();
  });
  homeWindow.on("closed", () => {
    homeWindow = null;
  });
}

function positionBubble() {
  const display = require("electron").screen.getPrimaryDisplay();
  const { x, y, width, height } = display.workArea;
  bubbleWindow.setPosition(x + width - 96, y + height - 112, false);
}

function registerShortcut(accelerator) {
  globalShortcut.unregisterAll();
  const ok = globalShortcut.register(accelerator || "Control+Alt+Space", toggleDictation);
  if (!ok) {
    setState("error", "Ctrl+Alt+Space is already in use. Open Home and choose another shortcut.");
  }
}

function toggleDictation() {
  if (dictationState.mode === "listening") {
    bubbleWindow.webContents.send("recording-stop");
    setState("processing", "Finalising locally with Whisper...");
    return;
  }
  if (dictationState.mode === "processing") {
    return;
  }
  startDictation();
}

function startDictation() {
  const state = settings.all();
  if (!isValid(state.licenseKey)) {
    setState("error", "Activate i don't type before dictating.");
    showHome();
    return;
  }
  if (state.speechModel === SpeechModel.openaiCloud && state.openAICloudMode === OpenAICloudMode.apiKey && !getStoredOpenAIAPIKey()) {
    setState("error", "Save your OpenAI API key before using Own OpenAI key mode.");
    showHome();
    return;
  }
  if (state.speechModel !== SpeechModel.openaiCloud) {
    runtimeStatus = inspectRuntime();
    if (!runtimeStatus.ready) {
      setState("error", runtimeStatus.message);
      showHome();
      return;
    }
  }
  if (!bubbleWindow.isVisible()) {
    bubbleWindow.showInactive();
  }
  setState("listening", "Listening.");
  bubbleWindow.webContents.send("recording-start", {
    language: state.speechLanguage,
    dictionaryWords: state.dictionaryWords
  });
}

function setState(mode, message, extra = {}) {
  dictationState = {
    ...dictationState,
    ...extra,
    mode,
    message
  };
  broadcastState();
}

function broadcastState() {
  if (bubbleWindow && !bubbleWindow.isDestroyed()) {
    bubbleWindow.webContents.send("dictation-state", dictationState);
  }
  sendHomeState();
  updateTrayMenu();
}

function sendHomeState() {
  if (!homeWindow || homeWindow.isDestroyed()) {
    return;
  }
  const state = settings?.all();
  if (!state) {
    return;
  }
  const licensePayload = payloadFor(state.licenseKey);
  homeWindow.webContents.send("home-state", {
    settings: {
      ...state,
      licenseKey: state.licenseKey ? "saved" : "",
      openAIAPIKey: state.openAIAPIKeyEncrypted ? "saved" : "",
      openAIAPIKeyEncrypted: ""
    },
    license: {
      active: Boolean(licensePayload),
      plan: displayPlan(licensePayload),
      issuedAt: licensePayload?.issued_at || ""
    },
    runtime: state.speechModel === SpeechModel.openaiCloud
      ? {
          ready: true,
          message: state.openAICloudMode === OpenAICloudMode.apiKey
            ? "Own OpenAI key selected. Audio is sent directly to OpenAI."
            : "i don't type cloud service selected. Audio leaves this PC for transcription."
        }
      : (runtimeStatus || inspectRuntime()),
    dictation: dictationState,
    styles: Object.values(TransformStyle)
  });
}

async function handleRecordingComplete(event, payload) {
  if (dictationState.mode !== "processing" && dictationState.mode !== "listening") {
    return;
  }
  setState("processing", "Preparing transcription...");

  try {
    const state = settings.all();
    const rawBuffer = Buffer.from(payload.buffer);
    const rawExtension = payload.mimeType && payload.mimeType.includes("wav") ? "wav" : "webm";
    if (state.speechModel === SpeechModel.openaiCloud) {
      setState("processing", "Transcribing with OpenAI...");
      const cloudText = await transcribeWithOpenAICloud(rawBuffer, {
        filename: `recording.${rawExtension}`,
        mimeType: payload.mimeType || "audio/webm"
      });
      await finishTranscript(cloudText);
      return;
    }

    const workingDir = fs.mkdtempSync(path.join(os.tmpdir(), "idonttype-"));
    setState("processing", "Transcribing locally with Whisper...");
    const sourcePath = path.join(workingDir, `recording.${rawExtension}`);
    const wavPath = path.join(workingDir, "recording.wav");
    const outputBasePath = path.join(workingDir, "transcript");
    const outputTextPath = `${outputBasePath}.txt`;
    fs.writeFileSync(sourcePath, rawBuffer);

    await runProcess(runtimeStatus.ffmpegPath, [
      "-y",
      "-loglevel", "error",
      "-i", sourcePath,
      "-ar", "16000",
      "-ac", "1",
      "-c:a", "pcm_s16le",
      wavPath
    ]);

    const args = [
      "-m", runtimeStatus.modelPath,
      "-f", wavPath,
      "-l", state.speechLanguage || "en",
      "-otxt",
      "-of", outputBasePath,
      "-nt"
    ];
    if (state.dictionaryWords?.length) {
      args.push("--prompt", state.dictionaryWords.slice(0, 80).join(", "));
    }
    await runProcess(runtimeStatus.whisperPath, args, { cwd: path.dirname(runtimeStatus.whisperPath) });

    const rawText = fs.existsSync(outputTextPath)
      ? fs.readFileSync(outputTextPath, "utf8")
      : "";
    await finishTranscript(rawText);
    fs.rmSync(workingDir, { recursive: true, force: true });
  } catch (error) {
    setState("error", cleanError(error));
  }
}

async function finishTranscript(rawText) {
  const state = settings.all();
  const cleanedRaw = normalizeWhisperOutput(rawText);
  if (!cleanedRaw) {
    setState("idle", "Nothing was captured.", { partial: "" });
    return;
  }

  const processed = state.cleanupEnabled
    ? processText(cleanedRaw, state.transformStyle, state.snippets)
    : { text: cleanedRaw, shouldPressEnter: false, cancelled: false };
  if (processed.cancelled || !processed.text.trim()) {
    setState("idle", "Dictation cancelled.", { partial: "" });
    return;
  }

  clipboard.writeText(processed.text);
  settings.addRecent(processed.text, "Windows");
  settings.learnLikelyTerms(processed.text);

  let pasted = false;
  if (state.autoPaste && process.platform === "win32") {
    pasted = await sendPaste(processed.shouldPressEnter);
  }

  setState("success", pasted ? "Pasted into the active app." : "Copied to clipboard.", {
    partial: "",
    lastText: processed.text
  });
  setTimeout(() => {
    if (dictationState.mode === "success") {
      setState("idle", "Ready.");
    }
  }, 1400);
}

function normalizeWhisperOutput(input) {
  return String(input || "")
    .replace(/\[[^\]]*?-->\s*[^\]]*?\]/g, " ")
    .replace(/\[\s*BLANK_AUDIO\s*\]/gi, " ")
    .replace(/<\|[^>]+?\|>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function runProcess(executablePath, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = childProcess.spawn(executablePath, args, {
      windowsHide: true,
      ...options
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(stderr.trim() || `${path.basename(executablePath)} exited with code ${code}.`));
      }
    });
  });
}

function sendPaste(shouldPressEnter) {
  const escapedDelay = shouldPressEnter ? "Start-Sleep -Milliseconds 90; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}');" : "";
  const command = [
    "Add-Type -AssemblyName System.Windows.Forms;",
    "Start-Sleep -Milliseconds 120;",
    "[System.Windows.Forms.SendKeys]::SendWait('^v');",
    escapedDelay
  ].join(" ");
  return new Promise((resolve) => {
    childProcess.execFile("powershell.exe", [
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-Command", command
    ], { windowsHide: true }, (error) => {
      resolve(!error);
    });
  });
}

async function transcribeWithOpenAICloud(audioBuffer, { filename, mimeType }) {
  const state = settings.all();
  if (state.openAICloudMode === OpenAICloudMode.apiKey) {
    const apiKey = getStoredOpenAIAPIKey();
    if (!apiKey) {
      throw new Error("Save your OpenAI API key before using Own OpenAI key mode.");
    }
    return transcribeDirectlyWithOpenAI(audioBuffer, { filename, mimeType, apiKey });
  }

  const response = await fetch(CLOUD_TRANSCRIBE_URL, {
    method: "POST",
    headers: {
      "authorization": `Bearer ${state.licenseKey}`,
      "content-type": "application/json"
    },
    body: JSON.stringify({
      audio_base64: Buffer.from(audioBuffer).toString("base64"),
      filename: filename || "recording.webm",
      mime_type: mimeType || "audio/webm",
      language: state.speechLanguage || "en",
      prompt: (state.dictionaryWords || []).slice(0, 80).join(", ")
    })
  });

  const responseText = await response.text();
  let data = {};
  try {
    data = JSON.parse(responseText);
  } catch {
    data = { text: responseText, error: responseText };
  }
  if (!response.ok) {
    if (response.status === 404) {
      throw new Error("The i don't type cloud service is not available yet. Use Own OpenAI key mode or switch back to Local Whisper.");
    }
    throw new Error(data.error || data.detail || "OpenAI cloud transcription failed.");
  }
  return normalizeWhisperOutput(data.text || "");
}

async function transcribeDirectlyWithOpenAI(audioBuffer, { filename, mimeType, apiKey }) {
  const state = settings.all();
  const form = new FormData();
  form.append("file", new Blob([Buffer.from(audioBuffer)], { type: mimeType || "audio/webm" }), filename || "recording.webm");
  form.append("model", "gpt-4o-transcribe");
  form.append("response_format", "json");
  const language = normalizeLanguage(state.speechLanguage);
  if (language) {
    form.append("language", language);
  }
  const prompt = (state.dictionaryWords || []).slice(0, 80).join(", ");
  if (prompt) {
    form.append("prompt", prompt);
  }

  const response = await fetch("https://api.openai.com/v1/audio/transcriptions", {
    method: "POST",
    headers: {
      "authorization": `Bearer ${apiKey}`
    },
    body: form
  });

  const responseText = await response.text();
  let data = {};
  try {
    data = JSON.parse(responseText);
  } catch {
    data = { text: responseText, error: responseText };
  }
  if (!response.ok) {
    const message = data.error?.message || data.error || "OpenAI cloud transcription failed.";
    throw new Error(message);
  }
  return normalizeWhisperOutput(data.text || responseText);
}

function inspectRuntime() {
  const runtimeRoot = runtimeDirectory();
  const whisperPath = findFile(runtimeRoot, /^whisper-(cli|main)\.exe$/i) || findFile(runtimeRoot, /^main\.exe$/i);
  const ffmpegPath = findFile(runtimeRoot, /^ffmpeg\.exe$/i);
  const modelPath = findFile(runtimeRoot, /^ggml-(base\.en|base|tiny\.en|tiny)\.bin$/i);

  if (process.platform !== "win32") {
    return {
      ready: false,
      message: "The Windows client packages on Windows. Run the workflow or npm scripts on a Windows machine.",
      runtimeRoot,
      whisperPath,
      ffmpegPath,
      modelPath
    };
  }
  if (!whisperPath || !ffmpegPath || !modelPath) {
    return {
      ready: false,
      message: "Local Whisper runtime is missing. Run npm run prepare-runtime from the windows folder, then build again.",
      runtimeRoot,
      whisperPath,
      ffmpegPath,
      modelPath
    };
  }

  return {
    ready: true,
    message: "Local Whisper runtime is ready.",
    runtimeRoot,
    whisperPath,
    ffmpegPath,
    modelPath
  };
}

function runtimeDirectory() {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "runtime");
  }
  return path.join(app.getAppPath(), "runtime");
}

function findFile(root, pattern) {
  if (!root || !fs.existsSync(root)) {
    return null;
  }
  const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const fullPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        stack.push(fullPath);
      } else if (pattern.test(entry.name)) {
        return fullPath;
      }
    }
  }
  return null;
}

function mimeTypeForPath(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".mp3":
    case ".mpga":
      return "audio/mpeg";
    case ".m4a":
    case ".mp4":
      return "audio/mp4";
    case ".wav":
      return "audio/wav";
    case ".webm":
      return "audio/webm";
    case ".ogg":
      return "audio/ogg";
    case ".flac":
      return "audio/flac";
    case ".aac":
      return "audio/aac";
    default:
      return "audio/wav";
  }
}

function getStoredOpenAIAPIKey() {
  const encrypted = settings?.all().openAIAPIKeyEncrypted;
  if (!encrypted || !safeStorage.isEncryptionAvailable()) {
    return "";
  }
  try {
    return safeStorage.decryptString(Buffer.from(encrypted, "base64")).trim();
  } catch {
    return "";
  }
}

function normalizeLanguage(value) {
  const cleaned = String(value || "").trim().replace(/_/g, "-").toLowerCase();
  const code = cleaned.split("-")[0];
  return /^[a-z]{2,3}$/.test(code) ? code : "";
}

function sanitizeHomeSettingsPatch(patch) {
  const source = patch && typeof patch === "object" ? patch : {};
  const allowed = [
    "transformStyle",
    "speechModel",
    "openAICloudMode",
    "speechLanguage",
    "shortcut",
    "autoPaste",
    "cleanupEnabled",
    "bubbleVisible",
    "dictionaryWords",
    "snippets"
  ];
  return Object.fromEntries(
    allowed
      .filter((key) => Object.prototype.hasOwnProperty.call(source, key))
      .map((key) => [key, source[key]])
  );
}

function cleanError(error) {
  return String(error?.message || error || "Something went wrong.")
    .replace(/\s+/g, " ")
    .trim();
}

function createTrayImage() {
  const svg = encodeURIComponent(`
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
      <rect x="3" y="3" width="26" height="26" rx="8" fill="#eef4d0"/>
      <path d="M12 10v8a4 4 0 0 0 8 0v-8" fill="none" stroke="#11130f" stroke-width="2.4" stroke-linecap="round"/>
      <path d="M8 17a8 8 0 0 0 16 0" fill="none" stroke="#11130f" stroke-width="2.2" stroke-linecap="round"/>
      <path d="M16 25v4" stroke="#11130f" stroke-width="2.2" stroke-linecap="round"/>
    </svg>
  `);
  return nativeImage.createFromDataURL(`data:image/svg+xml;charset=utf-8,${svg}`);
}

ipcMain.handle("dictation-toggle", toggleDictation);
ipcMain.handle("recording-complete", handleRecordingComplete);
ipcMain.handle("recording-error", (event, message) => {
  setState("error", String(message || "Microphone access failed."));
});
ipcMain.handle("home-get-state", () => {
  sendHomeState();
});
ipcMain.handle("home-save-settings", (event, patch) => {
  const previousShortcut = settings.all().shortcut;
  const saved = settings.update(sanitizeHomeSettingsPatch(patch));
  if (saved.shortcut !== previousShortcut) {
    registerShortcut(saved.shortcut);
  }
  runtimeStatus = inspectRuntime();
  broadcastState();
  return { ok: true };
});
ipcMain.handle("home-save-license", (event, licenseKey) => {
  const key = String(licenseKey || "").trim();
  if (!isValid(key)) {
    return { ok: false, message: "That license key is not valid." };
  }
  settings.update({ licenseKey: key });
  broadcastState();
  return { ok: true, plan: displayPlan(payloadFor(key)) };
});
ipcMain.handle("home-save-openai-key", (event, apiKey) => {
  const key = String(apiKey || "").trim();
  if (!key) {
    settings.update({ openAIAPIKeyEncrypted: "" });
    broadcastState();
    return { ok: true, saved: false };
  }
  if (!safeStorage.isEncryptionAvailable()) {
    return { ok: false, message: "Windows secure storage is not available on this PC." };
  }
  const encrypted = safeStorage.encryptString(key).toString("base64");
  settings.update({ openAIAPIKeyEncrypted: encrypted });
  broadcastState();
  return { ok: true, saved: true };
});
ipcMain.handle("home-transcribe-file", async () => {
  if (!isValid(settings.all().licenseKey)) {
    return { ok: false, message: "Activate i don't type before transcribing a file." };
  }
  const selected = await dialog.showOpenDialog(homeWindow || undefined, {
    title: "Choose an audio or video file",
    properties: ["openFile"],
    filters: [
      { name: "Audio and video", extensions: ["mp3", "m4a", "wav", "webm", "mp4", "mov", "aac", "flac", "ogg"] }
    ]
  });
  if (selected.canceled || !selected.filePaths[0]) {
    return { ok: false, message: "No file selected." };
  }
  return transcribeFile(selected.filePaths[0]);
});
ipcMain.handle("home-open-runtime", () => {
  const runtimeRoot = runtimeDirectory();
  fs.mkdirSync(runtimeRoot, { recursive: true });
  shell.openPath(runtimeRoot);
});
ipcMain.handle("home-clear-history", () => {
  settings.update({ recent: [] });
  broadcastState();
});
ipcMain.handle("home-copy-text", (event, text) => {
  clipboard.writeText(String(text || ""));
});
ipcMain.handle("home-send-feedback", () => {
  openFeedbackEmail();
});

async function transcribeFile(sourcePath) {
  if (!isValid(settings.all().licenseKey)) {
    return { ok: false, message: "Activate i don't type before transcribing a file." };
  }
  const state = settings.all();
  if (state.speechModel === SpeechModel.openaiCloud && state.openAICloudMode === OpenAICloudMode.apiKey && !getStoredOpenAIAPIKey()) {
    return { ok: false, message: "Save your OpenAI API key before using Own OpenAI key mode." };
  }
  if (state.speechModel !== SpeechModel.openaiCloud) {
    runtimeStatus = inspectRuntime();
    if (!runtimeStatus.ready) {
      return { ok: false, message: runtimeStatus.message };
    }
  }
  try {
    if (state.speechModel === SpeechModel.openaiCloud) {
      setState("processing", `Transcribing ${path.basename(sourcePath)} with OpenAI...`);
      const text = await transcribeWithOpenAICloud(fs.readFileSync(sourcePath), {
        filename: path.basename(sourcePath),
        mimeType: mimeTypeForPath(sourcePath)
      });
      const transcriptPath = `${sourcePath}.txt`;
      fs.writeFileSync(transcriptPath, `${text}\n`, "utf8");
      clipboard.writeText(text);
      settings.addRecent(text, "File");
      setState("success", "Transcript copied and saved beside the file.", { lastText: text });
      return { ok: true, text, transcriptPath };
    }

    setState("processing", `Transcribing ${path.basename(sourcePath)} locally...`);
    const workingDir = fs.mkdtempSync(path.join(os.tmpdir(), "idonttype-file-"));
    const wavPath = path.join(workingDir, "input.wav");
    const outputBasePath = path.join(workingDir, "transcript");
    const outputTextPath = `${outputBasePath}.txt`;
    await runProcess(runtimeStatus.ffmpegPath, [
      "-y",
      "-loglevel", "error",
      "-i", sourcePath,
      "-ar", "16000",
      "-ac", "1",
      "-c:a", "pcm_s16le",
      wavPath
    ]);
    await runProcess(runtimeStatus.whisperPath, [
      "-m", runtimeStatus.modelPath,
      "-f", wavPath,
      "-l", settings.all().speechLanguage || "en",
      "-otxt",
      "-of", outputBasePath,
      "-nt"
    ], { cwd: path.dirname(runtimeStatus.whisperPath) });
    const text = normalizeWhisperOutput(fs.readFileSync(outputTextPath, "utf8"));
    const transcriptPath = `${sourcePath}.txt`;
    fs.writeFileSync(transcriptPath, `${text}\n`, "utf8");
    clipboard.writeText(text);
    settings.addRecent(text, "File");
    fs.rmSync(workingDir, { recursive: true, force: true });
    setState("success", "Transcript copied and saved beside the file.", { lastText: text });
    return { ok: true, text, transcriptPath };
  } catch (error) {
    const message = cleanError(error);
    setState("error", message);
    return { ok: false, message };
  }
}

function openFeedbackEmail() {
  const subject = encodeURIComponent("i don't type Windows feedback");
  const body = encodeURIComponent([
    "",
    "",
    "Version: 0.1.0 beta",
    `Platform: ${os.type()} ${os.release()} ${os.arch()}`
  ].join("\n"));
  shell.openExternal(`mailto:hello@lukejbyrne.com?subject=${subject}&body=${body}`);
}
