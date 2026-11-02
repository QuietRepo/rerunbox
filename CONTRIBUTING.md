# Contributing to RerunBox

Thanks for taking the time. RerunBox is a small project run by one maintainer, so
please keep changes focused and expect reviews to take a little while.

## Reporting bugs and trying it on new hardware

Open an issue and include:

- the output of `rerunbox version` and `rerunbox doctor`
- your OS, CPU/GPU and ffmpeg version
- what you expected and what happened
- the relevant lines from `rerunbox logs`, **with your stream key removed**

Reports from hardware other than Intel Skylake are especially useful, whether they
work or not.

## Suggesting changes

The `main` branch is protected: nobody pushes to it directly. Changes come in as
pull requests from your own fork.

1. Fork the repository and create a branch from `main`.
2. Make your change, keeping it small and on one topic.
3. Run the checks below.
4. Open a pull request that explains what changed and why.

For anything bigger than a small fix, open an issue first so we can agree on the
approach before you spend time on it. A pull request may be declined if it doesn't
fit the project, even if it's well made.

## Before you open a pull request

```bash
bash tests/smoke-test.sh                   # needs ffmpeg, ffprobe, python3, curl; no GPU
shellcheck -x install.sh uninstall.sh bin/* lib/*.sh tests/*.sh
```

Both should pass. The smoke test uses a software encoder, so it proves the loop
logic but not the Intel VAAPI path. If you change the encoder or the ffmpeg
command, say how you tested it on real hardware.

## Where things live

- `lib/pipeline.sh` builds the ffmpeg command. The feeder, `rerunbox preflight` and
  `rerunbox test-encode` all use it, so change it there and only there.
- `lib/common.sh` holds configuration loading and validation.
- `bin/` has the services and the `rerunbox` command; `systemd/` has the unit templates.
- `docs/` is user documentation. Update it when behaviour changes.

## Style

- Bash with `set -u`, quoted variables, and shellcheck-clean code.
- Files use LF line endings (`.gitattributes` enforces this).
- Anything that ends up in a config file must be validated, since those files are
  read by shell scripts.
- Secrets never go in the repo, in logs, or in test fixtures.

## Scope

In scope: the looped-stream pipeline, the installer, the command-line tool, the
webhook, documentation, and support for additional encoders.

Out of scope for now: chatbots and chat integrations, platform-specific automation
(tags, titles, rerun labels), and a graphical interface.

## Licence

By contributing you agree that your work is released under the project's
[MIT licence](LICENSE).

## Security problems

Please don't report these publicly. See [SECURITY.md](SECURITY.md).
