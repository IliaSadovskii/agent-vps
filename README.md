# vps — a server where Claude Code agents live

Turns a clean Ubuntu VPS into a machine where **Claude Code agents run around the clock** and
develop your projects. Sessions survive reboots and crashes, and are reachable from the mobile
app and over SSH. Projects run in docker and are never exposed to the internet.

One control session maintains the server; every project gets its own session in its own folder.
The repo's own docs are written in Russian — this README is the English overview — but the
language agents **talk to you** in is a setting, see [Language](#language).

## Install

Ubuntu 22.04/24.04 with an SSH key on `root`.

```bash
ssh root@<IP>
git clone https://github.com/IliaSadovskii/vps.git && cd vps
sudo bash init.sh
```

The root pass creates the `dev` user, hardens access and copies the repo to `/home/dev/vps`.
Everything after that runs as `dev` — just repeat `bash init.sh`: it prints a checklist, does
the next step and stops whenever it needs you.

```
  ✔ 1. Сервер: пользователь, безопасность, пакеты
  ▶ 2. Вход в Claude Code
  · 3. Вход в GitHub
  · 4. Автозапуск управляющей сессии
  · 5. Платформа: docker, tailscale
  · 6. Подключение к сети Tailscale
```

Three browser logins: Claude Code (**subscription**, not an API key), GitHub, Tailscale.
Re-running is safe at every step; step 4 restarts every open session, so run it from a plain
terminal. Finally, install the [Tailscale client](https://tailscale.com/download) on your laptop
and phone — the server is closed to the internet and this is the only way in. Enable **MagicDNS
and HTTPS certificates** in the [Tailscale console](https://login.tailscale.com).

## First project

```bash
claude-project shop https://github.com/me/shop   # clone and open a session

ports claim shop          # reserve a free block of ten, e.g. 8030-8039
$EDITOR ports/shop.env    # APP_PORT=8030, DB_PORT=8031 — names come from the project's compose file
bash init.sh              # append them to /projects/shop/.env
```

Then, inside the project session: `make up`, `make test`.

## How it works

Three layers. The host only deals with infrastructure; everything project-specific comes from
the project's own repo, so a project on any stack needs no changes to the server.

| Layer | Provides | Installed by |
|---|---|---|
| **Server** | user `dev`, key-only SSH, Claude Code, sessions | `setup-server.sh` |
| **Platform** | docker, tailscale, firewall, ports, swap | `setup-dev.sh` |
| **Project** | its own database, runtime and versions | the project's `docker-compose.yml` |

`init.sh` calls these in the right order — you never run them by hand. Two scripts deliberately:
the first one owns access to the server, and breaking it costs you the server.

Projects must satisfy the [contract](docs/PROJECT-CONTRACT.md): a `Makefile` with `up`/`down`/
`test`, ports through variables, an `.env.example` without secrets. Agents pick the rules up on
their own — Claude Code reads `CLAUDE.md` up the tree, so they live in `/projects/CLAUDE.md`
(from `templates/projects-CLAUDE.md`).

## Sessions

| Name | Role | Folder |
|---|---|---|
| `vps-main` | server control, never closes | `~/vps` |
| `proj-<name>` | a project's main session | `/projects/<name>` |
| `proj-<project>-<name>` | side task inside a project | `/projects/<project>` |
| `vps-<name>` | side task outside projects | current folder |

The name in the app says **where** the session works, not how it was created: the second session
of `shop` is `proj-shop-2`, next to the main `proj-shop`. It is still a side session —
`claude-close-all` closes it, the main one it keeps.

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

The commands are `skills/<name>/SKILL.md` — the file is both the slash command and the
description an agent matches a plain phrase against. Skills live in the repo and are deployed to
`~/.claude/skills`, shared by every session. Edit one, then apply with
`sudo bash setup-server.sh --sessions`.

Closing frees memory; files stay. Side sessions idle for 7 days close themselves. Attach to a
live terminal: `ssh dev@<IP> -t 'tmux attach -t <session>'` (`Ctrl+B`, then `D` to detach).

**Reboots and crashes.** Open sessions are tracked in `~/.claude/open-sessions/` (working folder
+ last conversation id). After a reboot `claude-ops.service` runs `claude-restore --boot` and
they come back **continuing their conversation**; a session that dies on its own (OOM, crash) is
revived by `claude-restore.timer` within 5 minutes — `claude-list` lists such sessions
separately. Closing by hand deregisters the session, so what you closed stays closed. If a
session dies 3 times in an hour the watchdog stops reviving it (`journalctl --user -u
claude-restore -e`), and it never starts anything when less than 800 MB is free.

## Language

Nothing on this server orders agents to speak Russian — they simply mirror the language of what
they read, and the rules and skills happen to be Russian. So the reply language is set
explicitly, in `vps.conf`:

```bash
AGENT_LANG=en     # ru, en, or a language name in English: Spanish, Japanese
bash init.sh      # writes the directive into ~/.claude/CLAUDE.md, read by every session
```

Rules, skills and command output stay Russian — translating them is not what makes the server
multilingual; one explicit line is. The file is only read at session start, so reopen a session
to apply the change (or just ask the agent to switch for this conversation).

## Network and security

- Only **SSH** is reachable from the internet, plus `41641/udp` for direct Tailscale
  connections; 80/443 are closed, passwords are off, fail2ban is on. Projects are reachable from
  your own devices at `dev-vps.<tailnet>.ts.net` — no domain, nginx or Let's Encrypt needed.
- **Containers are cut off from the internet by a `DOCKER-USER` rule** (`/etc/ufw/after.rules`).
  Without it a project's database is exposed: docker publishes ports behind UFW's back, and
  `"ip"` in `daemon.json` only covers the default bridge network — compose creates its own.
- Agents run in bypass mode, so `~/.claude/settings.json` carries a deny list that holds even
  there: no edits to `/etc/ssh/**` or `~/.ssh/**`, no `ufw disable`/`reset`, no stopping `ssh`,
  no `passwd`.
- Every project owns a block of 10 ports (`ports/<name>.env`, in git). `ports claim <name>`
  reserves a free block atomically, `ports map` shows what is taken; also `which`, `free`,
  `doctor`. Blocks run 8010-8999; `8060-8069` is infrastructure.
- **Same-number mapping into the tailnet**: `127.0.0.1:8050` → `https://dev-vps.<tailnet>.ts.net:8050`.
  Done by `ports-web` (timer every minute), which tells web services from databases by container
  image — databases are never exposed. It also generates the **dashboard** at `:8062`, a page
  linking to every taken port. Bookmark that one link.
- **A shared proxy in front of every project** (`vps-proxy`, Caddy). Tailscale terminates TLS but
  ships bytes as they come, and dev servers rarely send `Cache-Control` — so a megabyte of markup
  is re-downloaded in full on every reload. The proxy gzips responses and marks fingerprinted
  build assets (`/build/assets/app-C6yGb0eL.css`) immutable for a year. On a real Laravel page
  that is 878 KB → 169 KB. **No repository changes anything for this**: a project keeps listening
  on its own port `80XY`, the proxy listens on the shadow port `90XY` and the tailnet mapping
  points there instead — `tailnet :8050 → 127.0.0.1:9050 → 127.0.0.1:8050`. Port numbers you use
  stay the same. `ports-web` writes the Caddyfile and only switches a service over once the proxy
  answers its own health path, so a broken proxy means "slow, as before", never "down".
- **Dozzle** (`:8060`) — docker containers and logs, read-only socket. **DbGate** (`:8061`) —
  a database client for all projects; it opens no database ports, it joins the projects' docker
  networks and reaches each database by container name.
- **12 GB of swap** as an OOM cushion — a session takes 300-500 MB, and several of them next to
  project containers is exactly how sessions used to get killed.

## Projects keep themselves up to date

`projects-pull` (timer every 2 minutes) pulls what you pushed from other machines. It never
touches work in progress: `--ff-only` only, and it skips a repo that is not on `main`, is dirty,
or is mid-merge. Anything needing attention goes to `~/.local/state/projects-pull.log` —
unpushed local commits (autopull stops there), changed lockfiles, compose files or migrations
(`make up` needed), a changed `.env.example`.

## Moving to a new server

Repeat "Install" and "First project". Two things you carry by hand: **project secrets** (API
keys, tokens, Firebase configs — none of them are in git) and **dev database data** (docker
volumes, rebuilt by migrations and seeds).

## Files

```
~/vps/                     this repo: scripts, port registry, skills, contract.
       vps.conf            server settings (agent language)
       bin/                ports, ports-web — installed into ~/.local/bin
       skills/             slash commands — deployed to ~/.claude/skills
       ports/              a block of ten ports per project
/projects/                 project code + CLAUDE.md with the server rules
~/.local/bin/              claude-* commands, ports, projects-pull
~/.claude/open-sessions/   registry of open sessions (used to restore them)
~/.local/state/            ports-web state, projects-pull.log
       vps-proxy/Caddyfile generated by ports-web — edits here are overwritten
```

## When something breaks

- **SSH won't let you in** — check for a ban: `sudo fail2ban-client status sshd`, unban with
  `sudo fail2ban-client set sshd unbanip <IP>`. Login is always by key; never turn passwords on.
  With no access at all, the hosting panel's VNC console bypasses SSH and the firewall.
- **A session hangs in the app and doesn't answer** — the process died (usually OOM) and the
  card stayed. `claude-list` lists dead ones separately, `journalctl -b -1 | grep -i oom` shows
  why; `claude-restore` brings them back now. Archiving in the app frees nothing — only
  `claude-close` does.
- **A skill from a project repo is invisible** — the repo was cloned into an already running
  session; reopen the project (`claude-close X` → `claude-project X`).
- **A project stopped picking up pushes** — most likely unpushed local commits;
  `~/.local/state/projects-pull.log` names it.
