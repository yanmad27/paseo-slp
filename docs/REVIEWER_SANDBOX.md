# Reviewer sandbox

`Review peer` and `Codex review peer` run on their own providers, `claude-reviewer` and
`codex-reviewer`. `install.sh` renders runtimes that **attempt** to stop a reviewer from
writing the source, using the network, or using writer credentials. Nothing here is claimed
as enforced: every guarantee below is *doc-claimed* until `slp-reviewer-check` has probed it
on your machine, and the installer, CI and `validate.sh` never run those probes (a probe starts `claude` / `codex`).

## Run the self-check

```sh
~/.config/slp-room/bin/slp-reviewer-check              # both runtimes
~/.config/slp-room/bin/slp-reviewer-check --runtime codex
~/.config/slp-room/bin/slp-reviewer-check --dry-run    # prints the plan, starts nothing
```

It builds a throwaway repo under `$HOME` (source, candidate copy, bare remote — all inside
the denied region), runs the attempts, and prints `PASS|FAIL|SKIP <id> <label>` per row, then per
runtime `ENFORCED:` (PASS rows), `PROMPT-ONLY:` (FAIL rows, plus MCP tools and hooks, which it cannot
probe) and `UNVERIFIED:` (SKIP rows). A row passes only if the attempt failed **and** a control proves it
ran (the sandboxed command reported an exit code; a permitted write worked). Exit status is 1 if any row fails.
Rows that need a model turn use `SLP_CHECK_CLAUDE_MODEL` (default `claude-haiku-5-5`) and
`SLP_CHECK_CODEX_MODEL` (unset: the Codex tool-write row is skipped), and are skipped without a token.

## What is configured, and what is proven

| Guarantee | Claude reviewer (rendered `claude-reviewer/settings.json`) | Codex reviewer (`bin/codex-reviewer`) | Probed? |
|---|---|---|---|
| Tool write | `permissions.deny` `Edit(//$HOME/**)` (+ `SLP_REVIEWER_DENY_WRITE` paths); deny beats `bypassPermissions` | `sandbox_mode="read-only"` | row `tool` / `cx-tool` |
| Shell redirect, script | `sandbox.enabled`, `allowUnsandboxedCommands:false`, `failIfUnavailable:true`, `filesystem.denyWrite` of `$HOME` | read-only seatbelt/landlock | `redirect`, `script` / `cx-redirect`, `cx-script` |
| Symlink | sandbox paths | not documented for Codex | `symlink` / `cx-symlink` |
| Temp-dir checks | per-user temp dir is writable (outside `$HOME` on macOS) | **unsupported** (read-only) | `tmp` / `cx-tmp` (always SKIP) |
| Push | empty `network.allowedDomains`; the bare remote sits in the denied region; `Bash(git push:*)`/`Bash(gh:*)` are only hints | no network, no writes | `push`, `net` / `cx-push`, `cx-net` |
| Credentials | `sandbox.credentials` deny of `~/.config/gh`, `~/.ssh`, `~/.aws`, `~/.netrc`, `~/.codex`, `$ROOM_HOME/auth`; env `GH_TOKEN`, `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`; provider env `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`; `Read(...)` denies | `shell_environment_policy.inherit="core"` | `cred-files`, `cred-env` / `cx-cred-*` |
| MCP tools, hooks | outside the sandbox: **prompt-only** | not documented: **prompt-only** | never probed |

Claude reviewer settings are the user's `~/.claude/settings.json` plus these keys, which are merged last
so they win: the user's `Bash`/`Edit`/`Write` allow rules, `additionalDirectories`, `excludedCommands` and any
existing `sandbox` block are dropped, `disableBypassPermissionsMode` is `disable`, and the same spawner and
`slp-wait` denies as `claude-peer` apply. The profile `modeId` is `default`
(Paseo's Claude modes are plan / default / acceptEdits / auto / bypassPermissions): `autoAllowBashIfSandboxed`
runs sandboxed Bash without prompts, `Read(//**)` and the two Lead-messaging MCP tools are allowed, so a
reviewer should not stall on prompts; the writer modes would let a failed sandboxed command retry unsandboxed.

The working-directory problem: both runtimes make the launch cwd writable by default, and the
docs have no cwd-relative form for user-scope settings (`.` resolves to the config dir). So the Claude reviewer
denies writes under the whole `$HOME` (the docs say `denyWrite` applies "including paths inside a directory that is
otherwise writable") and allows only the room `state/` directory (for `slp-journal`; `journal` probes it).
Sources outside `$HOME` and `$TMPDIR` are not covered: set `SLP_REVIEWER_DENY_WRITE=/path:/other` when running
`install.sh`. Codex needs no such path: read-only has no writable cwd.

## Limits

- **Unverified until the self-check passes.** The docs claim these; no probe ran in CI or in this PR's development.
- **modeId mapping.** Paseo's Codex modes (`auto`, `auto-review`, `full-access`) may set sandbox flags that override the
  launcher's `-c`. The profile uses `auto`; whether `-c` wins is only visible through the `cx-*` rows, which call
  `codex sandbox` with the same `-c` flags and so do **not** test Paseo's mapping. Treat it as unknown.
- **Credentials.** The Codex reviewer shares the user's `auth.json` (no separate login is created) and read-only does not restrict reads, so
  `~/.config/gh` is readable there. The Claude reviewer's token is in its provider env.
- **MCP tools and hooks** run outside the Claude sandbox; Codex MCP behaviour is undocumented.
- **Claude Edit rules** use `//path` for absolute paths and the sandbox lists use `/path`; a wildcard in
  `denyWrite` has no effect on Linux. `failIfUnavailable` makes the seat fail to start instead of running unsandboxed.
- **Unsupported on Codex:** running checks in a temp workspace.
- The brief still says read-only; the sandbox is a second layer, not a replacement.
