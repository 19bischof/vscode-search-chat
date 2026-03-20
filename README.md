# Cursor Chat Search extension

This extension adds Cursor/VS Code commands to search local chat history directly from
within the extension (no external shell script required).

## Features

- `Search Cursor Chats...` command
  - search term / regex
  - case sensitivity
  - role filter (`user`/`assistant`)
  - project filter
  - context size
  - optional date windows (`--after`, `--before`)
- preview matching chats in a quick-pick list
- open transcript file directly
- show a markdown snippet preview
- rerun last search via `Search Cursor Chats: Reopen Last 20 Results`
- copy the exact query metadata or open the raw transcript file as fallback

## Files

- Search runs internally in the extension code and reads from:
  - `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`
  - Cursor `workspaceStorage` composer metadata for chat titles (`composer.composerData`)
  - first user message content in each chat as a fallback title

## Build

```bash
cd tools/cursor-chat-search-extension
npm install
npm run build
```

Then open Cursor Extensions panel and load this extension folder in development mode.

## Permissions

- The extension reads `agent-transcripts` JSONL files from:
  `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`
- It also reads Cursor workspace metadata at:
  `~/Library/Application Support/Cursor/User/workspaceStorage/*/state.vscdb`
  to display stored chat titles when available.
- No network requests are made.
