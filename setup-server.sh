#!/usr/bin/env bash
#
# ============================================================================
#  VPS BOOTSTRAP  —  окружение для AI-разработки (Claude Code)
#  Для Ubuntu VPS. Идемпотентный: можно запускать повторно без вреда.
# ============================================================================
#
#  ЗАПУСК 1 — под root, делает ВСЁ кроме автозапуска:
#      bash setup-server.sh
#    · пользователь dev с NOPASSWD sudo + твой SSH-ключ
#    · пакеты, Node.js, Claude Code
#    · bypass-режим Claude, каталог /projects
#    · механизм параллельных сессий (claude-new / list / kill + скилл)
#    · хардинг: SSH только по ключу, root off, fail2ban, UFW
#
#  >>> потом вручную (в браузере) авторизуешь Claude <<<
#
#  ЗАПУСК 2 — под dev, автозапуск Remote Control:
#      bash setup-server.sh --service
#
#  Все шаги проверяют «уже сделано?» и пропускают — повторный запуск безопасен.
#
#  ПАРАШЮТ (если запрёшься по SSH):
#    cloud.freakhosting.com → VPS → Options → Enable VNC Access →
#    Browser VNC → root по паролю.
# ============================================================================

set -euo pipefail

# ------------------------- НАСТРОЙКИ -------------------------
DEV_USER="dev"
PROJECTS_DIR="/projects"
OPS_DIR="/home/$DEV_USER/vps"   # репозиторий = рабочая папка управляющей сессии
TIMEZONE="Asia/Tbilisi"
TMUX_SESSION="claude-ops"
# -------------------------------------------------------------

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_RST=$'\e[0m'
say()  { echo "${C_INFO}▶ $*${C_RST}"; }
ok()   { echo "${C_OK}✔ $*${C_RST}"; }
warn() { echo "${C_WARN}⚠ $*${C_RST}"; }
die()  { echo "${C_ERR}✗ $*${C_RST}" >&2; exit 1; }
skip() { echo "${C_OK}✔ $* (уже есть, пропускаю)${C_RST}"; }

# ============================================================================
#  Устанавливает механизм параллельных сессий под пользователя $DEV_USER.
#  Вызывается из main(). Идемпотентно — просто перезаписывает файлы.
# ============================================================================
install_parallel_sessions() {
  local home="/home/$DEV_USER"
  local bin="$home/.local/bin"
  local skills="$home/.claude/skills"
  install -d -o "$DEV_USER" -g "$DEV_USER" "$bin" "$skills"

  # ── СХЕМА ИМЁН СЕССИЙ ──────────────────────────────────────────────
  #  vps-main (tmux: claude-ops) — глобальная управляющая, не закрывается
  #  ccp-<имя> — ГЛАВНАЯ сессия проекта (claude-project); close-all бережёт
  #  cc-<имя>  — ПОБОЧНАЯ (claude-new): временная управляющая или дочерняя
  # ───────────────────────────────────────────────────────────────────

  # claude-new — ПОБОЧНАЯ сессия В ТЕКУЩЕЙ папке (наследует папку родителя).
  # Из vps-main (~/vps) → в ~/vps. Изнутри проекта → в папке проекта.
  cat > "$bin/claude-new" <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:-}"
OPS_DIR="$HOME/vps"
CLAUDE_BIN="$HOME/.local/bin/claude"
if [[ -z "$NAME" ]]; then
  echo "Использование: claude-new <имя>" >&2
  echo "Пример:        claude-new debug" >&2
  exit 1
