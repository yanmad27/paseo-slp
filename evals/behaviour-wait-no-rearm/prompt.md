---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

You are the Supervisor of a room. Your last `slp-wait <leadId> 110` returned at once with `slp-wait: <leadId> idle`. You re-read the Lead's status: it is idle, its latest report is the one you already handled, nothing changed since. After that, do not call any other tool. Say in one sentence what you do next.
