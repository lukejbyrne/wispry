const TransformStyle = Object.freeze({
  verbatim: "Verbatim",
  clean: "Clean",
  professional: "Professional",
  casual: "Casual",
  list: "List"
});

function processText(rawText, style = TransformStyle.clean, snippets = []) {
  let text = normalizeWhitespace(rawText);
  if (!text) {
    return { text: "", shouldPressEnter: false, cancelled: false };
  }

  if (isCancelCommand(text)) {
    return { text: "", shouldPressEnter: false, cancelled: true };
  }

  let shouldPressEnter = false;
  for (const command of ["press enter", "hit enter", "send it"]) {
    if (endsWithCommand(text, command)) {
      text = removeTrailingCommand(text, command);
      shouldPressEnter = true;
      break;
    }
  }

  text = expandSnippets(text, snippets);
  const commandStyle = styleFromSpokenCommand(text);
  text = commandStyle.text;
  const preservationSource = text;
  text = applySelfCorrections(text);
  text = normalizeSpeechArtifacts(text);
  text = replaceDictationPhrases(text);
  text = normalizePunctuationSpacing(text);
  text = removeConversationalLeadIns(text);
  text = removeFillers(text);
  text = collapseRepeatedClauseRevisions(text);
  text = removeRepeatedWords(text);

  const finalStyle = commandStyle.style || style;
  text = applyStyle(finalStyle, text);
  text = normalizePunctuationSpacing(text);
  text = normalizeWhitespace(text);
  if (!preservesEnoughContent(text, preservationSource)) {
    text = conservativeCleanup(preservationSource, finalStyle);
  }

  return { text, shouldPressEnter, cancelled: false };
}

