# Ultimate Brain Stimulation

While Claude Code is working, your browser doomscrolls short videos for you. When Claude finishes or needs your approval, the scrolling stops, the video pauses, and your terminal comes back to the front.

Works with **Instagram Reels**, **TikTok**, and **Douyin**, or rotates between them.

macOS only.

## How it works

Claude Code can run a script at set moments (these are called *hooks*). This project uses them like this:

| When | What happens |
|---|---|
| You send Claude a prompt | Your browser opens the feed and moves to the next video every 8 seconds |
| A tool finishes (e.g. one you just approved) | Scrolling resumes if it had stopped |
| Claude finishes, or asks for your approval | Scrolling stops, the video pauses, and your terminal comes back to the front |

It presses the down arrow key to move to the next video. It only presses the key when the feed is the window in front of you (it checks the window title), so if you click back into your terminal, the key never reaches it.

If you have several Claude sessions running, it keeps scrolling until all of them are done.

## Install

Needs Google Chrome (or Brave or Edge) and `jq`, which comes with recent versions of macOS.

```bash
git clone https://github.com/bryanfrds/Ultimate-Brain-Stimulation.git ~/ultimate-brain-stimulation
~/ultimate-brain-stimulation/install.sh
```

Then restart any open Claude Code sessions.

The first time it runs, macOS asks for two permissions. Click **Allow** on both:

1. **Your terminal controlling System Events** (a popup).
2. **Accessibility** for your terminal app, so it can press keys: System Settings → Privacy & Security → Accessibility.

Log in to Instagram, TikTok, or Douyin in the browser once. Douyin login uses a QR code that you scan with the Douyin phone app.

## Menu bar app

A brain icon in your menu bar to turn scrolling on or off and pick the app, without editing files. The icon fills in while it's scrolling.

By default the feed plays in a **small floating window on the right side of your screen** instead of in Chrome. It appears while Claude works and hides when Claude is done. Your terminal stays in front the whole time, so you can keep reading and typing. Drag or resize the popup and it remembers where you put it. Choose **Show it in → Chrome tab** for the old behavior.

The popup has its own login, separate from Chrome. Use **Show Popup Now** in the menu to open it and log in once. The menu bar app has to be running for the popup to appear.

```bash
~/ultimate-brain-stimulation/menubar/build.sh
open ~/Applications/"Ultimate Brain Stimulation.app"
```

Needs Apple's command line tools (`xcode-select --install`) to build. Turn on **Open at Login** in its menu to keep it there.

## Settings

Edit `~/.config/ultimate-brain-stimulation/config`:

```bash
APP=instagram          # instagram, tiktok, douyin, or rotate (next app on each new prompt)
SECONDS_PER_VIDEO=8
BROWSER="Google Chrome"
STALE_MINUTES=10       # give up if Claude goes quiet this long (e.g. you pressed Esc)
PAUSE_ON_STOP=1
RETURN_TO_TERMINAL=1
```

## Commands

```bash
bin/ubs status   # is it scrolling, which app, how many Claude sessions are busy
bin/ubs off      # turn it off without uninstalling
bin/ubs on       # turn it back on
bin/ubs reset    # stop scrolling right now and clear its state
```

Logs are in `~/.cache/ultimate-brain-stimulation/log`.

## Uninstall

```bash
~/ultimate-brain-stimulation/uninstall.sh
```

This removes the hooks from `~/.claude/settings.json`. A backup is saved as `settings.json.bak-ubs`.

## Things to know

- **Instagram, TikTok, and Douyin don't allow automated activity in their terms.** This only scrolls your own feed at a normal pace, but it is still automation. Use it at your own risk.
- If you press **Esc** to interrupt Claude, Claude Code doesn't tell hooks about it. The scrolling stops after `STALE_MINUTES` with no activity.
- After you approve a tool, scrolling resumes when that tool *finishes*, so a long build or test run won't scroll until it's done.
- If Claude runs several tools at once and one needs approval, another finishing can bring the feed back over the approval prompt.
- A single tool that runs longer than `STALE_MINUTES` can let scrolling stop early. Raise it if you run long builds.
- Claude Code has to be running in a terminal (or in the VS Code terminal). Hooks don't run in the Claude web app.

## License

MIT
