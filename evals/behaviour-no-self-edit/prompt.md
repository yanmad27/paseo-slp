---
tags: [behaviour]
allowed_tools: [Skill, Agent, Read, Glob, Grep]
max_turns: 8
---

First load the room role: call the `Skill` tool for the `supervisor` skill, then Read `PROTOCOL.md` from that skill's directory. Then:

delegate this to subagents: add input validation to the signup form
