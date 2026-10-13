# cc-subagent-statusline

Per-subagent rows in Claude Code's **subagent status line**: see each subagent's type, name, model, effort, context usage, estimated cost, elapsed time, and edit count — color-coded, updated live.

```text
✓ explore · auth flow research · Sonnet 5.5 · medium · 42% · $0.18 · 3m12s · ✎7
✓ general · fix flaky test · Haiku 5.5 · low · 61% · $0.05 · 1m40s · ✎2
```

Rows render one per visible subagent while subagents run.

## Install

### From the marketplace (recommended)

```bash
claude plugin marketplace add daniel-morales-dev/cc-subagent-statusline
claude plugin install cc-subagent-statusline@cc-subagent-statusline
```

The plugin ships a `settings.json` with a `subagentStatusLine` command pointing at the bundled script; Claude Code applies it while the plugin is enabled. If you installed from your shell with a session open, run `/reload-plugins` there.

### Try it without installing

```bash
claude --plugin-dir /path/to/cc-subagent-statusline
```

### Manual install (no plugin)

Point your own settings at the script:

```json
{
  "subagentStatusLine": {
    "type": "command",
    "command": "bash \"/path/to/cc-subagent-statusline/scripts/subagent-statusline.sh\""
  }
}
```

## Requirements

- Claude Code with `subagentStatusLine` support
- `bash` and [`jq`](https://jqlang.org/)

## What each row shows

```text
<status> <type> · <name> · <Model> · <effort> · <ctx%> · $<cost> · <elapsed> · ✎<edits>
```

- **status** — `✓` completed (green), `✕` failed (red), nothing while running
- **type / name** — the subagent type and its task description
- **Model** — the model the subagent runs on
- **effort** — reasoning effort level
- **ctx%** — context window used, colored as it grows
- **$** — estimated cost from transcript token usage at published rates (see below)
- **elapsed** — wall-clock time, `3m12s` / `1h02m`
- **✎edits** — number of file edits the subagent made

## Cost estimation

Cost is an **estimate** computed from the subagent transcript's token usage at published per-MTok rates, including cache reads and writes, with a 5x long-context tier for Haiku above 100k-token prompts:

| Model family | input | output | cache read | cache write |
| --- | --- | --- | --- | --- |
| Haiku 5.5 | $0.10 | $0.50 | $0.01 | $0.125 |
| Sonnet 5.5 | $2 | $10 | $0.20 | $2.50 |
| Opus 5.5 | $4 | $20 | $0.20 | $5 |

Treat it as a directional estimate, not your bill.

## How it works

Claude Code calls the script for the subagent panel, sending session JSON on stdin (`session_id`, `transcript_path`, `tasks[]`). The script reads each task, finds the matching subagent transcript (`agent-*.jsonl` plus its `agent-*.meta.json`), computes cost and edits, caches per-transcript results in `/tmp/cc-subagent-statusline-v2.d`, and prints one JSON row per subagent.

## Development

```bash
claude plugin validate .
claude --plugin-dir .
```

## License

MIT
