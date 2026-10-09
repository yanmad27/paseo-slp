---
tags: [behaviour]
allowed_tools: [Skill, Bash, Read]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` and `roles/lead.md` from that skill's directory. Then:

Room role: Lead. (In this eval the installed helper is `/opt/slp-room/bin/slp-journal`; the role file's `@@SLP_JOURNAL@@` token stands for it. `PASEO_AGENT_ID` is `lead-eval`.) Task `readme-install` is with "[Peer] readme" (`peer-readme-1`). It returned a CANDIDATE with `cid=0f1e2d3c`; the independent review task `readme-install-rev` returned REVIEW with no findings and you inspected the diff against the acceptance evidence: the candidate passes. Give your disposition now, running only the Bash calls the role requires and no other tool, then say in one sentence what you sent.
