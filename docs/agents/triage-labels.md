# Triage labels

Mapping between the canonical `/triage` skill roles and the actual GitHub labels used in this repo.

## Category roles (one per issue)

| Role | Label | Meaning |
|------|-------|---------|
| `bug` | `bug` | Something is broken |
| `enhancement` | `enhancement` | New feature or improvement |

## State roles (one per issue)

| Role | Label | Meaning |
|------|-------|---------|
| `needs-triage` | `needs-triage` | Maintainer needs to evaluate |
| `needs-info` | `needs-info` | Waiting on reporter for more information |
| `ready-for-agent` | `ready-for-agent` | Fully specified, ready for an AFK agent |
| `ready-for-human` | `ready-for-human` | Needs human implementation |
| `wontfix` | `wontfix` | Will not be actioned |

## Conventions

- Every triaged issue carries exactly one category role and one state role.
- Unlabeled issues go to `needs-triage` first; from there to `needs-info`, `ready-for-agent`, `ready-for-human`, or `wontfix`.
- `needs-info` returns to `needs-triage` once the reporter replies.
- Other labels (`documentation`, `duplicate`, `good first issue`, `help wanted`, `invalid`, `question`) are informational and not part of the triage state machine.
