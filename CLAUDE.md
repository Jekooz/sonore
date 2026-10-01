# Operating Rules — read before every task

These rules apply to every milestone, every worker agent, every session. They override
convenience. If you cannot follow one of them for a specific step, stop and say why instead
of skipping it silently.

## 1. Never claim something works without proof in the same message

"Verified", "confirmed", "should work now", "ready for testing" are banned unless followed
immediately by the actual command you ran and its actual output, pasted in full.

- Wrong: "I've verified the endpoint returns the correct data."
- Right: "Ran `curl http://localhost:8000/auth/status` → output: `{"logged_in": true}`"

If you did not run it, say "not yet tested" — do not imply that you tested it.

## 2. Match commands to the actual shell

Before running any shell command, confirm which shell you are in. `Select-String`,
`Get-Content`, `$env:VAR` are PowerShell only. `grep`, `cat`, `$VAR` are Bash/POSIX only.
If a command fails with "command not found", that means you used the wrong shell's syntax —
fix it and rerun in the SAME turn. Never report a task done when the verification command
itself errored out.

## 3. Test through the real code path, not a stand-in

Do not write throwaway scripts (`test_auth.py`, `debug_x.py`, etc.) that reimplement or
shortcut what the actual server/app already does. Test by calling the real endpoint, the
real UI flow, the real function the frontend/user will actually use. If a temporary script
is genuinely necessary to isolate a bug, say so explicitly, delete it once done, and never
use its output as proof that the real path works.

## 4. Silent edit failures are stop conditions, not skip conditions

If a file edit fails ("Error editing file", a patch doesn't apply, etc.), do not move on to
other files and summarize as if things are fine. Stop, report the failure, show the current
actual content of the file in question, and resolve it before continuing.

## 5. No mocks, stubs, or placeholders unless explicitly told this step allows them

Every feature must be built against the real library/API/service, using the real methods
that exist in the installed version. If you are not sure a method name or class exists in
the installed version, check it (read the installed package source, or run
`pip show <pkg>` + inspect it) before writing code that calls it.

## 6. State your evidence checklist before saying a milestone is done

For each milestone, list the specific checkpoint(s) defined for it in PROJECT_CONTEXT.md.
For each one, either show the command + output proving it passes, or say explicitly which
ones are unverified and need the human to test manually (e.g. anything requiring a real
Google login, a real UI click, a real external service). Never mark a milestone complete
with unverified checkpoints folded silently into "ready for testing."

## 7. One file, one purpose

Never create a second, parallel version of a file that already has a canonical location
(e.g. don't invent a new auth flow in a test script while the real one lives in
`services/ytmusic_client.py`). If you need to change behavior, change it in the real file.

## 8. Reviewer agent must re-check against PROJECT_CONTEXT.md, not against the diff alone

When acting as reviewer, don't just check "does this diff do what it claims" — check it
against the milestone's actual written checkpoint and the non-negotiables in
PROJECT_CONTEXT.md. If a claimed fix touches a file other than the one the bug was in,
flag that as unresolved.

## 9. When blocked on something only the human can do

Say so plainly and stop there — don't simulate it, don't skip it and report success anyway.
Example: "This requires a real Google account approving the device code in a browser. I
cannot do this step. Please run: [exact steps]. Paste the output back and I'll continue."
