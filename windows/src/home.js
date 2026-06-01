const panels = {
  home: document.getElementById("homePanel"),
  history: document.getElementById("historyPanel"),
  dictionary: document.getElementById("dictionaryPanel"),
  transcribe: document.getElementById("transcribePanel")
};

const titleBySection = {
  home: ["Home", "Private Windows dictation with Local Whisper or OpenAI cloud."],
  history: ["History", "Recent dictations saved locally on this PC."],
  dictionary: ["Dictionary", "Terms and snippets used to guide cleanup."],
  transcribe: ["Transcribe", "Create a local transcript from an audio or video file."]
};

let currentState = null;

for (const button of document.querySelectorAll(".nav-item")) {
  button.addEventListener("click", () => showSection(button.dataset.section));
}

document.getElementById("toggleDictation").addEventListener("click", () => {
  window.wispry.toggleDictation();
});

document.getElementById("saveSettings").addEventListener("click", saveSettingsFromForm);
document.getElementById("saveDictionary").addEventListener("click", saveDictionaryAndSnippets);
document.getElementById("saveSnippets").addEventListener("click", saveDictionaryAndSnippets);
document.getElementById("openRuntime").addEventListener("click", () => window.wispry.openRuntime());
document.getElementById("sendFeedback").addEventListener("click", () => window.wispry.sendFeedback());
document.getElementById("clearHistory").addEventListener("click", () => window.wispry.clearHistory());
document.getElementById("saveOpenAIAPIKey").addEventListener("click", saveOpenAIAPIKey);
document.getElementById("speechModel").addEventListener("change", renderCloudControls);
document.getElementById("openAICloudMode").addEventListener("change", renderCloudControls);

document.getElementById("saveLicense").addEventListener("click", async () => {
  const key = document.getElementById("licenseKey").value;
  const result = await window.wispry.saveLicense(key);
  if (!result.ok) {
    setInlineStatus(result.message);
    return;
  }
  document.getElementById("licenseKey").value = "";
  setInlineStatus(`License active: ${result.plan}`);
});

document.getElementById("transcribeFile").addEventListener("click", async () => {
  const output = document.getElementById("fileResult");
  output.textContent = "Transcribing...";
  const result = await window.wispry.transcribeFile();
  if (!result.ok) {
    output.textContent = result.message;
    return;
  }
  output.textContent = `${result.text}\n\nSaved to: ${result.transcriptPath}`;
});

window.wispry.onHomeState((state) => {
  currentState = state;
  renderState(state);
});

window.wispry.onDictationState((state) => {
  if (!currentState) {
    return;
  }
  currentState = { ...currentState, dictation: state };
  renderStatus(currentState);
});

window.wispry.getHomeState();

function renderState(state) {
  const settings = state.settings;
  renderStatus(state);
  renderStyleOptions(state.styles, settings.transformStyle);
  document.getElementById("speechModel").value = settings.speechModel || "localWhisper";
  document.getElementById("openAICloudMode").value = settings.openAICloudMode || "service";
  document.getElementById("openAIAPIKey").placeholder = settings.openAIAPIKey ? "Saved" : "sk-...";
  renderCloudControls();
  document.getElementById("speechLanguage").value = settings.speechLanguage || "en";
  document.getElementById("shortcut").value = settings.shortcut || "Control+Alt+Space";
  document.getElementById("autoPaste").checked = settings.autoPaste !== false;
  document.getElementById("cleanupEnabled").checked = settings.cleanupEnabled !== false;
  document.getElementById("bubbleVisible").checked = settings.bubbleVisible !== false;
  document.getElementById("dictionaryWords").value = (settings.dictionaryWords || []).join("\n");
  document.getElementById("snippets").value = (settings.snippets || [])
    .map((snippet) => `${snippet.phrase} => ${snippet.expansion.replace(/\n/g, "\\n")}`)
    .join("\n");
  renderHistory(settings.recent || []);
}

function renderStatus(state) {
  document.getElementById("dictationStatus").textContent = state.dictation?.message || "Ready.";
  document.getElementById("licenseStatus").textContent = state.license?.active ? state.license.plan : "Inactive";
  document.getElementById("runtimeStatus").textContent = state.runtime?.message || "Checking...";
  const toggle = document.getElementById("toggleDictation");
  toggle.textContent = state.dictation?.mode === "listening" ? "Stop and paste" : "Start dictation";
}

