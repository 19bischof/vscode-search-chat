#!/usr/bin/env bash
set -euo pipefail

CURSOR_PROJECTS_DIR="$HOME/.cursor/projects"

usage() {
    cat <<'EOF'
Search all Cursor agent chat history.

Usage:
    search-cursor-chats.sh <pattern> [options]

Arguments:
    <pattern>           Search term or regex pattern

Options:
    -i, --ignore-case   Case-insensitive search (default)
    -s, --case-sensitive Case-sensitive search
    -r, --role <role>    Filter by role: user | assistant
    -p, --project <str>  Filter by project directory name (substring match)
    -C, --context <n>    Show n surrounding messages for context (default: 0)
    -l, --list           List matching chats (titles only), don't show content
    -j, --json           Output machine-readable JSON
    --after <date>       Only chats modified after YYYY-MM-DD
    --before <date>      Only chats modified before YYYY-MM-DD
    -h, --help           Show this help

Examples:
    search-cursor-chats.sh "FortiGate"
    search-cursor-chats.sh "nat-source-vip" -r user
    search-cursor-chats.sh "docker" -p furniture --after 2025-03-01
    search-cursor-chats.sh "SNAT|DNAT" -C 1
    search-cursor-chats.sh "migration" --list
EOF
    exit 0
}

# Defaults
PATTERN=""
CASE_FLAG="-i"
ROLE_FILTER=""
PROJECT_FILTER=""
CONTEXT=0
LIST_ONLY=false
JSON_OUTPUT=false
AFTER_DATE=""
BEFORE_DATE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -i|--ignore-case) CASE_FLAG="-i"; shift ;;
        -s|--case-sensitive) CASE_FLAG=""; shift ;;
        -r|--role) ROLE_FILTER="$2"; shift 2 ;;
        -p|--project) PROJECT_FILTER="$2"; shift 2 ;;
        -C|--context) CONTEXT="$2"; shift 2 ;;
        -l|--list) LIST_ONLY=true; shift ;;
        -j|--json) JSON_OUTPUT=true; shift ;;
        --after) AFTER_DATE="$2"; shift 2 ;;
        --before) BEFORE_DATE="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) PATTERN="$1"; shift ;;
    esac
done

if [[ -z "$PATTERN" ]]; then
    echo "Error: search pattern required" >&2
    echo "Run with --help for usage" >&2
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 is required" >&2
    exit 1
fi

python3 - "$PATTERN" "$CASE_FLAG" "$ROLE_FILTER" "$PROJECT_FILTER" "$CONTEXT" "$LIST_ONLY" "$AFTER_DATE" "$BEFORE_DATE" "$CURSOR_PROJECTS_DIR" "$JSON_OUTPUT" <<'PYEOF'
import sys, os, json, re, glob, sqlite3
from datetime import datetime
from pathlib import Path

pattern_str = sys.argv[1]
case_flag = sys.argv[2]
role_filter = sys.argv[3]
project_filter = sys.argv[4]
context_count = int(sys.argv[5])
list_only = sys.argv[6] == "true"
after_date = sys.argv[7]
before_date = sys.argv[8]
cursor_projects_dir = sys.argv[9]
json_output = sys.argv[10] == "true"

def build_composer_title_index():
    """Build a dict of composerId -> title from all Cursor workspace DBs."""
    titles = {}
    workspace_storage = os.path.expanduser(
        "~/Library/Application Support/Cursor/User/workspaceStorage"
    )
    for db_path in glob.glob(os.path.join(workspace_storage, "*/state.vscdb")):
        try:
            con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
            row = con.execute(
                "SELECT value FROM ItemTable WHERE key = 'composer.composerData'"
            ).fetchone()
            con.close()
            if not row:
                continue
            data = json.loads(row[0])
            for c in data.get("allComposers", []):
                cid = c.get("composerId")
                name = c.get("name", "").strip()
                if cid and name:
                    titles[cid] = name
        except Exception:
            pass
    return titles

