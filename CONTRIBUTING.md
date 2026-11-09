# Contributing to Hoshi

Thanks for wanting to help. Hoshi started as the terminal I wanted on my own
phone, and it gets better every time someone else uses it and tells me what's
missing. Bug reports, fixes, new key sets, themes, and fonts are all welcome.

## Getting set up

You need a Mac with Xcode, XcodeGen, and ripgrep. Then:

```bash
git clone https://github.com/fcoury/hoshi.git
cd hoshi
./scripts/bootstrap.sh --prebuilt
open Hoshi/Hoshi.xcodeproj
```

`--prebuilt` downloads GhosttyKit, so you don't need Zig or the Metal
toolchain. [AGENTS.md](AGENTS.md) has the details: how to run the tests, how
the code is laid out, the rules that must not break, and step-by-step notes
for the most common changes. It's written for coding agents, but it's the best
map of the project for people too.

## What makes a good PR

- One thing per PR. A small, focused change gets reviewed quickly.
- Build it and run it on the simulator or a device before opening the PR.
- Add or update tests when the change can be tested.
- If you change `Hoshi/project.yml` or add files, regenerate the project with
  XcodeGen and commit the `.pbxproj`. CI checks this.
- UI changes need a screenshot (or a short recording).
- For bigger ideas, open an issue or a discussion first so we can talk before
  you spend a weekend on it.

Some things I won't merge: analytics or tracking of any kind, anything that
sends data somewhere other than your own servers, or anything that weakens
host-key checks or stores secrets outside the Keychain.

## Using LLMs

LLM-written PRs are welcome. The bar is the same as for any other PR, plus a
few things:

- You built and ran the change yourself, on the simulator or a device.
- You added or updated tests where it's testable.
- The PR description is in your own words: what changed, why, and how you
  checked it.
- Tell me which tool you used. There's no penalty for it; it just helps me
  review.

If you point an agent at this repo, point it at [AGENTS.md](AGENTS.md) first.

## Reporting bugs

Open an issue with the bug template. The things that help most:

- Hoshi version (App Store or TestFlight build, or the commit if you built it)
- Device and iOS version
- Server OS and `mosh-server` version, if you use Mosh
- Connection type: SSH or Mosh, and whether tmux or Herdr is involved
- What you did, what you expected, and what happened

Please leave out hostnames, usernames, keys, and anything else private.

Questions and ideas go to [Discussions](https://github.com/fcoury/hoshi/discussions).

## License

Hoshi is MIT licensed. By contributing, you agree your contribution is
released under the same [MIT License](LICENSE).

Felipe
