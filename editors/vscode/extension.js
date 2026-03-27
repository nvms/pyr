const { LanguageClient, TransportKind } = require("vscode-languageclient/node");
const vscode = require("vscode");

let client;
let outputChannel;

function activate(context) {
  outputChannel = vscode.window.createOutputChannel("pyr");
  outputChannel.appendLine("pyr extension activating");

  const config = vscode.workspace.getConfiguration("pyr.lsp");
  const enabled = config.get("enabled", true);
  if (!enabled) {
    outputChannel.appendLine("LSP disabled via settings");
    return;
  }

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
  };

  client = new LanguageClient("pyr", "pyr language server", serverOptions, clientOptions);
  client.start().then(
    () => outputChannel.appendLine("LSP client started"),
    (err) => outputChannel.appendLine(`LSP client failed to start: ${err}`),
  );
}

function deactivate() {
  if (client) return client.stop();
}

module.exports = { activate, deactivate };
