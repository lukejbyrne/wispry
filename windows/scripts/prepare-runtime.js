const fs = require("fs");
const http = require("http");
const https = require("https");
const path = require("path");
const { pipeline } = require("stream/promises");

const extract = require("extract-zip");

const ROOT = path.resolve(__dirname, "..");
const RUNTIME_DIR = path.join(ROOT, "runtime");
const WHISPER_VERSION = process.env.WHISPER_CPP_VERSION || "v1.8.4";
const WHISPER_ASSET = process.env.WHISPER_CPP_ASSET || "whisper-bin-x64.zip";
const WHISPER_URL = process.env.WHISPER_CPP_URL
  || `https://github.com/ggml-org/whisper.cpp/releases/download/${WHISPER_VERSION}/${WHISPER_ASSET}`;
const MODEL_NAME = process.env.WHISPER_MODEL_NAME || "ggml-base.en.bin";
const MODEL_URL = process.env.WHISPER_MODEL_URL
  || `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_NAME}`;

async function main() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  await prepareWhisper();
  prepareFfmpeg();
  await prepareModel();
  writeReadme();
  console.log(`Windows runtime prepared in ${RUNTIME_DIR}`);
}

async function prepareWhisper() {
  const whisperDir = path.join(RUNTIME_DIR, "whisper");
  if (findFile(whisperDir, /^whisper-(cli|main)\.exe$/i)) {
    console.log("whisper.cpp runtime already present.");
    return;
  }

  const tempDir = fs.mkdtempSync(path.join(require("os").tmpdir(), "idonttype-whisper-"));
  const zipPath = path.join(tempDir, WHISPER_ASSET);
  const extractDir = path.join(tempDir, "extract");
  console.log(`Downloading whisper.cpp ${WHISPER_VERSION}...`);
  await download(WHISPER_URL, zipPath);
  await extract(zipPath, { dir: extractDir });
  fs.rmSync(whisperDir, { recursive: true, force: true });
  fs.mkdirSync(whisperDir, { recursive: true });
  copyRecursive(extractDir, whisperDir);
  fs.rmSync(tempDir, { recursive: true, force: true });
}

function prepareFfmpeg() {
  if (process.platform !== "win32") {
    console.log("Skipping ffmpeg.exe copy on non-Windows host. The Windows workflow copies it during packaging.");
    return;
  }
  const ffmpegSource = require("ffmpeg-static");
  if (!ffmpegSource || !fs.existsSync(ffmpegSource)) {
    throw new Error("ffmpeg-static did not provide a Windows ffmpeg binary.");
  }
  fs.copyFileSync(ffmpegSource, path.join(RUNTIME_DIR, "ffmpeg.exe"));
  console.log("Copied ffmpeg.exe.");
}

async function prepareModel() {
  const modelDir = path.join(RUNTIME_DIR, "models");
  const modelPath = path.join(modelDir, MODEL_NAME);
  fs.mkdirSync(modelDir, { recursive: true });
  if (fs.existsSync(modelPath)) {
    console.log(`${MODEL_NAME} already present.`);
    return;
  }
  console.log(`Downloading ${MODEL_NAME}...`);
  await download(MODEL_URL, modelPath);
}

function writeReadme() {
  fs.writeFileSync(
    path.join(RUNTIME_DIR, "README.txt"),
    [
      "i don't type Windows runtime",
      "",
      `whisper.cpp: ${WHISPER_VERSION}`,
      `model: ${MODEL_NAME}`,
      "",
      "These files are bundled into the Windows installer by electron-builder."
    ].join("\n"),
    "utf8"
  );
}

async function download(url, destination, redirectCount = 0) {
  if (redirectCount > 6) {
    throw new Error(`Too many redirects while downloading ${url}`);
  }
  const client = url.startsWith("https:") ? https : http;
  await new Promise((resolve, reject) => {
    const request = client.get(url, {
      headers: {
        "User-Agent": "idonttype-windows-build"
      }
    }, (response) => {
      if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
        response.resume();
        const nextURL = new URL(response.headers.location, url).toString();
        download(nextURL, destination, redirectCount + 1).then(resolve, reject);
        return;
      }
      if (response.statusCode < 200 || response.statusCode > 299) {
        response.resume();
        reject(new Error(`Download failed with HTTP ${response.statusCode}: ${url}`));
        return;
      }
      const file = fs.createWriteStream(destination);
      pipeline(response, file).then(resolve, reject);
    });
    request.on("error", reject);
  });
}

function copyRecursive(source, destination) {
  for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
    const from = path.join(source, entry.name);
    const to = path.join(destination, entry.name);
    if (entry.isDirectory()) {
      fs.mkdirSync(to, { recursive: true });
      copyRecursive(from, to);
    } else {
      fs.copyFileSync(from, to);
    }
  }
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

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
