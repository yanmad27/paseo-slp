---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read, Glob, Grep]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

supervise the running room: the Lead "[Lead] docs" is already working. Set up the monitoring heartbeat (one per Supervisor). Show the exact create_heartbeat call you make: its name and cron.
