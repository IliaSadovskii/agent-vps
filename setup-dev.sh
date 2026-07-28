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
#  Здесь ставится только то, что общее для любого стека — docker и
#  tailscale. Языки, рантаймы и БД приходят из репозитория самого проекта
#  (docker-compose.yml). Поэтому в этом файле НЕТ и не должно
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
CONF_FILE="$REPO_DIR/vps.conf"       # настройки сервера (язык агентов и т.п.)
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
  #
  # Считаем сумму всех swap-файлов (/proc/swaps): на живом сервере к 4 ГБ
  # /swap.img руками добавлен /swap2.img до 12 ГБ — шаг видит «уже достаточно»
  # и не трогает. На чистом сервере создаётся один /swap.img на 12 ГБ.
  local want_gb=12
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
#  DOZZLE — веб-обзор docker-контейнеров (только просмотр)
# ============================================================================
step_dozzle() {
  echo; say "═══ Dozzle ═══"

  # Зачем: смотреть запущенные контейнеры и их логи из браузера, не заходя в
  # терминал. Read-only обзор — docker-сокет монтируется :ro. Наружу не торчит:
  # контейнер слушает только 127.0.0.1, доступ с твоих устройств даёт tailscale.
  #
  # Инфра-сервис сервера, а не проект: живёт здесь, а не в /projects. Порт берёт
  # из инфра-диапазона 8060-8069. В tailnet его (как и всё веб) отдаёт ports-web
  # на том же номере порта — https://<host>:8060; отдельного serve тут не держим.
  local name="vps-dozzle"
  local image="amir20/dozzle:latest"   # монитор, не БД — плавающий тег допустим
  local bind="127.0.0.1:8060"          # host → контейнерный 8080

  command -v docker &>/dev/null || { warn "Docker не установлен — пропускаю Dozzle."; return 0; }

  # --- контейнер ---
  # Пересоздаём только если не бежит: не трогаем чужие контейнеры и не рестартим
  # докер (это уронило бы контейнеры проектов).
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    skip "Контейнер $name запущен"
  else
    say "Поднимаю $name…"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --restart unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      -p "$bind:8080" \
      "$image" >/dev/null
    ok "Dozzle запущен на $bind (docker-сокет только для чтения)."
  fi
  say "Dozzle в tailnet: https://<host>:8060 (публикует ports-web, ссылка — на дашборде)"
}

