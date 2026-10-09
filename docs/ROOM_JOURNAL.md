# Room journal (`slp-journal`)

`slp-journal` is a stdlib-only Python (>= 3.9) helper that gives the room a versioned message
envelope and an append-only, durable, concurrency-safe journal. It is a helper capability only:
`PROTOCOL.md`, `SKILL.md` and the role prompts do not call it yet, and Paseo delivery is not wired
to it. Signal text is unchanged (compatibility: the envelope carries the existing tokens verbatim).
"room-state" still means the Supervisor's 🕒 block; the journal is unrelated to it.

Installed to `$HOME/.config/slp-room/bin/slp-journal`; the published schema goes to
`$HOME/.config/slp-room/schemas/room-message.v1.schema.json`. `install.sh` never creates a journal;
without python3 >= 3.9 it skips the helper with a warning.

## Envelope v1

Fields (unknown top-level fields are rejected): `version` (=1), `roomId`, `taskId`, `messageId`,
`causationId` (string or null), `senderAgentId`, `recipientAgentId`, `signal`, `createdAt`
(RFC3339 UTC, `...Z`), `payload` (object, serialized <= 16384 bytes), `candidateId` (64 lowercase hex).

- IDs match `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`.
- `signal` is one of CANDIDATE, REVIEW, REOPEN_REQUEST, DEPENDENCY_REQUEST, BLOCKED, QUESTION, ACK,
  ACCEPT, REJECT, REVISED BRIEF, HOLD, ANSWER, DEFER, DONE, STATUS, DECISION_NEEDED, BRIEF.
- `candidateId` is required for CANDIDATE, ACCEPT, REJECT and for REVIEW with `payload.kind ==
  "candidate"`. REVIEW needs `payload.kind` in candidate | plan | watch | other; non-candidate
  REVIEWs must not carry a `candidateId`.
- The stdlib validator is the enforcer; `room-message.v1.schema.json` is the published contract.
  A test asserts they agree on required fields, enums, patterns, limits and version (it does not
  run a JSON Schema engine).
- The journal holds coordination data, artifact paths and hashes only. Never put tokens,
  credentials or transcripts in a payload.

Rejections exit 3 with `{"ok":false,"reason":"<code>","detail":"..."}` on stdout; a corrupt or
unusable journal exits 4; usage errors exit 2.

## Journal

JSONL at an explicit path (`--journal PATH` or `SLP_JOURNAL`; there is no default). The path is
resolved with `realpath` before the lock path is derived, so a symlink alias of the journal takes the
same lock. New file 0600, new directory 0700. On every open, a journal whose mode grants group/other
access is `chmod`ed to 0600 if we own it, otherwise refused (`journal-permissions`). Every mutating operation (dedup lookup, transition validation, `seq`
allocation, append, fsync) runs inside one exclusive `flock` on `PATH.lock`. `seq` is
writer-assigned, gapless and monotonic; timestamps are never used for ordering.

Entries: `message` (an envelope), `control` (see Ownership) and `delivery` (`messageId` + state `delivered | processing |
processed`), each with its own `entryId`. "Recorded" means the message entry exists.

- Same `messageId` + identical envelope, ignoring `createdAt` (a retry regenerates the clock): no-op
  returning the original `seq`. Same `messageId` + any other difference: rejected `conflict`.
- Delivery states go recorded -> delivered -> processing -> processed. Repeating the current state is a
  no-op; going back is `state-regression`; skipping a step is `state-out-of-order`.
- Crash handling: the whole complete prefix is validated first. Only if it is clean is an incomplete
  trailing line truncated (under the write lock) and reported (`repaired`). A malformed complete
  record, a `seq` gap, or interior corruption is a hard error (exit 4, seq and offset reported) and
  the file is left byte-for-byte unchanged. Only a missing journal reads as an empty room; any
  other open error (e.g. permission denied) is an error exit (`io-error`).
- `state` reports a message at `processing` as `needsReconcile`; it is never retried automatically.
  Messages at recorded/delivered are `unprocessed`.

## Transitions (validated at record time, so replay never applies one twice)

- BRIEF: creates the task; the recipient becomes owner; `payload.writeScope = {root, paths[]}`. A
  second BRIEF for the same task is rejected.
