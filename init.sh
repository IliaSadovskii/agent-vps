#!/usr/bin/env bash
# ============================================================================
#  init.sh — единственная точка входа
# ============================================================================
#
#  Смотрит, что уже сделано, выполняет следующий шаг и останавливается, если
#  нужно твоё участие (вход в браузере, перезаход по SSH). Запусти снова —
#  продолжит с того же места. Повторный запуск безопасен всегда.
#
#      sudo bash init.sh   # первый раз, под root
#      bash init.sh        # дальше, под dev
# ============================================================================

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DEV_USER="dev"
TS_HOSTNAME="dev-vps"

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_INFO=$'\e[36m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
die()  { echo "${C_WARN}✗ $*${C_RST}" >&2; exit 1; }

# --- Состояние: каждый шаг определяется по факту, а не по флагу в файле ---
done_server()    { id "$DEV_USER" &>/dev/null && [[ -f /etc/ssh/sshd_config.d/99-hardening.conf ]]; }
done_claude()    { [[ -s "$HOME/.claude/.credentials.json" ]]; }
done_gh()        { gh auth status &>/dev/null; }
done_autostart() { systemctl --user is-enabled claude-ops.service &>/dev/null; }
done_platform()  { command -v docker &>/dev/null && command -v tailscale &>/dev/null; }
done_tailnet()   { tailscale status &>/dev/null; }

STEPS=(
  "Сервер: пользователь, безопасность, пакеты"
  "Вход в Claude Code"
  "Вход в GitHub"
  "Автозапуск управляющей сессии"
  "Платформа: docker, tailscale"
  "Подключение к сети Tailscale"
)

step_done() {
  case "$1" in
    0) done_server ;; 1) done_claude ;; 2) done_gh ;;
    3) done_autostart ;; 4) done_platform ;; 5) done_tailnet ;;
  esac
}

# Первый невыполненный шаг — он же текущий.
current_step() {
  local i
  for i in "${!STEPS[@]}"; do step_done "$i" || { echo "$i"; return; }; done
  echo "${#STEPS[@]}"
}

show_progress() {
  local cur="$1" i mark
  echo
  for i in "${!STEPS[@]}"; do
    if step_done "$i"; then mark="${C_OK}✔${C_RST}"
    elif [[ "$i" == "$cur" ]]; then mark="${C_INFO}▶${C_RST}"
    else mark="${C_DIM}·${C_RST}"; fi
    printf "  %b %d. %s\n" "$mark" "$((i+1))" "${STEPS[$i]}"
  done
  echo
}

manual() {  # инструкция вместо действия: то, что нельзя сделать за пользователя
  echo "${C_INFO}Сделай вручную:${C_RST}"
  echo
  printf '      %s\n' "$@"
  echo
  echo "${C_DIM}Потом запусти снова:  bash init.sh${C_RST}"
  exit 0
}

# ============================================================================

if [[ "$(id -u)" -eq 0 ]]; then
  # Под root доступен ровно один шаг — всё остальное делается от имени dev.
  if done_server; then
    echo "${C_OK}✔ Шаг 1 уже выполнен.${C_RST}"
  else
    echo "${C_INFO}▶ Шаг 1: настройка сервера${C_RST}"
    bash setup-server.sh
  fi

  # Репозиторий должен оказаться у dev: это и рабочая папка управляющей сессии,
  # и источник всех дальнейших шагов. Под root он обычно лежит в /root.
  DEST="/home/$DEV_USER/vps"
  if [[ "$PWD" != "$DEST" ]]; then
    echo
    echo "${C_INFO}▶ Копирую репозиторий в $DEST${C_RST}"
    install -d -o "$DEV_USER" -g "$DEV_USER" "$DEST"
    cp -r ./. "$DEST/"
    chown -R "$DEV_USER:$DEV_USER" "$DEST"
    echo "${C_OK}✔ Готово.${C_RST}"
  fi

  echo
  echo "Дальше — под пользователем '$DEV_USER':"
  echo "      ssh $DEV_USER@<IP>"
  echo "      cd ~/vps && bash init.sh"
  exit 0
fi

[[ "$(id -u)" -ne 0 ]] || true
done_server || die "Сначала шаг 1 под root:  sudo bash init.sh"

CUR="$(current_step)"
show_progress "$CUR"

case "$CUR" in
  1)
    manual "claude" \
           "" \
           "Выбери вход по ПОДПИСКЕ (не по API-ключу), доведи до конца, затем /exit"
    ;;
  2)
    manual "gh auth login && gh auth setup-git"
    ;;
  3)
    echo "${C_INFO}▶ Шаг 4: автозапуск управляющей сессии${C_RST}"
    echo "${C_WARN}⚠ Все открытые Claude-сессии будут закрыты и поднята свежая vps-main.${C_RST}"
    echo "${C_DIM}Если запускаешь это изнутри Claude-сессии — выйди в обычный терминал.${C_RST}"
    echo
    read -rp "Продолжить? [y/N] " a; [[ "$a" == [yY] ]] || { echo "Отменено."; exit 0; }
    bash setup-server.sh
    ;;
  4)
    echo "${C_INFO}▶ Шаг 5: платформа разработки${C_RST}"
    bash setup-dev.sh
    echo
    manual "sudo tailscale up --hostname=$TS_HOSTNAME" \
           "" \
           "Открой напечатанную ссылку в браузере и авторизуй сервер"
    ;;
  5)
    manual "sudo tailscale up --hostname=$TS_HOSTNAME" \
           "" \
           "Открой напечатанную ссылку в браузере и авторизуй сервер"
    ;;
esac

# Все шаги пройдены: обновляем платформу (порты новых проектов, правила) и итог.
echo "${C_INFO}▶ Обновляю платформу${C_RST}"
bash setup-dev.sh | tail -n +2
echo
echo "${C_OK}═══ Сервер готов ═══${C_RST}"
echo
echo "  Управляющая сессия ${C_INFO}vps-main${C_RST} — в приложении Claude (раздел Code)."
echo "  Адрес в твоей сети: ${C_INFO}$(tailscale status --json 2>/dev/null | grep -m1 '"DNSName"' | cut -d'"' -f4 | sed 's/\.$//')${C_RST}"
echo
echo "  Новый проект:"
echo "      claude-project <имя> <git-url>"
echo
echo "  Если проекту нужны порты — заведи ports/<имя>.env и запусти init.sh снова."
echo "  Правила для проектов: docs/PROJECT-CONTRACT.md"