COMPOSER_TITLES = build_composer_title_index()

BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
RED = "\033[31m"
MAGENTA = "\033[35m"

re_flags = re.IGNORECASE if case_flag == "-i" else 0
try:
    compiled = re.compile(pattern_str, re_flags)
except re.error as e:
    print(f"Invalid regex pattern: {e}", file=sys.stderr)
    sys.exit(1)

after_ts = None
before_ts = None
if after_date:
    after_ts = datetime.strptime(after_date, "%Y-%m-%d").timestamp()
if before_date:
    before_ts = datetime.strptime(before_date, "%Y-%m-%d").timestamp()


def extract_project_name(project_dir_name):
    parts = project_dir_name.replace("-", "/").split("/")
    if len(parts) >= 3:
        return parts[-1]
    return project_dir_name


def make_snippet(text, pat):
    match = pat.search(text)
    if not match:
        return text[:260]
    start, end = match.span()
    context = 80
    snippet_start = max(0, start - context)
    snippet_end = min(len(text), end + context)
    snippet = text[snippet_start:snippet_end].replace("\n", " ").strip()
    prefix = "... " if snippet_start > 0 else ""
    suffix = " ..." if snippet_end < len(text) else ""
    return f"{prefix}{snippet}{suffix}"


def highlight_match(text, pat):
    def replacer(m):
        return f"{RED}{BOLD}{m.group()}{RESET}"
    return pat.sub(replacer, text)


def get_message_text(msg):
    content = msg.get("message", {}).get("content", [])
    texts = []
    for c in content:
        if c.get("type") == "text":
            raw = c.get("text", "")
            cleaned = re.sub(r"<user_query>\s*", "", raw)
            cleaned = re.sub(r"\s*</user_query>", "", cleaned)
            for tag in ("system_reminder", "attached_files", "task_notification",
                        "user_info", "git_status", "rules", "agent_transcripts",
                        "open_and_recently_viewed_files", "agent_skills",
                        "reproduction_steps", "mcp_file_system"):
                cleaned = re.sub(rf"<{tag}[^>]*>.*?</{tag}>", "", cleaned, flags=re.DOTALL)
            texts.append(cleaned.strip())
    return "\n".join(texts)


def first_user_message(messages):
    for m in messages:
        if m.get("role") == "user":
            text = get_message_text(m)
            if text:
                first_line = text.split("\n")[0][:120]
                return first_line
    return "(no user message)"


transcript_files = glob.glob(os.path.join(cursor_projects_dir, "*/agent-transcripts/*/*.jsonl"))

results = []

for fpath in transcript_files:
    project_dir = Path(fpath).parts[-4]

    if project_filter and project_filter.lower() not in project_dir.lower():
        continue

    mtime = os.path.getmtime(fpath)
    if after_ts and mtime < after_ts:
        continue
    if before_ts and mtime > before_ts:
        continue

    try:
        with open(fpath) as f:
            messages = [json.loads(line) for line in f if line.strip()]
    except (json.JSONDecodeError, IOError):
        continue

    chat_id = Path(fpath).stem
    modified = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
    project_name = extract_project_name(project_dir)

    matching_indices = []
    for i, msg in enumerate(messages):
        role = msg.get("role", "")
        if role_filter and role != role_filter:
            continue
        text = get_message_text(msg)
        if compiled.search(text):
            matching_indices.append(i)

    if matching_indices:
        title = COMPOSER_TITLES.get(chat_id) or first_user_message(messages)
        top_snippet = ""
        matches = []
        for match_index in matching_indices[:3]:
            msg = messages[match_index]
            text = get_message_text(msg)
            snippet = make_snippet(text, compiled) if text else ""
            if text and not top_snippet:
                top_snippet = snippet
            matches.append(
                {
                    "index": match_index,
                    "role": msg.get("role", ""),
                    "snippet": snippet,
                }
            )
        if not top_snippet:
            top_snippet = "(empty match)"

        results.append({
            "fpath": fpath,
            "chat_id": chat_id,
            "project_name": project_name,
            "project_dir": project_dir,
            "modified": modified,
            "mtime": mtime,
            "title": title,
            "matching_indices": matching_indices,
            "messages": messages,
            "match_count": len(matching_indices),
            "top_snippet": top_snippet,
            "matches": matches,
        })