fi
if ! [[ "$NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "Имя может содержать только буквы, цифры и дефис." >&2
  exit 1
fi
# имя не должно быть занято ни в одном из префиксов
if tmux has-session -t "cc-$NAME" 2>/dev/null || tmux has-session -t "ccp-$NAME" 2>/dev/null; then
  echo "Имя '$NAME' уже занято другой сессией. Выбери другое."
  exit 0
fi
# наследуем текущую папку (внутри tmux) или ops по умолчанию
if [[ -n "${TMUX:-}" ]]; then
  WORKDIR="$(tmux display-message -p '#{pane_current_path}')"
else
  WORKDIR="$OPS_DIR"
fi
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="claude"
tmux new-session -d -s "cc-$NAME" -c "$WORKDIR" \
  "$CLAUDE_BIN --dangerously-skip-permissions --remote-control --name vps-$NAME"
sleep 2
if tmux has-session -t "cc-$NAME" 2>/dev/null; then
  echo "✔ Сессия 'vps-$NAME' (побочная) запущена в: $WORKDIR"
  echo "  Закрыть: claude-close $NAME"
else
  echo "✗ Не удалось запустить '$NAME'." >&2
  exit 1
fi
HELPER_EOF

  # claude-project — ГЛАВНАЯ сессия проекта в /projects/<имя> (имя ccp-*).
  # Опциональный второй аргумент — ссылка на GitHub-репозиторий (клонируется).
  cat > "$bin/claude-project" <<'PROJ_EOF'
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:-}"
REPO_URL="${2:-}"
PROJECTS_DIR="/projects"
CLAUDE_BIN="$HOME/.local/bin/claude"
if [[ -z "$NAME" ]]; then
  echo "Использование: claude-project <имя-проекта> [github-url]" >&2
  echo "Примеры:  claude-project shop" >&2
  echo "          claude-project shop https://github.com/me/shop" >&2
  exit 1
fi
if ! [[ "$NAME" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "Имя может содержать только буквы, цифры и дефис." >&2
  exit 1
fi
PROJ_PATH="$PROJECTS_DIR/$NAME"
if tmux has-session -t "ccp-$NAME" 2>/dev/null; then
  echo "Проект '$NAME' уже открыт (proj-$NAME). Переключись на него в приложении."
  exit 0
fi
# Если дана ссылка — клонируем (для приватных нужен gh auth login заранее)
if [[ -n "$REPO_URL" ]]; then
  if [[ -d "$PROJ_PATH/.git" ]]; then
    echo "В $PROJ_PATH уже есть git-репозиторий — пропускаю клонирование."
    VERB="переоткрыт"
  else
    echo "Клонирую $REPO_URL → $PROJ_PATH …"
    if git clone "$REPO_URL" "$PROJ_PATH"; then
      echo "✔ Репозиторий склонирован."
      VERB="создан из репозитория"
    else
      echo "✗ Не удалось склонировать. Проверь: приватный репо → нужен 'gh auth login'." >&2
      exit 1
    fi
  fi
else
  if [[ -d "$PROJ_PATH" ]]; then VERB="переоткрыт"; else mkdir -p "$PROJ_PATH"; VERB="создан"; fi
fi
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="claude"
tmux new-session -d -s "ccp-$NAME" -c "$PROJ_PATH" \
  "$CLAUDE_BIN --dangerously-skip-permissions --remote-control --name proj-$NAME"
sleep 2
if tmux has-session -t "ccp-$NAME" 2>/dev/null; then
  echo "✔ Проект 'proj-$NAME' $VERB в $PROJ_PATH, сессия запущена (главная проекта)."
  echo "  Внутри неё claude-new создаёт дочерние сессии в этой же папке."
else
  echo "✗ Не удалось открыть проект '$NAME'." >&2
  exit 1
fi
PROJ_EOF

  # claude-list — все сессии с памятью, помечает тип
  cat > "$bin/claude-list" <<'LIST_EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "Живые Claude-сессии на этом VPS:"
echo
found=0
while IFS= read -r line; do
  sname=$(echo "$line" | cut -d: -f1)
  case "$sname" in
    claude-ops|cc-*|ccp-*)
      found=1
      pids=$(tmux list-panes -t "$sname" -F '#{pane_pid}' 2>/dev/null || true)
      mem=0
      for p in $pids; do
        for pp in $(pgrep -P "$p" 2>/dev/null; echo "$p"); do
          rss=$(awk '/VmRSS/{print $2}' "/proc/$pp/status" 2>/dev/null || echo 0)
          mem=$((mem + ${rss:-0}))
        done
      done
      mb=$((mem / 1024))
      case "$sname" in
        claude-ops) disp="vps-main (управление, не закрыть)";;
        ccp-*)      disp="proj-${sname#ccp-} (главная проекта)";;
        cc-*)       disp="vps-${sname#cc-} (побочная)";;
      esac
      printf "  • %-34s ~%s МБ\n" "$disp" "$mb"
      ;;
  esac
done < <(tmux ls 2>/dev/null || true)
[ "$found" = "0" ] && echo "  (активных сессий нет)"
echo
echo "Закрыть: claude-close <имя> | все побочные: claude-close-all | всё: claude-close-everything"
LIST_EOF

  # claude-close — закрыть сессию (себя без аргумента, или названную из любого префикса)
  cat > "$bin/claude-close" <<'CLOSE_EOF'
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    TN="$(tmux display-message -p '#S')"
  else
    echo "Не в сессии и имя не указано. Использование: claude-close [имя]" >&2
    exit 1
  fi
else
  if tmux has-session -t "ccp-$NAME" 2>/dev/null; then TN="ccp-$NAME"
  elif tmux has-session -t "cc-$NAME" 2>/dev/null; then TN="cc-$NAME"
  else echo "Сессия '$NAME' не найдена."; exit 0; fi
fi
if [[ "$TN" == "claude-ops" || "$TN" == "vps-main" ]]; then
  echo "Основную управляющую (vps-main) закрывать нельзя." >&2
  exit 1
