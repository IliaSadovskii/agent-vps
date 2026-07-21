#!/usr/bin/env bash
# ============================================================================
#  setup-dev.sh — ПЛАТФОРМА РАЗРАБОТКИ на этом VPS
# ============================================================================
#
#  Отдельно от setup-server.sh намеренно: bootstrap — это скрипт «получить
#  доступ к серверу» (пользователь, SSH, ключи). Сломав его правкой, теряешь
#  вход. Платформа разработки меняется чаще — пусть её правки не могут
#  уронить SSH.
#
#  ПРИНЦИП: платформа даёт СПОСОБНОСТЬ, проект объявляет ПОТРЕБНОСТЬ.
#  Здесь ставится только то, что общее для любого стека — docker, mise,
#  tailscale. Языки, рантаймы и БД приходят из репозитория самого проекта
#  (docker-compose.yml, .mise.toml). Поэтому в этом файле НЕТ и не должно
#  появиться ни одного упоминания php/postgres/flutter/node — если появилось,
#  граница слоёв нарушена.
#
#  Запуск:  bash setup-dev.sh          (под обычным пользователем, sudo внутри)
#  Идемпотентный — повторный запуск безопасен.
# ============================================================================

set -euo pipefail

# ------------------------- НАСТРОЙКИ -------------------------
PROJECTS_DIR="/projects"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_DIR="$REPO_DIR/ports"          # ports/<имя>.env — блок портов проекта
# -------------------------------------------------------------

C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_INFO=$'\e[36m'; C_RST=$'\e[0m'
say()  { echo "${C_INFO}▶ $*${C_RST}"; }
ok()   { echo "${C_OK}✔ $*${C_RST}"; }
warn() { echo "${C_WARN}⚠ $*${C_RST}"; }
die()  { echo "${C_ERR}✗ $*${C_RST}" >&2; exit 1; }
skip() { echo "${C_OK}✔ $* (уже есть, пропускаю)${C_RST}"; }

