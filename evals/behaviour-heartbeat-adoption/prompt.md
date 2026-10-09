---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read, Glob, Grep]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

adopt the running room: its Lead "[Lead] docs" carries the label paseo.parent-agent-id=aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa, and get_agent_status shows that previous Supervisor, "[Supervisor] old", is still running with its own heartbeat. Your own agent ID is bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb. What do you do about the old Supervisor's heartbeat? After that, do not call any other tool; answer, ending with your room-state block.
