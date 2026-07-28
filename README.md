# vps — a server where Claude Code agents live

Turns a clean Ubuntu VPS into a machine where **Claude Code agents run around the clock**
and develop your projects. Sessions survive reboots and crashes, and are reachable from the
mobile app and over SSH. Projects run in docker and are never exposed to the internet.

One control session maintains the server; every project gets its own session in its own
folder. They run in parallel without getting in each other's way.

The scripts, the agents and the docs on this server speak Russian — this README is the
English overview of what they do.

## Install

Ubuntu 22.04/24.04 with an SSH key on `root`.

```bash
ssh root@<IP>
git clone https://github.com/IliaSadovskii/vps.git && cd vps
sudo bash init.sh
```

The root pass creates the `dev` user, hardens access and copies the repo to `/home/dev/vps`.
Everything after that runs as `dev` — just repeat `bash init.sh`. It prints a checklist, does
the next step and stops whenever it needs you (a browser login, an SSH re-login):

```
  ✔ 1. Сервер: пользователь, безопасность, пакеты
  ▶ 2. Вход в Claude Code
  · 3. Вход в GitHub
  · 4. Автозапуск управляющей сессии
  · 5. Платформа: docker, tailscale
  · 6. Подключение к сети Tailscale
```

Three browser logins in total: Claude Code (**subscription**, not an API key), GitHub and
Tailscale. Re-running is safe at every step. Step 4 replaces the control session, so it asks
for confirmation and closes every open Claude session — run it from a plain terminal, not
from inside a session.

