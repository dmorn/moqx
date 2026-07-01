# Triage labels

Each issue file under `.scratch/` carries a `Status:` line near the top (see
`issue-tracker.md`). Use one of these values:

| Status            | Meaning                                             |
| ----------------- | --------------------------------------------------- |
| `needs-triage`    | Not yet evaluated.                                  |
| `needs-info`      | Blocked waiting on more information.                |
| `ready-for-agent` | Fully specified; an AFK agent can implement it.     |
| `ready-for-human` | Needs a human (judgement call, access, or risk).    |
| `done`            | Implemented and verified.                           |
| `wontfix`         | Will not be actioned.                               |

Record follow-up work as a new issue rather than reopening a `done` one, and
append progress under a `## Comments` heading at the bottom of the file.