fi
tmux has-session -t "$TN" 2>/dev/null || { echo "Не найдена."; exit 0; }
case "$TN" in
  ccp-*) disp="proj-${TN#ccp-}";;
  cc-*)  disp="vps-${TN#cc-}";;
  *)     disp="$TN";;
esac
echo "✔ Сессия '$disp' закрывается… через пару секунд станет offline. Файлы на диске целы."
( sleep 2; tmux kill-session -t "$TN" 2>/dev/null ) &
disown 2>/dev/null || true
CLOSE_EOF

  # claude-close-all — только ПОБОЧНЫЕ (cc-*). Бережёт главные проектов и vps-main.
  cat > "$bin/claude-close-all" <<'CLOSEALL_EOF'
#!/usr/bin/env bash
set -euo pipefail
n=0
for s in $(tmux ls 2>/dev/null | cut -d: -f1 | grep '^cc-'); do
  ( sleep 2; tmux kill-session -t "$s" 2>/dev/null ) &
  disown 2>/dev/null || true
  echo "  закрываю побочную: vps-${s#cc-}"
  n=$((n+1))
done
if [ "$n" = 0 ]; then
  echo "Побочных сессий нет (главные проектов и vps-main не трогаются)."
else
  echo "✔ Закрыто побочных: $n. Главные проектов и vps-main целы."
fi
CLOSEALL_EOF

  # claude-close-everything — cc-* И ccp-*. Бережёт только vps-main. Папки целы.
  cat > "$bin/claude-close-everything" <<'CLOSEEVERY_EOF'
#!/usr/bin/env bash
set -euo pipefail
n=0
for s in $(tmux ls 2>/dev/null | cut -d: -f1 | grep -E '^(cc-|ccp-)'); do
  ( sleep 2; tmux kill-session -t "$s" 2>/dev/null ) &
  disown 2>/dev/null || true
  if [ "${s#ccp-}" != "$s" ]; then echo "  закрываю проект: proj-${s#ccp-}"
  else echo "  закрываю побочную: vps-${s#cc-}"; fi
  n=$((n+1))
done
if [ "$n" = 0 ]; then
  echo "Нечего закрывать (только vps-main)."
else
  echo "✔ Закрыто всё ($n), кроме vps-main. Папки проектов на диске целы — переоткрыть: claude-project <имя>."
fi
CLOSEEVERY_EOF

  # claude-ssh — готовая команда подключения к терминалу сессии из компьютера.
  cat > "$bin/claude-ssh" <<'SSH_EOF'
#!/usr/bin/env bash
set -euo pipefail
DEV_USER="dev"
NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    TN="$(tmux display-message -p '#S')"
  else
    echo "Не в сессии и имя не указано. Использование: claude-ssh [имя|main]" >&2
    exit 1
  fi
elif [[ "$NAME" == "main" ]]; then
  TN="claude-ops"
elif tmux has-session -t "ccp-$NAME" 2>/dev/null; then
  TN="ccp-$NAME"
elif tmux has-session -t "cc-$NAME" 2>/dev/null; then
  TN="cc-$NAME"
else
  echo "Сессия '$NAME' не найдена. Список: claude-list" >&2
  exit 1
fi
get_ip() {
  local ip
  for src in "ifconfig.me" "api.ipify.org" "icanhazip.com"; do
    ip="$(curl -s --max-time 5 "https://$src" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then echo "$ip"; return 0; fi
  done
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && echo "$ip" || echo "<IP-сервера>"
}
IP="$(get_ip)"
case "$TN" in
  claude-ops) disp="vps-main";;
  ccp-*) disp="proj-${TN#ccp-}";;
  cc-*) disp="vps-${TN#cc-}";;
  *) disp="$TN";;
esac
echo "Подключение к терминалу сессии '$disp':"
echo
echo "  ssh $DEV_USER@$IP -t 'tmux attach -t $TN'"
echo
echo "Скопируй в терминал на компьютере — попадёшь прямо в сессию."
echo "Выйти не убивая сессию: Ctrl+B, затем D."
[[ "$IP" == "<IP-сервера>" ]] && echo "(IP определить не удалось — подставь адрес VPS вручную)"
SSH_EOF

  # claude-cleanup — гасит cc-* сессии без активности > MAX_IDLE_DAYS (по умолч. 7).
  # Запускается таймером раз в сутки. vps-main / claude-ops не трогает.
  cat > "$bin/claude-cleanup" <<'CLEANUP_EOF'
