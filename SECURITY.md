# Security policy

RerunBox is a small, volunteer-maintained project. Reports are handled on a
best-effort basis, with no guaranteed response time, but they are taken seriously.

## Supported versions

Only the latest release on the `main` branch receives fixes.

## Reporting a vulnerability

**Please do not open a public issue or pull request for a security problem.**

Use GitHub's private reporting instead:

1. Go to the **Security** tab of this repository.
2. Choose **Report a vulnerability** and describe the problem.

If that option isn't available, open a public issue that says only that you have a
security report and would like a private way to send it. Do not include any details
in the issue.

Useful things to include:

- what you found and why it matters
- the RerunBox version (`rerunbox version`) and your OS
- steps to reproduce it
- a suggested fix, if you have one

You will get an acknowledgement when the report is read. Please give a reasonable
amount of time to fix the problem before disclosing it publicly, and I will credit
you in the fix if you'd like.

## What counts as in scope

RerunBox installs system services and handles credentials, so these matter most:

- the installer (`install.sh`, `uninstall.sh`) doing something unsafe with root privileges
- the sudoers rule letting the service account do more than start and stop its own services
- the webhook accepting requests without a valid token, leaking the token, or running
  anything other than its documented actions
- the stream key, webhook token or Discord URL being written somewhere readable by
  other users, or logged
- config values that can be used to inject commands

Not in scope: problems in ffmpeg, your streaming platform, or a webhook you have
deliberately exposed to the internet without a VPN or TLS (the documentation warns
against this).

## Protecting yourself

- Never paste your stream key, `/etc/rerunbox/secrets.env`, or unredacted logs into
  an issue. ffmpeg can print the full RTMP URL, including the key, in some error messages.
- If a key is exposed, regenerate it in your streaming platform straight away.
- Keep `WEBHOOK_BIND` on `127.0.0.1` unless you need remote control, and firewall the
  port if you change it. See [docs/webhook.md](docs/webhook.md).
