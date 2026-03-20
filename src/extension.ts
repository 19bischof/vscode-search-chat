import * as vscode from "vscode"
import { ChatSearchResult } from "./resultsProvider"
import { runSearch } from "./search"

interface LastSearchState {
  query: string
}

interface QuickPickChatItem extends vscode.QuickPickItem {
  itemKind: "result"
  result: ChatSearchResult
}

const STATE_KEY = "cursorChatSearch.last"

function pluralMatches(count: number): string {
  return count === 1 ? "1 match" : `${count} matches`
}

async function tryOpenChatInCursor(chatId: string): Promise<boolean> {
  // composer.openComposer is an internal Cursor command for opening a chat by ID.
  // Discovered by inspecting Cursor's compiled workbench bundle.
  try {
    await vscode.commands.executeCommand("composer.openComposer", chatId, { view: "pane" })
    return true
  } catch {
    return false
  }
}

async function openResult(result: ChatSearchResult): Promise<void> {
  if (await tryOpenChatInCursor(result.chatId)) {
    return
  }

  // Fallback: open the raw transcript file in the editor.
  try {
    const doc = await vscode.workspace.openTextDocument(vscode.Uri.file(result.filePath))
    await vscode.window.showTextDocument(doc)
  } catch {
    void vscode.window.showErrorMessage(`Could not open transcript: ${result.filePath}`)
  }
}

function makeResultItems(results: ChatSearchResult[]): QuickPickChatItem[] {
  return results.map((result) => ({
    itemKind: "result" as const,
    label: `[${result.project}] ${result.title}`,
    detail: `${pluralMatches(result.matchCount)} · ${result.modified}`,
    description: result.topSnippet,
    result,
  }))
}

function showResultsQuickPick(query: string, results: ChatSearchResult[]): void {
  const quickPick = vscode.window.createQuickPick<QuickPickChatItem>()
  quickPick.title = `Cursor Chats · ${query}`
  quickPick.placeholder = "Enter to open chat"
  quickPick.matchOnDescription = true
  quickPick.matchOnDetail = true
  quickPick.items = makeResultItems(results)

  quickPick.onDidAccept(async () => {
    const selection = quickPick.selectedItems[0]
    if (!selection) {
      return
    }
    quickPick.hide()
    await openResult(selection.result)
  })

  quickPick.onDidHide(() => quickPick.dispose())
  quickPick.show()
}

export async function activate(context: vscode.ExtensionContext) {
  const searchCommand = vscode.commands.registerCommand("cursorChatSearch.search", async () => {
    const previousQuery = context.globalState.get<LastSearchState>(STATE_KEY)?.query

    const query = await vscode.window.showInputBox({
      title: "Search Cursor chat history",
      value: previousQuery,
      placeHolder: "Search text",
      prompt: "Type a query and press Enter",
    })

    if (!query?.trim()) {
      return
    }

    const trimmedQuery = query.trim()

    try {
      const run = await vscode.window.withProgress(
        {
          location: vscode.ProgressLocation.Notification,
          title: `Searching chats for "${trimmedQuery}"`,
        },
        () => runSearch({ query: trimmedQuery })
      )

      await context.globalState.update(STATE_KEY, { query: trimmedQuery } satisfies LastSearchState)

      if (!run.results.length) {
        void vscode.window.showInformationMessage(`No chats found for "${trimmedQuery}"`)
        return
      }

      showResultsQuickPick(trimmedQuery, run.results)
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error"
      void vscode.window.showErrorMessage(`Search failed: ${message}`)
    }
  })

  context.subscriptions.push(searchCommand)
}

export function deactivate() {}
