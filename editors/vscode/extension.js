const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const vscode = require("vscode");

let client;
let outputChannel;
let freedType;
let movedType;
let conditionalFreeType;
let updateTimer;

const COLORS = {
  freed: "rgba(86, 182, 194, 0.7)",
  moved: "rgba(229, 192, 123, 0.8)",
  conditional_free: "rgba(209, 154, 102, 0.7)",
};

function activate(context) {
  outputChannel = vscode.window.createOutputChannel("pyr");
  outputChannel.appendLine("pyr extension activating");

  const config = vscode.workspace.getConfiguration("pyr.lsp");
  const enabled = config.get("enabled", true);
  if (!enabled) {
    outputChannel.appendLine("LSP disabled via settings");
    return;
  }

  freedType = vscode.window.createTextEditorDecorationType({});
  movedType = vscode.window.createTextEditorDecorationType({});
  conditionalFreeType = vscode.window.createTextEditorDecorationType({});

  const pyrPath = config.get("path", "pyr");
  outputChannel.appendLine(`using pyr binary: ${pyrPath}`);

  const serverOptions = {
    command: pyrPath,
    args: ["lsp"],
    transport: TransportKind.stdio,
  };

  const clientOptions = {
    documentSelector: [{ scheme: "file", language: "pyr" }],
    outputChannel,
    middleware: {
      provideInlayHints: () => [],
    },
  };

  client = new LanguageClient("pyr", "pyr language server", serverOptions, clientOptions);
  client.start().then(
    () => {
      outputChannel.appendLine("LSP client started");
      scheduleUpdate();
    },
    (err) => outputChannel.appendLine(`LSP client failed to start: ${err}`),
  );

  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(() => scheduleUpdate()),
    vscode.workspace.onDidChangeTextDocument((e) => {
      const editor = vscode.window.activeTextEditor;
      if (editor && e.document === editor.document) scheduleUpdate();
    }),
  );
}

function scheduleUpdate() {
  if (updateTimer) clearTimeout(updateTimer);
  updateTimer = setTimeout(() => updateDecorations(), 300);
}

async function updateDecorations() {
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document.languageId !== "pyr") return;
  if (!client || !client.isRunning()) return;

  const uri = editor.document.uri.toString();
  const range = {
    start: { line: 0, character: 0 },
    end: { line: editor.document.lineCount, character: 0 },
  };

  try {
    const hints = await client.sendRequest("textDocument/inlayHint", {
      textDocument: { uri },
      range,
    });

    if (!hints || !Array.isArray(hints)) {
      editor.setDecorations(freedType, []);
      editor.setDecorations(movedType, []);
      editor.setDecorations(conditionalFreeType, []);
      return;
    }

    const freed = [];
    const moved = [];
    const conditionalFree = [];

    const byLine = new Map();
    for (const hint of hints) {
      const line = hint.position.line;
      const kind = hint.data || "freed";
      if (!byLine.has(line)) byLine.set(line, []);
      byLine.get(line).push({ label: hint.label, kind });
    }

    for (const [line, entries] of byLine) {
      const lineEnd = editor.document.lineAt(line).range.end;
      const range = new vscode.Range(lineEnd, lineEnd);

      const grouped = { freed: [], moved: [], conditional_free: [] };
      for (const e of entries) {
        (grouped[e.kind] || grouped.freed).push(e.label);
      }

      for (const [kind, labels] of Object.entries(grouped)) {
        if (labels.length === 0) continue;
        const text = labels.join("  ");
        const dec = {
          range,
          renderOptions: {
            after: {
              contentText: `  ${text}`,
              color: COLORS[kind],
              fontStyle: "italic",
            },
          },
        };
        if (kind === "freed") freed.push(dec);
        else if (kind === "moved") moved.push(dec);
        else conditionalFree.push(dec);
      }
    }

    editor.setDecorations(freedType, freed);
    editor.setDecorations(movedType, moved);
    editor.setDecorations(conditionalFreeType, conditionalFree);
  } catch (err) {
    outputChannel.appendLine(`decoration update failed: ${err}`);
  }
}

function deactivate() {
  if (client) return client.stop();
}

module.exports = { activate, deactivate };
