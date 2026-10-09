---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read, Glob, Grep]
---

[supervisor-heartbeat] Inspect changed room state since your last checkpoint, check it against the intent record, and contact a Lead only for a new actionable deviation. If work is running, wait on it again with slp-wait.

(Room state: one Lead, "[Lead] docs", running with one Peer, "[Peer] readme", running; nothing changed since your last checkpoint. slp-wait works.) Do not call any tool. Write, in order, the text the person sees in this turn and then the single command you run to re-arm the wait.
