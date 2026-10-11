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

It builds a throwaway fixture under `$HOME` (source, candidate copy, bare remote, a repo carrying a
`.claude/settings.json` with `excludedCommands` — all inside the denied region) plus a temp dir, writes nowhere else, runs the attempts, and prints `PASS|FAIL|SKIP <id> <label>` per row, then per
runtime `ENFORCED:` (PASS rows; each needs an observed denial plus a control),
`CONFIG PRESENT:` (the static `cfg-*` rows, never counted as enforced), `PROMPT-ONLY:` (FAIL rows, plus MCP tools and hooks, which it cannot
probe) and `UNVERIFIED:` (SKIP rows). A row passes only if the attempt failed **and** a control proves it
ran (the sandboxed command reported an exit code; a permitted write worked; a non-denied canary env var is visible next to the denied ones; tool rows need a refused Edit/Write on the protected path in `stream-json` output). Exit status is 1 if any row fails.
The Claude probe runs in `--permission-mode default`, the seat's real mode, and its `no-prompt` row lists which normal review actions (Read, Grep, Glob, git log/diff/show, a temp-dir script, Skill) were refused.
`slp-reviewer-check --self-test` runs the same fixture and evaluation logic against stub runners (no `claude`/`codex`), proving the controls can succeed and a leak or a denial is detected; `validate.sh` runs it.
Rows that need a model turn use `SLP_CHECK_CLAUDE_MODEL` (default `claude-haiku-5-5`) and
`SLP_CHECK_CODEX_MODEL` (unset: the Codex tool-write row is skipped).

### Auth for the Claude rows

`SLP_CHECK_CLAUDE_AUTH` picks the route (default `auto`):