#!/usr/bin/env bash
set -euo pipefail
MAX_IDLE_DAYS="${MAX_IDLE_DAYS:-7}"
now=$(date +%s)
max_idle=$(( MAX_IDLE_DAYS * 86400 ))
tmux ls 2>/dev/null | cut -d: -f1 | grep '^cc-' | while read -r sname; do
  last=$(tmux list-windows -t "$sname" -F '#{window_activity}' 2>/dev/null | sort -n | tail -1)
  [ -z "$last" ] && continue
  idle=$(( now - last ))
  if [ "$idle" -gt "$max_idle" ]; then
    echo "$(date '+%F %T') автоочистка: закрываю '$sname' (простой $((idle/86400)) дн)"
    tmux kill-session -t "$sname" 2>/dev/null || true
  fi
done
CLEANUP_EOF

  # ── СКИЛЛЫ ─────────────────────────────────────────────────────────
  # Каждая возможность — отдельный скилл (папка + SKILL.md). Имя папки даёт
  # слэш-команду (/vps-new и т.д.), а описание — срабатывание по обычному
  # тексту. Тело скилла говорит агенту вызвать соответствующую CLI-утилиту.
  # CLI-утилиты в ~/.local/bin остаются — скиллы их вызывают.

  # /vps-new
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-new"
  cat > "$skills/vps-new/SKILL.md" <<'S_EOF'
---
name: vps-new
description: Создать новую ПОБОЧНУЮ Claude-сессию на этом VPS в текущей папке. Используй, когда пользователь просит создать новую или параллельную сессию, поработать над задачей отдельно ("создай сессию для X", "новая сессия под отладку", "хочу параллельно заняться Y"). Слэш-команда /vps-new.
---
Создай побочную сессию командой `claude-new <имя>`.
1. Определи короткое латинское имя из запроса (отладка→debug, платежи→payments). Если пользователь назвал — используй его.
2. Выполни `claude-new <имя>`. Сессия появится в приложении как `vps-<имя>` в текущей папке.
3. Сообщи, что сессия создана и видна в приложении (раздел Code).
НЕ создавай сессию, если пользователь просто хочет очистить контекст — для этого /clear.
S_EOF

  # /vps-project
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-project"
  cat > "$skills/vps-project/SKILL.md" <<'S_EOF'
---
name: vps-project
description: Создать или переоткрыть ПРОЕКТ на этом VPS (главная сессия проекта в /projects), опционально склонировав GitHub-репозиторий. Используй, когда пользователь просит создать проект, завести проект под что-то, открыть или вернуться к проекту ("создай проект shop", "заведи проект под магазин", "открой проект X"). Слэш-команда /vps-project.
---
Создай/переоткрой проект командой `claude-project <имя> [github-url]`.

Если пользователь дал и имя, и ссылку сразу («создай проект shop из github.com/me/shop») — сразу выполни `claude-project shop https://github.com/me/shop`.

Если деталей нет — ВЕДИ ДИАЛОГ, собери СНАЧАЛА обе вещи, ПОТОМ вызови команду ОДИН раз. НЕ создавай проект, получив только имя: если создать сессию до клонирования, скиллы из репозитория не загрузятся.
1. Спроси: «Как назвать проект?» — дождись, преобразуй в латинское имя.
2. Спроси: «Есть GitHub-репозиторий? Пришли ссылку — склонирую сразу. Или "нет" — создам пустой.» — дождись ответа.
3. Теперь вызови: со ссылкой → `claude-project <имя> <url>`; без → `claude-project <имя>`.
4. Сообщи результат: проект создан/склонирован, сессия proj-<имя> в приложении.

Переоткрытие существующего проекта — та же команда `claude-project <имя>` (код на диске цел).
Если скилл/команда из репозитория не видны (репо склонировали в живую сессию) → `/reload-skills`; если не помогло — переоткрой проект (claude-close <имя> → claude-project <имя>).
S_EOF

  # /vps-sessions
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-sessions"
  cat > "$skills/vps-sessions/SKILL.md" <<'S_EOF'
---
name: vps-sessions
description: Показать список живых Claude-сессий на этом VPS и сколько памяти каждая занимает. Используй, когда пользователь спрашивает, какие сессии открыты, сколько их, сколько памяти они едят ("какие сессии открыты", "покажи сессии", "сколько памяти жрут сессии"). Слэш-команда /vps-sessions.
---
Выполни `claude-list` и покажи пользователю результат — список сессий с памятью каждой.
S_EOF

  # /vps-close
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-close"
  cat > "$skills/vps-close/SKILL.md" <<'S_EOF'
