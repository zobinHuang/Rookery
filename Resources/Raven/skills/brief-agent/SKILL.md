---
name: brief-agent
description: Put what the user wants an agent to do into a clear message and propose it, for the user to send with one click. Use when the user asks Raven to tell, ask, instruct or answer an agent, such as "tell G-Watch to run the tests" or "answer its question with yes".
---

# Brief an agent

You never send to an agent yourself: you propose, and the user sends from Rookery.

1. Find the agent (`@agent/...`, or by title in `rook-client agent status --json`). If it has ended or its rook is offline, say so: it cannot take a message now.
2. Read where it stands, `rook-client agent tail <id> --steps 20`, so the message fits: what it is doing, what it asked.
3. Write the message as the user would type it into the agent's prompt:
   - in the language the agent and the user have been using with each other;
   - the instruction first, then only the context the agent lacks; no greeting, no sign-off;
   - when it answers a question the agent asked, answer exactly that question.
4. Propose it: `rook-client propose message <agent id> "<message>"`. One proposal per agent; do not propose the same message twice.
5. Tell the user in a line what you proposed and to whom; the card with the Send button shows under your answer. If the agent is busy, say the message will wait until it stops.
6. To stop an agent that is going the wrong way, propose `rook-client propose interrupt <id>` first, then the message that sets it right; the user carries out both in order.
7. In your next turn you hear whether the user sent it; once sent, `rook-client agent tail` shows the agent's answer when the user asks how it went.