- CANDIDATE: sender must be the owner; `payload.identity = {base, commit | patchSha256,
  changedPaths[], evidenceRefs[]}`; `candidateId` must equal sha256 of the canonical identity
  (paths normalized, deduplicated, sorted). A later CANDIDATE supersedes earlier ones.
- REVIEW kind=candidate: records which candidate was reviewed.
- ACCEPT: same room and task as the candidate; candidate must be current; `payload.reviewMessageId`
  must name a REVIEW of exactly that candidate, or `payload.reviewWaived` a non-empty string; not
  already accepted. Releases the write scope. REJECT keeps the scope with the owner.
- Scope check: `realpath(root)` + normalized relative path; paths escaping the root (including via
  symlinks) are rejected. Overlap is by path component (`src/a` overlaps `src/a/b`, not `src/ab`),
  compared on canonical absolute paths, so nested roots are covered (`/p`+`src` vs `/p/src`+`.`).
  A BRIEF overlapping an unreleased scope of a different owner is rejected. The resolved scope is
  computed once at record time and stored in the journal entry as `resolvedScope` (next to, not
  inside, the envelope); replay uses only the stored value, so later symlink changes do not move
  recorded ownership. Also available as `scope-overlap --root R --a P --b Q`.

## Task state machine

Validated at record time under the lock; replay applies only what was persisted. Task states:

```text
READY -> ASSIGNED -> RUNNING -> CANDIDATE_READY -> REVIEWING -> ACCEPTED
REJECT: CANDIDATE_READY|REVIEWING -> NEEDS_REPAIR -> RUNNING (new CANDIDATE = new identity)
BLOCKED (peer, needs payload.owner + payload.returnCondition) and DEFERRED (Lead DEFER, same fields)
CANCELLED (control cancel) revokes ownership; REVIEWED ends a review-only task.
```

- `BRIEF` creates the task (`ASSIGNED`). `payload.kind` is `work` (default; needs `writeScope`) or
  `review` (read-only; no `writeScope`/`lease`/`dependsOn`). A review BRIEF may name the candidate
  under review in the envelope's `candidateId`: it must be the current, undisposed candidate, and the
  reviewed task becomes `REVIEWING` until the review ends (`ACCEPT` meanwhile: `under-review`).
- `ASSIGNED -> RUNNING` (and `NEEDS_REPAIR -> RUNNING`): the BRIEF (or REJECT/ANSWER/REVISED BRIEF)
  delivery record reaching `delivered`, or the owner's first own signal on the task. No extra seat command.
- `CANDIDATE` (owner only; also supersedes an undisposed one, which makes older reviews stale) ->
  `CANDIDATE_READY`. Review-only tasks never take a candidate; their `REVIEW` ends them (`REVIEWED`) and a
  candidate review returns the reviewed task to `CANDIDATE_READY`.
- `ACCEPT` (coordinator, exact current candidate, with a review of exactly that candidate or a
  non-empty waiver) -> `ACCEPTED`, scope released (`ownership.event = released-by-accept`).
- `REJECT` keeps scope and owner by default (`ownership.event = kept`); `payload.ownership` =
  `release` (scope freed, owner none, task `READY`) or `reassign` + `payload.reassignTo`
  (`reassigned`, scope kept). `state` shows `ownership`, `owner`, `scopeReleased`.
- `BLOCKED` is allowed from ASSIGNED/RUNNING/NEEDS_REPAIR; `DEFER` from those and BLOCKED (not while a
  candidate awaits disposition: ACCEPT or REJECT it). `ANSWER` / `REVISED BRIEF` from the coordinator
  resumes a BLOCKED/DEFERRED task (`ASSIGNED`). Scope stays held while blocked or deferred.
- Peer signals QUESTION / DEPENDENCY_REQUEST / REOPEN_REQUEST / BLOCKED (and non-candidate REVIEWs) are
  open loops until an `ANSWER` / `HOLD` / `REVISED BRIEF` / `DEFER` (with `causationId`: that signal only;
  without: all open ones of the task) or the task's ACCEPT/REJECT (for review signals of that candidate).
- Anything else is `illegal-transition` (reason names the state). Signals for a task with no BRIEF are
  rejected by the seat commands; a raw `append` of a non-candidate signal for an unknown task is only
  recorded, tracked nowhere.
