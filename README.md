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

The list shows each session with its tabs and panes. A pane's dot pulses while an
agent works in it, turns green when it's done, and reads "Needs you" when it's
waiting on you; the line under the title counts them. Tap a pane to open it, and
the button in its corner (or a swipe from the left edge) to go back. + starts a
new session with a shell.

Above the keyboard sit the keys a terminal needs that the software keyboard
lacks: esc, ctrl (it applies to the next key), tab, shift-tab, the arrows, and a
few symbols. A hardware keyboard works as it does in any terminal.

When irex shows a pane, it becomes the pane's owner, so the pane takes the size
of the phone's screen, and other clients see it at that size until one of them
takes it back.

Settings hold the server, text size, and keeping the screen on while a pane is
open.

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

Split layouts (a pane opens on its own), text selection, links, and file upload.

## License

MIT. See [LICENSE](LICENSE).
