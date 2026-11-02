# Webhook

RerunBox runs a small HTTP server (`rerunbox-webhook.service`) so that a Stream
Deck, Lumia Stream, Home Assistant, a cron job or any script can control the loop.

- Listens on `WEBHOOK_BIND:WEBHOOK_PORT` (default `127.0.0.1:8787`, this machine only)
- Every request needs the token from `/etc/rerunbox/secrets.env`
  (`sudo rerunbox token` prints it), sent as the header `X-Webhook-Token: <token>`
  or as `Authorization: Bearer <token>`
- Wrong or missing token gives `403`. The server refuses to start with no token.

| Request | Does |
|---------|------|
| `POST /start` | start the relay, then the feeder |
| `POST /stop` | stop the feeder, then the relay |
| `POST /restart` | stop, then start |
| `POST /reset-position` | forget the resume position and restart only the feeder, so playback begins at the first file and the outbound connection stays up |
| `GET /status` | JSON: `{"relay": "active", "feeder": "active", "now_playing": "01-intro.mp4"}` |

```bash
TOKEN=$(sudo rerunbox token)
curl -X POST -H "X-Webhook-Token: $TOKEN" http://127.0.0.1:8787/stop
```

## Using it from another device

To call it from a PC on your network (say, the machine with your Stream Deck),
set `WEBHOOK_BIND` to the box's LAN address in `/etc/rerunbox/rerunbox.conf`,
then `rerunbox restart`.

The webhook is **plain HTTP with a shared token**. Anyone who can sniff your LAN
traffic can read the token. So:

- Only expose it on a network you trust, and firewall the port to the specific
  machines that need it (for example `ufw allow from 192.168.1.20 to any port 8787`).
- Never port-forward it to the internet. If you need remote control, put it behind
  a VPN (WireGuard, Tailscale) or a TLS reverse proxy.

## Stream Deck / Lumia Stream / similar tools

Any tool that can send an HTTP POST with a custom header works. Typical setup:
one button per action, method `POST`, URL `http://HOST:8787/stop` (and so on),
header `X-Webhook-Token`. Useful buttons: **Stop loop**, **Start loop**,
**Restart from the top** (`/reset-position`), **Status**.

## Handing over to a live broadcast on the same stream key

If you also go live to the same destination with OBS or similar, only one thing
can be connected to a stream key at a time. The safe order is:

**Going live:** `POST /stop`, wait about 10 to 15 seconds so the destination
releases the old connection, *then* start your live software.

**Ending the live show:** stop your live software, wait a few seconds, then `POST /start`.

A short delay of a couple of seconds is often not enough: restreaming services and
platforms can keep the old connection for a while, and the first reconnect then
fails. Build the wait into your button's action list.

The scheduled restart (`RESTART_INTERVAL_HOURS`) is skipped whenever the loop is
stopped, so it won't start the loop underneath a live show.

## Troubleshooting

- **Connection refused:** check `rerunbox status` and that `WEBHOOK_BIND` is the
  address you're calling.
- **403:** wrong token. Re-read it with `sudo rerunbox token`.
- **500 with a `sudo` message:** the sudoers rule is missing. Re-run `install.sh`.
