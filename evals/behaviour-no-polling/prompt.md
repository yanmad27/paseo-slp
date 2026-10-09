---
tags: [behaviour]
allowed_tools: [Skill, Agent, Bash, Read, Glob, Grep]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

orchestrate: open a PR for the current branch and tell me when the CI check passes. You are the Supervisor: whenever you have to wait on a running room agent, do it with the room's slp-wait helper (110 s, one call per wait).