# ============================================================================
#  DBGATE — веб-клиент БД проектов (просмотр и правка)
# ============================================================================
step_db_client() {
  echo; say "═══ DbGate ═══"

  # Зачем: одна веб-морда на все базы всех проектов вместо клиента в каждом
  # контейнере. Инфра-сервис сервера (живёт здесь, не в /projects), паттерн —
  # как у Dozzle: контейнер слушает только 127.0.0.1, наружу отдаётся через
  # tailscale. Сохранённые подключения лежат в томе dbgate-data, задаёшь раз.
  #
  # Порт из инфра-диапазона 8060-8069 (следующий за Dozzle). В tailnet отдаёт
  # ports-web на том же номере — https://<host>:8061; отдельного serve тут нет.
  local name="vps-dbgate"
  local image="dbgate/dbgate:latest"   # клиент-обозреватель, не БД — плавающий тег ок
  local bind="127.0.0.1:8061"          # host → контейнерный 3000
  local vol="dbgate-data"              # том с сохранёнными подключениями

  command -v docker &>/dev/null || { warn "Docker не установлен — пропускаю DbGate."; return 0; }

  # --- контейнер ---
  # Пересоздаём только если не бежит: не рестартим docker и не трогаем чужое.
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    skip "Контейнер $name запущен"
  else
    say "Поднимаю $name…"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --restart unless-stopped \
      -v "$vol:/root/.dbgate" \
      -p "$bind:3000" \
      "$image" >/dev/null
    ok "DbGate запущен на $bind (подключения сохраняются в томе $vol)."
  fi

  # --- доступ к базам проектов ---
  # Базы порты наружу не публикуют (security-контракт), поэтому клиент цепляем
  # к docker-сетям, где живут БД: тогда база достижима по ИМЕНИ КОНТЕЙНЕРА
  # (напр. metsomeone-db-1) без единого открытого порта. Базой считаем контейнер
  # с образом postgres/mysql/mariadb/mongo. Идемпотентно: к своей сети повторно
  # не подключаемся. После заведения НОВОГО проекта перезапусти этот скрипт —
  # клиент доцепится к его сети.
  local db_re='postgres|mysql|mariadb|mongo'
  local reachable=() connected=0 cid net img cname
  while read -r cid img cname; do
    [[ -n "$cid" ]] || continue
    reachable+=("$cname")
    while read -r net; do
      [[ -n "$net" ]] || continue
      docker network inspect "$net" -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null \
        | grep -qw "$name" && continue
      docker network connect "$net" "$name" 2>/dev/null && connected=$((connected+1))
    done < <(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$cid" 2>/dev/null)
  done < <(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | grep -E " ($db_re)" )

  if (( ${#reachable[@]} == 0 )); then
    warn "Запущенных БД проектов не нашёл — подключения добавишь в DbGate вручную."
  else
    (( connected > 0 )) && ok "Клиент подключён к $connected сет(и/ям) с БД." \
                        || skip "Сети БД уже подключены"
    say "Базы (host в DbGate = имя контейнера, порт — стандартный для движка):"
    printf '        %s\n' "${reachable[@]}"
  fi

  say "DbGate в tailnet: https://<host>:8061 (публикует ports-web, ссылка — на дашборде)"
}

# ============================================================================
#  PROXY — общий веб-фронт перед всеми проектами (сжатие и кэш)
# ============================================================================
step_proxy() {
  echo; say "═══ Прокси проектов (Caddy) ═══"

  # Зачем: tailscale терминирует TLS, но отдаёт байт-в-байт — ни сжатия, ни
  # кэширующих заголовков. Дев-серверы приложений (какой бы стек их ни поднял)
  # тоже обычно молчат про Cache-Control, поэтому браузер тянет всю статику
  # заново на каждой перезагрузке. Мегабайт вёрстки по каналу tailnet — это
  # секунды на пустой странице.
  #
  # Один прокси перед всеми проектами чинит это разом и НЕ ТРОГАЕТ РЕПОЗИТОРИИ:
  # платформа даёт способность, проекту ничего объявлять не нужно. Способность
  # общая для любого стека — граница слоёв цела.
  #
  # СХЕМА. Проект как слушал свой порт 80XY, так и слушает. Прокси слушает
  # ТЕНЕВОЙ порт (80XY + 1000 = 90XY) и ходит на 80XY. В tailnet ports-web
  # отдаёт сервис на прежнем номере 80XY, но целью ставит теневой порт:
  #
  #     tailnet :8050 ──► 127.0.0.1:9050 (vps-proxy) ──► 127.0.0.1:8050 (проект)
  #
  # Номера портов, которыми пользуешься ты и `ports map`, не меняются; 90xx —
  # внутренняя кухня, наружу не торчит и в реестр не попадает.
  #
  # Сеть — host: иначе на каждый новый проект пришлось бы пересоздавать
  # контейнер ради -p. Слушает при этом только 127.0.0.1 (см. Caddyfile),
  # то есть снаружи по-прежнему недоступен.
  local name="vps-proxy"
  local image="caddy:2-alpine"          # прокси без состояния — плавающий минор ок
  local conf_dir="$HOME/.local/state/vps-proxy"

  command -v docker &>/dev/null || { warn "Docker не установлен — пропускаю прокси."; return 0; }

  # --- конфиг ---
  # Полную раскладку пишет ports-web (он один знает, какие сервисы живы). Здесь
  # только заготовка, чтобы контейнеру было с чем стартовать до первого прогона.
  install -d -m 755 "$conf_dir"
  if [[ ! -f "$conf_dir/Caddyfile" ]]; then
    cat > "$conf_dir/Caddyfile" <<'CADDY'
# Заготовка. Рабочий конфиг генерит ports-web — правки здесь затрутся.
{
	admin 127.0.0.1:2019
	auto_https off
}
CADDY
    ok "Заготовка конфига: $conf_dir/Caddyfile"
  else
    skip "Конфиг $conf_dir/Caddyfile"
  fi

  # --- контейнер ---
  # Как у Dozzle: пересоздаём только если не бежит — чужое не трогаем.
  if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" == "true" ]]; then
    skip "Контейнер $name запущен"
  else
    say "Поднимаю $name…"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --restart unless-stopped \
      --network host \
      -v "$conf_dir:/etc/caddy" \
      "$image" >/dev/null
    ok "Прокси запущен (теневые порты 90xx на 127.0.0.1)."
  fi

  say "Раскладку прокси держит ports-web; проверить — docker logs vps-proxy"
}

# ============================================================================
#  PORTS — CLI учёта портов (ставим команду, сам реестр раздаёт step_ports)
# ============================================================================
step_portstool() {
  echo; say "═══ Учёт портов (ports) ═══"

  # Самообслуживание для проектов: `ports claim <имя>` атомарно бронирует
  # свободный блок, `ports map` показывает занятое/свободное. Исходник — bin/ports
  # в репозитории (в git → переживает переезд), сюда просто копируем на PATH.
  local src="$REPO_DIR/bin/ports" dst="$HOME/.local/bin/ports"
  [[ -f "$src" ]] || { warn "Нет $src — пропускаю"; return; }
  install -d -m 755 "$HOME/.local/bin"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    skip "Команда ports установлена"
  else
    install -m 755 "$src" "$dst"
    ok "Команда ports установлена (ports map / claim / free / doctor)."
  fi
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
    (( base != 8060 )) || die "$name: блок 8060-8069 зарезервирован под инфру (dozzle/dbgate). Возьми другой: ports claim $name."

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
#  DASHBOARD — веб-сервисы в tailnet (порт=порт) + страница со ссылками
# ============================================================================
# ports-web отдаёт каждый веб-сервис проекта в tailnet на его же номере порта
# (tailnet :8050 → host :8050) и рисует index.html со ссылками на всё занятое.
# Таймер раз в минуту держит и раскладку serve, и страницу в актуальном виде:
# поднял новый проект — он сам появится и в tailnet, и на дашборде.
step_dashboard() {
  echo; say "═══ Дашборд сервисов ═══"

  local src="$REPO_DIR/bin/ports-web" dst="$HOME/.local/bin/ports-web"
  [[ -f "$src" ]] || { warn "Нет $src — пропускаю"; return; }
  install -d -m 755 "$HOME/.local/bin"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    skip "Команда ports-web установлена"
  else
    install -m 755 "$src" "$dst"
    ok "Команда ports-web установлена."
  fi

  if ! tailscale status &>/dev/null; then
    warn "Tailscale не в сети — дашборд поднимется после 'sudo tailscale up'."
  else
    "$dst" >/dev/null 2>&1 || true    # первый прогон: разложить serve и сгенерить страницу
    local host
    host="$(tailscale status --json | grep -m1 '"DNSName"' | cut -d'"' -f4 | sed 's/\.$//')"
    ok "Веб-сервисы отданы в tailnet на своих портах."
    say "Дашборд: https://$host:8062"
  fi

  # --- таймер: держим serve и страницу свежими ---
  install -d -m 755 "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/ports-web.service" <<'UNIT'
[Unit]
Description=Опубликовать веб-сервисы в tailnet и обновить дашборд

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ports-web
UNIT
  cat > "$HOME/.config/systemd/user/ports-web.timer" <<'UNIT'
[Unit]
Description=Обновлять раскладку tailnet и дашборд сервисов

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=20s

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now ports-web.timer >/dev/null 2>&1
  if systemctl --user is-active --quiet ports-web.timer; then
    ok "Автообновление включено: раз в минуту."
  else
    warn "Таймер дашборда не запустился: systemctl --user status ports-web.timer"
  fi
}

# ============================================================================
#  АВТОПУЛ — изменения, запушенные с других машин, приезжают сами
# ============================================================================
# Код правится в трёх местах: на ноутбуке владельца, здесь агентом и изредка
# прямо на GitHub. Без автопула сервер молча отстаёт, и расхождение обнаруживает
# себя в самый неудобный момент.
#
# Опрос по таймеру, а не webhook: webhook требует входящего HTTP, то есть либо
# открытого порта, либо tailscale funnel. Отдавать наружу вход ради удобства
# деплоя — плохой размен, весь смысл настройки firewall в обратном. `git fetch`
# на таком репозитории стоит один запрос и пару килобайт; раз в две минуты
# сервер этого не замечает.
step_autopull() {
  echo; say "═══ Автопул проектов ═══"

  local bin="$HOME/.local/bin/projects-pull"
  install -d -m 755 "$HOME/.local/bin"
  cat > "$bin" <<'PULLSH'
#!/usr/bin/env bash
# Подтягивает в проекты изменения, запушенные с других машин.
# Ставится setup-dev.sh, руками не правится.
#
# Главный принцип: НИКОГДА не трогать работу, которая идёт прямо сейчас.
# Поэтому только --ff-only (он не мержит и ничего не перезаписывает: либо
# перемотка начисто, либо отказ) и пропуск всего, что выглядит занятым.
set -uo pipefail

PROJECTS_DIR="/projects"
LOG="$HOME/.local/state/projects-pull.log"
mkdir -p "$(dirname "$LOG")"

log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }

shopt -s nullglob
for repo in "$PROJECTS_DIR"/*/; do
  [[ -d "$repo/.git" ]] || continue
  name="$(basename "$repo")"
  cd "$repo" || continue

  # Не main — значит идёт работа в ветке. Это нормально, молчим.
  branch="$(git symbolic-ref --short -q HEAD || true)"
  [[ "$branch" == "main" ]] || continue

  # Незаконченный мерж или ребейз — вмешиваться нельзя.
  [[ -d .git/rebase-merge || -d .git/rebase-apply || -f .git/MERGE_HEAD ]] && continue

  # Незакоммиченные правки: кто-то (человек или агент) сейчас работает.
  # Молча ждём следующего запуска — файл из-под редактирования не уедет.
  [[ -z "$(git status --porcelain)" ]] || continue

  timeout 60 git fetch --quiet origin 2>/dev/null || { log "$name: fetch не удался"; continue; }

  before="$(git rev-parse HEAD)"
  after="$(git rev-parse origin/main 2>/dev/null)" || continue
  [[ "$before" != "$after" ]] || continue   # уже актуально — не шумим в журнал

  # Локальные коммиты, которых нет на GitHub. Перемотка невозможна, и это ровно
  # тот случай, когда автопул тихо встаёт навсегда — поэтому пишем в журнал.
  if ! git merge-base --is-ancestor "$before" "$after"; then
    log "$name: есть незапушенные локальные коммиты — автопул остановлен, нужен push"
    continue
  fi

  changed="$(git diff --name-only "$before" "$after")"
  if timeout 120 git merge --ff-only --quiet "$after" 2>/dev/null; then
    log "$name: обновлён $(git rev-parse --short "$before") → $(git rev-parse --short "$after")"
    # PHP интерпретируемый — правки кода действуют сразу. Перезапуск нужен
    # только для этих случаев, и решает его человек, а не таймер.
    grep -qE '(^|/)(composer\.lock|package-lock\.json|yarn\.lock|Dockerfile|docker-compose[^/]*\.yml)$' <<< "$changed" \
      && log "$name:   \\_ изменились зависимости или сборка — нужен make up"
    grep -qE '(^|/)database/migrations/' <<< "$changed" \
      && log "$name:   \\_ новые миграции — нужен make up"
    # .env в git нет, поэтому новая переменная приедет только как пример.
    grep -qE '(^|/)\.env\.example$' <<< "$changed" \
      && log "$name:   \\_ изменился .env.example — сверь свой .env, его git не переносит"
  else
    log "$name: перемотка не удалась"
  fi
done

# Журнал не должен расти бесконечно.
if [[ -f "$LOG" ]] && (( $(wc -l < "$LOG") > 500 )); then
  tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
PULLSH
  chmod 755 "$bin"
  ok "Команда projects-pull установлена."

  install -d -m 755 "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/projects-pull.service" <<'UNIT'
[Unit]
Description=Подтянуть в проекты изменения из GitHub

[Service]
Type=oneshot
ExecStart=%h/.local/bin/projects-pull
UNIT
  cat > "$HOME/.config/systemd/user/projects-pull.timer" <<'UNIT'
[Unit]
Description=Проверять GitHub на изменения в проектах

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
# Таймеру не нужна точность до секунды; послабление позволяет systemd
# группировать пробуждения и не дёргать процессор впустую.
AccuracySec=30s

[Install]
WantedBy=timers.target
UNIT

  systemctl --user daemon-reload
  systemctl --user enable --now projects-pull.timer >/dev/null 2>&1
  if systemctl --user is-active --quiet projects-pull.timer; then
    ok "Автопул включён: раз в 2 минуты, только main, только перемотка."
    say "Журнал: ~/.local/state/projects-pull.log"
  else
    warn "Таймер автопула не запустился. Диагностика:"
    echo "    systemctl --user status projects-pull.timer"
  fi
}

# ============================================================================
#  ПРАВИЛА ДЛЯ АГЕНТОВ
# ============================================================================
# ============================================================================
#  ЯЗЫК ОБЩЕНИЯ АГЕНТОВ
# ============================================================================
# Русский в этом репозитории — язык документов, а не приказ отвечать по-русски:
# нигде нет директивы про язык, агент просто зеркалит то, что читает. Поэтому
# язык ответа задаём явно, одной строкой в ~/.claude/CLAUDE.md — его Claude Code
# читает в КАЖДОЙ сессии этого пользователя, и управляющей, и проектной. Так
# сервер становится многоязычным без перевода правил и скиллов.
step_agent_lang() {
  echo; say "═══ Язык общения агентов ═══"

  local lang="ru"
  if [[ -f "$CONF_FILE" ]]; then
    local v
    v="$(grep -E '^[[:space:]]*AGENT_LANG=' "$CONF_FILE" | tail -1 | cut -d= -f2- \
         | tr -d '"'"'" | sed 's/[[:space:]]*$//; s/^[[:space:]]*//')"
    [[ -n "$v" ]] && lang="$v"
  fi
  # Значение попадает в файл, который читает агент, — пускаем только язык.
  if ! [[ "$lang" =~ ^[A-Za-z][A-Za-z\ -]{0,30}$ ]]; then
    warn "AGENT_LANG='$lang' не похож на язык — оставляю русский. Примеры: ru, en, Spanish."
    lang="ru"
  fi

  local line note
  case "${lang,,}" in
    ru|rus|russian)
      line="Общайся с пользователем по-русски."
      note="Отвечай так независимо от того, на каком языке написаны файлы, которые читаешь." ;;
    en|eng|english)
      line="Talk to the user in English."
      note="Answer in that language regardless of the language of the files you read." ;;
    *)
      line="Talk to the user in $lang."
      note="Answer in that language regardless of the language of the files you read." ;;
  esac

  local f="$HOME/.claude/CLAUDE.md"
  local begin="<!-- vps:lang — генерируется setup-dev.sh из vps.conf, правь там -->"
  local end="<!-- /vps:lang -->"
  install -d -m 700 "$HOME/.claude"
  [[ -f "$f" ]] || : > "$f"

  # Блок с маркерами, а не весь файл: рядом могут лежать личные заметки
  # пользователя, и перезаписывать их платформа права не имеет.
  local tmp="$f.tmp"
  if grep -qF "$begin" "$f" && grep -qF "$end" "$f"; then
    awk -v b="$begin" -v e="$end" -v l="$line" -v n="$note" '
      $0 == b { print b; print l; print n; print e; skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { print }
    ' "$f" > "$tmp"
  else
    { cat "$f"; [[ -s "$f" ]] && echo; printf '%s\n%s\n%s\n%s\n' "$begin" "$line" "$note" "$end"; } > "$tmp"
  fi

  if cmp -s "$f" "$tmp"; then
    rm -f "$tmp"
    skip "Язык агентов: $lang"
  else
    mv "$tmp" "$f"
    ok "Язык агентов: $lang (записано в $f)."
    say "Уже открытые сессии читают правила только при старте — переоткрой их, если нужно сразу."
  fi
}

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
  step_dozzle
  step_db_client
  step_proxy
  step_portstool
  step_ports
  step_dashboard
  step_autopull
  step_agent_lang
  step_rules

  echo
  ok "Готово."
}

main "$@"
