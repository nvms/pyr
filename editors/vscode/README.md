# pyr for VS Code

Language support for the [pyr](https://github.com/nvms/pyr) programming language.

## Features

- Syntax highlighting for `.pyr` files
- Real-time diagnostics via the pyr language server (parser + semantic errors)
- String interpolation and escape sequence highlighting
- Auto-closing pairs and bracket matching
- Comment toggling (`Ctrl+/` / `Cmd+/`)
- Code folding

## Requirements

The `pyr` binary must be on your PATH (or configured via `pyr.lsp.path`). Build it from source:

```sh
cd /path/to/pyr
zig build
```

## Install from source

```sh
cd editors/vscode
npm install
npm install -g @vscode/vsce
vsce package
code --install-extension pyr-0.1.0.vsix
```

Or symlink for development:

```sh
ln -s $(pwd)/editors/vscode ~/.vscode/extensions/pyr
cd editors/vscode && npm install
```

Then reload VS Code.

## Configuration

- `pyr.lsp.path` - path to the pyr binary (default: `"pyr"`)
- `pyr.lsp.enabled` - enable/disable the language server (default: `true`)
