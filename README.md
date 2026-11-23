# CCBR Ponytail skills installer

Install the [Ponytail](https://github.com/DietrichGebert/ponytail) Agent Skills
for VS Code GitHub Copilot, pinned to an upstream release. The default is
`v5.3.3`. This installer is independent of the Copilot CLI.[^ai]

## What is installed

The installer checks out the upstream repository under
`~/.claude/repos/ponytail` and creates managed links under `~/.claude/skills`
for `ponytail`, `ponytail-audit`, `ponytail-debt`, `ponytail-gain`,
`ponytail-help`, and `ponytail-review`. Each installation belongs to the home
directory where the installer runs: install separately on a laptop and on each
remote environment where VS Code runs the agent.

This is a **skills-only** installation. It does not install Ponytail's
lifecycle hooks, automatically activate Ponytail at session start, or guarantee
the plugin's persistent mode behavior. Invoke `/ponytail` or another installed
skill in a new VS Code Copilot session; the agent may also load skills when it
finds them relevant. Existing higher-priority instructions still apply.

## Install

Requirements: Bash, Git, GitHub network access, and write access to
`~/.claude`. No Python or Node.js is needed to install the skills.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/CCBR/vscode-ghcopilot-ponytail/main/install_ponytail.sh \
  | bash -s --
```

Or inspect and run the script from a checkout:

```bash
bash install_ponytail.sh
```

Installation does not modify the current project's `AGENTS.md` unless
`--agents-policy` is supplied.

## Versions and health

List upstream tags, install a particular tag, or roll back using the same
version flag:

```bash
bash install_ponytail.sh --list-versions
bash install_ponytail.sh --version v5.3.3
bash install_ponytail.sh --status
bash install_ponytail.sh --verify
```

When using the download command, place options after `bash -s --`, for example
`| bash -s -- --version v5.3.3`. Status and verify do not fetch or change
files; version listing queries the upstream repository.

The installer refuses to overwrite an existing unrelated skill, use a checkout
with local changes or an unexpected origin, or switch to an unavailable tag.
It only removes obsolete links that are recorded in its manifest and still
point to its own checkout. If a conflict occurs, inspect and back up your
existing files before resolving it; the installer does not remove them for you.

## Optional repository guidance

From anywhere inside a Git working tree:

```bash
bash install_ponytail.sh --agents-policy
```

This adds or refreshes a marked block in the repository root's `AGENTS.md`.
Existing text outside that block is retained. The block describes optional
skills-only use and does not install hooks or make Ponytail mandatory. Review
and commit project guidance only if your team wants to share it.

## Development and testing

The installer is Bash; the test suite uses Python 3.11 and local Git fixtures:

```bash
bash -n install_ponytail.sh
python3.11 -m unittest discover -s tests -v
```

For isolated tests or a trusted mirror, `CCBR_PONYTAIL_INSTALL_ROOT` overrides
`~/.claude`, and `CCBR_PONYTAIL_REPO_URL` overrides the upstream Git URL.
Only set the latter to a repository you trust: its contents become agent
instructions.

## Attribution

Ponytail is developed by Dietrich Gebert and contributors and distributed
under its [MIT license](https://github.com/DietrichGebert/ponytail/blob/v5.3.3/LICENSE).
The installer fetches the complete upstream checkout, including its license.

[^ai]: ⚡Generated using AI⚡
