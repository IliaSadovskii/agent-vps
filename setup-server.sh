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
#    · реестр сессий и их восстановление после ребута и падений (claude-restore)
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

# Папка репозитория — из неё берутся файлы, которые скрипт раскладывает
# по серверу (skills/, templates/). Запуск из любого места.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
  #  Внутри (tmux) имя говорит про ТИП сессии — от него зависит закрытие:
  #    claude-ops — глобальная управляющая, не закрывается никогда
  #    ccp-<имя>  — ГЛАВНАЯ сессия проекта (claude-project); close-all бережёт
  #    cc-<имя>   — ПОБОЧНАЯ (claude-new): временная управляющая или дочерняя
  #  Снаружи (в приложении) имя говорит про МЕСТО работы — считает claude-name:
  #    vps-main, proj-<проект> — как и раньше
  #    побочная в /projects/<проект> → тоже proj-* (proj-shop-2, proj-shop-debug)
  #    побочная вне /projects       → vps-<имя>
  # ───────────────────────────────────────────────────────────────────

  # ── РЕЕСТР ОТКРЫТЫХ СЕССИЙ ─────────────────────────────────────────
  #  ~/.claude/open-sessions/<tmux-имя> — по файлу на сессию:
  #     workdir=<папка>     — где сессия была запущена
  #     session=<uuid>      — последний известный id диалога (для --resume)
  #  Запись появляется при создании сессии и исчезает при ЯВНОМ закрытии
  #  (claude-close*, автоочистка). Аварийная смерть (OOM, краш, ребут) записи
  #  НЕ трогает — именно по ней claude-restore поднимает сессию обратно.
  # ───────────────────────────────────────────────────────────────────
  cat > "$bin/claude-registry" <<'REG_EOF'
#!/usr/bin/env bash
set -euo pipefail
REG="$HOME/.claude/open-sessions"
mkdir -p "$REG/.revives"
cmd="${1:-}"
name="${2:-}"
# Имена сессий валидируются при создании (^[A-Za-z0-9-]+$ с префиксом cc-/ccp-),
# но реестр вызывается и из других мест — проверяем ещё раз, это путь к файлу.
if [[ -n "$name" ]] && ! [[ "$name" =~ ^(cc|ccp)-[A-Za-z0-9-]+$ ]]; then
  echo "claude-registry: недопустимое имя сессии '$name'" >&2
  exit 1
fi
case "$cmd" in
  add)
    printf 'workdir=%s\n' "${3:?нужна папка}" > "$REG/$name"
    # Ручное открытие снимает «карантин» упавшей сессии — счётчик подъёмов с нуля.
    rm -f "$REG/.revives/$name"
    ;;
  set-session)
    [[ -f "$REG/$name" ]] || exit 0
    { grep -v '^session=' "$REG/$name" || true; printf 'session=%s\n' "${3:?нужен id}"; } > "$REG/$name.tmp"
    mv "$REG/$name.tmp" "$REG/$name"
    ;;
  del)
    rm -f "$REG/$name" "$REG/.revives/$name"
    ;;
  get)
    sed -n "s/^${3:?нужен ключ}=//p" "$REG/$name" 2>/dev/null | tail -1
    ;;
  list)
    find "$REG" -maxdepth 1 -type f ! -name '.*' ! -name '*.tmp' -printf '%f\n' 2>/dev/null | sort
    ;;
  *)
    echo "Использование: claude-registry {add <имя> <папка>|set-session <имя> <id>|del <имя>|get <имя> <ключ>|list}" >&2
    exit 1
    ;;
esac
REG_EOF

  # claude-name — единственное место, где tmux-имя превращается в то, что
  # видно в приложении. Побочная сессия в папке проекта — это сессия ЭТОГО
  # проекта, поэтому она тоже proj-*: рядом с proj-shop вторая называется
  # proj-shop-2, а не vps-shop-2. Тип (побочная/главная) по-прежнему живёт в
  # tmux-префиксе (cc-/ccp-), от имени в приложении он не зависит.
  cat > "$bin/claude-name" <<'NAME_EOF'