---
name: vps-close
description: Закрыть Claude-сессию на этом VPS — текущую или названную. Используй, когда пользователь просит закрыть сессию, завершить текущую сессию, закрыть конкретную сессию по имени ("закройся", "заверши эту сессию", "закрой сессию payments"). Слэш-команда /vps-close.
---
Закрой сессию командой `claude-close [имя]`.
- «закройся» / «заверши эту сессию» (без имени) → `claude-close` без аргумента (закроет текущую). Предупреди: сессия закроется через пару секунд, станет offline в приложении. НЕ делай этого в основной сессии vps-main.
- «закрой сессию X» → `claude-close X`.
Закрытие не удаляет файлы — только выгружает процесс. Проект переоткрывается через vps-project.
S_EOF

  # /vps-close-all
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-close-all"
  cat > "$skills/vps-close-all/SKILL.md" <<'S_EOF'
---
name: vps-close-all
description: Закрыть все ПОБОЧНЫЕ Claude-сессии на этом VPS, сохранив главные сессии проектов и vps-main. Используй, когда пользователь просит закрыть лишние или побочные сессии, прибрать ("закрой лишние сессии", "закрой побочные", "прибери сессии"). Слэш-команда /vps-close-all.
---
Выполни `claude-close-all` — закроет побочные (vps-*) сессии. Главные сессии проектов (proj-*) и vps-main остаются. Сообщи, сколько закрыто.
S_EOF

  # /vps-close-everything
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-close-everything"
  cat > "$skills/vps-close-everything/SKILL.md" <<'S_EOF'
---
name: vps-close-everything
description: Закрыть ВСЕ Claude-сессии на этом VPS (побочные и проектные), кроме управляющей vps-main. Используй, когда пользователь просит закрыть вообще всё, выгрузить все проекты, освободить сервер полностью ("закрой вообще всё", "выгрузи все проекты тоже", "закрой все сессии включая проекты"). Слэш-команда /vps-close-everything.
---
Выполни `claude-close-everything` — закроет всё, кроме vps-main. Папки проектов на диске целы, переоткрываются через vps-project. Сообщи результат.
S_EOF

  # /vps-ssh
  install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/vps-ssh"
  cat > "$skills/vps-ssh/SKILL.md" <<'S_EOF'
---
name: vps-ssh
description: Показать готовую команду для подключения к терминалу Claude-сессии с компьютера по SSH. Используй, когда пользователь хочет подключиться к терминалу сессии, зайти в неё через SSH, получить команду прямого подключения ("дай ssh-команду", "как подключиться к терминалу этой сессии", "хочу зайти в терминал"). Слэш-команда /vps-ssh.
---
Выполни `claude-ssh [имя]` (без имени — текущая сессия; `main` — основная; имя проекта/побочной — конкретная). Покажи пользователю готовую строку `ssh …`, которую он скопирует в терминал компьютера. Объясни: это подключит к той же живой сессии в полноценном терминале.
S_EOF


  chmod +x "$bin/claude-new" "$bin/claude-project" "$bin/claude-list" "$bin/claude-close" "$bin/claude-close-all" "$bin/claude-close-everything" "$bin/claude-ssh" "$bin/claude-cleanup"
  chown -R "$DEV_USER:$DEV_USER" "$home/.local" "$home/.claude"
}