function renderStyleOptions(styles, selected) {
  const select = document.getElementById("transformStyle");
  if (select.options.length !== styles.length) {
    select.replaceChildren(...styles.map((style) => {
      const option = document.createElement("option");
      option.value = style;
      option.textContent = style;
      return option;
    }));
  }
  select.value = selected;
}

function renderCloudControls() {
  const usingCloud = document.getElementById("speechModel").value === "openaiCloud";
  const usingOwnKey = usingCloud && document.getElementById("openAICloudMode").value === "apiKey";
  document.getElementById("cloudModeRow").hidden = !usingCloud;
  document.getElementById("openAIKeyBlock").hidden = !usingOwnKey;
}

function renderHistory(items) {
  const list = document.getElementById("historyList");
  if (!items.length) {
    list.innerHTML = "<div class=\"empty-state\">No local dictation history yet.</div>";
    return;
  }
  list.replaceChildren(...items.map((item) => {
    const row = document.createElement("article");
    row.className = "history-item";
    const meta = document.createElement("div");
    meta.className = "history-meta";
    meta.textContent = `${item.appName || "Windows"} · ${formatDate(item.date)}`;
    const text = document.createElement("p");
    text.textContent = item.text || "";
    const actions = document.createElement("div");
    actions.className = "history-actions";
    const copy = document.createElement("button");
    copy.type = "button";
    copy.textContent = "Copy";
    copy.addEventListener("click", () => window.wispry.copyText(item.text || ""));
    actions.append(copy);
    row.append(meta, text, actions);
    return row;
  }));
}

async function saveSettingsFromForm() {
  await window.wispry.saveSettings({
    transformStyle: document.getElementById("transformStyle").value,
    speechModel: document.getElementById("speechModel").value,
    openAICloudMode: document.getElementById("openAICloudMode").value,
    speechLanguage: document.getElementById("speechLanguage").value,
    shortcut: document.getElementById("shortcut").value,
    autoPaste: document.getElementById("autoPaste").checked,
    cleanupEnabled: document.getElementById("cleanupEnabled").checked,
    bubbleVisible: document.getElementById("bubbleVisible").checked
  });
  setInlineStatus("Settings saved.");
}

async function saveOpenAIAPIKey() {
  const input = document.getElementById("openAIAPIKey");
  const result = await window.wispry.saveOpenAIAPIKey(input.value);
  if (!result.ok) {
    setInlineStatus(result.message);
    return;
  }
  input.value = "";
  input.placeholder = result.saved ? "Saved" : "sk-...";
  setInlineStatus(result.saved ? "OpenAI API key saved." : "OpenAI API key cleared.");
}

async function saveDictionaryAndSnippets() {
  await window.wispry.saveSettings({
    dictionaryWords: document.getElementById("dictionaryWords").value
      .split(/\r?\n/)
      .map((word) => word.trim())
      .filter(Boolean),
    snippets: document.getElementById("snippets").value
      .split(/\r?\n/)
      .map(parseSnippetLine)
      .filter(Boolean)
  });
  setInlineStatus("Dictionary saved.");
}

function parseSnippetLine(line) {
  const index = line.indexOf("=>");
  if (index < 0) {
    return null;
  }
  const phrase = line.slice(0, index).trim();
  const expansion = line.slice(index + 2).trim().replace(/\\n/g, "\n");
  return phrase && expansion ? { phrase, expansion } : null;
}

function showSection(section) {
  for (const [key, panel] of Object.entries(panels)) {
    panel.classList.toggle("active", key === section);
  }
  for (const button of document.querySelectorAll(".nav-item")) {
    button.classList.toggle("active", button.dataset.section === section);
  }
  const [title, subtitle] = titleBySection[section] || titleBySection.home;
  document.getElementById("sectionTitle").textContent = title;
  document.getElementById("sectionSubtitle").textContent = subtitle;
}

function setInlineStatus(message) {
  document.getElementById("dictationStatus").textContent = message;
}

function formatDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit"
  }).format(date);
}
