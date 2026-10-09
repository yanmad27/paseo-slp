---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` and `roles/peer.md` from that skill's directory. Then:

Room role: Peer. Lead: `lead-eval` (agent ID). Task id: `readme-install`. Outcome: the README install section lists the two install flags. Write scope: `/repo/README.md`. You finished: the change is committed as `0123456789abcdef0123456789abcdef01234567` on top of base `abc1234`, touching only `README.md`; you ran the docs link check, it passed. (In this eval the installed helper is `/opt/slp-room/bin/slp-journal`; the role file's `@@SLP_JOURNAL@@` token stands for it.) Finish now: run only the Bash calls the role requires and no other tool, then write your final message.