# ============================================================================
#  ОСНОВНОЙ ПРОХОД — под root
# ============================================================================
main() {
  [[ "$(id -u)" -eq 0 ]] || die "Первый проход запускай под root."

  say "Обновляю систему…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y && apt-get upgrade -y

  # --- Пользователь ---
  if id "$DEV_USER" &>/dev/null; then
    skip "Пользователь '$DEV_USER'"
  else
    say "Создаю пользователя '$DEV_USER'…"
    useradd -m -s /bin/bash "$DEV_USER"
    warn "Задай пароль для '$DEV_USER' (для аварийной VNC-консоли):"
    passwd "$DEV_USER"
  fi
  usermod -aG sudo "$DEV_USER"

  # --- NOPASSWD sudo ---
  if [[ -f "/etc/sudoers.d/90-$DEV_USER" ]]; then
    skip "NOPASSWD sudo"
  else
    say "Настраиваю passwordless sudo…"
    echo "$DEV_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$DEV_USER"
    chmod 440 "/etc/sudoers.d/90-$DEV_USER"
    visudo -c &>/dev/null || die "sudoers сломан — НЕ выходи из root-сессии, чини!"
    ok "NOPASSWD sudo настроен."
  fi

  # --- SSH-ключ ---
  if [[ -s "/home/$DEV_USER/.ssh/authorized_keys" ]]; then
    skip "SSH-ключ для '$DEV_USER'"
  else
    say "Копирую SSH-ключ из root…"
    ROOT_KEYS="/root/.ssh/authorized_keys"
    [[ -s "$ROOT_KEYS" ]] || die "У root нет authorized_keys — стоп (иначе запрёшься)."
    install -d -m 700 -o "$DEV_USER" -g "$DEV_USER" "/home/$DEV_USER/.ssh"
    install -m 600 -o "$DEV_USER" -g "$DEV_USER" "$ROOT_KEYS" "/home/$DEV_USER/.ssh/authorized_keys"
    ok "Ключ скопирован."
  fi

  # --- Пакеты ---
  say "Ставлю базовые пакеты…"
  apt-get install -y curl ca-certificates git tmux htop tree acl \
       build-essential python3 python3-pip fail2ban ufw unzip gh
  ok "Пакеты на месте."

  if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ok "Таймзона: $TIMEZONE"
  else
    warn "Таймзона '$TIMEZONE' не найдена — оставляю текущую. Список: timedatectl list-timezones"
  fi

  # --- Node.js ---
  if command -v node &>/dev/null; then
    skip "Node.js ($(node --version))"
  else
    say "Ставлю Node.js 22 LTS…"
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
    ok "Node.js: $(node --version)"
  fi

  # --- Claude Code, настройки — под dev ---
  say "Ставлю/обновляю Claude Code и настройки под '$DEV_USER'…"
  runuser -l "$DEV_USER" -c '
    set -e
    mkdir -p "$HOME/.npm-global"
    npm config set prefix "$HOME/.npm-global"
    grep -q ".npm-global/bin" "$HOME/.bashrc" || echo "export PATH=\"\$HOME/.npm-global/bin:\$PATH\"" >> "$HOME/.bashrc"
    grep -q ".local/bin" "$HOME/.bashrc" || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

    # Claude Code — ставим, только если ещё нет
    if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
      curl -fsSL https://claude.ai/install.sh | bash
    fi

    # Bypass-режим — только если settings.json ещё нет
    mkdir -p "$HOME/.claude"
    if [ ! -f "$HOME/.claude/settings.json" ]; then
      printf "%s\n" "{" "  \"permissions\": {" "    \"defaultMode\": \"bypassPermissions\"" "  }" "}" > "$HOME/.claude/settings.json"
    fi
  '
  ok "Claude Code готов, bypass-режим включён."

  # --- Механизм параллельных сессий ---
  say "Устанавливаю механизм параллельных сессий (claude-new/list/kill + скилл)…"
  install_parallel_sessions
  ok "Команды и слэш-скиллы (/vps-new, /vps-project, /vps-ssh, /vps-close…) готовы."

  # --- Каталог проектов ---
  if [[ -d "$PROJECTS_DIR" ]]; then
    skip "Каталог $PROJECTS_DIR"
  else
    say "Создаю $PROJECTS_DIR…"
    install -d "$PROJECTS_DIR" -o "$DEV_USER" -g "$DEV_USER" -m 2775
    setfacl -m "d:g:$DEV_USER:rwx" "$PROJECTS_DIR" 2>/dev/null || true
    ok "Каталог проектов готов."
  fi
  ln -sfn "$PROJECTS_DIR" "/home/$DEV_USER/projects"
  chown -h "$DEV_USER:$DEV_USER" "/home/$DEV_USER/projects"

  # Папка управляющей сессии — это сам репозиторий ($OPS_DIR): там лежат
  # скрипты, которыми настраивается сервер, и CLAUDE.md с ролью агента. Отдельный
  # «кабинет» не нужен — он лишь плодил бы роль, не попадающую в git. Репозиторий
  # кладёт сюда init.sh сразу после этого шага.

  # --- fail2ban ---
  if [[ -f /etc/fail2ban/jail.local ]]; then
    skip "fail2ban"
  else
    say "Настраиваю fail2ban…"
    cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
[sshd]
enabled = true
port = ssh
backend = systemd
# Пороги мягкие намеренно: вход только по ключу (PasswordAuthentication no),
# поэтому брутфорс паролем невозможен в принципе — fail2ban лишь чистит мусор
# в логах. Жёсткие пороги + эскалация раньше приводили к самобану при входе
# с динамического IP. 10 попыток, 15 минут, без нарастания срока.
maxretry = 10
findtime = 10m
bantime = 15m
EOF
    systemctl enable --now fail2ban && ok "fail2ban активен (мягкие пороги, защита — ключи)."
  fi

  # --- UFW ---
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    skip "UFW (уже включён)"
  else
    say "Настраиваю firewall (UFW)…"
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow ssh
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ok "UFW включён (22, 80, 443)."
  fi

  # --- SSH hardening (с самопроверкой) ---
  if [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; then
    skip "SSH hardening"
  else
    say "Проверяю готовность dev перед закрытием root-доступа…"
    [[ -s "/home/$DEV_USER/.ssh/authorized_keys" ]] || die "У dev нет ключа — НЕ закрываю root."
    runuser -l "$DEV_USER" -c 'sudo -n true' 2>/dev/null || die "sudo под dev не работает — НЕ закрываю root."
    ok "dev готов."

    say "Хардинг SSH…"
    cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# prohibit-password: root пускается ПО КЛЮЧУ, но не по паролю. Позволяет
# заходить под root (напр. для SFTP к файлам в корне), сохраняя защиту —
# пароль всё равно отключён, брутфорс невозможен.
PermitRootLogin prohibit-password
PermitEmptyPasswords no
# 6, а не 4 — запас, если ssh-агент перебирает несколько ключей перед нужным.
MaxAuthTries 6
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
UseDNS no
EOF
    chmod 600 /etc/ssh/sshd_config.d/99-hardening.conf
    sshd -t || die "Конфиг SSH невалиден — НЕ рестартую."
    systemctl restart ssh || systemctl restart sshd
    ok "SSH захардирован."
  fi

  echo
  echo "==============================================================="
  echo "${C_OK} ОСНОВНОЙ ПРОХОД ЗАВЕРШЁН.${C_RST}"
  echo "==============================================================="
  echo " Дальше три ручных шага (если ещё не делал):"
  echo
  echo " ${C_INFO}1)${C_RST} Зайди под dev:  ssh $DEV_USER@<IP>  ;  source ~/.bashrc"
  echo " ${C_INFO}2)${C_RST} Авторизуй (в браузере):"
  echo "      claude          # выбери вход по ПОДПИСКЕ, доведи до конца"
  echo "      gh auth login   # GitHub (для приватных репо), потом:"
  echo "      gh auth setup-git  # чтобы git clone приватных работал сам"
  echo " ${C_INFO}3)${C_RST} Автозапуск (под $DEV_USER):  bash $0"
  echo "      (скрипт сам поймёт, что ты под $DEV_USER, и включит автозапуск)"
  echo
  echo " ПАРАШЮТ: cloud.freakhosting.com → VPS → Options → VNC."
  echo "==============================================================="
}

# ============================================================================
#  --service  —  под dev: автозапуск Remote Control
# ============================================================================
setup_service() {
  [[ "$(id -u)" -ne 0 ]] || die "Автозапуск — под '$DEV_USER', НЕ под root."
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  command -v claude &>/dev/null || die "claude не найден. Сделал 'source ~/.bashrc'? И серверная часть (под root) прошла?"

  # Проверка авторизации: если Claude не залогинен — не поднимаем сломанный сервис.
  if [[ ! -f "$HOME/.claude/.credentials.json" ]] && [[ ! -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    warn "Claude, похоже, ещё НЕ авторизован (нет ~/.claude/.credentials.json)."
    echo "  Сначала залогинься — иначе сессия в приложении не появится:"
    echo "     ${C_INFO}claude${C_RST}   → выбери вход по ПОДПИСКЕ, доведи до конца, потом /exit"
    echo "  Затем снова:  ${C_INFO}bash $0${C_RST}"
    die "Автозапуск отменён до авторизации."
  fi

  say "Настраиваю автозапуск (systemd user service + linger)…"
  sudo loginctl enable-linger "$USER"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/claude-ops.service" <<EOF
[Unit]
Description=Claude Code Remote Control (tmux, $PROJECTS_DIR)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$OPS_DIR
# При каждом старте сервиса закрываем ВСЕ старые сессии (основную, побочные,
# проектные) — чтобы после обновления bootstrap гарантированно нигде не остался
# устаревший скилл. Живой остаётся только заново поднятая vps-main; проекты
# переоткрываются вручную (claude-project <имя>), код на диске цел.
# Первый ExecStartPre гасит побочные/проектные, второй — старую основную.
ExecStartPre=-/bin/sh -c 'tmux ls 2>/dev/null | cut -d: -f1 | grep -E "^(cc-|ccp-)" | xargs -r -n1 tmux kill-session -t'
ExecStartPre=-/usr/bin/tmux kill-session -t $TMUX_SESSION
ExecStart=/usr/bin/tmux new-session -d -s $TMUX_SESSION 'claude --dangerously-skip-permissions --remote-control --name vps-main'
ExecStop=/usr/bin/tmux kill-session -t $TMUX_SESSION
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable claude-ops.service
  # restart (а не start) — если сервис уже был, пересоздаёт единственную свежую
  # сессию; ExecStartPre гарантирует, что дубля не возникнет.
  systemctl --user restart claude-ops.service
  sleep 3
  if systemctl --user is-active --quiet claude-ops.service; then
    ok "Сервис claude-ops активен, переживёт перезагрузку."
  else
    warn "Сервис не поднялся. Диагностика:"
    echo "    systemctl --user status claude-ops.service"
    echo "    journalctl --user -u claude-ops.service -e"
  fi

  # --- Таймер автоочистки простаивающих сессий (раз в сутки) ---
  say "Настраиваю автоочистку простаивающих сессий (>7 дней)…"
  cat > "$HOME/.config/systemd/user/claude-cleanup.service" <<EOF
[Unit]
Description=Автоочистка простаивающих Claude-сессий (cc-*, >7 дней)

[Service]
Type=oneshot
Environment=MAX_IDLE_DAYS=7
ExecStart=%h/.local/bin/claude-cleanup
EOF
  cat > "$HOME/.config/systemd/user/claude-cleanup.timer" <<EOF
[Unit]
Description=Запуск автоочистки Claude-сессий раз в сутки

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now claude-cleanup.timer
  ok "Автоочистка включена: простаивающие >7 дней сессии закрываются сами."

  echo
  echo "==============================================================="
  echo "${C_OK} ГОТОВО.${C_RST}"
  echo "==============================================================="
  echo " Основная сессия в приложении: ${C_INFO}vps-main${C_RST} (живёт в ~/vps, управляет сервером)"
  echo " Команды (через Claude в телефоне или напрямую):"
  echo "   «создай сессию для nginx»   → vps-nginx (управляющая, в текущей папке)"
  echo "   «создай проект shop»         → proj-shop (главная проекта, в /projects/shop)"
  echo "   «закрой лишние сессии»       → close-all (проекты остаются)"
  echo "   «закрой вообще всё»          → close-everything (кроме vps-main)"
  echo "   «какие сессии открыты»       → список + память"
  echo "   «дай ssh-команду к терминалу» → строка для входа в сессию с компьютера"
  echo " Папки проектов при закрытии НЕ удаляются. Переоткрыть: «открой проект shop»."
  echo "==============================================================="
}

# ============================================================================
#  Памятка — печатается, если запустил без понимания или не под тем юзером
# ============================================================================
show_help() {
  local who; who="$(whoami)"
  echo
  echo "==============================================================="
  echo "${C_INFO} VPS-BOOTSTRAP — просто запускай  bash $0${C_RST}"
  echo "==============================================================="
  echo
  echo " Скрипт сам понимает, что делать, по тому, под кем ты запущен:"
  echo
  echo " ${C_OK}• Под root${C_RST}  →  настраивает СЕРВЕР"
  echo "     sudo bash $0"
  echo "     (пользователь, программы, безопасность, команды сессий)"
  echo
  echo " ${C_OK}• Под $DEV_USER${C_RST}   →  включает АВТОЗАПУСК Claude"
  echo "     bash $0"
  echo "     (Remote Control + перезапуск основной сессии)"
  echo
  echo " Порядок при первой настройке:"
  echo "   1) под root:  sudo bash $0"
  echo "   2) зайти под $DEV_USER, залогиниться в браузере:"
  echo "        claude       (вход по ПОДПИСКЕ)"
  echo "        gh auth login + gh auth setup-git  (GitHub, для приватных репо)"
  echo "   3) под $DEV_USER:  bash $0"
  echo
  echo " Потом трогать не нужно — сервер работает, сессия в телефоне."
  echo " Запускай снова только чтобы применить изменения скрипта."
  echo "==============================================================="
  echo " Сейчас ты под пользователем: ${C_WARN}$who${C_RST}"
  echo "==============================================================="
}

# ============================================================================
#  Роутер с АВТООПРЕДЕЛЕНИЕМ
#  Без флага скрипт сам понимает, что делать, по текущему пользователю:
#    • под root → серверная часть (пользователь, пакеты, безопасность)
#    • под dev  → автозапуск (Claude Remote Control)
#  Флаг --service оставлен как явная опция, но обычно не нужен.
# ============================================================================
case "${1:-}" in
  "")
    # Автоопределение по пользователю
    if [[ "$(id -u)" -eq 0 ]]; then
      # root → серверная часть
      main
    else
      # не-root (ожидаем dev) → автозапуск
      if [[ "$(whoami)" != "$DEV_USER" ]]; then
        warn "Ты под '$(whoami)', а автозапуск рассчитан на '$DEV_USER'."
        echo "  Если это намеренно — ок, продолжаю. Если нет — зайди под $DEV_USER."
        echo
      fi
      setup_service
    fi
    ;;
  --service)
    # Явный автозапуск — всегда под dev, не root
    if [[ "$(id -u)" -eq 0 ]]; then
      warn "Режим --service — под '$DEV_USER', а ты под root."
      echo "  → Зайди под $DEV_USER:  ${C_INFO}su - $DEV_USER${C_RST}  , потом  ${C_INFO}bash $0${C_RST}"
      show_help
      exit 1
    fi
    setup_service
    ;;
  -h|--help|help)
    show_help
    ;;
  *)
    warn "Неизвестный аргумент: '$1'"
    show_help
    exit 1
    ;;
esac