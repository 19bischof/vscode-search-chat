import { ChatSearchRun, ChatSearchResult } from "./resultsProvider"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import { execFileSync } from "node:child_process"

export interface SearchCommandInput {
  query: string
}

const TAGS_TO_STRIP = [
  "system_reminder",
  "attached_files",
  "task_notification",
  "user_info",
  "git_status",
  "rules",
  "agent_transcripts",
  "open_and_recently_viewed_files",
  "agent_skills",
  "reproduction_steps",
  "mcp_file_system",
]

function getWorkspaceStorageDir(): string {
  const home = os.homedir()
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Application Support", "Cursor", "User", "workspaceStorage")
  }

  if (process.platform === "win32") {
    return path.join(home, "AppData", "Roaming", "Cursor", "User", "workspaceStorage")
  }

  return path.join(home, ".config", "Cursor", "User", "workspaceStorage")
}

function getCursorProjectsDir(): string {
  return path.join(os.homedir(), ".cursor", "projects")
}

function getProjectDirectory(fpath: string): string {
  return path.basename(path.dirname(path.dirname(path.dirname(fpath))))
}

function extractProjectName(projectDir: string): string {
  const parts = projectDir.replaceAll("-", "/").split("/")
  if (parts.length >= 3) {
    return parts.at(-1) ?? projectDir
  }

  return projectDir
}

function makeSnippet(text: string, pattern: RegExp): string {
  const match = pattern.exec(text)
  if (!match) {
    return text.slice(0, 260)
  }

  const start = match.index
  const end = match.index + match[0].length
  const context = 80
  const snippetStart = Math.max(0, start - context)
  const snippetEnd = Math.min(text.length, end + context)
  const snippet = text.slice(snippetStart, snippetEnd).replace(/\n/g, " ").trim()
  const prefix = snippetStart > 0 ? "... " : ""
  const suffix = snippetEnd < text.length ? " ..." : ""
  return `${prefix}${snippet}${suffix}`
}

function getMessageText(msg: Record<string, unknown>): string {
  const content = (msg.message as Record<string, unknown> | undefined)?.content
  if (!Array.isArray(content)) {
    return ""
  }

  const texts: string[] = []

  for (const c of content) {
    if (!c || typeof c !== "object") {
      continue
    }

    const block = c as Record<string, unknown>
    if (block.type !== "text") {
      continue
    }

    let cleaned = String(block.text ?? "")
    cleaned = cleaned.replace(/<user_query>\s*/g, "").replace(/\s*<\/user_query>/g, "")

    for (const tag of TAGS_TO_STRIP) {
      cleaned = cleaned.replace(new RegExp(`<${tag}[^>]*>[\\s\\S]*?<\\/${tag}>`, "g"), "")
    }

    const trimmed = cleaned.trim()
    if (trimmed) {
      texts.push(trimmed)
    }
  }

  return texts.join("\n")
}

function firstUserMessage(messages: Record<string, unknown>[]): string {
  for (const msg of messages) {
    if (msg.role !== "user") {
      continue
    }

    const text = getMessageText(msg)
    if (text) {
      return text.split("\n")[0].slice(0, 120)
    }
  }

  return "(no user message)"
}

// Cached lazily on first search — titles don't change during an editor session.
let composerTitleCache: Record<string, string> | undefined

function getComposerTitles(): Record<string, string> {
  if (composerTitleCache !== undefined) {
    return composerTitleCache
  }

  try {
    const script = `
import glob, json, os, sqlite3, sys
storage = sys.argv[1]
titles = {}
for db in glob.glob(os.path.join(storage, "*/state.vscdb")):
  try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    row = con.execute("SELECT value FROM ItemTable WHERE key='composer.composerData'").fetchone()
    con.close()
    if not row: continue
    for c in json.loads(row[0]).get("allComposers", []):
      cid = c.get("composerId")
      name = c.get("name", "").strip()
      if cid and name: titles[cid] = name
  except Exception: pass
print(json.dumps(titles))
`
    const stdout = execFileSync("python3", ["-c", script, getWorkspaceStorageDir()], {
      encoding: "utf8",
    })
    composerTitleCache = JSON.parse(stdout.trim() || "{}") as Record<string, string>
  } catch {
    composerTitleCache = {}
  }

  return composerTitleCache
}

function listTranscriptFiles(rootDir: string): string[] {
  const files: string[] = []
  if (!fs.existsSync(rootDir)) {
    return files
  }

  for (const projectEntry of fs.readdirSync(rootDir, { withFileTypes: true })) {
    if (!projectEntry.isDirectory()) {
      continue
    }

    const transcriptRoot = path.join(rootDir, projectEntry.name, "agent-transcripts")
    if (!fs.existsSync(transcriptRoot) || !fs.statSync(transcriptRoot).isDirectory()) {
      continue
    }

    for (const bucketEntry of fs.readdirSync(transcriptRoot, { withFileTypes: true })) {
      if (!bucketEntry.isDirectory()) {
        continue
      }

      const bucketPath = path.join(transcriptRoot, bucketEntry.name)
      for (const file of fs.readdirSync(bucketPath)) {
        if (file.endsWith(".jsonl")) {
          files.push(path.join(bucketPath, file))
        }
      }
    }
  }

  return files
}

export async function runSearch(input: SearchCommandInput): Promise<ChatSearchRun> {
  const escaped = input.query.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const pattern = new RegExp(escaped, "i")

  const composerTitles = getComposerTitles()
  const transcriptFiles = listTranscriptFiles(getCursorProjectsDir())
  const results: Array<ChatSearchResult & { mtime: number }> = []

  for (const fpath of transcriptFiles) {
    let messages: Record<string, unknown>[] = []
    try {
      messages = fs
        .readFileSync(fpath, "utf8")
        .split(/\r?\n/)
        .filter((line) => line.trim())
        .map((line) => JSON.parse(line) as Record<string, unknown>)
    } catch {
      continue
    }

    const matchingIndices: number[] = []
    for (const [index, msg] of messages.entries()) {
      if (pattern.test(getMessageText(msg))) {
        matchingIndices.push(index)
      }
    }

    if (matchingIndices.length === 0) {
      continue
    }

    const stat = fs.statSync(fpath)
    const chatId = path.basename(fpath, ".jsonl")
    const title = composerTitles[chatId] ?? firstUserMessage(messages)
    const projectDir = getProjectDirectory(fpath)

    // Use a fresh regex per snippet call to avoid stateful lastIndex issues
    const snippetPattern = new RegExp(pattern.source, pattern.flags)
    let topSnippet = ""
    const snippets = matchingIndices.slice(0, 3).map((idx) => {
      const text = getMessageText(messages[idx])
      const snippet = text ? makeSnippet(text, snippetPattern) : ""
      if (text && !topSnippet) {
        topSnippet = snippet
      }
      return { index: idx, role: String(messages[idx].role ?? ""), snippet }
    })

    results.push({
      chatId,
      title,
      project: extractProjectName(projectDir),
      projectDir,
      modified: new Date(stat.mtime).toISOString().slice(0, 16).replace("T", " "),
      matchCount: matchingIndices.length,
      filePath: fpath,
      snippets,
      topSnippet: topSnippet || "(empty match)",
      mtime: stat.mtimeMs,
    })
  }

  results.sort((a, b) => b.mtime - a.mtime)

  return {
    query: input.query,
    totalMatches: results.reduce((sum, r) => sum + r.matchCount, 0),
    chatCount: results.length,
    results: results.map(({ mtime: _, ...rest }) => rest),
  }
}
