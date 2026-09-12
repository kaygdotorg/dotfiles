---
name: harness-web-search
description: Run a narrowly scoped web search through the Codex or Claude CLI when the built-in search needs a second source. Keep the invocation read-only, ephemeral, and attached to the current terminal.
---

# Harness Web Search

Use a coding-agent CLI only as a web-retrieval client. Ask for source URLs and
keep the question specific enough that the result can be checked quickly.

## Check what exists

Availability differs by host, so probe before dispatching:

```bash
for c in codex claude agy; do
  command -v "$c" >/dev/null 2>&1 && printf '%s\n' "$c ok"
done
```

The supported examples below were checked against the local CLI help. Codex is
constrained to an ephemeral read-only run, while Claude is constrained to its
web-tool allowlist; both prompts prohibit local tools.

## Codex

Codex has a first-class live-search switch. Run it with a read-only sandbox,
no approval prompts, and no persisted session state:

```bash
query='<question>'
prompt="Use only the live web search tool. Do not read or modify local files, run shell commands, or call other tools. Answer with one line per finding and include the source URL for each. Question: ${query}"
codex --search --ask-for-approval never exec \
  --ephemeral \
  --sandbox read-only \
  "$prompt"
```

Add `--output-last-message "$output"` after `--sandbox read-only` when the
final answer needs to be captured in a file. Keep that file in a temporary
directory and inspect it after the attached command exits.

## Claude

Claude's tool allowlist can expose only its built-in web retrieval tools. Plan
mode and disabled session persistence keep the request read-only and
non-resumable:

```bash
query='<question>'
prompt="Use only WebSearch and WebFetch. Do not read or modify local files, run shell commands, or call other tools. Answer with one line per finding and include the source URL for each. Question: ${query}"
claude --bare \
  --no-session-persistence \
  --permission-mode plan \
  --tools WebSearch,WebFetch \
  --print \
  "$prompt"
```

Antigravity (`agy`) is not included until its installed version documents a
read-only web-tool allowlist in `agy --help`. Do not substitute a generic
permission-bypass flag for that allowlist.

Run searches one at a time, or in separately supervised terminal sessions if
parallel results are useful. Keep each process attached so failures and
permission errors are visible; do not use `nohup`, `&`, or a background-agent
mode for a simple lookup.

## Rules

1. Put the question and the requested answer shape in the prompt.
2. Require source URLs, then open the relevant sources and verify load-bearing
   claims yourself.
3. Treat a missing CLI, a tool-permission error, or an empty final answer as an
   unavailable searcher and continue with the other supported invocation.
4. Ignore transport noise only after confirming that a usable final answer and
   source URLs were returned.

## Cost

Each call spends the vendor's tokens. Ask only the question needed for the
current claim and stop once the relevant primary sources are found.

## When this beats built-in search

- The built-in search returned nothing usable.
- A load-bearing claim needs corroboration from an independent searcher.
- The question requires an agent to read and reconcile a small number of
  source pages rather than return a list of search hits.
