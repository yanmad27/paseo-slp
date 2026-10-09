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

JSONL at an explicit path (`--journal PATH` or `SLP_JOURNAL`; there is no default). File mode 0600,
new directory 0700. Every mutating operation (dedup lookup, transition validation, `seq`
allocation, append, fsync) runs inside one exclusive `flock` on `PATH.lock`. `seq` is
writer-assigned, gapless and monotonic; timestamps are never used for ordering.

Entries: `message` (an envelope) and `delivery` (`messageId` + state `delivered | processing |
processed`), each with its own `entryId`. "Recorded" means the message entry exists.

- Same `messageId` + identical envelope: no-op returning the original `seq`. Same `messageId` +
  different content: rejected `conflict`.
- Delivery states go recorded -> delivered -> processing -> processed. Repeating the current state is a
  no-op; going back is `state-regression`; skipping a step is `state-out-of-order`.
- Crash handling: under the lock, an incomplete trailing line is truncated and reported
  (`repaired`). A malformed complete record, a `seq` gap, or interior corruption is a hard error
  (exit 4, seq and offset reported) and nothing is written.
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
  symlinks) are rejected. Overlap is by path component (`src/a` overlaps `src/a/b`, not `src/ab`).
  A BRIEF overlapping an unreleased scope of a different owner under the same canonical root is
  rejected. Also available as `scope-overlap --root R --a P --b Q`.

The full lifecycle state machine is out of scope here.

## CLI

`append [FILE|-]`, `deliver <messageId> <state>`, `state`, `validate <file>`, `candidate-id <identity.json>`,
`scope-overlap`, `contract`, `--version` (`slp-journal envelope-v1`), `--self-check`.

## Limits

- Assumes a local filesystem with working `flock` (not NFS). `--self-check` only verifies `flock`
  can be taken in a temp dir.
- Effectively-once processing comes from dedup plus idempotent handlers; this is not exactly-once.
- Writers fsync each append; an OS or disk that lies about fsync is outside what is tested.
- The whole journal is re-read on each operation (O(n)); fine for room-sized journals, not tuned.
- Nothing authenticates the sender: `senderAgentId` is a claim, not an identity proof.

## Migration

`version` is 1. A future incompatible envelope gets a new `version` and schema file
(`room-message.v2.schema.json`); this helper rejects other versions rather than guessing.
