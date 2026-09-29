# Skill Garden

Claude Code plugins that are still growing. A skill often starts inside the
project that needed it, before it is big enough to be worth a repository of its
own. This is where such skills live in the meantime, side by side, and they
graduate out when they are ready.

## Install

```
/plugin marketplace add ichabodcole/skill-garden
/plugin install <plugin>@skill-garden
```

## Plugins

| Plugin         | What it does                                                                              | Needs                                                                     |
| -------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `operator`     | Authenticate to Operator and triage its documents into a project's docs                   | An Operator account and API key                                           |
| `recipes`      | Opinionated implementation recipes for specific stack patterns, and a skill to write them | Nothing extra                                                             |
| `toolbox`      | Interactive HTML mockups, Maestro mobile testing, screenshot optimisation                 | Nothing extra; the Maestro skill uses the Maestro CLI                     |
| `agent-bridge` | Join an Agent Bridge for cross-project knowledge sharing between agents                   | The Agent Bridge MCP server and desktop app                               |
| `hivemind`     | Capture, consult, digest and give feedback to a cross-project knowledge base              | Operator and a HiveMind workspace; signs in through the `operator` plugin |

Each plugin's own `README.md` or skill files say more.

## History

These plugins started in
[project-docs-scaffold-template](https://github.com/ichabodcole/project-docs-scaffold-template)
and were copied here on 2026-09-29, from its commit `ece3a03`. Their earlier
history is there.
