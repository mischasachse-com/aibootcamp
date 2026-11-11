# Presentation decks

Trainer-facing HTML slide decks for the bootcamp — self-contained files, no
build step. Each deck is a pair:

- `slideshow.html` — the audience-facing deck (1920×1080, auto-scales)
- `presenter.html` — trainer view: current/next slide + speaker notes

| Folder | Deck | Use |
| --- | --- | --- |
| `Kickoff/` | Mission briefing — whole bootcamp | open before Day 1 |
| `Day1/` | Ground the Flight Director — Foundry + RAG | Day 1 theory session |
| `Day2/` | The Blackbox Investigation | Day 2 theory session |
| `Day3/` | The Flight Director Takes Command | Day 3 theory session |

## How to present

1. Open `slideshow.html` in a browser — click, Arrow keys, Space, Home/End.
2. Open `presenter.html` in a second window — it syncs via
   `BroadcastChannel` (both directions; presenter can drive the deck).
   Works in Chromium-based browsers; Firefox may isolate `file://` pages.
3. Notes are in English; slide content assumes you read the lab guides.

No clock times or durations are shown anywhere — pace each session to your
group. Brand: mischasachse.com. All scenario data is fictional (see repo
`README.md`).
