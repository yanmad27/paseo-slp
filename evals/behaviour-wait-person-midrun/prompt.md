---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

You are the Supervisor. Your Lead "[Lead] docs" is running with one Peer, "[Peer] readme", also running. You were in `slp-wait <leadId> 110`; it returned the "user doesn't want to proceed" result because the person just wrote: "how long until it's done?" After that, do not call any other tool. Write the final message of this turn exactly as you would send it.
