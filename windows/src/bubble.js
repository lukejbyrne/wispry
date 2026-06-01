const bubble = document.getElementById("bubble");
const glyph = document.getElementById("bubbleGlyph");

let mediaRecorder = null;
let chunks = [];

bubble.addEventListener("click", () => {
  window.wispry.toggleDictation();
});

window.wispry.onDictationState((state) => {
  bubble.className = `bubble ${state.mode || "idle"}`;
  glyph.textContent = glyphForMode(state.mode);
  bubble.title = state.message || "Toggle dictation";
});

window.wispry.onRecordingStart(async () => {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    });
    chunks = [];
    mediaRecorder = new MediaRecorder(stream, preferredRecorderOptions());
    mediaRecorder.addEventListener("dataavailable", (event) => {
      if (event.data.size > 0) {
        chunks.push(event.data);
      }
    });
    mediaRecorder.addEventListener("stop", async () => {
      const blob = new Blob(chunks, { type: mediaRecorder.mimeType || "audio/webm" });
      stream.getTracks().forEach((track) => track.stop());
      const buffer = await blob.arrayBuffer();
      window.wispry.recordingComplete(buffer, blob.type);
      chunks = [];
      mediaRecorder = null;
    });
    mediaRecorder.start(250);
  } catch (error) {
    window.wispry.recordingError(error.message || "Microphone access failed.");
  }
});

window.wispry.onRecordingStop(() => {
  if (mediaRecorder && mediaRecorder.state !== "inactive") {
    mediaRecorder.stop();
  }
});

function preferredRecorderOptions() {
  if (MediaRecorder.isTypeSupported("audio/webm;codecs=opus")) {
    return { mimeType: "audio/webm;codecs=opus" };
  }
  if (MediaRecorder.isTypeSupported("audio/webm")) {
    return { mimeType: "audio/webm" };
  }
  return {};
}

function glyphForMode(mode) {
  switch (mode) {
    case "listening":
      return "";
    case "processing":
      return "...";
    case "success":
      return "✓";
    case "error":
      return "!";
    default:
      return "i";
  }
}