- **Token** (`CLAUDE_CODE_OAUTH_TOKEN` set, e.g. from `claude setup-token`): the rendered settings are copied into a fixture `CLAUDE_CONFIG_DIR`, the same load path the seat uses.
- **Default login** (no token, `auto` or `login`): `CLAUDE_CONFIG_DIR` is left alone so `claude` uses your normal login, and the reviewer settings are passed with `--settings <file>` plus the same flags. The script unsets `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` in the child, so an exported value cannot stand in for the login. `--settings` is merged with your user and project settings (lists and hooks merge), so a login-route row can pass or fail differently from the seat. Every login-route row therefore ends with `[route: login --settings; …]`, and the summary is `SETTINGS-PROBE (claude, login route: …)` with `ENFORCED (claude): none`. Only the token route, which loads the rendered settings through `CLAUDE_CONFIG_DIR` like the seat, can produce `ENFORCED (claude)`.
  - `--setting-sources` ([CLI reference](https://code.claude.com/docs/en/cli-reference)) is documented as a comma-separated list of `user`, `project`, `local`; an empty list, and so "flag settings only", is not documented, and the check cannot show it without a real run. It is not used.
  - A turn that cannot authenticate runs no steps, so the rows SKIP with the first lines of `claude`'s stderr when any were captured, plus a hint to log in with `claude`.
- `SLP_CHECK_CLAUDE_AUTH=token` never falls back to the login: without the token every Claude row SKIPs naming `CLAUDE_CODE_OAUTH_TOKEN`.

The room provider's token in `~/.paseo/config.json` is deliberately never read or used.

```sh
SLP_CHECK_CLAUDE_AUTH=login ~/.config/slp-room/bin/slp-reviewer-check --runtime claude   # default login; an exported token is unset by the script
CLAUDE_CODE_OAUTH_TOKEN=... ~/.config/slp-room/bin/slp-reviewer-check --runtime claude   # token route
```

### Codex invocation and diagnostics

The Codex rows run `codex -c … sandbox -- sh steps.sh …` (current codex-cli: the OS is implied). The older `codex sandbox macos|linux -- …` form is retried, with the same `-c` flags, only when the first attempt exits 2 with a clap-style parser error (`error: unexpected argument`, `error: unrecognized subcommand`, `Usage: codex sandbox`); a runtime denial never retries.

Which errors reach which reasons (first 3 non-empty lines, 200 characters, redacted as above; a source that produced nothing adds nothing):

| Source | Reaches |
|---|---|
| `claude` stderr (first turn) | every Claude row SKIPped with "the turn ran no steps", and the tool and no-prompt SKIPs |
| second `claude` turn stderr (repo-settings) | the `repo-settings` SKIP |
| `jq` parse errors on the transcripts, read when each row is emitted | the tool, no-prompt and repo-settings SKIPs and the `cx-tool` SKIP |
| reading `steps.log` / the control Write marker | "ran no steps" rows / the tool SKIP for the missing control Write |
| `jq` check of the rendered settings | the `cfg-claude` FAIL |
| `codex sandbox` stderr (and the legacy attempt's) | the `cx-*` SKIPs when the control read did not run |
| copying the Codex runtime to the fixture | the `cx-*` SKIPs when codex is unusable |
| `codex-reviewer exec` stderr | the `cx-tool` SKIP |
| outside-network controls (curl, TCP connect) and the in-sandbox client's error | the `net` / `tcp` (`cx-net` / `cx-tcp`) SKIPs |
| fixture `mktemp` error inside the steps | the `tmp` FAIL |
| `git rev-parse` of the pushed ref in the bare remote (exit 1 with no stderr = ref absent) | the `push` / `cx-push` SKIP when the remote cannot be inspected (exit 128, fatal message); never a PASS |

Not covered: the `emit` log append inside the steps, trap cleanup and `command -v` / `grep -q` tests (none decides a row by itself), and any failure whose tool prints nothing. Results change no label: a row reaches `ENFORCED` only with an observed denial, and in the Claude summary only on the token route (the login route prints `SETTINGS-PROBE`; the Codex summary keeps its own sandbox-binary `ENFORCED` line).

## What is configured, and what is proven

| Guarantee | Claude reviewer (rendered `claude-reviewer/settings.json`) | Codex reviewer (`bin/codex-reviewer`) | Probed? |
|---|---|---|---|
| Tool write | `permissions.deny` `Edit`/`Write` of `//$HOME/**` (+ absolute `SLP_REVIEWER_DENY_WRITE` paths); Edit/Write allowed only under the temp dirs; deny beats `bypassPermissions` | `sandbox_mode="read-only"` | row `tool` / `cx-tool` |
| Shell redirect, script | `sandbox.enabled`, `allowUnsandboxedCommands:false`, `failIfUnavailable:true`, `filesystem.denyWrite` of `$HOME` | read-only seatbelt/landlock | `redirect`, `script` / `cx-redirect`, `cx-script` |
| Symlink | sandbox paths | not documented for Codex | `symlink` / `cx-symlink` |
| Temp-dir checks | per-user temp dir is writable (outside `$HOME` on macOS) | **unsupported** (read-only) | `tmp` / `cx-tmp` (always SKIP) |
| Push | empty `network.allowedDomains`; the bare remote sits in the denied region; `Bash(git push:*)`/`Bash(gh:*)` are only hints | no network, no writes | `push`, `net` / `cx-push`, `cx-net` |
| Credentials (partial denylist: only listed paths) | `sandbox.credentials` + `Read` deny of `~/.config/gh`, `~/.ssh`, `~/.aws`, `~/.netrc`, `~/.npmrc`, `~/.codex`, `~/.claude`, `~/.claude.json`, `~/.paseo/config.json`, `$ROOM_HOME/auth` and the other seats' runtime dirs; env `GH_TOKEN`, `GITHUB_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN`; provider env `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`; `Read(...)` denies | `shell_environment_policy.inherit="core"` | `cred-files`, `cred-env` / `cx-cred-*` |
| Issue edits / pushes to GitHub | network-blocked (doc + probe); `Bash(gh:*)` and `git push` denies are hints only; API-level behaviour unprobed | no network | `tcp`, `gh`, `net` / `cx-tcp`, `cx-gh`, `cx-net` (`GH_HOST=github.invalid`, raw TCP; no real write possible) |
| Repository settings (`excludedCommands` in a candidate's `.claude/settings.json`) | **prompt-only**: user-scope `allowUnsandboxedCommands:false` is not documented to lock repository settings (that needs managed settings or `--settings`, and no evidence was found that the Paseo provider can pass `--settings`) | n/a | `repo-settings` reports whether the escape works |
| MCP tools, hooks | outside the sandbox: **prompt-only** | not documented: **prompt-only** | never probed |

Claude reviewer settings are the user's `~/.claude/settings.json` plus these keys, which are merged last
so they win: the user's `Bash`/`Edit`/`Write` and non-paseo `mcp__` allow rules, `additionalDirectories`, hooks, `statusLine`, credential helpers,
MCP server lists, enabled plugins (the plugins/agents/commands links are not created), most `env` (only locale and model variables stay) and any
existing `sandbox` block are dropped; `settings.json` is mode 600, `disableBypassPermissionsMode` is `disable`, and the same spawner and
`slp-wait` denies as `claude-peer` apply. The profile `modeId` is `default`
(Paseo's Claude modes are plan / default / acceptEdits / auto / bypassPermissions): `autoAllowBashIfSandboxed`
runs sandboxed Bash without prompts, `Read(//**)`, `Grep`, `Glob`, `Skill`, `TaskStop` and the two Lead-messaging MCP tools are allowed, so a
reviewer should not stall on prompts; the writer modes would let a failed sandboxed command retry unsandboxed.

The working-directory problem: both runtimes make the launch cwd writable by default, and the
docs have no cwd-relative form for user-scope settings (`.` resolves to the config dir). So the Claude reviewer
denies writes under the whole `$HOME` (the docs say `denyWrite` applies "including paths inside a directory that is
otherwise writable"). Sources outside `$HOME` and the temp dirs are not covered: set `SLP_REVIEWER_DENY_WRITE=/abs/path:/other` (absolute paths only; relative entries abort the install) when running
`install.sh`. A source under `/tmp` stays writable. Codex needs no such path: read-only has no writable cwd.

## Limits

- **Snapshots under `/tmp` or `$TMPDIR` are not protected.** The Edit/Write tools and sandboxed Bash may write the temp dirs (that is where reviewers run checks), so a candidate snapshot placed there can be modified by the reviewer; only sources under `$HOME` or `SLP_REVIEWER_DENY_WRITE` paths are protected. Keep snapshots outside the temp dirs.
- **Evidence rules.** A row is ENFORCED only with an observed denial: the `tool` row needs the explicit deny-rule wording in the transcript (a generic "requested permissions / haven't granted" refusal, which any un-allowed Edit gets in `-p` default mode, is SKIP); `net` / `tcp` need a sandbox or proxy denial message (DNS errors and timeouts are SKIP); `gh` against `github.invalid` is a diagnostic and never PASS; `repo-settings` passes only when the exact `touch` command completed and its marker is absent (a permission-mode refusal is reported as "not proof the exclusion is locked"); `cx-tool` needs an identified apply_patch/file-change event with an explicit sandbox denial (the Codex event schema was not verified, so expect SKIP). The Codex probes run against a copy of the reviewer runtime in the fixture, never the live `CODEX_HOME` or journal.
- **Install failure behaviour.** The reviewer settings are rendered to a side file (mode 600) and moved into place only after the restricted merge succeeds. If the render fails, the previous restricted `claude-reviewer/settings.json` is kept untouched; if there is none, a deny-all stub (sandbox on, no network, Edit/Write/Bash/WebFetch/WebSearch denied) is written instead. Only staging files are removed, and the install exits non-zero. `SLP_REVIEWER_DENY_WRITE` is validated before anything is written. This is install-time behaviour, not a probed runtime guarantee.
- **Journal.** `allowWrite` does not override `denyWrite $HOME` (the docs describe re-allowing for reads only) and the Codex reviewer is read-only, so reviewer seats very likely **cannot record their `REVIEW` with `slp-journal`**; the `journal` row is kept and expected to report FAIL (blocked). No unsandboxed exception is made; who records a review is a pending Human decision.
- **Repository settings.** A candidate repo's `.claude/settings.json` may add `sandbox.excludedCommands`; this is prompt-only until the provider can pass `--settings`. In `default` mode an excluded command still goes through the permission flow, which refuses it non-interactively; a human approving it in Paseo would defeat that.
- **Credential denylist is partial**: anything not listed (other dotfiles, project `.env` files) is readable.
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