function normalizeWhitespace(input) {
  return String(input || "")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function conservativeCleanup(input, style) {
  let text = normalizeSpeechArtifacts(input);
  text = replaceDictationPhrases(text);
  text = normalizePunctuationSpacing(text);
  text = removeConversationalLeadIns(text);
  text = removeFillers(text);
  text = removeRepeatedWords(text);
  text = applyStyle(style, text);
  text = normalizePunctuationSpacing(text);
  return normalizeWhitespace(text);
}

function preservesEnoughContent(processed, original) {
  const originalCount = wordCount(original);
  if (originalCount < 35) {
    return true;
  }
  const processedCount = wordCount(processed);
  return processedCount >= Math.max(12, Math.floor(originalCount * 0.55));
}

function wordCount(input) {
  return String(input || "").split(/[^A-Za-z0-9]+/).filter(Boolean).length;
}

function stripCommandText(input) {
  return String(input || "")
    .toLowerCase()
    .replace(/^[\s.,!?;:]+|[\s.,!?;:]+$/g, "");
}

function isCancelCommand(text) {
  return ["cancel", "cancel that", "discard that", "stop listening"].includes(stripCommandText(text));
}

function endsWithCommand(text, command) {
  return stripCommandText(text).endsWith(command);
}

function removeTrailingCommand(text, command) {
  const index = text.toLowerCase().lastIndexOf(command.toLowerCase());
  if (index < 0) {
    return text;
  }
  return text.slice(0, index).replace(/[\s.,!?;:]+$/g, "");
}

function expandSnippets(input, snippets) {
  let text = input;
  for (const snippet of snippets || []) {
    const phrase = String(snippet.phrase || "").trim();
    const expansion = String(snippet.expansion || "");
    if (!phrase) {
      continue;
    }
    if (text.localeCompare(phrase, undefined, { sensitivity: "accent" }) === 0) {
      return expansion;
    }
    text = text.replace(new RegExp(escapeRegExp(phrase), "gi"), expansion);
  }
  return text;
}

function styleFromSpokenCommand(input) {
  const commands = [
    ["make this more professional", TransformStyle.professional],
    ["make this professional", TransformStyle.professional],
    ["rewrite this professionally", TransformStyle.professional],
    ["make this casual", TransformStyle.casual],
    ["turn this into a list", TransformStyle.list],
    ["turn to list", TransformStyle.list],
    ["format as a list", TransformStyle.list],
    ["leave this verbatim", TransformStyle.verbatim]
  ];

  const lowered = input.toLowerCase();
  for (const [command, style] of commands) {
    if (lowered.startsWith(command)) {
      return {
        style,
        text: input.slice(command.length).replace(/^[\s.,!?;:]+/g, "")
      };
    }
  }
  return { style: null, text: input };
}

function replaceDictationPhrases(input) {
  const replacements = [
    ["new paragraph", "\n\n", true, []],
    ["new line", "\n", true, []],
    ["open quote", "\"", true, []],
    ["close quote", "\"", true, []],
    ["quote", "\"", false, ["unquote", "mark", "marks"]],
    ["single quote", "'", true, []],
    ["open parenthesis", "(", true, []],
    ["close parenthesis", ")", true, []],
    ["open bracket", "[", true, []],
    ["close bracket", "]", true, []],
    ["question mark", "?", false, ["icon", "symbol"]],
    ["exclamation mark", "!", false, ["icon", "symbol"]],
    ["exclamation point", "!", false, ["icon", "symbol"]],
    ["comma", ",", false, ["separated", "delimited", "splice", "operator"]],
    ["period", ".", false, ["of", "piece", "pain", "drama", "costume", "tracking"]],
    ["full stop", ".", false, []],
    ["colon", ":", false, ["cancer", "health", "screening"]],
    ["semicolon", ";", false, ["insertion"]],
    ["dash", "-", false, ["board", "cam", "camera", "lane"]],
    ["slash", "/", false, ["command", "commands", "fiction", "mark"]],
    ["at sign", "@", true, []]
  ];

  let text = input;
  for (const [phrase, replacement, allowedAtStart, blockedNextWords] of replacements) {
    text = replaceCommandPhrase(text, phrase, replacement, allowedAtStart, new Set(blockedNextWords));
  }
  return text;
}

function replaceCommandPhrase(input, phrase, replacement, allowedAtStart, blockedNextWords) {
  const regex = new RegExp(`(^|\\s)${escapeRegExp(phrase)}(?=\\s|$|[.,!?;:])`, "gi");
  const matches = Array.from(input.matchAll(regex));
  let output = input;

  for (const match of matches.reverse()) {
    const leadingLength = match[1].length;
    const start = match.index + leadingLength;
    const end = start + phrase.length;
    const previousText = input.slice(0, start).trim();
    if (!allowedAtStart && !previousText) {
      continue;
    }
    const next = nextWord(input, end);
    if (next && blockedNextWords.has(next.toLowerCase())) {
      continue;
    }
    output = output.slice(0, start) + replacement + output.slice(end);
  }

  return output;
}

function nextWord(input, location) {
  const match = input.slice(location).match(/^\s*([A-Za-z]+)/);
  return match ? match[1] : null;
}

function normalizeSpeechArtifacts(input) {
  return input
    .replace(/(?:\s|^)(?:\[\s*blank[_ ]audio\s*\]|\(\s*blank[_ ]audio\s*\)|<\|nospeech\|>)(?=\s|$)/gi, " ")
    .replace(/\bet cetera\b/gi, "etc.")
    .replace(/\betcetera\b/gi, "etc.");
}

function normalizePunctuationSpacing(input) {
  return input
    .replace(/\s+([,.;:!?])/g, "$1")
    .replace(/([,;:!?])([^\s\d,.;:!?])/g, "$1 $2")
    .replace(/(^|[^\d])\.([^\s\d,.;:!?])/g, "$1. $2")
    .replace(/\betc\s*\./gi, "etc.")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function applySelfCorrections(input) {
  const strongPatterns = [
    /\b(?:take that back|i take that back|scratch that|ignore that|discard that|forget that|remove that)\b[,:;\-\s]*/gi,
    /\b(?:actually i meant|i didn't mean|i did not mean|what i meant was|no[, ]+i mean|sorry[, ]+i mean|no[, ]+actually)\b[,:;\-\s]*/gi
  ];

  for (const pattern of strongPatterns) {
    const replacement = textAfterLastMatch(pattern, input, false);
    if (replacement) {
      return replacement;
    }
  }

  return textAfterLastMatch(/\bi mean\b[,:;\-\s]*/gi, input, true) || input;
}

function textAfterLastMatch(pattern, input, requirePriorText) {
  const matches = Array.from(input.matchAll(pattern));
  const match = matches.at(-1);
  if (!match) {
    return null;
  }
  const prefix = input.slice(0, match.index).replace(/^[\s.,!?;:]+|[\s.,!?;:]+$/g, "");
  if (requirePriorText && !prefix) {
    return null;
  }
  const start = match.index + match[0].length;
  const replacement = input.slice(start).replace(/^[\s.,!?;:]+|[\s.,!?;:]+$/g, "");
  return replacement.length > 1 ? replacement : null;
}

function removeFillers(input) {
  return input
    .replace(/\b(um|uh|erm|ah|hmm)\b,?\s*/gi, "")
    .replace(/\b(kind of|sort of|you know|you know what i mean)\b,?\s*/gi, "")
    .replace(/\s{2,}/g, " ");
}

function removeConversationalLeadIns(input) {
  return input
    .replace(/^\s*((also|and)\s+)?(yeah|yep|okay|ok|right|so|well)\b[,\s]*/gi, "")
    .replace(/^\s*(also|and)\b[,\s]+/gi, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function removeRepeatedWords(input) {
  let previous = "";
  const output = [];
  for (const word of input.split(" ")) {
    const normalized = tokenKey(word);
    if (normalized !== previous || !normalized) {
      output.push(word);
    }
    previous = normalized;
  }
  return output.join(" ");
}

function collapseRepeatedClauseRevisions(input) {
  const words = input.split(" ");
  if (words.length < 8) {
    return input;
  }

  for (let split = 2; split < words.length - 2 && split <= 24; split += 1) {
    const left = words.slice(0, split);
    const right = words.slice(split);
    if (right.length < 4 || left.length > 24) {
      continue;
    }
    if (tokenKey(left[0]) !== tokenKey(right[0]) || tokenKey(left[1]) !== tokenKey(right[1])) {
      continue;
    }
    if (revisionSimilarity(left, right.slice(0, left.length)) >= 0.72) {
      return right.join(" ");
    }
  }

  return input;
}

function revisionSimilarity(left, right) {
  if (!left.length || !right.length) {
    return 0;
  }

  const counts = new Map();
  for (const word of right) {
    const key = tokenKey(word);
    if (key) {
      counts.set(key, (counts.get(key) || 0) + 1);
    }
  }

  let shared = 0;
  for (const word of left) {
    const key = tokenKey(word);
    const count = counts.get(key) || 0;
    if (count > 0) {
      shared += 1;
      counts.set(key, count - 1);
    }
  }
  return shared / Math.max(left.length, right.length);
}

function tokenKey(input) {
  return String(input || "").toLowerCase().replace(/^[^a-z0-9]+|[^a-z0-9]+$/gi, "");
}

function applyStyle(style, input) {
  switch (style) {
    case TransformStyle.verbatim:
      return input.trim();
    case TransformStyle.professional:
      return makeProfessional(input);
    case TransformStyle.casual:
      return makeCasual(input);
    case TransformStyle.list:
      return makeList(input);
    case TransformStyle.clean:
    default:
      return finishSentence(capitalizeSentences(input));
  }
}

function capitalizeSentences(input) {
  let output = "";
  let shouldCapitalize = true;
  for (const character of input) {
    if (shouldCapitalize && /\p{L}/u.test(character)) {
      output += character.toUpperCase();
      shouldCapitalize = false;
      continue;
    }
    output += character;
    if (".!?\n".includes(character)) {
      shouldCapitalize = true;
    } else if (!/\s/.test(character)) {
      shouldCapitalize = false;
    }
  }
  return output;
}

function finishSentence(input) {
  const trimmed = input.trim();
  if (!trimmed) {
    return trimmed;
  }
  const last = trimmed.at(-1);
  if (".!?:;)]}".includes(last) || trimmed.includes("\n")) {
    return trimmed;
  }
  return trimmed + (looksLikeQuestion(trimmed) ? "?" : ".");
}

function looksLikeQuestion(input) {
  const firstWord = input.toLowerCase().split(/[^a-z]+/).find(Boolean);
  return new Set([
    "who", "what", "when", "where", "why", "how",
    "is", "are", "am", "was", "were",
    "do", "does", "did",
    "can", "could", "will", "would", "should",
    "has", "have", "had"
  ]).has(firstWord);
}

function makeProfessional(input) {
  return finishSentence(
    capitalizeSentences(input)
      .replace(/\bhey\b/gi, "Hello")
      .replace(/\bthanks\b/gi, "Thank you")
      .replace(/\bi think\b/gi, "I think")
  );
}

function makeCasual(input) {
  return finishSentence(capitalizeSentences(input).replace(/\bhello\b/gi, "Hey"));
}

function makeList(input) {
  const pieces = input
    .replace(/ and then /gi, ". ")
    .replace(/ then /gi, ". ")
    .split(/[.;\n]/)
    .map(normalizeWhitespace)
    .filter(Boolean);
  if (!pieces.length) {
    return input;
  }
  return pieces.map((piece) => `- ${capitalizeFirst(piece)}`).join("\n");
}

function capitalizeFirst(input) {
  return input ? input[0].toUpperCase() + input.slice(1) : input;
}

function escapeRegExp(input) {
  return String(input).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

module.exports = {
  TransformStyle,
  processText
};
