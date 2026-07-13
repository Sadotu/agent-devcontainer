# Shared Agent Skills

Repo-level skills shared by Claude Code and OpenAI Codex.

## Layout

```
.agents/skills/
  <skill-name>/
    SKILL.md        # required — the skill definition (frontmatter + instructions)
    references/     # optional supporting files
```

Every skill is a directory containing a `SKILL.md` with YAML frontmatter
(`name`, `description`) followed by the instructions the agent must follow.

Both instruction files (`CLAUDE.md`, `AGENTS.md` at the repo root) point
agents here. When a user invokes a skill by name, the agent reads
`.agents/skills/<name>/SKILL.md` and follows it exactly.

## Adding a skill

1. Create `.agents/skills/<kebab-case-name>/SKILL.md`.
2. Give it frontmatter: `name`, and a `description` starting with "Use when …".
3. Keep it self-contained — no absolute host paths, no secrets.

## Updating skills

Skills are plain files: edit `SKILL.md` and commit.

## Plugins (Superpowers, Caveman)

Installed automatically on every container start by `.devcontainer/setup-agents.sh`
— Claude Code gets both as real plugins (marketplace + install); Codex gets
superpowers via a renamed local marketplace (works around a reserved-name
collision) and caveman via the skill files already in this directory. See that
script for the exact commands.
