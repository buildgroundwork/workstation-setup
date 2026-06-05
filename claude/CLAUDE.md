# Global preferences (Adam Milligan)

Standing, cross-project preferences for Adam. These apply on this machine regardless of working directory. Project-specific facts live in per-repo memory; this file is for behavioral rules that should always hold.

## Clipboard / shell

- **Copy to the clipboard with a direct heredoc into `pbcopy`**, never piped through `cat`/`echo`:

  ```
  pbcopy <<'EOF'
  ...content...
  EOF
  ```

  Not `cat <<'EOF' | pbcopy`. `pbcopy` already reads stdin; the pipe adds a useless process. Quote the delimiter (`'EOF'`) so `$`, backticks, etc. in the content aren't expanded.

- **Generalize this:** for any tool that reads stdin (`gh pr comment --body-file -`, `jq`, etc.), prefer a direct heredoc over `cat | tool`. Avoid the useless use of `cat`.

- **Don't re-`pbcopy` Adam's own edits.** When Adam pastes his edited version of something I drafted, the canonical copy already lives wherever he put it (Slack, a doc). Copying it back creates a stale duplicate. Treat the paste as "here's what I'm using" and respond to the substance of the edit. `pbcopy` is for *my* drafts he hasn't yet placed somewhere; once it's edited and placed, my copy adds nothing. If unsure whether he wants a draft copied, ask.

## Communication register (Slack, doc comments, PR replies)

- **Don't open replies to peers with "Thanks [Name], that's helpful"** or similar personalized acknowledgments. It performs deferential relationship-management that isn't load-bearing — the substantive follow-up already signals collaboration. Default to a neutral acknowledgment ("Okay, that's helpful." / "Got it." / "Makes sense.") instead. Reserve "Thanks [Name]" for when the gratitude is the actual point (the person did real work, went out of their way).

  This matters most when Adam is the lower-titled person in the exchange (IC → PE, L5 → L7): the deferential opener reinforces the title gap rather than flattening it, and undercuts a position he's defending.

- **Watch the related deferential tics:** "Asking because…", "Just wanted to understand…", "To make sure I understand…". Same shape. Default to declarative forms ("I ask because…", or just state the reason) unless genuine uncertainty or gratitude is the point.