#!/usr/bin/env bash
set -euo pipefail
TN="${1:-}"
DIR="${2:-}"
case "$TN" in
  claude-ops|vps-main) echo "vps-main"; exit 0;;
  ccp-*) echo "proj-${TN#ccp-}"; exit 0;;
  cc-*)  SHORT="${TN#cc-}";;
  *)     echo "$TN"; exit 0;;
esac
# Папка: аргумент → реестр (там записана папка запуска) → живая tmux-панель.
if [[ -z "$DIR" ]]; then
  DIR="$("$HOME/.local/bin/claude-registry" get "$TN" workdir 2>/dev/null || true)"
fi
if [[ -z "$DIR" ]]; then
  DIR="$(tmux display-message -p -t "$TN" '#{pane_current_path}' 2>/dev/null || true)"
fi
PROJ=""
case "$DIR" in
  /projects/*) PROJ="${DIR#/projects/}"; PROJ="${PROJ%%/*}";;
esac
if [[ -z "$PROJ" ]]; then
  echo "vps-$SHORT"
elif [[ "$SHORT" == "$PROJ" || "$SHORT" == "$PROJ-"* ]]; then
  echo "proj-$SHORT"          # имя уже начинается с проекта — не дублируем
else
  echo "proj-$PROJ-$SHORT"    # claude-new debug в /projects/shop → proj-shop-debug
fi
NAME_EOF

  # claude-new — ПОБОЧНАЯ сессия В ТЕКУЩЕЙ папке (наследует папку родителя).
  # Из vps-main (~/vps) → в ~/vps. Изнутри проекта → в папке проекта.
  # Второй аргумент — явная папка (папку нельзя передать через cd: скрипт
  # берёт её у tmux-панели родителя, а не из cwd вызывающей оболочки).
  cat > "$bin/claude-new" <<'HELPER_EOF'
#!/usr/bin/env bash
set -euo pipefail
NAME="${1:-}"
DIR_ARG="${2:-}"
OPS_DIR="$HOME/vps"
CLAUDE_BIN="$HOME/.local/bin/claude"
if [[ -z "$NAME" ]]; then
  echo "Использование: claude-new <имя> [папка]" >&2
  echo "Пример:        claude-new debug" >&2
  echo "Пример:        claude-new kit-2 /projects/agent-kit" >&2
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
# папка: явный аргумент → папка родительской панели (внутри tmux) → ops
if [[ -n "$DIR_ARG" ]]; then
  if [[ ! -d "$DIR_ARG" ]]; then
    echo "Папки '$DIR_ARG' нет." >&2
    exit 1
  fi
  WORKDIR="$(cd "$DIR_ARG" && pwd)"
elif [[ -n "${TMUX:-}" ]]; then
  WORKDIR="$(tmux display-message -p '#{pane_current_path}')"
else
  WORKDIR="$OPS_DIR"
fi
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="claude"
DISP="$("$HOME/.local/bin/claude-name" "cc-$NAME" "$WORKDIR")"
tmux new-session -d -s "cc-$NAME" -c "$WORKDIR" \
  "$CLAUDE_BIN --dangerously-skip-permissions --remote-control --name $DISP"
sleep 2
if tmux has-session -t "cc-$NAME" 2>/dev/null; then
  "$HOME/.local/bin/claude-registry" add "cc-$NAME" "$WORKDIR" || true
  echo "✔ Сессия '$DISP' (побочная) запущена в: $WORKDIR"
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
# Ссылку тоже проверяем, а не только имя. git понимает транспорты вида
# `ext::<команда>`, и такой URL — это выполнение произвольной команды на
# сервере в момент clone. Пускаем ровно два безопасных формата.
if [[ -n "$REPO_URL" ]] \
   && ! [[ "$REPO_URL" =~ ^https://[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+$ ]] \
   && ! [[ "$REPO_URL" =~ ^git@[A-Za-z0-9._-]+:[A-Za-z0-9._/-]+$ ]]; then
  echo "Ссылка должна быть https://host/owner/repo или git@host:owner/repo." >&2
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
  "$HOME/.local/bin/claude-registry" add "ccp-$NAME" "$PROJ_PATH" || true
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
      disp="$("$HOME/.local/bin/claude-name" "$sname")"
      case "$sname" in
        claude-ops) disp="$disp (управление, не закрыть)";;
        ccp-*)      disp="$disp (главная проекта)";;
        cc-*)       disp="$disp (побочная)";;
      esac
      printf "  • %-34s ~%s МБ\n" "$disp" "$mb"
      ;;
  esac
done < <(tmux ls 2>/dev/null || true)
[ "$found" = "0" ] && echo "  (активных сессий нет)"

# Числятся в реестре, но не живы — упали и ждут сторожа (проверка раз в 5 минут).
pending=0
for tn in $("$HOME/.local/bin/claude-registry" list 2>/dev/null || true); do
  tmux has-session -t "$tn" 2>/dev/null && continue
  if [ "$pending" = "0" ]; then echo; echo "Упали, будут подняты автоматически:"; pending=1; fi
  case "$tn" in
    ccp-*) echo "  • $("$HOME/.local/bin/claude-name" "$tn") (главная проекта)";;
    cc-*)  echo "  • $("$HOME/.local/bin/claude-name" "$tn") (побочная)";;
  esac
done
[ "$pending" = "1" ] && echo "  Поднять прямо сейчас: claude-restore"

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
# Имя считаем ДО снятия с реестра — claude-name берёт папку оттуда.
disp="$("$HOME/.local/bin/claude-name" "$TN")"

# Гасим docker-контейнеры проекта, но ТОЛЬКО когда закрывается его последняя
# сессия — иначе закрытие одной сессии убьёт контейнеры, которыми ещё пользуется
# вторая (у проекта бывает и главная, и побочная сессия сразу). Проект узнаём по
# имени (ccp-<proj>) или по рабочей папке побочной сессии (/projects/<proj>).
proj=""
case "$TN" in
  ccp-*) proj="${TN#ccp-}";;
  cc-*)  d="$(tmux display-message -p -t "$TN" '#{pane_current_path}' 2>/dev/null || true)"
         case "$d" in /projects/*) proj="${d#/projects/}"; proj="${proj%%/*}";; esac;;
esac
if [[ -n "$proj" && -d "/projects/$proj" ]] && command -v docker >/dev/null 2>&1; then
  others=0
  for s in $(tmux list-sessions -F '#S' 2>/dev/null || true); do
    if [[ "$s" == "$TN" ]]; then continue; fi
    if [[ "$s" == "ccp-$proj" ]]; then others=1; fi
    if [[ "$s" == cc-* ]]; then
      sd="$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null || true)"
      if [[ "$sd" == "/projects/$proj" || "$sd" == "/projects/$proj/"* ]]; then others=1; fi
    fi
  done
  if (( others == 0 )); then
    cids="$(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null || true)"
    if [[ -n "$cids" ]]; then
      echo "  Останавливаю контейнеры проекта '$proj' (закрывается его последняя сессия)…"
      docker stop $cids >/dev/null 2>&1 || true
    fi
  else
    echo "  Контейнеры '$proj' оставляю — у проекта есть ещё открытая сессия."
  fi
fi

# Снимаем с реестра ДО убийства: закрытие намеренное, поднимать обратно не надо.
"$HOME/.local/bin/claude-registry" del "$TN" || true

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
  disp="$("$HOME/.local/bin/claude-name" "$s")"
  "$HOME/.local/bin/claude-registry" del "$s" || true
  ( sleep 2; tmux kill-session -t "$s" 2>/dev/null ) &
  disown 2>/dev/null || true
  echo "  закрываю побочную: $disp"
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
  disp="$("$HOME/.local/bin/claude-name" "$s")"
  "$HOME/.local/bin/claude-registry" del "$s" || true
  ( sleep 2; tmux kill-session -t "$s" 2>/dev/null ) &
  disown 2>/dev/null || true
  if [ "${s#ccp-}" != "$s" ]; then echo "  закрываю проект: $disp"
  else echo "  закрываю побочную: $disp"; fi
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
disp="$("$HOME/.local/bin/claude-name" "$TN")"
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
    # Снять с реестра обязательно — иначе сторож поднимет её обратно через 5 минут.
    "$HOME/.local/bin/claude-registry" del "$sname" 2>/dev/null || true
    tmux kill-session -t "$sname" 2>/dev/null || true
  fi
done
CLEANUP_EOF

  # claude-restore — поднимает сессии из реестра, которых нет в живых.
  #   --boot  : после старта claude-ops (ребут / рестарт сервиса) — без ограничений
  #   --watch : раз в 5 минут таймером — со страховкой от циклического падения
  # Диалог продолжается: по записанному id (--resume) либо последним диалогом
  # этой папки (--continue). Если истории нет — сессия стартует чистой.
  cat > "$bin/claude-restore" <<'RESTORE_EOF'
#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---watch}"
REG="$HOME/.claude/open-sessions"
REV="$REG/.revives"
REGISTRY="$HOME/.local/bin/claude-registry"
CLAUDE_BIN="$HOME/.local/bin/claude"
[[ -x "$CLAUDE_BIN" ]] || CLAUDE_BIN="claude"
# Не поднимаем сессии, когда памяти уже мало: очередной claude только добьёт
# сервер (именно OOM и убивает сессии, которые мы здесь чиним).
MIN_FREE_MB="${MIN_FREE_MB:-800}"
# Сколько раз за час сторож готов поднимать одну и ту же сессию.
MAX_REVIVES="${MAX_REVIVES:-3}"
# Пауза между запусками — чтобы N сессий не стартовали одновременно.
STAGGER="${STAGGER:-3}"
mkdir -p "$REG" "$REV"

log() { echo "$(date '+%F %T') claude-restore: $*"; }

# Один экземпляр за раз: таймер и ExecStartPost могут пересечься.
exec 9>"$REG/.lock"
flock -n 9 || exit 0

# ── 1. Синхронизация id диалогов у ЖИВЫХ сессий ────────────────────
# Пока сессия жива, claude держит ~/.claude/sessions/<pid>.json со своим
# текущим sessionId. Складываем его в реестр, чтобы после падения поднять
# именно тот диалог, а не «последний в папке» (в одной папке сессий бывает две).
for f in "$HOME"/.claude/sessions/*.json; do
  [[ -e "$f" ]] || continue
  pid="$(basename "$f" .json)"
  # файл мог остаться от убитого процесса — проверяем, что pid жив
  [[ -d "/proc/$pid" ]] || continue
  disp="$(jq -r '.name // empty' "$f" 2>/dev/null || true)"
  sid="$(jq -r '.sessionId // empty' "$f" 2>/dev/null || true)"
  [[ -n "$disp" && -n "$sid" ]] || continue
  [[ "$disp" == "vps-main" ]] && continue   # основная, в реестре не числится
  # Обратное сопоставление «имя в приложении → tmux-имя» разбором не сделать:
  # побочная сессия в папке проекта тоже зовётся proj-*. Идём от реестра и
  # сравниваем с тем, что даёт claude-name.
  tn=""
  for cand in $("$REGISTRY" list); do
    if [[ "$("$HOME/.local/bin/claude-name" "$cand")" == "$disp" ]]; then tn="$cand"; break; fi
  done
  [[ -n "$tn" ]] || continue
  "$REGISTRY" set-session "$tn" "$sid" 2>/dev/null || true
done

# ── 2. Подъём сессий, которых нет в живых ──────────────────────────
restored=0
for tn in $("$REGISTRY" list); do
  tmux has-session -t "$tn" 2>/dev/null && continue

  wd="$("$REGISTRY" get "$tn" workdir)"
  if [[ -z "$wd" || ! -d "$wd" ]]; then
    log "папка сессии '$tn' исчезла ($wd) — убираю из реестра"
    "$REGISTRY" del "$tn"
    continue
  fi

  case "$tn" in
    ccp-*|cc-*) disp="$("$HOME/.local/bin/claude-name" "$tn" "$wd")" ;;
    *)          continue ;;
  esac

  # Страховка от цикла: если сессия падает сразу после подъёма, перестаём
  # её дёргать. Окно скользящее — через час после последнего падения
  # счётчик обнуляется сам; ручное открытие сбрасывает его сразу.
  if [[ "$MODE" == "--watch" ]]; then
    now=$(date +%s); cutoff=$((now - 3600)); rf="$REV/$tn"
    if [[ -f "$rf" ]]; then
      awk -v c="$cutoff" '$1 > c' "$rf" > "$rf.tmp" 2>/dev/null && mv "$rf.tmp" "$rf"
    fi
    n=0
    if [[ -f "$rf" ]]; then n=$(wc -l < "$rf"); fi
    if (( n >= MAX_REVIVES )); then
      log "'$disp' падает повторно ($n раз за час) — больше не поднимаю, нужно разобраться вручную"
      continue
    fi
    echo "$now" >> "$rf"
  fi

  avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  if (( avail < MIN_FREE_MB )); then
    log "свободно ${avail} МБ (< ${MIN_FREE_MB}) — откладываю подъём '$disp' до следующей проверки"
    break
  fi

  # Чем продолжить диалог: точный id из реестра → последний диалог папки → ничего.
  mangled="$(echo "$wd" | sed 's#[/.]#-#g')"
  sid="$("$REGISTRY" get "$tn" session)"
  if [[ -n "$sid" && -f "$HOME/.claude/projects/$mangled/$sid.jsonl" ]]; then
    resume=(--resume "$sid")
    how="диалог продолжен"
  elif compgen -G "$HOME/.claude/projects/$mangled/*.jsonl" >/dev/null 2>&1; then
    resume=(--continue)
    how="продолжен последний диалог папки"
  else
    resume=()
    how="история не найдена, старт с чистого листа"
  fi

  tmux new-session -d -s "$tn" -c "$wd" \
    "$CLAUDE_BIN ${resume[*]} --dangerously-skip-permissions --remote-control --name $disp"
  sleep 2
  if tmux has-session -t "$tn" 2>/dev/null; then
    log "поднял '$disp' в $wd ($how)"
    restored=$((restored + 1))
    sleep "$STAGGER"
  else
    log "не удалось поднять '$disp' в $wd"
  fi
done

(( restored > 0 )) && log "восстановлено сессий: $restored"
exit 0
RESTORE_EOF

  # ── СКИЛЛЫ ─────────────────────────────────────────────────────────
  # Живут файлами в репозитории (skills/<имя>/SKILL.md) и раскладываются
  # отсюда в ~/.claude/skills — общие для всех сессий этого VPS. Правишь
  # скилл в репозитории, применяешь `sudo bash setup-server.sh --sessions`.
  # Имя папки даёт слэш-команду (/vps-new), описание — срабатывание по
  # обычному тексту, тело говорит агенту вызвать CLI-утилиту из ~/.local/bin.
  local src="$SCRIPT_DIR/skills"
  if [[ -d "$src" ]]; then
    for d in "$src"/*/; do
      [[ -f "$d/SKILL.md" ]] || continue
      local sname; sname="$(basename "$d")"
      install -d -o "$DEV_USER" -g "$DEV_USER" "$skills/$sname"
      install -m 644 -o "$DEV_USER" -g "$DEV_USER" "$d/SKILL.md" "$skills/$sname/SKILL.md"
    done
    # Скилл, которого нет в репозитории, переезд не переживёт — говорим вслух.
    for d in "$skills"/*/; do
      [[ -d "$d" ]] || continue
      local iname; iname="$(basename "$d")"
      [[ -d "$src/$iname" ]] || warn "Скилл '$iname' есть на сервере, но не в репозитории — при переезде потеряется."
    done
  else
    warn "Папки skills/ рядом со скриптом нет — скиллы не разложены."
  fi

  chmod +x "$bin/claude-name" "$bin/claude-new" "$bin/claude-project" "$bin/claude-list" "$bin/claude-close" "$bin/claude-close-all" "$bin/claude-close-everything" "$bin/claude-ssh" "$bin/claude-cleanup" "$bin/claude-registry" "$bin/claude-restore"
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
  apt-get install -y curl ca-certificates git tmux htop tree acl jq \
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

  # --- Запреты, которые переживают bypass ---
  # Агенты работают в bypass-режиме: разрешения не спрашиваются. Это осознанно —
  # ради автономности. Но deny-правила действуют ДАЖЕ в bypass (проверено), и
  # сюда вынесено ровно то, что может отрезать владельца от собственного сервера.
  #
  # Это защита от аварии, а не от злоумышленника: агент, которому нужно обойти
  # запрет, обойдёт его другим инструментом. Смысл в другом — случайная правка
  # sshd_config или `ufw disable` посреди длинной задачи больше не превратится
  # в потерю доступа к машине.
  #
  # Заметь, чего в списке НЕТ: правки этих же файлов из setup-server.sh. Скрипт
  # запускается как bash-программа, а не инструментом Edit, и под запрет не
  # попадает. Ровно то поведение, которое нужно: настройки сервера меняются
  # через репозиторий, а не разовым редактированием файла в /etc.
  say "Прописываю запреты на необратимое (действуют и в bypass-режиме)…"
  local claude_settings="/home/$DEV_USER/.claude/settings.json"
  # Только Edit(...) — Write(...) в проверках путей не участвует, о чём Claude
  # Code честно предупреждает при запуске. Edit покрывает все инструменты,
  # которые пишут в файл, так что отдельное правило для Write не нужно и лишь
  # создаёт видимость защиты.
  local deny_rules='[
    "Edit(//etc/ssh/**)",
    "Edit(~/.ssh/**)",
    "Bash(sudo ufw disable*)",
    "Bash(sudo ufw --force reset*)",
    "Bash(sudo systemctl stop ssh*)",
    "Bash(sudo systemctl disable ssh*)",
    "Bash(sudo passwd*)"
  ]'
  # Правила, которые платформа ставила раньше и признала негодными. Без явного
  # вычитания они остались бы в settings.json навсегда: слияние только добавляет.
  local obsolete_rules='["Write(//etc/ssh/**)", "Write(~/.ssh/**)"]'
  # Слияние, а не перезапись: в файле лежат личные настройки (тема, режим TUI).
  # unique сохраняет идемпотентность — повторный запуск не плодит дубли.
  local merged
  merged="$(jq --argjson deny "$deny_rules" --argjson obsolete "$obsolete_rules" \
    '.permissions //= {} | .permissions.deny = (((.permissions.deny // []) - $obsolete) + $deny | unique)' \
    "$claude_settings")" || die "Не смог разобрать $claude_settings — не трогаю его."
  printf '%s\n' "$merged" > "$claude_settings"
  chown "$DEV_USER:$DEV_USER" "$claude_settings"
  ok "Запреты прописаны ($(printf '%s' "$merged" | jq '.permissions.deny | length') правил)."

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
  local ssh_conf=/etc/ssh/sshd_config.d/99-hardening.conf
  local ssh_tmp
  ssh_tmp="$(mktemp)"
  cat > "$ssh_tmp" <<EOF
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# Вход под root закрыт полностью. Раньше здесь было prohibit-password (root по
# ключу, без пароля) ради SFTP к файлам в корне — но у $DEV_USER есть NOPASSWD
# sudo, так что отдельный root-вход ничего не даёт, зато держит вторую живую
# точку входа с правами суперпользователя. Для файлов в корне: sudo из-под dev.
PermitRootLogin no
# Белый список: любая будущая системная учётка, которой кто-то положит ключ,
# не получит вход автоматически. Пускаем ровно того, кто нужен.
AllowUsers $DEV_USER
PermitEmptyPasswords no
# 6, а не 4 — запас, если ssh-агент перебирает несколько ключей перед нужным.
MaxAuthTries 6
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
UseDNS no
EOF
  if [[ -f "$ssh_conf" ]] && cmp -s "$ssh_tmp" "$ssh_conf"; then
    skip "SSH hardening"
    rm -f "$ssh_tmp"
  else
    say "Проверяю готовность $DEV_USER перед закрытием root-доступа…"
    [[ -s "/home/$DEV_USER/.ssh/authorized_keys" ]] || die "У $DEV_USER нет ключа — НЕ закрываю root."
    runuser -l "$DEV_USER" -c 'sudo -n true' 2>/dev/null || die "sudo под $DEV_USER не работает — НЕ закрываю root."
    ok "$DEV_USER готов."

    say "Хардинг SSH…"
    install -m 600 "$ssh_tmp" "$ssh_conf"
    rm -f "$ssh_tmp"
    # Проверяем ДО рестарта: битый конфиг оставил бы сервер без sshd.
    sshd -t || die "Конфиг SSH невалиден — НЕ рестартую."
    systemctl restart ssh || systemctl restart sshd
    ok "SSH захардирован (вход только под $DEV_USER по ключу)."
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

  # Догоняем реестр живыми сессиями: при первой установке (и после ручных
  # запусков tmux) в нём может не быть того, что сейчас открыто. Сделать это
  # надо ДО рестарта сервиса — он погасит сессии, и восстанавливать будет нечего.
  for s in $(tmux ls 2>/dev/null | cut -d: -f1 | grep -E '^(cc-|ccp-)' || true); do
    [[ -f "$HOME/.claude/open-sessions/$s" ]] && continue
    wd="$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null || true)"
    [[ -n "$wd" ]] || continue
    "$HOME/.local/bin/claude-registry" add "$s" "$wd" 2>/dev/null \
      && echo "  в реестр: $s → $wd"
  done
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
# устаревший скилл. Первый ExecStartPre гасит побочные/проектные, второй —
# старую основную.
ExecStartPre=-/bin/sh -c 'tmux ls 2>/dev/null | cut -d: -f1 | grep -E "^(cc-|ccp-)" | xargs -r -n1 tmux kill-session -t'
ExecStartPre=-/usr/bin/tmux kill-session -t $TMUX_SESSION
ExecStart=/usr/bin/tmux new-session -d -s $TMUX_SESSION 'claude --dangerously-skip-permissions --remote-control --name vps-main'
# …и сразу поднимаем их заново из реестра — уже с обновлённым bootstrap и с
# продолжением прежнего диалога. Это же возвращает сессии после перезагрузки
# сервера. Сессии, закрытые намеренно, в реестре не числятся и не вернутся.
ExecStartPost=-%h/.local/bin/claude-restore --boot
ExecStop=/usr/bin/tmux kill-session -t $TMUX_SESSION
Restart=on-failure
RestartSec=10
# Восстановление поднимает сессии по одной с паузой — даём ему время.
TimeoutStartSec=600

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

  # --- Сторож: поднимает упавшие сессии (раз в 5 минут) ---
  say "Настраиваю сторожа сессий (подъём после падения/OOM)…"
  cat > "$HOME/.config/systemd/user/claude-restore.service" <<EOF
[Unit]
Description=Поднять Claude-сессии из реестра, которых нет в живых
After=claude-ops.service

[Service]
Type=oneshot
Environment=PATH=%h/.local/bin:%h/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=%h/.local/bin/claude-restore --watch
TimeoutStartSec=600
EOF
  cat > "$HOME/.config/systemd/user/claude-restore.timer" <<EOF
[Unit]
Description=Проверять раз в 5 минут, не упала ли Claude-сессия

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now claude-restore.timer
  ok "Сторож включён: упавшая сессия сама поднимется в течение 5 минут."

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
  echo " Открытые сессии переживают перезагрузку и падения: возвращаются сами,"
  echo " с продолжением прежнего диалога. Немедленно: ${C_INFO}claude-restore${C_RST}"
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
  --sessions)
    # Только перевыложить команды сессий (claude-new и соседи) — быстрый путь,
    # когда поменялись именно они, а трогать пакеты и хардинг незачем.
    if [[ "$(id -u)" -ne 0 ]]; then
      warn "Режим --sessions требует root:  ${C_INFO}sudo bash $0 --sessions${C_RST}"
      exit 1
    fi
    install_parallel_sessions
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