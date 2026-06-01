const fs = require("fs");
const path = require("path");

const { TransformStyle } = require("./text-pipeline");

const DEFAULT_SNIPPETS = [
  { phrase: "insert signature", expansion: "Best,\nLuke" },
  { phrase: "standup update", expansion: "Yesterday:\n- \n\nToday:\n- \n\nBlocked:\n- None" },
  { phrase: "shipping note", expansion: "Implemented, checked locally, and ready for review." }
];

const DEFAULT_SETTINGS = Object.freeze({
  autoPaste: true,
  cleanupEnabled: true,
  transformStyle: TransformStyle.clean,
  speechModel: "localWhisper",
  openAICloudMode: "service",
  openAIAPIKeyEncrypted: "",
  speechLanguage: "en",
  licenseKey: "",
  dictionaryWords: [],
  snippets: DEFAULT_SNIPPETS,
  recent: [],
  bubbleVisible: true,
  shortcut: "Control+Alt+Space"
});

class SettingsStore {
  constructor(userDataPath) {
    this.filePath = path.join(userDataPath, "settings.json");
    this.data = this.read();
  }

  read() {
    try {
      const raw = fs.readFileSync(this.filePath, "utf8");
      const parsed = JSON.parse(raw);
      return normalizeSettings({ ...DEFAULT_SETTINGS, ...parsed });
    } catch {
      return normalizeSettings({ ...DEFAULT_SETTINGS });
    }
  }

  all() {
    return normalizeSettings({ ...DEFAULT_SETTINGS, ...this.data });
  }

  update(patch) {
    this.data = normalizeSettings({ ...this.all(), ...patch });
    this.save();
    return this.all();
  }

  save() {
    fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
    fs.writeFileSync(this.filePath, `${JSON.stringify(this.data, null, 2)}\n`, "utf8");
  }

  addRecent(text, appName = "Windows") {
    const cleaned = String(text || "").trim();
    if (!cleaned) {
      return;
    }
    const recent = Array.isArray(this.data.recent) ? [...this.data.recent] : [];
    const now = new Date().toISOString();
    const first = recent[0];
    if (first && first.appName === appName && first.text === cleaned) {
      recent[0] = { ...first, date: now };
    } else {
      recent.unshift({ date: now, appName, text: cleaned });
    }
    this.update({ recent: recent.slice(0, 30) });
  }

  learnLikelyTerms(text) {
    const words = String(text || "")
      .split(/[^A-Za-z0-9-]+/)
      .filter((word) => word.length > 2 && /[A-Z]/.test(word));
    if (!words.length) {
      return;
    }
    const existing = new Set(this.data.dictionaryWords || []);
    for (const word of words) {
      existing.add(word);
    }
    this.update({ dictionaryWords: Array.from(existing) });
  }
}

function normalizeSettings(settings) {
  return {
    ...settings,
    autoPaste: settings.autoPaste !== false,
    cleanupEnabled: settings.cleanupEnabled !== false,
    transformStyle: Object.values(TransformStyle).includes(settings.transformStyle)
      ? settings.transformStyle
      : TransformStyle.clean,
    speechModel: ["localWhisper", "openaiCloud"].includes(settings.speechModel)
      ? settings.speechModel
      : "localWhisper",
    openAICloudMode: ["service", "apiKey"].includes(settings.openAICloudMode)
      ? settings.openAICloudMode
      : "service",
    openAIAPIKeyEncrypted: String(settings.openAIAPIKeyEncrypted || ""),
    speechLanguage: String(settings.speechLanguage || "en").trim() || "en",
    licenseKey: String(settings.licenseKey || "").trim(),
    dictionaryWords: uniqueStrings(settings.dictionaryWords),
    snippets: normalizeSnippets(settings.snippets),
    recent: Array.isArray(settings.recent) ? settings.recent.slice(0, 30) : [],
    bubbleVisible: settings.bubbleVisible !== false,
    shortcut: String(settings.shortcut || DEFAULT_SETTINGS.shortcut)
  };
}

function uniqueStrings(values) {
  const seen = new Set();
  for (const value of Array.isArray(values) ? values : []) {
    const cleaned = String(value || "").trim();
    if (cleaned) {
      seen.add(cleaned);
    }
  }
  return Array.from(seen);
}

function normalizeSnippets(values) {
  const source = Array.isArray(values) && values.length ? values : DEFAULT_SNIPPETS;
  return source
    .map((snippet) => ({
      phrase: String(snippet.phrase || "").trim(),
      expansion: String(snippet.expansion || "")
    }))
    .filter((snippet) => snippet.phrase && snippet.expansion);
}

module.exports = {
  DEFAULT_SETTINGS,
  SettingsStore
};
