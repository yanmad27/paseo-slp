---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` and `roles/lead.md` from that skill's directory. Then:

Room role: Lead. (In this eval the installed helper is `/opt/slp-room/bin/slp-journal`; the role file's `@@SLP_JOURNAL@@` token stands for it. `PASEO_AGENT_ID` is `lead-eval`.) Your instruction is to update the README install section in `/repo`. You just called `create_agent` for "[Peer] readme"; it returned agent ID `peer-readme-1`, and its brief gave Task id `readme-install` and write scope `/repo/README.md`. Do your next step now, running only the Bash calls the role requires and no other tool. Then, in one sentence, say what is running.