# ============================================================================
#  DOCKER — окружение проектов
# ============================================================================
step_docker() {
  echo; say "═══ Docker ═══"

  # --- Репозиторий Docker ---
  # Ставим docker-ce из официального репозитория, а не docker.io из Ubuntu:
  # в дистрибутивном пакете отстающая версия и нет compose-плагина.
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    skip "apt-репозиторий Docker"
  else
    say "Подключаю официальный apt-репозиторий Docker…"
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    ok "Репозиторий подключён."
  fi

  # --- daemon.json ---
  # Пишем ДО установки движка: тогда dockerd стартует уже с безопасными
  # настройками и не успевает открыть наружу ни одного порта.
  #
  #   Публикация портов только на localhost — САМОЕ ВАЖНОЕ. Docker пишет правила
  #   прямо в iptables ДО цепочек UFW, поэтому `ports: "5432:5432"` в любом
  #   compose открыл бы базу всему интернету, несмотря на `ufw default deny
  #   incoming`. Ниже порт физически не слушает внешние интерфейсы.
  #   Доступ снаружи даёт tailscale (см. step_tailscale).
  #
  #   Ключей ДВА, и одного мало:
  #     "ip" — действует ТОЛЬКО на дефолтный bridge (docker0). На сети, которые
  #       создаёт docker compose (br-*), он не влияет вообще. Проверено на
  #       Docker 29: `docker run -p` слушает 127.0.0.1, а `docker compose up`
  #       того же образа — 0.0.0.0. То есть для реальных проектов, а их сети
  #       всегда пользовательские, одного "ip" не хватает.
  #     "default-network-opts" — задаёт host_binding_ipv4 по умолчанию для
  #       КАЖДОЙ создаваемой bridge-сети, включая compose-сети. Это и есть
  #       рабочая защита; "ip" оставлен для docker run без сети.
  #   Требует Docker >= 28. Проверяется через `dockerd --validate` ниже.
  #
  #   log-opts — без ротации логи контейнеров растут безгранично и за пару
  #   месяцев съедают диск. Классическая беда долгоживущих dev-серверов.
  local daemon_json="/etc/docker/daemon.json"
  local daemon_tmp
  daemon_tmp="$(mktemp)"
  cat > "$daemon_tmp" <<'JSON'
{
  "ip": "127.0.0.1",
  "default-network-opts": {
    "bridge": { "com.docker.network.bridge.host_binding_ipv4": "127.0.0.1" }
  },
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  if [[ -f "$daemon_json" ]] && sudo cmp -s "$daemon_tmp" "$daemon_json"; then
    skip "daemon.json (bind на 127.0.0.1 уже настроен)"
    rm -f "$daemon_tmp"
  else
    if [[ -f "$daemon_json" ]]; then
      warn "daemon.json уже есть и отличается — сохраняю копию в ${daemon_json}.bak"
      sudo cp "$daemon_json" "${daemon_json}.bak"
    fi
    say "Пишу $daemon_json…"
    sudo install -d -m 755 /etc/docker
    sudo install -m 644 "$daemon_tmp" "$daemon_json"
    rm -f "$daemon_tmp"
    ok "daemon.json записан (порты публикуются только на localhost)."
    # Если движок уже стоит и крутится, новый конфиг сам собой не применится —
    # dockerd читает daemon.json только при старте. На чистой машине этой ветки
    # не будет: файл пишется до установки движка.
    if command -v dockerd &>/dev/null && systemctl is-active --quiet docker; then
      sudo dockerd --validate --config-file "$daemon_json" >/dev/null \
        || die "daemon.json не принят dockerd — не рестартую, чтобы не уронить движок."
      say "Перезапускаю docker, чтобы конфиг применился…"
      sudo systemctl restart docker
      ok "Docker перезапущен."
      # Уже запущенные контейнеры сохранили старую привязку портов: адрес
      # выбирается в момент старта контейнера, а не демона. Пересоздать их
      # может только владелец проекта — молча трогать чужие данные нельзя.
      local stale
      stale="$(docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -F '0.0.0.0:' | cut -f1 || true)"
      if [[ -n "$stale" ]]; then
        warn "Эти контейнеры всё ещё слушают 0.0.0.0 — пересоздай их"
        warn "(docker compose up -d --force-recreate) в каталоге проекта:"
        printf '        %s\n' $stale
      fi
    fi
  fi

  # --- Движок ---
  if command -v docker &>/dev/null; then
    skip "Docker ($(docker --version | awk '{print $3}' | tr -d ,))"
  else
    say "Ставлю docker-ce и compose-плагин…"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ok "Docker: $(docker --version)"
  fi
  sudo systemctl enable --now docker >/dev/null 2>&1 || true

  # daemon.json мог измениться при уже запущенном докере — перечитать.
  sudo systemctl reload-or-restart docker

  # --- Группа docker ---
  # Без этого каждая команда требует sudo, а агенту это лишний барьер.
  # Права группы docker == root, но на dev-сервере с единственным
  # пользователем это осознанный размен на удобство.
  if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    skip "Пользователь '$USER' в группе docker"
  else
    say "Добавляю '$USER' в группу docker…"
    sudo usermod -aG docker "$USER"
    warn "Группа применится после перезахода в сессию (или 'newgrp docker')."
  fi

  ok "Docker готов."
}

# ============================================================================
#  SWAP — подушка от OOM
# ============================================================================
step_swap() {
  echo; say "═══ Swap ═══"

  # 7.7 ГБ RAM делятся между контейнерами проектов и сессиями Claude Code
  # (~300–500 МБ каждая). При нескольких одновременных сессиях ядро может
  # начать убивать процессы — обычно самый жирный, то есть чью-то сессию
  # посреди работы. Swap не ускоряет ничего, он лишь превращает «убили
  # процесс» в «стало медленно», что для dev-сервера несравнимо лучше.
  local want_gb=4
  local cur_kb cur_mb
  cur_kb="$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps)"
  cur_mb=$(( cur_kb / 1024 ))

  # Допуск 64 МБ: mkswap отъедает часть файла под заголовок, поэтому swap-файл
  # на 4 ГиБ даёт ~4095 МБ полезных. Без допуска условие «уже достаточно»
  # никогда не выполнялось бы и swap пересоздавался при каждом запуске.
  if (( cur_mb >= want_gb * 1024 - 64 )); then
    skip "Swap (${cur_mb} МБ)"
    return
  fi

  local swapfile="/swap.img"
  [[ -f "$swapfile" ]] || die "Ожидал swap-файл $swapfile, но его нет — разберись руками, автоматом не трогаю."

  say "Расширяю swap: ${cur_mb} МБ → $(( want_gb * 1024 )) МБ…"
  # Отключать swap безопасно только когда он почти пуст: всё, что в нём лежит,
  # ядро при swapoff обязано вернуть в RAM.
  local used_kb
  used_kb="$(awk 'NR>1 {s+=$4} END {print s+0}' /proc/swaps)"
  (( used_kb < 262144 )) || die "В swap занято $((used_kb/1024)) МБ — отключать рискованно. Освободи память и повтори."

  sudo swapoff "$swapfile"
  sudo rm -f "$swapfile"
  # fallocate мгновенный, но на некоторых ФС даёт дырявый файл, непригодный
  # под swap; dd медленнее, зато работает везде.
  sudo fallocate -l "${want_gb}G" "$swapfile" 2>/dev/null \
    || sudo dd if=/dev/zero of="$swapfile" bs=1M count=$((want_gb*1024)) status=none
  sudo chmod 600 "$swapfile"
  sudo mkswap "$swapfile" >/dev/null
  sudo swapon "$swapfile"
  ok "Swap: $(free -h | awk '/Swap/{print $2}')"
}

# ============================================================================
#  FIREWALL
# ============================================================================
step_firewall() {
  echo; say "═══ Firewall (UFW) ═══"

  sudo ufw status 2>/dev/null | grep -q "Status: active" \
    || die "UFW не активен — его включает setup-server.sh."

  # 80/443 открыл bootstrap «на будущее» под веб-сервер. Веб-сервера нет и не
  # будет: наружу проекты смотрят через tailscale, а порты контейнеров и так
  # слушают только localhost. Открытые порты, которыми не пользуются, — это
  # чистый риск, закрываем.
  local port
  for port in 80 443; do
    if sudo ufw status | grep -q "^${port}/tcp "; then
      say "Закрываю ${port}/tcp…"
      sudo ufw delete allow "${port}/tcp" >/dev/null
    else
      skip "${port}/tcp закрыт"
    fi
  done

  # Внутри tailnet доверяем всему: попасть туда можно только с устройства,
  # авторизованного в твоей сети. Это снимает нужду открывать порты проектов
  # поштучно — новый проект просто работает.
  if sudo ufw status | grep -q "Anywhere on tailscale0"; then
    skip "Доступ через tailscale0"
  else
    say "Разрешаю входящие на tailscale0…"
    sudo ufw allow in on tailscale0 >/dev/null
    ok "tailscale0 разрешён."
  fi

  # Без этого порта устройства не могут установить прямое соединение и трафик
  # идёт через relay-серверы Tailscale — работает, но заметно медленнее.
  if sudo ufw status | grep -q "^41641/udp "; then
    skip "41641/udp (прямые соединения Tailscale)"
  else
    say "Открываю 41641/udp для прямых соединений Tailscale…"
    sudo ufw allow 41641/udp >/dev/null
    ok "41641/udp открыт."
  fi

  # --- Контейнеры: закрыть доступ из интернета ---
  #
  # ГЛАВНАЯ ЗАЩИТА ПРОЕКТОВ. Docker публикует порты, вписывая правила прямо в
  # iptables ДО цепочек UFW, поэтому `ufw default deny incoming` контейнеров не
  # касается вообще. Настройка "ip" в daemon.json помогает лишь частично: она
  # действует только на дефолтную bridge-сеть, а docker compose создаёт для
  # каждого проекта свою — и публикует на 0.0.0.0. Проверено на этом сервере:
  # `docker run` слушал 127.0.0.1, а поднятый рядом compose — 0.0.0.0, и база
  # проекта оказалась доступна из интернета.
  #
  # Расхожий совет «пишите 127.0.0.1:8000:8000 в compose» отвергнут намеренно:
  # он перекладывает безопасность на каждый проект, и одна опечатка в чужом
  # репозитории открывает базу наружу. Защита должна быть на платформе.
  #
  # DOCKER-USER — цепочка, которую docker создаёт специально для пользователя и
  # никогда не трогает сам; через неё проходит ВЕСЬ трафик к контейнерам.
  # Логика — «запрещено всё, кроме явно разрешённого», и без упоминания имени
  # внешнего интерфейса: на другом сервере он может называться иначе, и правило
  # с жёстким `-i ens3` там молча перестало бы работать.
  local marker="# --- DOCKER-USER (setup-dev.sh) ---"
  # Ищем по префиксу, а не по всей строке: если скрипт переименуют, блок в
  # after.rules не должен продублироваться.
  local marker_find="# --- DOCKER-USER ("
  local rules_file
  for rules_file in /etc/ufw/after.rules /etc/ufw/after6.rules; do
    if sudo grep -qF "$marker_find" "$rules_file"; then
      skip "Правила для контейнеров в $(basename "$rules_file")"
      continue
    fi
    say "Добавляю правила для контейнеров в $(basename "$rules_file")…"
    sudo tee -a "$rules_file" >/dev/null <<EOF

$marker
# Трафик к контейнерам идёт через FORWARD и не виден правилам ufw. Пускаем
# только из доверенных сетей, всё остальное (то есть интернет) — отбрасываем.
*filter
:DOCKER-USER - [0:0]
# Ответы на соединения, которые инициировал сам контейнер (доступ к внешним
# API, apt, composer и т.п.) — иначе проекты потеряют интернет.
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
# Твоя приватная сеть — полный доступ ко всем сервисам проектов.
-A DOCKER-USER -i tailscale0 -j RETURN
# Контейнер-контейнер и исходящие наружу: docker0 и сети compose (br-*).
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br+ -j RETURN
-A DOCKER-USER -i lo -j RETURN
# Всё прочее — входящие из интернета.
-A DOCKER-USER -j DROP
COMMIT
EOF
    ok "$(basename "$rules_file") обновлён."
  done

  sudo ufw reload >/dev/null
  ok "Firewall настроен (снаружи открыт только SSH, контейнеры недоступны из интернета)."
}

# ============================================================================
#  TAILSCALE — единственный вход снаружи
# ============================================================================
step_tailscale() {
  echo; say "═══ Tailscale ═══"

  # Зачем вообще: порты контейнеров слушают только localhost (см. daemon.json),
  # а 80/443 закрыты firewall'ом. Tailscale — приватная сеть между твоими
  # устройствами; сервер виден только в ней. Заодно снимает нужду в домене,
  # обратном прокси и Let's Encrypt: `tailscale serve` сам терминирует TLS
  # валидным сертификатом на *.ts.net.
  if command -v tailscale &>/dev/null; then
    skip "Tailscale ($(tailscale version | head -1))"
  else
    say "Ставлю Tailscale…"
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale установлен."
  fi

  # Авторизация — интерактивная, по ссылке в браузере. Скрипт её не делает
  # намеренно: он должен отрабатывать без участия человека, а вход в аккаунт
  # без человека невозможен. Поэтому просто сообщаем, что осталось сделать.
  if tailscale status &>/dev/null; then
    ok "Подключён к tailnet как $(tailscale status --json | grep -m1 '"DNSName"' | cut -d'"' -f4 | sed 's/\.$//')"
  else
    warn "Сервер ещё не в сети. Выполни и открой напечатанную ссылку в браузере:"
    echo "      sudo tailscale up --hostname=dev-vps"
  fi
}

# ============================================================================
#  MISE — менеджер версий тулчейнов
# ============================================================================
step_mise() {
  echo; say "═══ mise ═══"

  # Зачем нужен, если есть docker: не всякий тулчейн осмысленно заворачивать в
  # контейнер. Мобильная разработка — главный пример: сборка и тесты хотят
  # SDK на хосте. mise позволяет держать версию SDK в самом проекте
  # (.mise.toml), а не глобально: два проекта с разными версиями не подерутся,
  # и версия уезжает вместе с репозиторием на любую машину.
  #
  # ЗДЕСЬ НЕ СТАВИТСЯ НИ ОДИН ЯЗЫК. Платформа даёт только менеджер —
  # что именно ставить, объявляет проект в своём .mise.toml.
  if command -v mise &>/dev/null || [[ -x "$HOME/.local/bin/mise" ]]; then
    skip "mise ($("$HOME/.local/bin/mise" version 2>/dev/null | head -1))"
  else
    say "Ставлю mise…"
    curl -fsSL https://mise.run | sh
    ok "mise: $("$HOME/.local/bin/mise" version | head -1)"
  fi

  # --- PATH для НЕинтерактивных шеллов ---
  # Тонкое место. В ~/.bashrc первые строки — ранний выход для неинтерактивных
  # шеллов, поэтому дописанное в конец файла НЕ выполняется, когда команду
  # запускает агент или systemd. Если положить активацию mise только туда,
  # тулчейны будут видны тебе в терминале и невидимы агентам — ровно наоборот
  # тому, что нужно. Поэтому shims (обёртки над бинарниками) прописываем в
  # ~/.profile, который читают login-шеллы и всё, что от них наследуется.
  local shims='$HOME/.local/share/mise/shims'
  if grep -q 'mise/shims' "$HOME/.profile" 2>/dev/null; then
    skip "shims mise в ~/.profile"
  else
    say "Добавляю shims mise в ~/.profile…"
    printf '\n# mise: тулчейны проектов должны быть видны и неинтерактивным шеллам (агентам)\nexport PATH="%s:$PATH"\n' "$shims" >> "$HOME/.profile"
    ok "~/.profile обновлён."
  fi

  # --- Активация для интерактивных шеллов ---
  # Полноценная активация (в отличие от shims) переключает версии при переходе
  # между папками — это для живой работы в терминале.
  if grep -q 'mise activate' "$HOME/.bashrc" 2>/dev/null; then
    skip "активация mise в ~/.bashrc"
  else
    say "Добавляю активацию mise в ~/.bashrc…"
    printf '\neval "$(%s/.local/bin/mise activate bash)"\n' "$HOME" >> "$HOME/.bashrc"
    ok "~/.bashrc обновлён."
  fi

  # --- Доверие к конфигам проектов ---
  # По умолчанию mise требует подтвердить каждый новый .mise.toml вручную
  # (защита от чужого репозитория, который пропишет себе левый бинарник). Для
  # агента это тупик: он получит отказ и не сможет ответить на запрос.
  # Всё в /projects мы клонируем сами и осознанно, поэтому доверяем каталогу.
  if grep -q 'MISE_TRUSTED_CONFIG_PATHS' "$HOME/.profile" 2>/dev/null; then
    skip "доверие к конфигам в $PROJECTS_DIR"
  else
    say "Разрешаю mise доверять конфигам в $PROJECTS_DIR…"
    printf 'export MISE_TRUSTED_CONFIG_PATHS="%s"\n' "$PROJECTS_DIR" >> "$HOME/.profile"
    ok "Доверие настроено."
  fi

  ok "mise готов (языки ставит проект, не платформа)."
}

# ============================================================================
#  ПОРТЫ — блок на проект
# ============================================================================
step_ports() {
  echo; say "═══ Порты проектов ═══"

  # Единственное место, где платформа знает имена проектов, — и по-другому не
  # получится: конфликт портов разрешим только глобально, проект про соседей
  # не знает. Каждому выдаётся блок из 10 портов; как поделить его между
  # своими сервисами, решает сам проект в ports/<имя>.env. Имена переменных
  # платформе безразличны — их диктует docker-compose проекта.
  #
  # Файлы лежат в этом репозитории, потому что .env проектов не в git: без
  # реестра после переезда пришлось бы вспоминать раскладку по памяти.
  shopt -s nullglob
  local files=( "$PORTS_DIR"/*.env )
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    skip "Файлы портов не заданы"
    return
  fi

  # --- Валидация: один порт не может быть выдан двум проектам ---
  local dups
  dups="$(grep -hE '^[A-Za-z0-9_]+=[0-9]+$' "${files[@]}" | cut -d= -f2 | sort | uniq -d || true)"
  [[ -z "$dups" ]] || die "Порт(ы) выданы больше одного раза: $(echo "$dups" | tr '\n' ' ')— почини ports/*.env."

  local f name env_file base min max key val line
  for f in "${files[@]}"; do
    name="$(basename "$f" .env)"

    # --- Валидация: проект не вылезает за свой блок ---
    # Блок выводится из значений (нижняя граница — десяток минимального порта),
    # отдельного реестра для этого не нужно.
    min="$(grep -hE '^[A-Za-z0-9_]+=[0-9]+$' "$f" | cut -d= -f2 | sort -n | head -1)"
    max="$(grep -hE '^[A-Za-z0-9_]+=[0-9]+$' "$f" | cut -d= -f2 | sort -n | tail -1)"
    [[ -n "$min" ]] || { warn "$name: в файле нет ни одного порта, пропускаю"; continue; }
    base=$(( min / 10 * 10 ))
    (( max <= base + 9 )) || die "$name: порты $min-$max не помещаются в блок ${base}-$((base+9)) — расширь блок или сократи список."

    local proj_dir="$PROJECTS_DIR/$name"
    if [[ ! -d "$proj_dir" ]]; then
      warn "$name: блок ${base}-$((base+9)) закреплён, но проект не склонирован (claude-project $name <url>)"
      continue
    fi

    # --- Раздача в .env проекта ---
    # .env — конвенция docker compose: он сам подхватывает файл из папки
    # проекта. Многие проекты хранят рядом .env.example как заготовку.
    env_file="$proj_dir/.env"
    if [[ ! -f "$env_file" ]]; then
      if [[ -f "$proj_dir/.env.example" ]]; then
        say "$name: создаю .env из .env.example…"
        cp "$proj_dir/.env.example" "$env_file"
      else
        touch "$env_file"
      fi
    fi

    local added=0 conflict=0
    while IFS= read -r line; do
      [[ "$line" =~ ^[A-Za-z0-9_]+=[0-9]+$ ]] || continue
      key="${line%%=*}"; val="${line#*=}"
      if grep -qE "^${key}=" "$env_file"; then
        # Не перезаписываем: в .env могут быть осознанные локальные правки.
        local cur; cur="$(grep -E "^${key}=" "$env_file" | tail -1 | cut -d= -f2)"
        [[ "$cur" == "$val" ]] || { warn "$name: $key=$cur в .env, а в реестре $val — оставляю как есть"; conflict=1; }
      else
        printf '%s=%s\n' "$key" "$val" >> "$env_file"
        added=$(( added + 1 ))
      fi
    done < "$f"

    if (( added > 0 )); then
      ok "$name: блок ${base}-$((base+9)), дописано строк в .env: $added"
    elif (( conflict == 0 )); then
      skip "$name: блок ${base}-$((base+9)), .env уже настроен"
    fi
  done

  ok "Порты розданы, пересечений нет."
}

# ============================================================================
#  ПРАВИЛА ДЛЯ АГЕНТОВ
# ============================================================================
step_rules() {
  echo; say "═══ Правила для агентов ═══"

  # Claude Code читает CLAUDE.md вверх по дереву каталогов и склеивает найденное.
  # Поэтому файл в /projects автоматически виден любой сессии, открытой в
  # /projects/<имя>, и складывается с личным CLAUDE.md проекта. Копировать
  # правила в каждый проект не нужно — они в одном месте.
  local src="$REPO_DIR/templates/projects-CLAUDE.md"
  local dst="$PROJECTS_DIR/CLAUDE.md"
  [[ -f "$src" ]] || { warn "Нет шаблона $src — пропускаю"; return; }

  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    skip "Правила в $dst"
  else
    say "Обновляю $dst…"
    cp "$src" "$dst"
    ok "Правила на месте (видны всем сессиям проектов)."
  fi
}

# ============================================================================
main() {
  [[ "$(id -u)" -ne 0 ]] || die "Запускай под обычным пользователем (не root): часть настроек пишется в домашнюю папку."
  sudo -n true 2>/dev/null || die "Нужен passwordless sudo (его настраивает setup-server.sh)."

  step_docker
  step_swap
  step_firewall
  step_tailscale
  step_mise
  step_ports
  step_rules

  echo
  ok "Готово."
}

main "$@"