At the end install the [Tailscale client](https://tailscale.com/download) on your laptop and
phone and log in with the same account — the server is closed to the internet and this is the
only way to your projects. In the [Tailscale console](https://login.tailscale.com) enable
**MagicDNS and HTTPS certificates**, so services open as `https://dev-vps.<tailnet>.ts.net`
with a valid certificate.

## First project

```bash
claude-project shop https://github.com/me/shop   # clone and open a session
```

If the project needs ports, claim a block and re-run `init.sh`:

```bash
ports claim shop          # reserves a free block of ten, e.g. 8030-8039
$EDITOR ports/shop.env    # APP_PORT=8030, DB_PORT=8031 — names come from the project's compose file
bash init.sh              # appends them to /projects/shop/.env
```

Then, inside the project session: `make up`, `make test`.

## How it works

Three layers. The host only deals with infrastructure; everything project-specific comes from
the project's own repo — so a project on any stack needs no changes to the server.

| Layer | Provides | Installed by |
|---|---|---|
| **Server** | user `dev`, key-only SSH, Claude Code, sessions | `setup-server.sh` |
| **Platform** | docker, tailscale, firewall, ports, swap | `setup-dev.sh` |
| **Project** | its own database, runtime and versions | the project's `docker-compose.yml` |

`init.sh` calls these in the right order — you never run them by hand. There are deliberately
two scripts: the first one owns access to the server, and breaking it costs you the server.

Agents on this server run in bypass mode, so `setup-server.sh` writes a small deny list into
`~/.claude/settings.json` that holds even there: no edits to `/etc/ssh/**` or `~/.ssh/**`, no
`ufw disable`/`reset`, no stopping or disabling `ssh`, no `passwd`.

## Project rules

Projects must satisfy the [contract](docs/PROJECT-CONTRACT.md): a `Makefile` with `up`/`down`/
`test`, ports through variables, an `.env.example` without secrets.

Agents pick the rules up on their own: Claude Code reads `CLAUDE.md` up the directory tree, so
the rules live in `/projects/CLAUDE.md` and every project session sees them alongside the
project's own `CLAUDE.md`. The text is `templates/projects-CLAUDE.md`, deployed by `init.sh`.

To make an agent bring a project in line, tell it in the project session: «приведи проект к
контракту сервера» — it already knows where the document is.

## Sessions

| Name | Role | Folder |
|---|---|---|
| `vps-main` | server control, never closes | `~/vps` |
| `proj-<name>` | a project's main session | `/projects/<name>` |
| `proj-<project>-<name>` | side task inside a project | `/projects/<project>` |
| `vps-<name>` | side task outside projects | current folder |

The name you see in the app says **where** the session works, not how it was created: the
second session of project `shop` is `proj-shop-2`, right next to the main `proj-shop`. It is
still a side session (`claude-close-all` closes it, the main one it keeps).

Every command works as a slash command in a session, as a plain phrase, and in the terminal.

| Slash | CLI | Action |
|---|---|---|
| `/vps-project` | `claude-project <name> [url]` | project in `/projects`, clones when given a url |
| `/vps-new` | `claude-new <name> [folder]` | side session (defaults to the current folder) |
| `/vps-sessions` | `claude-list` | sessions and their memory |
| `/vps-close` | `claude-close [name]` | close a session |
| `/vps-close-all` | `claude-close-all` | close side sessions |
| `/vps-close-everything` | `claude-close-everything` | close everything but `vps-main` |
| `/vps-ssh` | `claude-ssh [name]` | command to attach to a session's terminal |

The commands themselves are `skills/<name>/SKILL.md`: the file is both the slash command and
the description an agent matches a plain phrase against. Skills are shared by every session on
this VPS — they live in the repo and are deployed to `~/.claude/skills`. Edit the file, then
apply:

```bash
sudo bash setup-server.sh --sessions   # session commands and skills only
```

Closing a session frees its memory; files stay. Side sessions idle for more than 7 days close
themselves. To attach to a live terminal: `ssh dev@<IP> -t 'tmux attach -t <session>'` (detach
without killing it — `Ctrl+B`, then `D`).

### Sessions survive reboots and crashes

Open sessions are tracked in `~/.claude/open-sessions/` — one file per session (working folder
plus the id of its last conversation, refreshed for live sessions every 5 minutes).

- **Server reboot** — `claude-ops.service` brings up `vps-main` and immediately runs
  `claude-restore --boot`: sessions from the registry come back **continuing their previous
  conversation** (`--resume` by the recorded id, otherwise `--continue` with the folder's last
  conversation, otherwise a clean start).
- **A session dies** (OOM, crash) — the `claude-restore.timer` unit revives anything listed in
  the registry but no longer alive, every 5 minutes. `claude-list` shows such sessions
  separately; to revive immediately, run `claude-restore`.
- **Closing by hand** removes the session from the registry, so what you closed stays closed.
  The idle cleanup does the same.

Loop protection: if a session dies **3 times within an hour**, the watchdog stops reviving it
and says so in the journal — that means the session itself is broken, not the server. The
counter resets after an hour, or immediately when you open the session by hand. The watchdog
also refuses to start sessions when less than 800 MB is free, so it never finishes off a
server that is already short on memory.

```bash
claude-restore                           # revive the dead ones right now
claude-registry list                     # what counts as open
journalctl --user -u claude-restore -e   # revival log
```

## Network and security

- Only **SSH** is reachable from the internet (plus `41641/udp`, which lets Tailscale build
  direct connections instead of relaying); 80/443 are closed. Projects are reachable from your
  own devices through Tailscale at `dev-vps.<tailnet>.ts.net`. No domain, nginx or Let's
  Encrypt needed — Tailscale issues a valid certificate itself.
- SSH is key-only, passwords are off, fail2ban is on.
- **Containers are cut off from the internet by a `DOCKER-USER` rule** (in `/etc/ufw/after.rules`).
  Without it a project's database is exposed: docker publishes ports behind UFW's back, and the
  `"ip"` setting in `daemon.json` only covers the default bridge network — compose creates its
  own and publishes on `0.0.0.0`.
- Every project gets a block of 10 ports (`ports/<name>.env`). The `ports` command keeps the
  books: `ports claim <name>` reserves a free block atomically, `ports map` shows what is taken
  and what is free, plus `which`, `free` and `doctor` (conflicts and drift against live ports).
  The registry is shared and lives in git, so a reservation is instantly visible to everyone and
  survives a move. Blocks run from 8010 to 8999; `8060-8069` is reserved for infrastructure.
- **Ports in the tailnet follow "same number" mapping.** Every web service of a project is
  served in the tailnet on the port it uses on the host: `127.0.0.1:8050` →
  `https://dev-vps.<tailnet>.ts.net:8050` — one number per service, matching `ports map`. This
  is done by `ports-web` (installed by `setup-dev.sh`, timer every minute): it tells web
  services from databases by container image (databases and redis are never exposed), picks up
  new projects and removes ones that are gone. Databases stay closed — you reach them through
  DbGate.
- **Dashboard** — a page linking to every taken port (project, service name, description) at
  `https://dev-vps.<tailnet>.ts.net:8062`. Generated by `ports-web`, always current. This is
  the entry point: bookmark one link, reach everything else by clicking.
- **Dozzle** (`:8060`) — a web view of docker containers and their logs, read-only (the docker
  socket is mounted read-only). **DbGate** (`:8061`) — a web database client for all projects:
  connections are stored in the `dbgate-data` docker volume, and it exposes no database ports —
  it joins the projects' docker networks and reaches each database **by container name**. Both
  are infrastructure services listening on `127.0.0.1`; the same `ports-web` publishes them.
- **12 GB of swap** as an OOM cushion — a Claude session takes 300-500 MB, and several of them
  next to project containers is exactly how sessions used to get killed. `setup-dev.sh` grows
  the swap file and leaves it alone once it is big enough.

## Projects keep themselves up to date

`projects-pull` (timer every 2 minutes) pulls into `/projects/*` whatever you pushed from other
machines. It never touches work in progress: `--ff-only` only, and it skips a repo that is not
on `main`, has uncommitted changes, or is mid-merge/rebase. Anything that needs your attention
goes into the log — unpushed local commits (autopull stops there), changed lockfiles, compose
files or migrations (`make up` needed), a changed `.env.example` (git does not carry your `.env`).

```bash
cat ~/.local/state/projects-pull.log
```

## Moving to a new server

Repeat "Install" and "First project" — that is the whole procedure. Two things you carry over
by hand:

- **project secrets** — API keys, tokens for paid packages, Firebase configs; none of them are in git;
- **dev database data** — it lives in docker volumes and is rebuilt by migrations and seeds.

## Files

```
~/vps/                     this repo: scripts, port registry, skills, contract.
                           Also the control session's working folder — its role is in CLAUDE.md
~/vps/bin/                 ports, ports-web — installed into ~/.local/bin
~/vps/skills/              slash commands for sessions — deployed to ~/.claude/skills
~/vps/ports/               a block of ten ports per project
/projects/                 project code + CLAUDE.md with the server rules
~/.local/bin/              claude-* commands, ports, projects-pull
~/.claude/open-sessions/   registry of open sessions (used to restore them)
~/.local/state/            ports-web state, projects-pull.log
```

## When something breaks

- **SSH won't let you in** — check for a ban: `sudo fail2ban-client status sshd`, unban with
  `sudo fail2ban-client set sshd unbanip <IP>`. Login is always by key; never turn passwords on.
- **No access at all** — the hosting panel's VNC console bypasses both SSH and the firewall.
- **A skill from a project repo is invisible** — the repo was cloned into a session that was
  already running; reopen the project (`claude-close X` → `claude-project X`).
- **Archiving in the app doesn't free memory** — it only hides the card, the process keeps
  running. Only `claude-close` frees it.
- **A session hangs in the app and doesn't answer** — the process died (usually OOM) and the
  card stayed. Check `claude-list` (dead ones are listed separately) and
  `journalctl -b -1 | grep -i oom`. The watchdog revives it within 5 minutes; by hand —
  `claude-restore`.
- **A dead session won't come back** — the watchdog may have muted it after three crashes in an
  hour: `journalctl --user -u claude-restore -e`. Fix the cause and open it by hand
  (`claude-project X` / `claude-new X`) — that resets the counter.
- **A project stopped picking up pushes** — most likely it has local commits that were never
  pushed; `~/.local/state/projects-pull.log` says so by name.
