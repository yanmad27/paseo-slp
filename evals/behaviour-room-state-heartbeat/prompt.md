---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read, Glob, Grep]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

[supervisor-heartbeat] Inspect changed room state since your last checkpoint, check it against the intent record, and contact a Lead only for a new actionable deviation. If work is running, wait on it again with slp-wait. End the turn with exactly one room-state block; its last row is the last line.

(Room state: one Lead, "[Lead] docs", running with one Peer, "[Peer] readme", running; nothing changed since your last checkpoint. slp-wait works.) State the room-state block and the wait you arm.
