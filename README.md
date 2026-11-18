# irex

Rex on iPhone and iPad, shortened to irex. [Rex](https://superlogical.com) keeps
terminal sessions running on a server, and its Mac app shows them. irex shows them
on iOS: every session on a Rex server, its tabs and panes, and the agents working
in them. It's the iOS sibling of [orex](https://github.com/Unayung/orex), the Linux
client.

> irex is an unofficial client. It isn't made by or affiliated with Superlogical.
> It speaks the API that Rex servers document at `/llms.txt`, which is still in
> beta and may change under it.

The terminal is [libghostty-vt](https://ghostty.org), the core Rex itself uses, so
irex reads Rex's terminal snapshots directly and draws what the program in each
pane draws.

## Use

The first launch asks for a server: a Rex server's address, such as
`host.tailnet.ts.net:7297` for one on your tailnet. Put `account@` in front to
connect as another account.

The list shows each session with its tabs and panes, on the server and on the
other hosts in its `rex hosts`. A pane's dot pulses while an agent works in it
and turns green when it's done; the line under the title counts them. When an
agent is waiting on you, its pane gets a Reply button: it shows the end of the
question with 1, 2, 3, Esc, and Enter, so you can answer without opening the
pane. + starts a new session with a shell.

Tap a pane to open it, and the button in its corner (or a swipe from the left
edge) to go back. Swipe sideways to go to the session's next or previous pane.
Long-press and drag to select and copy, pinch to change the text size, and tap
a link a program marks (OSC 8) to open it. The pencil opens a box for a longer
message, with dictation, sent as one paste. The paperclip attaches photos, a
picture from the camera, or files: Rex puts them on the pane's machine and types
their paths, so an agent can read them. Pasting an image does the same.

Pull the list down to search panes and sessions. Idle panes fold away in a
session that has a few, and panes running a coding agent show its mark.

Above the keyboard sit the keys a terminal needs that the software keyboard
lacks: esc, ctrl (it applies to the next key), tab, shift-tab, the arrows (hold
to repeat), and a few symbols. A hardware keyboard works as it does in any
terminal, and ⌘ adds irex's own keys: ⌘[ and ⌘] for the previous and next
pane, ⌘F to search, ⌘N for a new session, ⌘↩ to write a message, ⌘W to close
the pane. When you scroll back, a button takes you to the latest output.

When irex opens a pane, it becomes the pane's owner, so the pane takes the size
of the screen, and other clients see it at that size until one of them takes it
back; then Fit takes it again. Turn off "Fit panes to this screen" to watch
panes at their own size instead, until you type. Replying from the list never
resizes a pane.

Settings hold the server, the hosts, text size, fitting, and keeping the screen
on while a pane is open.

## Notifications and the Live Activity

irex-push, in `push/`, runs on the server's machine and watches every agent on it
and on the hosts in its `rex hosts`. When one needs you or finishes, your phone
gets a notification; while any are working, a Live Activity on the lock screen
and in the Dynamic Island shows how many, the ones that need you first. Tap
either to open the pane, or answer a "needs you" notification with its 1, 2,
or 3 buttons without opening irex (a locked phone asks for Face ID first). irex finds irex-push on port 7298 of the server's host.

It needs an APNs key (developer.apple.com → Keys → Apple Push Notifications
service), Go, and a way to reach it from the phone, such as Tailscale Serve:

```sh
cd push && go build -o ~/.local/bin/irex-push .
mkdir -p ~/.config/irex-push && cp env.example ~/.config/irex-push/env   # then fill it in
cp irex-push.service ~/.config/systemd/user/ && systemctl --user enable --now irex-push
sudo tailscale serve --bg --https=7298 http://127.0.0.1:7298
```

Settings → Notifications in irex shows whether it's registered and sends a test.

## Build

irex builds on a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and libghostty-vt as an xcframework. Build that from a
[Ghostty](https://github.com/ghostty-org/ghostty) checkout in `~/build/ghostty` on
the Mac:

```sh
zig build -Demit-lib-vt -Demit-xcframework
```

The scripts run from any machine that can reach the Mac over SSH. Copy
`bin/config.example` to `bin/config` and fill in the Mac, your Apple team ID,
and your devices; change `bundleIdPrefix` in `project.yml` to one of yours.

```sh
bin/build           # sync to the Mac and build there
bin/deploy iphone   # build signed, install, and launch on the iPhone (or ipad)
```

`bin/deploy` builds inside a Rex session on the Mac, since signing needs the
login keychain that an SSH session can't unlock, so the Mac needs a Rex server
listed in `rex hosts`.

## Not yet

Split layouts (a pane opens on its own), answering from a notification, and file upload.

## Agent icons

Claude, OpenAI (Codex), GitHub Copilot, Google Gemini, OpenCode, and Kimi come
from [Simple Icons](https://simpleicons.org) (CC0); the marks belong to their owners.

## License

MIT. See [LICENSE](LICENSE).
