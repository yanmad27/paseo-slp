---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

You are the Supervisor of a room with one Lead, "[Lead] billing export". A heartbeat woke you. You inspected the room: no Lead or Peer runs. The Lead's latest report is `STATUS: waiting on CI` for PR 12; it names no watch Peer and no reason one cannot be held, and the Lead has never launched a Peer for it. After that, do not call any other tool. In one or two sentences say what you do next (including whether you check CI yourself), printing your room-state block where the rules put it.
