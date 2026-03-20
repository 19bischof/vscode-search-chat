export interface MatchSnippet {
  index: number
  role: string
  snippet: string
}

export interface ChatSearchResult {
  chatId: string
  title: string
  project: string
  projectDir: string
  modified: string
  matchCount: number
  filePath: string
  snippets: MatchSnippet[]
  topSnippet: string
}

export interface ChatSearchRun {
  query: string
  totalMatches: number
  chatCount: number
  results: ChatSearchResult[]
}
