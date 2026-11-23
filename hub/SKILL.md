---
name: bluey-hub
description: "The user's notes and todos (Bluey Hub): read, add, edit, tick off or delete notes and todos; anything about 'my notes', 'my todos', 'my list', 'remind me to', 'note this down'."
---

# Bluey Hub: the user's notes and todos

The user keeps their **notes** and **todos** in Bluey Hub on this machine. The Bluey app on their iPhone and Mac
shows the same data live, so whatever you change here appears there within seconds. Always use the
`bluey-hub` command (it prints JSON), never edit the files by hand.

## Todos

```bash
bluey-hub todo list                 # open todos (and ones finished today); --all for everything
bluey-hub todo add "Call the dentist" --due 2026-11-21 [--list Work] [--notes "ask about Friday"]
bluey-hub todo done <id>            # tick off (undo: bluey-hub todo undo <id>)
bluey-hub todo edit <id> --title "…" --due 2026-11-22 | --due none | --list Home | --notes "…"
bluey-hub todo rm <id>
```

Dates are `YYYY-MM-DD` in the user's local time (Europe/Berlin). "Today" means due today. Lists are free-form
(default `Inbox`). When the user asks what's open, group by overdue / today / upcoming / no date. Keep the
user's ADHD-friendly rules: at most three main tasks a day, concrete first steps, never guilt-trip.

## Notes

```bash
bluey-hub note list                 # titles, previews, pinned first
bluey-hub note show <id>            # full text
bluey-hub note add $'Title\nBody…' [--pin]   # first line is the title (use $'…' for line breaks)
bluey-hub note append <id> "another line"
bluey-hub note edit <id> "whole new text"
bluey-hub note rm <id>
```

Notes are quick and plain like Raycast Notes: Markdown text, first line is the title. Prefer appending to an
existing note on the same topic over creating near-duplicates; search with `note list` first.

When you've changed something, say what in one short line ("Added 'Call the dentist' for Saturday.").