results.sort(key=lambda r: r["mtime"], reverse=True)

if json_output:
    payload_results = [
        {
            "chatId": r["chat_id"],
            "title": r["title"],
            "project": r["project_name"],
            "projectDir": r["project_dir"],
            "modified": r["modified"],
            "matchCount": r["match_count"],
            "filePath": r["fpath"],
            "snippets": r["matches"],
            "topSnippet": r["top_snippet"],
        }
        for r in results
    ]
    print(
        json.dumps(
            {
                "query": pattern_str,
                "totalMatches": sum(r["match_count"] for r in results),
                "chatCount": len(results),
                "results": payload_results,
            }
        )
    )
    sys.exit(0)

if not results:
    print(f"\n  No matches for {BOLD}{pattern_str}{RESET}\n")
    sys.exit(0)

total_matches = sum(r["match_count"] for r in results)
print(f"\n{BOLD}{total_matches} match(es) across {len(results)} chat(s){RESET}\n")

for r in results:
    chat_id = r["chat_id"]
    project = r["project_name"]
    modified = r["modified"]
    title = r["title"]
    match_count = r["match_count"]

    print(f"{CYAN}{'─' * 80}{RESET}")
    print(f"  {BOLD}{title}{RESET}")
    print(f"  {DIM}Chat: {chat_id}  |  Project: {project}  |  Modified: {modified}  |  {match_count} match(es){RESET}")
    print(f"{CYAN}{'─' * 80}{RESET}")

    if list_only:
        continue

    messages = r["messages"]
    matching_indices = r["matching_indices"]

    indices_to_show = set()
    for idx in matching_indices:
        for offset in range(-context_count, context_count + 1):
            target = idx + offset
            if 0 <= target < len(messages):
                indices_to_show.add(target)

    sorted_indices = sorted(indices_to_show)
    prev_idx = -2

    for idx in sorted_indices:
        if idx > prev_idx + 1:
            print(f"  {DIM}...{RESET}")

        msg = messages[idx]
        role = msg.get("role", "?")
        text = get_message_text(msg)
        is_match = idx in matching_indices

        role_color = YELLOW if role == "user" else GREEN
        role_label = f"{role_color}{BOLD}{role.upper()}{RESET}"

        lines = text.split("\n")
        if len(lines) > 8 and not is_match:
            preview = "\n".join(lines[:4]) + f"\n  {DIM}... ({len(lines) - 4} more lines){RESET}"
        elif len(lines) > 20:
            match_line_indices = [li for li, l in enumerate(lines) if compiled.search(l)]
            if match_line_indices:
                first_ml = match_line_indices[0]
                start = max(0, first_ml - 3)
                end = min(len(lines), first_ml + 10)
                shown = lines[start:end]
                preview = ""
                if start > 0:
                    preview += f"  {DIM}... ({start} lines above){RESET}\n"
                preview += "\n".join(shown)
                if end < len(lines):
                    preview += f"\n  {DIM}... ({len(lines) - end} more lines){RESET}"
            else:
                preview = "\n".join(lines[:6]) + f"\n  {DIM}... ({len(lines) - 6} more lines){RESET}"
        else:
            preview = text

        if is_match:
            preview = highlight_match(preview, compiled)

        marker = f" {MAGENTA}<< match{RESET}" if is_match else ""
        print(f"\n  [{role_label}]{marker}")
        for line in preview.split("\n"):
            print(f"    {line}")

        prev_idx = idx

    print(f"  {DIM}...{RESET}\n")
PYEOF
