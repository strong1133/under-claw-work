# Host context and persona templates

These files let different Agent hosts receive the same Under Claw Work identity
in their native context format.

| Host | Template | Intended target |
|---|---|---|
| Claude Code | `claude-code/CLAUDE.md` | workspace `CLAUDE.md` |
| Codex | `codex/AGENTS.md` | workspace `AGENTS.md` |
| Hermes | `hermes/AGENTS.md` | workspace `AGENTS.md` |
| Hermes persona | `hermes/SOUL.md` | `$HERMES_HOME/SOUL.md` |
| Gemini CLI | `gemini/GEMINI.md` | workspace `GEMINI.md` |
| GitHub Copilot | `copilot/copilot-instructions.md` | `.github/copilot-instructions.md` |
| Cursor | `cursor/under-claw-work.mdc` | `.cursor/rules/under-claw-work.mdc` |
| Generic model | `generic/SYSTEM.md` | system/developer context |

Copy or merge a template only when the user opts in. Never overwrite an
existing context or persona file automatically. The workspace's own safety and
development instructions take precedence over these explanatory defaults.
