I want to create a beautiful iOS application that lets me connect to a server via Mosh or SSH and automatically detects my existing tmux sessions and allows me to use one of of them or go straight to the terminal.

Make a focused research on the aesthetics and functionality of this app on the app store called Moshi. I want to replicate what it does while fixing a few bugs that keeps it in the way of my use.

Interview me with some questions in order to generate a new PRD to build this with the help of an AI coding agent.

Already answered questions:

Q: What platform(s) are you targeting for the initial build?
A: iOS only (Swift/SwiftUI)

Q: What specific bugs or friction points in Moshi do you want to fix in your version? (Select all that apply)
A: Keyboard toolbar discoverability / customization, Tell me in detail (I'll type it out), There is a dreaded monospace character alignment issue when you use tmux panes

Q: Which of Moshi's features are MUST-HAVE for your v1?
A: Ranked: 1. Mosh + SSH protocols, 2. tmux session auto-detect & picker, 3. Push notifications (webhook alerts), 4. Terminal themes, 5. Voice-to-terminal (Whisper), 6. Face ID for SSH keys

Q: What's your primary use case when connecting from your phone?
A: Monitoring/babysitting AI coding agents (Claude Code, etc.)

Q: For the keyboard toolbar — what's your ideal approach?
A: Fully customizable drag-to-reorder buttons

Q: How do you want to handle multiple servers/connections?
A: Preserve each connection and tmux session (or lack thereof) as a separate connection.

Q: What's your monetization strategy?
A: Free and open source but with me as the main and central user. No need to think about broad usage, want to taylor it to myself.

Q: Do you want this to be open source?
A: Yes, open source from the start

Q: Any of these extra features interest you for v1 or v2? (Select all that apply)
A: tailscale integration and clipboard sync, but we can push them to v2

Q: What's your aesthetic vision for the app?
A: Dark-only (like Moshi)

Q: Do you have a name for this app?
A: Help me brainstorm names

Q: When you connect to a server, what should the default tmux behavior be?
A: Show picker every time

The name works beautifully:

星 (Hoshi) = star — watching over your agents from afar
Phonetic echo of Moshi — instantly recognizable to anyone in this space
Clean, memorable, 5 letters, great for a GitHub repo (hoshi-terminal or just hoshi)
The ★ symbol works as a natural app icon element
