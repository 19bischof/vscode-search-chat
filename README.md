# Cursor Chat Search

Search your Cursor chat history from the command palette.

## Usage

Open the command palette and run **Search Cursor Chats...**.

Type your query and press Enter. Select a result to open the chat directly in Cursor.
The last query is pre-filled so you can repeat a search instantly.

## How it works

- Scans `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` for matching messages
- Reads `workspaceStorage` SQLite databases to resolve chat titles
- Falls back to the first user message as the title when no stored title exists
- All processing is local — no network requests

## Build

```bash
npm install
npm run build
```

This compiles the TypeScript and packages a `.vsix` file ready to install.