- Only the room's coordinator records BRIEF/ACCEPT/REJECT/dispositions/controls (`not-coordinator`); the
  recorder of a BRIEF can never be its owner (`owner-is-recorder`): source write owner != coordination
  recorder. Only the current owner may send CANDIDATE and the peer signals (`not-owner`).

## Ownership

- One write owner per scope. A work BRIEF is rejected (`scope-conflict`) if its scope overlaps the
  unreleased scope of any other task - same agent or not, so there is no duplicate writer.
- Root identity (`rootId`) is the realpath of `git rev-parse --show-toplevel` (else the root's realpath),
  persisted at record time. Paths are canonicalized against the nearest existing ancestor (symlinks
  resolved, nonexistent tail allowed, `..` escape = `scope-escape`) and compared by path component on
  absolute paths: nested roots overlap; two worktrees of one repo are different directories and do not.
- Scope metadata is not a sandbox: nothing stops an agent writing outside its scope or two agents ignoring
  the journal; the journal only refuses to hand out overlapping claims.
- `control` entries (journal-only, not message signals; signal text is untouched) are recorded by the
  coordinator with `controlId` dedup like messageId: `revoke T` (owner removed, scope released, task
  `READY`, current candidate stale), `transfer T --to X` (new owner, scope re-checked against other
  unreleased scopes, `ASSIGNED`, current candidate stale), `cancel T` (a review task that is revoked or cancelled leaves its target's open reviews, and the target returns to `CANDIDATE_READY` if none remain; `transfer` re-attaches it while the candidate is still current), `reconcile T [--lease ISO|none]`,
  `lead --from A --to B`.
- Lease: a work BRIEF may carry `payload.lease = {expiresAt}`. Expiry is read against the clock at
  `state` / `done-check` time (`--now` overrides it) and only sets `leaseExpired` / `needsReconcile`.
  The scope stays excluded until an explicit `reconcile` (extends or clears the lease), `revoke`,
  `transfer` or `cancel` record. The journal cannot tell whether the old writer is still running.

## Dependencies

`BRIEF payload.dependsOn = [{taskId, candidateId}]` is rejected unless each upstream task (same room, work
task) is `ACCEPTED` with exactly that `candidateId` (`dependency-not-accepted`,
`dependency-wrong-candidate`) and the artifact is accessible, checked once at record time and persisted
(`resolvedDeps`): the commit exists in the upstream scope root (`git cat-file -e <sha>^{commit}`) or the
patch file (`CANDIDATE payload.patchFile`) exists with the identity's sha256 (`dependency-artifact-inaccessible`).
A cancelled or merely closed upstream is not enough. Replay never re-checks the filesystem or git.

## DONE gate and Lead replacement

`done-check LEAD [--running AGENT]... [--permission-pending AGENT]...` prints one `blocker <type> <task> <detail>`
line per open loop and exits 3 (clean: one `ok` line, exit 0; Lead not known: `unknown-lead`). Types:
`task-open` (any non-terminal task: assigned/running with held scope, blocked, deferred, needs repair),
`candidate-undisposed`, `signal-undisposed` (a QUESTION / BLOCKED / DEPENDENCY_REQUEST / REOPEN_REQUEST or non-candidate REVIEW
still in `state.openSignals`, whatever its processing state - the protocol's "response without
disposition"), `message-unprocessed` (a Lead message not yet answered on a still-open
task), `message-needs-reconcile` (explicit `processing` left behind), `lease-expired`, `unreleased-scope`,
and the caller-supplied `agent-running` / `permission-pending`. Lead messages on ACCEPTED / CANCELLED /
REVIEWED tasks never block. The journal cannot see Paseo run or permission state: those two come only
from the flags (the caller reads Paseo).

### Implicit processing (no `deliver` needed)

Seats run one command per signal, so processing is inferred from causation at record time and persisted
in the fold (state `processed`, `implicit`). Explicit `deliver` stays available, is optional, and is a
no-op on an implicitly processed message; an explicit `processing` is never overwritten.

- A Lead disposition on a task (`accept`, `reject`, `send ANSWER|HOLD|"REVISED BRIEF"|DEFER`, `control
  revoke|cancel|transfer`) marks every earlier unprocessed Peer message on that task processed - or exactly
  the one named by `--cause MSGID` for ANSWER/HOLD/REVISED BRIEF/DEFER (`unknown-cause` if it is not a
  recorded message of the task). `accept`/`reject` dispose only the candidate and its REVIEWs (and process those messages): a
  QUESTION / BLOCKED / DEPENDENCY_REQUEST / REOPEN_REQUEST stays an open signal, and blocks `done-check`,
  until a Lead `send` (ANSWER/HOLD/REVISED BRIEF/DEFER) or `control revoke|cancel|transfer` disposes it.
  Disposition and delivery processing are separate.
- A Peer's next signal on a task marks the Lead's earlier BRIEF/dispositions on that task processed.
- ACCEPT and DEFER expect only an ACK, which is not journaled, so they are processed on record (an ACK
  that is journaled is processed on record too).

`control lead --from OLD --to NEW` (recorded by either; NEW must not own a held scope) moves the whole
room's coordination. `state` then restores tasks, owners, scopes, candidates and open signals for NEW; OLD
is `not-coordinator` from then on, and a BRIEF over a held scope is `scope-conflict` for anyone.

## CLI

Admin/low level: `append [FILE|-]`, `deliver <messageId> <state>`, `state`, `validate <file>`,
`candidate-id <identity.json>`, `scope-overlap`, `contract`, `--version` (`slp-journal envelope-v1`),
`--self-check`. Global: `--journal PATH` (or `SLP_JOURNAL`), `--now RFC3339Z`.

Seat commands: sender `--as AGENT` (default `$PASEO_AGENT_ID`, then `SLP_AGENT`, so prompts omit it), room `--room R` (or `SLP_ROOM`, or the task's room);
recipient is derived (Lead -> owner, Peer -> coordinator); `--id` makes a retry idempotent (dedup ignores `createdAt`, for messages and controls; any other difference is `conflict`). One command per
signal, one output line `ok [dup] SIGNAL TASK seq=N status=S msg=ID [cid=C]` (rejections: JSON, exit 3).

```text
Lead  brief T --to PEER --root DIR --path P... [--lease ISO] [--depends TASK:CID]...   (work BRIEF)
Lead  brief T --to PEER --review --cid CID                                             (review BRIEF)
Peer  candidate T --base B (--commit SHA | --patch-sha H --patch-file F) --path P... [--evidence E]...
Peer  review T [--kind plan|watch|other]                      (candidate review for a review task)
Peer  send T BLOCKED|QUESTION|DEPENDENCY_REQUEST|REOPEN_REQUEST [--note TXT] [--owner A --return COND]
Lead  accept T --cid C [--waive WHY]       (links the newest REVIEW of exactly C)
Lead  reject T --cid C [--release | --reassign AGENT] [--note TXT]
Lead  send T ANSWER|HOLD|"REVISED BRIEF"|DEFER [--cause MSGID] [--note TXT] [--owner A --return COND]
Lead  control revoke|cancel T | transfer T --to X | reconcile T [--lease ISO|none] | lead --from A --to B
Lead  done-check LEAD [--running ID]... [--permission-pending ID]...
```

`candidate` prints the `cid=` the Lead then uses in `accept`/`reject`/`brief --review`.
`state` is the only command that prints JSON on success.

## Limits

- Assumes a local filesystem with working `flock` (not NFS). `--self-check` only verifies `flock`
  can be taken in a temp dir.
- Effectively-once processing comes from dedup plus idempotent handlers; this is not exactly-once.
- Durability assumes a local filesystem that honours `fsync`. Each append is fsynced; when the
  journal or lock file is created, every mutating operation fsyncs the journal's directory and every ancestor up to the filesystem
  root under the lock before acknowledging a write (a few directory fsyncs per write; reads do not),
  so durability never depends on another writer having finished initialization; an ancestor whose
  fsync returns EINVAL/ENOTSUP is skipped, any other error propagates; missing directory levels are
  created one at a time (0700) and each new directory's containing directory (the pre-existing
  ancestor included) is fsynced. The test checks that directory fsyncs are issued, not that data survives
  power loss; a disk that lies about fsync is outside what is tested.
- The whole journal is re-read on each operation (O(n)); fine for room-sized journals, not tuned.
- Nothing authenticates the sender (so `not-owner` / `not-coordinator` stop mistakes, not impersonation): `senderAgentId` is a claim, not an identity proof.

## Migration

`version` is 1. A future incompatible envelope gets a new `version` and schema file
(`room-message.v2.schema.json`); this helper rejects other versions rather than guessing.
