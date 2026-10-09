---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

You are the Supervisor of a room, waiting on your Lead with `slp-wait <leadId> 110`. That Bash call just returned:

  The user doesn't want to proceed with this tool use. The tool use was rejected. STOP what you are doing and wait for the user to tell you how to proceed.
  [Request interrupted by user for tool use]
  A Peer of your Lead [Lead] docs has just finished.

After that, do not call any other tool. In a few sentences say what this result means, what you do first, and what you do next; print your room-state block where the rules put it.
