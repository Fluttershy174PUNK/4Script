#!/bin/bash
#
# seq_vps.sh — Комплексная защита VPS сервера
# Debian/Ubuntu · Fedora/RHEL/CentOS · Rocky · AlmaLinux
#
# Использование: sudo ./seq_vps.sh [--help]
#

# ponytail: без -e — это интерактивное меню, любой `return 1` из этапа
# (неверный номер, несовпавшие пароли) убивал бы весь скрипт вместо возврата в меню.
# Критичные операции проверяются явно (sshd -t перед рестартом).
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════
#  ЦВЕТА И СТИЛИ
# ═══════════════════════════════════════════════════════════════════
readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BG_RED='\033[41m'
readonly C_BG_GREEN='\033[42m'

# ── Иконки (работают в большинстве терминалов) ─────────────────────
readonly ICON_OK='✔'
readonly ICON_FAIL='✘'
readonly ICON_WARN='⚠'
readonly ICON_INFO='ℹ'
readonly ICON_KEY='🔑'
readonly ICON_LOCK='🔒'
readonly ICON_SHIELD='🛡'
readonly ICON_GLOBE='🌐'
readonly ICON_FIRE='🔥'
readonly ICON_USER='👤'
readonly ICON_GEAR='⚙'
readonly ICON_ARROW='❯'
readonly ICON_BULLET='•'
readonly SPINNER_CHARS='|/-\'

# ═══════════════════════════════════════════════════════════════════
#  ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
# ═══════════════════════════════════════════════════════════════════
readonly DATA_DIR="/opt/seq_vps"
# одна метка времени на прогон — иначе бэкап и лог могут разойтись на секунду
RUN_TS="$(date +%Y%m%d_%H%M%S)"
readonly RUN_TS
readonly BACKUP_DIR="${DATA_DIR}/backups/${RUN_TS}"
readonly LOG_FILE="${DATA_DIR}/seq_vps_${RUN_TS}.log"
readonly STAGE_STATUS_FILE="${DATA_DIR}/.seq_vps_status"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
# 00-, а не 99-: sshd берёт ПЕРВОЕ найденное значение, а на облачных образах
# лежит 50-cloud-init.conf с PasswordAuthentication yes, который перебьёт 99-*.
readonly SEQ_SSHD_DROPIN="00-seq-vps.conf"
CURRENT_SSH_PORT=22
SSH_KEY_USER=""
TERM_WIDTH=${COLUMNS:-80}
SPINNER_PID=""

PKG_MGR=""
DISTRO_NAME=""
SSH_SERVICE=""
SUDO_GROUP=""
HAS_SELINUX=false

# ═══════════════════════════════════════════════════════════════════
#  БАЗОВЫЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

# Спиннер — запуск/остановка
# ponytail: фон-сабшелл НЕ видит изменения переменной родителя, поэтому
# останавливаем по PID (kill), а не флагом — иначе вечный hang.
spinner_start() {
	local msg="${1:-}"
	spinner_stop
	(
		local i=0 n=${#SPINNER_CHARS}
		while :; do
			printf "\r  ${C_CYAN}%s${C_RESET} %s" "${SPINNER_CHARS:$((i % n)):1}" "$msg"
			i=$((i + 1))
			sleep 0.1
		done
	) &
	SPINNER_PID=$!
}

spinner_stop() {
	[[ -n "$SPINNER_PID" ]] || return 0
	kill "$SPINNER_PID" 2>/dev/null
	wait "$SPINNER_PID" 2>/dev/null
	SPINNER_PID=""
	printf "\r%*s\r" "$TERM_WIDTH" ""
}

cleanup() {
	spinner_stop 2>/dev/null
	printf "\n"
}
trap cleanup EXIT INT TERM

# Прогресс-бар: progress_bar current total [label]
progress_bar() {
	local cur=$1 total=$2 label="${3:-}" w=30
	local pct=$((cur * 100 / total))
	local filled=$((cur * w / total))
	local empty=$((w - filled))
	printf "\r  ${C_BLUE}%s${C_RESET} [${C_GREEN}" "$label"
	printf '%*s' "$filled" '' | tr ' ' '█'
	printf "${C_RESET}${C_DIM}"
	printf '%*s' "$empty" '' | tr ' ' '░'
	printf "${C_RESET}] %3d%%" "$pct"
}

log() { echo -e "$*" | tee -a "$LOG_FILE"; }
log_info() { log "${C_BLUE}${ICON_INFO}${C_RESET} $1"; }
log_ok() { log "${C_GREEN}${ICON_OK}${C_RESET} $1"; }
log_warn() { log "${C_YELLOW}${ICON_WARN}${C_RESET} $1"; }
log_err() { log "${C_RED}${ICON_FAIL}${C_RESET} $1"; }

# Визуальные элементы
hr() { printf "${C_DIM}%s${C_RESET}\n" "$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' '─')"; }
hr_thick() { printf "${C_BLUE}%s${C_RESET}\n" "$(printf '%*s' "$TERM_WIDTH" '' | tr ' ' '═')"; }

# Заголовок этапа с иконкой
stage_banner() {
	local icon="$1" num="$2" title="$3"
	echo ""
	hr_thick
	printf "  ${C_BOLD}${C_CYAN}${icon}  ЭТАП %s: %s${C_RESET}\n" "$num" "$title"
	hr_thick
	echo ""
}

# Одноклавишное подтверждение (y/N)
confirm() {
	local prompt="${1:-Продолжить?}" default="${2:-n}"
	local hint
	[[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
	printf "  ${C_YELLOW}%s %s${C_RESET} " "$prompt" "$hint"
	read -r -n1 -s answer
	echo "$answer"
	[[ "$default" == "y" ]] && { [[ "$answer" != "n" && "$answer" != "N" ]]; } || { [[ "$answer" == "y" || "$answer" == "Y" ]]; }
}

# Меню — цветной пункт со статусом
menu_item() {
	local num="$1" stage="$2" text="$3"
	local status mark="  " icon="" color=""

	status=$(get_stage_status "$stage" 2>/dev/null || echo "not_started")
	case "$status" in
	completed)
		mark="${C_GREEN}${ICON_OK}${C_RESET} "
		icon="${C_GREEN}"
		color="$C_GREEN"
		;;
	failed)
		mark="${C_RED}${ICON_FAIL}${C_RESET} "
		icon="${C_RED}"
		color="$C_RED"
		;;
	skipped)
		mark="─ "
		icon="${C_YELLOW}"
		color="$C_YELLOW"
		;;
	*)
		mark="  "
		icon="${C_DIM}"
		;;
	esac

	# %b интерпретирует escape-цвета (%s печатал бы их сырьём); padding — внутри
	local num_fmt
	if [[ -n "$stage" ]]; then
		num_fmt="${icon}$(printf '%-3s' "${num})")${C_RESET}"
	else
		num_fmt="${C_DIM}$(printf '%-3s' "${num})")${C_RESET}"
	fi
	printf "  %b %b%-50s%b\n" "$num_fmt" "$mark" "$text" "$color"
}

# ═══════════════════════════════════════════════════════════════════
#  ИНИЦИАЛИЗАЦИЯ
# ═══════════════════════════════════════════════════════════════════

detect_distro() {
	if [[ -f /etc/os-release ]]; then
		source /etc/os-release
	fi

	if [[ "${ID:-}" =~ ^(debian|ubuntu|linuxmint|pop|raspbian)$ ]]; then
		PKG_MGR="apt"
		DISTRO_NAME="${PRETTY_NAME:-Debian/Ubuntu}"
		SUDO_GROUP="sudo"
		if systemctl list-unit-files 2>/dev/null | grep -q "^ssh.service"; then
			SSH_SERVICE="ssh"
		elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd.service"; then
			SSH_SERVICE="sshd"
		else
			SSH_SERVICE="ssh"
		fi
	elif [[ "${ID:-}" =~ ^(fedora|rhel|centos|rocky|almalinux|ol)$ ]]; then
		DISTRO_NAME="${PRETTY_NAME:-Fedora/RHEL/CentOS}"
		SUDO_GROUP="wheel"
		SSH_SERVICE="sshd"
		PKG_MGR=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum")
	else
		echo -e "${C_RED}${ICON_FAIL}  Неподдерживаемый дистрибутив: ${ID:-неизвестно}${C_RESET}"
		echo "  Поддерживаются: Debian, Ubuntu, Fedora, RHEL, CentOS, Rocky, AlmaLinux"
		exit 1
	fi

	# SELinux: на RHEL-семействе без semanage sshd не поднимется на нестандартном порту
	if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
		HAS_SELINUX=true
	fi

	# Адаптируем ширину под терминал
	TERM_WIDTH=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	((TERM_WIDTH > 100)) && TERM_WIDTH=100
	((TERM_WIDTH < 60)) && TERM_WIDTH=60
}

init_status_file() {
	if [[ ! -f "$STAGE_STATUS_FILE" ]]; then
		cat >"$STAGE_STATUS_FILE" <<'EOF'
# Статус этапов seq_vps (completed / failed / skipped / not_started)
stage1_update=not_started
stage2_admin_user=not_started
stage3_root_password=not_started
stage4_ssh_key=not_started
stage5_ssh_config=not_started
stage6_sftp_user=not_started
stage7_ufw=not_started
stage8_autoupdate=not_started
stage9_intrusion=not_started
stage10_dns=not_started
stage11_fish=not_started
stage12_timezone=not_started
stage13_lynis=not_started
stage14_disk=not_started
stage15_bbr=not_started
EOF
	fi
}

check_root() {
	if [[ $EUID -ne 0 ]]; then
		echo -e "${C_RED}${ICON_FAIL}  Запустите от root:  sudo ./seq_vps.sh${C_RESET}"
		exit 1
	fi
}

# ═══════════════════════════════════════════════════════════════════
#  БЭКАП / СТАТУС
# ═══════════════════════════════════════════════════════════════════

backup_file() {
	local file="$1" stage="$2"
	if [[ ! -e "$file" ]]; then
		log_warn "Файл $file не существует, бэкап пропущен"
		return 0
	fi
	local dst="${BACKUP_DIR}/${stage}"
	mkdir -p "$dst"
	cp -a "$file" "$dst/"
	log_info "Бэкап: ${C_DIM}$file${C_RESET} → ${C_DIM}$dst/${C_RESET}"
}

update_stage_status() {
	local stage="$1" status="$2"
	[[ -f "$STAGE_STATUS_FILE" ]] && sed -i "s/^${stage}=.*/${stage}=${status}/" "$STAGE_STATUS_FILE"
}

get_stage_status() {
	local stage="$1"
	[[ -f "$STAGE_STATUS_FILE" ]] && grep "^${stage}=" "$STAGE_STATUS_FILE" 2>/dev/null | cut -d= -f2 || echo "not_started"
}

get_regular_users() {
	while IFS=: read -r user _ uid _ _ home shell; do
		[[ $uid -ge 1000 ]] || continue
		[[ "$shell" != "/usr/sbin/nologin" && "$shell" != "/bin/false" && "$shell" != "/sbin/nologin" ]] || continue
		local groups
		groups=$(groups "$user" 2>/dev/null | cut -d: -f2 | xargs)
		echo "$user:$uid:$groups:$home"
	done </etc/passwd
}

# ═══════════════════════════════════════════════════════════════════
#  СВОДКА СЕРВЕРА — с цветовой кодировкой безопасности
# ═══════════════════════════════════════════════════════════════════

# severity_color: возвращает цвет в зависимости от уровня опасности
severity_color() {
	case "$1" in
	danger) echo -n "${C_RED}" ;;
	warning) echo -n "${C_YELLOW}" ;;
	ok) echo -n "${C_GREEN}" ;;
	esac
}

show_server_summary() {
	local w=$((TERM_WIDTH - 2))
	echo -e "${C_BOLD}${C_CYAN}┌─${C_RESET} ${C_BOLD}СВОДКА СЕРВЕРА${C_RESET} ${C_DIM}— Seq VPS Security${C_RESET}"

	# ── Пользователи ──
	echo -e "\n${C_BOLD}${ICON_USER}  Пользователи:${C_RESET}"
	local has_users=false
	while IFS=: read -r user uid groups home; do
		has_users=true
		local has_key="нет"
		[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] && has_key="${C_GREEN}да ($(wc -l <"$home/.ssh/authorized_keys") шт.)${C_RESET}"
		echo -e "  ${ICON_BULLET} ${C_BOLD}$user${C_RESET}  uid=$uid  группы: $groups  SSH-ключ: $has_key"
	done < <(get_regular_users)
	[[ "$has_users" == false ]] && echo -e "  ${C_DIM}(нет обычных пользователей)${C_RESET}"

	# ── SFTP ──
	echo -e "\n${C_BOLD}${ICON_LOCK}  SFTP пользователи:${C_RESET}"
	local has_sftp=false
	while IFS=: read -r user _ uid _ _ home shell; do
		[[ "$shell" == "/usr/sbin/nologin" || "$shell" == "/bin/false" ]] || continue
		# 1000..65533: исключаем nobody (65534) и прочие системные
		[[ $uid -ge 1000 && $uid -lt 65534 ]] || continue
		has_sftp=true
		echo -e "  ${ICON_BULLET} ${C_BOLD}$user${C_RESET}  uid=$uid  дом=$home"
	done </etc/passwd
	[[ "$has_sftp" == false ]] && echo -e "  ${C_DIM}(нет SFTP пользователей)${C_RESET}"

	# ── SSH — с цветовой кодировкой безопасности ──
	local ssh_cfg
	ssh_cfg=$(sshd -T 2>/dev/null || true) || true
	local sp
	sp=$(echo "$ssh_cfg" | grep "^port " | awk '{print $2}')
	sp=${sp:-22}
	local pa
	pa=$(echo "$ssh_cfg" | grep "^passwordauthentication " | awk '{print $2}')
	pa=${pa:-yes}
	local rl
	rl=$(echo "$ssh_cfg" | grep "^permitrootlogin " | awk '{print $2}')
	rl=${rl:-yes}
	local ma
	ma=$(echo "$ssh_cfg" | grep "^maxauthtries " | awk '{print $2}')
	ma=${ma:-6}
	local ep
	ep=$(echo "$ssh_cfg" | grep "^permitemptypasswords " | awk '{print $2}')
	ep=${ep:-no}

	# Определяем цвета для каждого параметра
	local sc_port sc_pwd sc_root sc_empty
	[[ "$sp" == "22" ]] && sc_port="warning" || sc_port="ok"
	[[ "$pa" == "yes" ]] && { [[ "$sp" == "22" ]] && sc_pwd="danger" || sc_pwd="warning"; } || sc_pwd="ok"
	[[ "$rl" == "yes" ]] && sc_root="danger" || sc_root="ok"
	[[ "$ep" == "yes" ]] && sc_empty="danger" || sc_empty="ok"

	echo -e "\n${C_BOLD}${ICON_KEY}  SSH:${C_RESET}"
	printf "  порт: %b%s%b | пароль: %b%s%b | root: %b%s%b\n" \
		"$(severity_color "$sc_port")" "$sp" "$C_RESET" \
		"$(severity_color "$sc_pwd")" "$pa" "$C_RESET" \
		"$(severity_color "$sc_root")" "$rl" "$C_RESET"
	printf "  макс. попыток: %s | пустые пароли: %b%s%b\n" \
		"$ma" "$(severity_color "$sc_empty")" "$ep" "$C_RESET"

	# Оценка безопасности SSH
	local ssh_score=0
	[[ "$sp" != "22" ]] && ((ssh_score++))
	[[ "$pa" == "no" ]] && ((ssh_score++))
	[[ "$rl" != "yes" ]] && ((ssh_score++))
	[[ "$ep" == "no" ]] && ((ssh_score++))

	local ssh_label ssh_color
	case $ssh_score in
	4)
		ssh_label="ОТЛИЧНО"
		ssh_color="$C_BG_GREEN$C_BOLD"
		;;
	3)
		ssh_label="ХОРОШО"
		ssh_color="$C_GREEN"
		;;
	2)
		ssh_label="СРЕДНЕ"
		ssh_color="$C_YELLOW"
		;;
	*)
		ssh_label="СЛАБО"
		ssh_color="$C_BG_RED$C_BOLD"
		;;
	esac
	printf "  оценка: %b%s%b\n" "$ssh_color" "$ssh_label" "$C_RESET"

	if [[ -d "$SSHD_CONFIG_D" ]]; then
		local confs
		confs=$(find "$SSHD_CONFIG_D" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l)
		[[ $confs -gt 0 ]] && echo -e "  drop-in: ${C_DIM}$(find "$SSHD_CONFIG_D" -maxdepth 1 -name '*.conf' -printf '%f ' 2>/dev/null)${C_RESET}"
	fi

	# ── Фаервол (UFW / firewalld) ──
	local fw
	fw=$(_fw_cmd)
	echo -e "\n${C_BOLD}${ICON_FIRE}  Фаервол (${fw^^}):${C_RESET}"
	if [[ "$fw" == firewalld ]]; then
		if firewall-cmd --state 2>/dev/null | grep -q running; then
			echo -e "  ${C_GREEN}● активен${C_RESET}"
			firewall-cmd --list-all 2>/dev/null | grep -E 'ports|services' | sed 's/^/  /'
		else
			echo -e "  ${C_YELLOW}● не активен${C_RESET} ${C_DIM}(рекомендуется включить)${C_RESET}"
		fi
	elif command -v ufw &>/dev/null; then
		if ufw status 2>/dev/null | grep -q "Status: active"; then
			echo -e "  ${C_GREEN}● активен${C_RESET}"
			ufw status verbose 2>/dev/null | grep -E "^To " | head -10 | sed 's/^/  /'
		else
			echo -e "  ${C_YELLOW}● не активен${C_RESET} ${C_DIM}(рекомендуется включить)${C_RESET}"
		fi
	else
		echo -e "  ${C_DIM}не установлен${C_RESET}"
	fi

	# Интрузия (CrowdSec / Fail2Ban)
	echo -e "\n${C_BOLD}${ICON_SHIELD}  Защита от атак:${C_RESET}"
	local has_idps=false
	command -v cscli &>/dev/null && {
		has_idps=true
		echo -e "  ${C_GREEN}● CrowdSec установлен${C_RESET}"
	}
	systemctl is-active --quiet fail2ban 2>/dev/null && {
		has_idps=true
		echo -e "  ${C_GREEN}● Fail2Ban запущен${C_RESET}"
	}
	$has_idps || echo -e "  ${C_DIM}не установлена (CrowdSec/Fail2Ban)${C_RESET}"

	# ── DNS ──
	echo -e "\n${C_BOLD}${ICON_GLOBE}  DNS:${C_RESET}"
	[[ -f /etc/resolv.conf ]] && grep "^nameserver" /etc/resolv.conf | sed 's/^/  /' 2>/dev/null || echo -e "  ${C_DIM}(не настроены)${C_RESET}"

	# ── Подключение ──
	local ip_addr
	ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
	echo -e "\n${C_BOLD}${ICON_ARROW}  Подключение:${C_RESET}"
	echo -e "  ${C_GREEN}ssh${C_RESET} -p $CURRENT_SSH_PORT user@${ip_addr:-<server_ip>}"

	# Если есть проблемы — подсказка
	if [[ $ssh_score -le 2 ]]; then
		echo -e "\n  ${C_YELLOW}${ICON_WARN}  SSH нуждается в усилении — этапы 4 и 5${C_RESET}"
	fi
	if ! command -v ufw &>/dev/null || ! ufw status 2>/dev/null | grep -q "Status: active"; then
		echo -e "  ${C_YELLOW}${ICON_WARN}  Фаервол неактивен — этап 7${C_RESET}"
	fi
	if ! command -v cscli &>/dev/null && ! systemctl is-active --quiet fail2ban 2>/dev/null; then
		echo -e "  ${C_YELLOW}${ICON_WARN}  Защита от атак не установлена — этап 9${C_RESET}"
	fi

	hr
	echo ""
}

# ═══════════════════════════════════════════════════════════════════
#  ПАКЕТНЫЙ МЕНЕДЖЕР
# ═══════════════════════════════════════════════════════════════════

pkg_install_retry() {
	local pkg="$1" max=3 retry=0
	while [[ $retry -lt $max ]]; do
		log_info "Установка ${C_BOLD}$pkg${C_RESET} (попытка $((retry + 1))/$max)..."
		spinner_start "Устанавливаем $pkg..."
		case "$PKG_MGR" in
		apt) apt install -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 "$pkg" &>/dev/null && {
			spinner_stop
			return 0
		} ;;
		dnf | yum) $PKG_MGR install -y "$pkg" &>/dev/null && {
			spinner_stop
			return 0
		} ;;
		esac
		spinner_stop
		retry=$((retry + 1))
		[[ $retry -lt $max ]] && {
			log_warn "Повтор через 5 сек..."
			sleep 5
			repair_pkg
		}
	done
	log_err "Не удалось установить $pkg после $max попыток"
	return 1
}

repair_pkg() {
	case "$PKG_MGR" in
	apt)
		dpkg --configure -a 2>/dev/null || true
		apt-get -f install -y 2>/dev/null || true
		apt-get update 2>/dev/null || true
		;;
	dnf)
		dnf clean all 2>/dev/null || true
		dnf makecache 2>/dev/null || true
		;;
	yum)
		yum clean all 2>/dev/null || true
		yum makecache 2>/dev/null || true
		;;
	esac
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 1: ОБНОВЛЕНИЕ СИСТЕМЫ
# ═══════════════════════════════════════════════════════════════════

stage_update() {
	stage_banner "$ICON_GEAR" "1" "Обновление системы"

	case "$PKG_MGR" in
	apt)
		backup_file "/etc/apt/sources.list" "stage1_update"
		[[ -d "/etc/apt/sources.list.d" ]] && backup_file "/etc/apt/sources.list.d" "stage1_update"
		;;
	dnf | yum)
		[[ -d "/etc/yum.repos.d" ]] && backup_file "/etc/yum.repos.d" "stage1_update"
		;;
	esac

	log_info "Обновление списка пакетов..."
	spinner_start "Обновляем списки пакетов..."
	local max=3 retry=0
	while [[ $retry -lt $max ]]; do
		case "$PKG_MGR" in
		apt) apt update &>/dev/null && break ;;
		dnf | yum) $PKG_MGR update -y &>/dev/null && break ;;
		esac
		retry=$((retry + 1))
		[[ $retry -lt $max ]] && {
			sleep 5
			repair_pkg
		}
	done
	spinner_stop

	log_info "Установка обновлений..."
	spinner_start "Устанавливаем обновления..."
	case "$PKG_MGR" in
	apt)
		apt upgrade -y &>/dev/null || true
		apt full-upgrade -y &>/dev/null || true
		apt autoremove --purge -y &>/dev/null || true
		;;
	dnf | yum)
		$PKG_MGR upgrade -y &>/dev/null || true
		$PKG_MGR autoremove -y &>/dev/null || true
		;;
	esac
	spinner_stop

	log_ok "Система обновлена"
	update_stage_status "stage1_update" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 0: УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

stage_utilities() {
	stage_banner "$ICON_GEAR" "0" "Установка утилит"

	echo "  ${C_BOLD}1)${C_RESET} micro  ${C_DIM}— удобный редактор${C_RESET}"
	echo "  ${C_BOLD}2)${C_RESET} mc     ${C_DIM}— файловый менеджер${C_RESET}"
	echo "  ${C_BOLD}3)${C_RESET} Обе утилиты"
	echo "  ${C_BOLD}0)${C_RESET} Пропустить"
	echo ""
	read -rp "  ${C_BOLD}${ICON_ARROW}${C_RESET} " choice
	echo ""

	case "$choice" in
	1) pkg_install_retry "micro" ;;
	2) pkg_install_retry "mc" ;;
	3)
		pkg_install_retry "micro"
		pkg_install_retry "mc"
		;;
	*) log_info "Пропущено" ;;
	esac
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 2: ПОЛЬЗОВАТЕЛИ
# ═══════════════════════════════════════════════════════════════════

stage_users() {
	stage_banner "$ICON_USER" "2" "Управление пользователями"

	# Список пользователей
	echo -e "${C_BOLD}▸ Текущие пользователи:${C_RESET}"
	local users=() idx=1
	while IFS=: read -r user uid groups home; do
		echo -e "  ${C_BOLD}$idx)${C_RESET} ${C_BOLD}$user${C_RESET}  uid=$uid  группы: $groups"
		users+=("$user")
		idx=$((idx + 1))
	done < <(get_regular_users)
	[[ ${#users[@]} -eq 0 ]] && echo -e "  ${C_DIM}(нет обычных пользователей)${C_RESET}"

	echo ""
	echo -e "  ${C_BOLD}C)${C_RESET} Создать нового"

	[[ ${#users[@]} -gt 0 ]] && {
		echo -e "  ${C_BOLD}P)${C_RESET} Сменить пароль"
		echo -e "  ${C_BOLD}G)${C_RESET} Группы"
		echo -e "  ${C_BOLD}D)${C_RESET} Удалить"
	}
	echo -e "  ${C_BOLD}S)${C_RESET} Пропустить"
	echo ""
	read -rp "  ${C_BOLD}${ICON_ARROW}${C_RESET} " action
	echo ""

	case "${action,,}" in
	c)
		read -rp "  Имя пользователя: " username
		id "$username" &>/dev/null && {
			log_err "Уже существует: $username"
			return 1
		}
		read -rsp "  Пароль: " pw
		echo
		read -rsp "  Подтвердите: " pw2
		echo
		[[ "$pw" != "$pw2" ]] && {
			log_err "Пароли не совпадают"
			return 1
		}
		[[ -z "$pw" ]] && {
			log_err "Пароль не может быть пустым"
			return 1
		}
		useradd -m -s /bin/bash "$username"
		echo "$username:$pw" | chpasswd
		usermod -aG "$SUDO_GROUP" "$username"
		log_ok "Пользователь ${C_BOLD}$username${C_RESET} создан (группа $SUDO_GROUP)"
		echo "ADMIN_USER=$username" >>"$STAGE_STATUS_FILE"
		;;
	p)
		[[ ${#users[@]} -eq 0 ]] && {
			log_err "Нет пользователей"
			return 1
		}
		read -rp "  Номер (1-${#users[@]}): " num
		[[ ! "$num" =~ ^[0-9]+$ || $num -lt 1 || $num -gt ${#users[@]} ]] && {
			log_err "Неверный номер"
			return 1
		}
		local u="${users[$((num - 1))]}"
		read -rsp "  Новый пароль для ${C_BOLD}$u${C_RESET}: " pw
		echo
		read -rsp "  Подтвердите: " pw2
		echo
		[[ "$pw" != "$pw2" ]] && {
			log_err "Пароли не совпадают"
			return 1
		}
		echo "$u:$pw" | chpasswd
		log_ok "Пароль ${C_BOLD}$u${C_RESET} изменён"
		;;
	g)
		[[ ${#users[@]} -eq 0 ]] && {
			log_err "Нет пользователей"
			return 1
		}
		read -rp "  Номер (1-${#users[@]}): " num
		[[ ! "$num" =~ ^[0-9]+$ || $num -lt 1 || $num -gt ${#users[@]} ]] && {
			log_err "Неверный номер"
			return 1
		}
		local u="${users[$((num - 1))]}"
		local cg
		cg=$(groups "$u" 2>/dev/null | cut -d: -f2 | xargs)
		local hs="нет"
		groups "$u" 2>/dev/null | grep -qE '\b(sudo|wheel)\b' && hs="${C_GREEN}да${C_RESET}"
		echo ""
		echo -e "  ${C_BOLD}▸ $u${C_RESET}  группы: $cg  sudo: $hs"
		echo ""
		echo "  1) Дать sudo ($SUDO_GROUP)"
		echo "  2) Забрать sudo"
		echo "  3) Добавить в группу"
		echo "  4) Удалить из группы"
		echo "  5) Все группы системы"
		echo "  S) Назад"
		read -rp "  ${C_BOLD}${ICON_ARROW}${C_RESET} " ga
		case "$ga" in
		1) usermod -aG "$SUDO_GROUP" "$u" && log_ok "$u → $SUDO_GROUP" || log_err "Не удалось" ;;
		2)
			gpasswd -d "$u" sudo 2>/dev/null
			gpasswd -d "$u" wheel 2>/dev/null
			log_ok "sudo отключён для $u"
			;;
		3)
			read -rp "  Группа: " gn
			getent group "$gn" &>/dev/null && {
				usermod -aG "$gn" "$u"
				log_ok "$u → $gn"
			} || log_err "Группа $gn не найдена"
			;;
		4)
			read -rp "  Группа: " gn
			gpasswd -d "$u" "$gn" 2>/dev/null && log_ok "$u удалён из $gn" || log_err "Не удалось"
			;;
		5)
			echo ""
			cut -d: -f1 /etc/group | sort | column | sed 's/^/  /'
			echo ""
			;;
		*) log_info "Назад" ;;
		esac
		;;
	d)
		[[ ${#users[@]} -eq 0 ]] && {
			log_err "Нет пользователей"
			return 1
		}
		read -rp "  Номер (1-${#users[@]}): " num
		[[ ! "$num" =~ ^[0-9]+$ || $num -lt 1 || $num -gt ${#users[@]} ]] && {
			log_err "Неверный номер"
			return 1
		}
		local u="${users[$((num - 1))]}"
		echo ""
		if confirm "Удалить пользователя ${C_BOLD}$u${C_RESET}?"; then
			gpasswd -d "$u" sudo 2>/dev/null || true
			gpasswd -d "$u" wheel 2>/dev/null || true
			userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
			log_ok "Пользователь $u удалён"
		else
			log_info "Отмена"
		fi
		;;
	*) log_info "Пропущено" ;;
	esac
	update_stage_status "stage2_admin_user" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 3: ПАРОЛЬ ROOT
# ═══════════════════════════════════════════════════════════════════

stage_root_password() {
	stage_banner "$ICON_KEY" "3" "Изменение пароля root"
	read -rsp "  Новый пароль root: " pw
	echo
	read -rsp "  Подтвердите:     " pw2
	echo
	[[ "$pw" != "$pw2" ]] && {
		log_err "Пароли не совпадают"
		update_stage_status "stage3_root_password" "failed"
		return 1
	}
	[[ -z "$pw" ]] && {
		log_err "Пароль не может быть пустым"
		return 1
	}
	echo "root:$pw" | chpasswd
	log_ok "Пароль root изменён"
	update_stage_status "stage3_root_password" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 4: SSH-КЛЮЧ
# ═══════════════════════════════════════════════════════════════════

stage_ssh_key() {
	stage_banner "$ICON_KEY" "4" "Установка SSH-ключа"

	echo -e "${C_BOLD}▸ Пользователи и ключи:${C_RESET}"
	local users=() idx=1
	while IFS=: read -r user uid groups home; do
		local ki="${C_DIM}нет${C_RESET}"
		[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] && ki="${C_GREEN}да ($(wc -l <"$home/.ssh/authorized_keys") шт.)${C_RESET}"
		echo -e "  ${C_BOLD}$idx)${C_RESET} ${C_BOLD}$user${C_RESET}  ключи: $ki"
		users+=("$user")
		idx=$((idx + 1))
	done < <(get_regular_users)
	[[ ${#users[@]} -eq 0 ]] && {
		log_err "Нет пользователей"
		return 1
	}

	# SFTP-ключи
	shopt -s nullglob
	local sftp_keys=(/etc/ssh/keys.d/*.pub)
	shopt -u nullglob
	[[ ${#sftp_keys[@]} -gt 0 ]] && {
		echo -e "\n${C_DIM}▸ SFTP (/etc/ssh/keys.d/):${C_RESET}"
		for kf in "${sftp_keys[@]}"; do
			local su
			su=$(basename "$kf" .pub)
			echo -e "  ${ICON_BULLET} $su: $(head -1 "$kf" | cut -c1-60)..."
		done
	}

	echo ""
	read -rp "  ${C_BOLD}Номер пользователя (1-${#users[@]}):${C_RESET} " num
	[[ ! "$num" =~ ^[0-9]+$ || $num -lt 1 || $num -gt ${#users[@]} ]] && {
		log_err "Неверный номер"
		return 1
	}
	SSH_KEY_USER="${users[$((num - 1))]}"

	local uh
	uh=$(getent passwd "$SSH_KEY_USER" | cut -d: -f6)
	[[ -z "$uh" ]] && {
		log_err "Не удалось определить homedir $SSH_KEY_USER"
		return 1
	}
	local ssh_dir="$uh/.ssh"

	[[ ! -d "$ssh_dir" ]] && {
		mkdir -p "$ssh_dir"
		chown "$SSH_KEY_USER:$SSH_KEY_USER" "$ssh_dir"
		chmod 700 "$ssh_dir"
	}
	backup_file "$ssh_dir/authorized_keys" "stage4_ssh_key"

	echo ""
	echo -e "${C_BOLD}▸ Действия с ключами (${C_BOLD}$SSH_KEY_USER${C_RESET}${C_BOLD}):${C_RESET}"
	echo "  1) Вставить ключ вручную"
	echo "  2) Скопировать от другого пользователя"
	echo "  3) Просмотреть ключи $SSH_KEY_USER"
	echo "  4) Все ключи на сервере"
	echo "  5) Удалить ключ"
	echo "  6) Инструкция: Linux/Mac"
	echo "  7) Инструкция: Windows"
	echo "  S) Пропустить"
	read -rp "  ${ICON_ARROW} " ka

	local srv_ip
	srv_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	srv_ip=${srv_ip:-<server_ip>}

	case "$ka" in
	1)
		echo ""
		echo "  Вставьте публичный ключ (ssh-ed25519 AAAA...):"
		read -r pk
		[[ -z "$pk" ]] && {
			log_err "Ключ пуст"
			return 1
		}
		if ! echo "$pk" | grep -qE '^(ssh-|ecdsa-|sk-ssh)'; then
			log_warn "Не похоже на SSH-ключ"
			confirm "Продолжить?" || return 1
		fi
		echo "$pk" >>"$ssh_dir/authorized_keys"
		chown "$SSH_KEY_USER:$SSH_KEY_USER" "$ssh_dir/authorized_keys"
		chmod 600 "$ssh_dir/authorized_keys"
		log_ok "Ключ добавлен для ${C_BOLD}$SSH_KEY_USER${C_RESET}"
		;;
	2)
		echo ""
		echo "Пользователи с ключами:"
		local sus=() si=1
		while IFS=: read -r user uid groups home; do
			[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] || continue
			echo "  $si) $user ($(wc -l <"$home/.ssh/authorized_keys") ключей)"
			sus+=("$user")
			si=$((si + 1))
		done < <(get_regular_users)
		[[ ${#sus[@]} -eq 0 ]] && {
			log_warn "Нет пользователей с ключами"
			return 1
		}
		read -rp "  Номер: " sn
		[[ "$sn" =~ ^[0-9]+$ && $sn -ge 1 && $sn -le ${#sus[@]} ]] || {
			log_err "Неверный номер"
			return 1
		}
		local su="${sus[$((sn - 1))]}"
		local sh
		sh=$(getent passwd "$su" | cut -d: -f6)
		cat "$sh/.ssh/authorized_keys" >>"$ssh_dir/authorized_keys"
		chown "$SSH_KEY_USER:$SSH_KEY_USER" "$ssh_dir/authorized_keys"
		chmod 600 "$ssh_dir/authorized_keys"
		log_ok "Ключи от $su скопированы для $SSH_KEY_USER"
		;;
	3)
		if [[ -f "$ssh_dir/authorized_keys" && -s "$ssh_dir/authorized_keys" ]]; then
			echo ""
			cat -n "$ssh_dir/authorized_keys"
			echo ""
		else log_info "Ключи не установлены"; fi
		;;
	4)
		while IFS=: read -r user uid groups home; do
			[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] || continue
			echo -e "\n${C_BOLD}▸ $user${C_RESET} ($home/.ssh/authorized_keys):"
			cat -n "$home/.ssh/authorized_keys"
		done < <(get_regular_users)
		shopt -s nullglob
		sftp_keys=(/etc/ssh/keys.d/*.pub)
		shopt -u nullglob
		[[ ${#sftp_keys[@]} -gt 0 ]] && {
			echo -e "\n${C_BOLD}▸ SFTP${C_RESET} (/etc/ssh/keys.d/):"
			for kf in "${sftp_keys[@]}"; do
				echo "  [$(basename "$kf" .pub)]:"
				cat -n "$kf"
			done
		}
		;;
	5)
		[[ -f "$ssh_dir/authorized_keys" && -s "$ssh_dir/authorized_keys" ]] || {
			log_warn "Нет ключей"
			return 0
		}
		echo ""
		cat -n "$ssh_dir/authorized_keys"
		echo ""
		read -rp "  Номер для удаления: " kn
		[[ "$kn" =~ ^[0-9]+$ ]] || {
			log_err "Введите номер строки"
			return 1
		}
		local total
		total=$(wc -l <"$ssh_dir/authorized_keys")
		[[ $kn -ge 1 && $kn -le $total ]] || {
			log_err "Нет строки $kn (всего $total)"
			return 1
		}
		sed -i "${kn}d" "$ssh_dir/authorized_keys"
		log_ok "Ключ $kn удалён"
		;;
	6)
		echo ""
		echo -e "${C_BOLD}${ICON_ARROW}  Инструкция: Linux / Mac${C_RESET}"
		echo ""
		echo -e "  ${C_BOLD}Сервер:${C_RESET} $SSH_KEY_USER@$srv_ip:$CURRENT_SSH_PORT"
		echo ""
		echo -e "  ${C_DIM}# Сгенерировать ключ:${C_RESET}"
		echo "  ssh-keygen -t ed25519 -C \"your@email.com\""
		echo ""
		echo -e "  ${C_DIM}# Скопировать на сервер:${C_RESET}"
		echo "  ssh-copy-id -p $CURRENT_SSH_PORT $SSH_KEY_USER@$srv_ip"
		echo ""
		echo -e "  ${C_DIM}# Подключиться:${C_RESET}"
		echo "  ssh -p $CURRENT_SSH_PORT $SSH_KEY_USER@$srv_ip"
		echo ""
		;;
	7)
		echo ""
		echo -e "${C_BOLD}${ICON_ARROW}  Инструкция: Windows${C_RESET}"
		echo ""
		echo -e "  ${C_BOLD}Сервер:${C_RESET} $SSH_KEY_USER@$srv_ip:$CURRENT_SSH_PORT"
		echo ""
		echo -e "  ${C_DIM}# PowerShell — сгенерировать ключ:${C_RESET}"
		echo "  ssh-keygen -t ed25519"
		echo ""
		echo -e "  ${C_DIM}# PowerShell — скопировать на сервер:${C_RESET}"
		echo "  type \$env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh -p $CURRENT_SSH_PORT $SSH_KEY_USER@$srv_ip \"mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys\""
		echo ""
		echo -e "  ${C_DIM}# Или через PuTTY:${C_RESET}  PuTTYgen → Generate → вставить ключ в authorized_keys (пункт 1)"
		echo ""
		;;
	*) log_info "Пропущено" ;;
	esac
	update_stage_status "stage4_ssh_key" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 5: SSH КОНФИГ
# ═══════════════════════════════════════════════════════════════════

# SELinux: без семантики порта sshd не стартует на нестандартном порту (RHEL/Fedora)
_selinux_ssh_port() {
	local port="$1"
	$HAS_SELINUX || return 0
	command -v semanage &>/dev/null || {
		log_warn "SELinux enforcing, но semanage нет — установите policycoreutils-python-utils"
		log_warn "  иначе sshd не поднимется на порту $port"
		return 0
	}
	log_info "SELinux: разрешаю sshd порт $port..."
	semanage port -a -t ssh_port_t -p tcp "$port" 2>/dev/null ||
		semanage port -m -t ssh_port_t -p tcp "$port" 2>/dev/null ||
		log_warn "semanage port $port не сработал — проверьте: semanage port -l | grep ssh"
}

# Фаервол: на RHEL-семействе нативный firewalld, не ufw (конфликтуют на netfilter)
_fw_cmd() {
	[[ "$PKG_MGR" == dnf || "$PKG_MGR" == yum ]] && echo firewalld || echo ufw
}

stage_ssh_config() {
	stage_banner "$ICON_KEY" "5" "Настройка SSH"

	[[ ! -d "$SSHD_CONFIG_D" ]] && {
		mkdir -p "$SSHD_CONFIG_D"
		chmod 755 "$SSHD_CONFIG_D"
	}

	if ! grep -q "^Include $SSHD_CONFIG_D" /etc/ssh/sshd_config 2>/dev/null; then
		backup_file "/etc/ssh/sshd_config" "stage5_ssh_config"
		local tf
		tf=$(mktemp)
		echo "Include $SSHD_CONFIG_D/*.conf" >"$tf"
		cat /etc/ssh/sshd_config >>"$tf"
		mv "$tf" /etc/ssh/sshd_config
		log_info "Include $SSHD_CONFIG_D → sshd_config"
	else
		backup_file "/etc/ssh/sshd_config" "stage5_ssh_config"
	fi

	local cfg="$SSHD_CONFIG_D/$SEQ_SSHD_DROPIN"
	# миграция со старого имени 99-seq-vps.conf, если оно осталось
	[[ -f "$SSHD_CONFIG_D/99-seq-vps.conf" ]] && {
		backup_file "$SSHD_CONFIG_D/99-seq-vps.conf" "stage5_ssh_config"
		rm -f "$SSHD_CONFIG_D/99-seq-vps.conf"
		log_info "Старый drop-in 99-seq-vps.conf удалён (заменён на 00-)"
	}
	backup_file "$cfg" "stage5_ssh_config"
	[[ ! -f "$cfg" ]] && echo "# seq_vps drop-in config" >"$cfg"

	# Хелпер
	_ssh_set() { if grep -q "^$1 " "$cfg"; then sed -i "s/^$1 .*/$1 $2/" "$cfg"; else echo "$1 $2" >>"$cfg"; fi; }

	local sc
	sc=$(sshd -T 2>/dev/null)
	local sp
	sp=$(echo "$sc" | grep "^port " | awk '{print $2}' | head -1)
	sp=${sp:-22}
	# обновляем глобальный порт уже ПОСЛЕ того, как sp определён
	CURRENT_SSH_PORT=$sp
	local pa
	pa=$(echo "$sc" | grep "^passwordauthentication " | awk '{print $2}')
	pa=${pa:-yes}
	local rl
	rl=$(echo "$sc" | grep "^permitrootlogin " | awk '{print $2}')
	rl=${rl:-yes}
	local ma
	ma=$(echo "$sc" | grep "^maxauthtries " | awk '{print $2}')
	ma=${ma:-6}
	local ep
	ep=$(echo "$sc" | grep "^permitemptypasswords " | awk '{print $2}')
	ep=${ep:-no}

	local sc_port sc_pwd sc_root sc_empty
	[[ "$sp" == "22" ]] && sc_port="$C_YELLOW" || sc_port="$C_GREEN"
	[[ "$pa" == "yes" ]] && sc_pwd="$C_RED" || sc_pwd="$C_GREEN"
	[[ "$rl" == "yes" ]] && sc_root="$C_RED" || sc_root="$C_GREEN"
	[[ "$ep" == "yes" ]] && sc_empty="$C_RED" || sc_empty="$C_GREEN"

	echo -e "${C_BOLD}▸ Текущая конфигурация:${C_RESET}"
	echo -e "  1) Порт:            ${sc_port}${sp}${C_RESET}"
	echo -e "  2) Парольный вход:  ${sc_pwd}${pa}${C_RESET}"
	echo -e "  3) Вход root:       ${sc_root}${rl}${C_RESET}"
	echo -e "  4) Макс. попыток:   ${ma}"
	echo -e "  5) Пустые пароли:   ${sc_empty}${ep}${C_RESET}"
	echo "  6) Показать все настройки"
	echo "  S) Пропустить"
	echo ""
	read -rp "  ${ICON_ARROW} " sa

	case "$sa" in
	1)
		read -rp "  Новый порт (1024-65535): " np
		[[ "$np" =~ ^[0-9]+$ && $np -ge 1024 && $np -le 65535 ]] || {
			log_err "Порт должен быть 1024-65535"
			return 1
		}
		_ssh_set "Port" "$np"
		_selinux_ssh_port "$np"
		CURRENT_SSH_PORT=$np
		log_ok "Порт → $np"
		;;
	2)
		echo "  1) yes  2) no"
		read -rp "  ${ICON_ARROW} " c
		[[ "$c" == "2" ]] && {
			_ssh_set "PasswordAuthentication" "no"
			log_ok "Парольный вход отключён"
			echo -e "  ${C_YELLOW}${ICON_WARN}  Убедитесь, что SSH-ключ установлен!${C_RESET}"
		}
		[[ "$c" == "1" ]] && {
			_ssh_set "PasswordAuthentication" "yes"
			log_ok "Парольный вход включён"
		}
		;;
	3)
		echo "  1) yes  2) no  3) prohibit-password"
		read -rp "  ${ICON_ARROW} " c
		case "$c" in 1) _ssh_set "PermitRootLogin" "yes" ;; 2) _ssh_set "PermitRootLogin" "no" ;; 3) _ssh_set "PermitRootLogin" "prohibit-password" ;; esac
		log_ok "PermitRootLogin изменён"
		;;
	4)
		read -rp "  Макс. попыток (1-10): " nm
		[[ "$nm" =~ ^[0-9]+$ && $nm -ge 1 && $nm -le 10 ]] || {
			log_err "1-10"
			return 1
		}
		_ssh_set "MaxAuthTries" "$nm"
		log_ok "MaxAuthTries → $nm"
		;;
	5)
		echo "  1) no (рекомендуется)  2) yes"
		read -rp "  ${ICON_ARROW} " c
		[[ "$c" == "1" ]] && {
			_ssh_set "PermitEmptyPasswords" "no"
			log_ok "Пустые пароли запрещены"
		}
		[[ "$c" == "2" ]] && {
			_ssh_set "PermitEmptyPasswords" "yes"
			echo -e "  ${C_RED}${ICON_WARN}  Небезопасно!${C_RESET}"
		}
		;;
	6)
		echo ""
		sshd -T 2>/dev/null | head -35
		echo ""
		echo "Drop-in ($cfg):"
		cat "$cfg"
		echo ""
		;;
	*) log_info "Пропущено" ;;
	esac

	echo ""
	log_info "Валидация конфигурации..."
	if ! sshd -t 2>&1 | tee -a "$LOG_FILE"; then
		log_err "Ошибка в конфиге SSH! Перезапуск отменён."
		return 1
	fi

	echo ""
	if confirm "Перезапустить SSH?"; then
		systemctl restart "$SSH_SERVICE"
		log_ok "SSH перезапущен ($SSH_SERVICE)"
		sleep 2
		if command -v ss &>/dev/null && ss -tlnp 2>/dev/null | grep -q ":${sp} " 2>/dev/null; then
			log_ok "SSH слушает на порту $sp"
		elif command -v netstat &>/dev/null && netstat -tlnp 2>/dev/null | grep -q ":${sp} " 2>/dev/null; then
			log_ok "SSH слушает на порту $sp"
		else
			log_warn "Не удалось проверить порт $sp"
		fi
	fi

	echo ""
	echo -e "  ${C_YELLOW}${ICON_WARN}  НЕ закрывайте текущую сессию, не проверив новое подключение!${C_RESET}"
	update_stage_status "stage5_ssh_config" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 6: SFTP ПОЛЬЗОВАТЕЛЬ
# ═══════════════════════════════════════════════════════════════════

stage_sftp_user() {
	stage_banner "$ICON_LOCK" "6" "Создание SFTP пользователя"

	read -rp "  Имя: " sfu
	id "$sfu" &>/dev/null && {
		log_err "Пользователь $sfu уже существует"
		update_stage_status "stage6_sftp_user" "failed"
		return 1
	}
	read -rsp "  Пароль: " sfpw
	echo
	read -rsp "  Подтвердите: " sfpw2
	echo
	[[ "$sfpw" != "$sfpw2" ]] && {
		log_err "Пароли не совпадают"
		update_stage_status "stage6_sftp_user" "failed"
		return 1
	}
	[[ -z "$sfpw" ]] && {
		log_err "Пароль не может быть пустым"
		return 1
	}

	echo ""
	echo "  Папка для chroot:"
	echo "  1) /opt    2) /var/www    3) /srv    4) Своя"
	read -rp "  ${ICON_ARROW} " fc
	case "$fc" in 1) sff="/opt" ;; 2) sff="/var/www" ;; 3) sff="/srv" ;; 4) read -rp "  Путь: " sff ;; *) sff="/opt" ;; esac

	useradd -M -s /usr/sbin/nologin -d "$sff" "$sfu"
	echo "$sfu:$sfpw" | chpasswd

	local sftp_cfg="$SSHD_CONFIG_D/98-sftp-$sfu.conf"
	backup_file "/etc/ssh/sshd_config" "stage6_sftp_user"
	cat >"$sftp_cfg" <<EOF
# SFTP: $sfu (seq_vps)
Match User $sfu
    ForceCommand internal-sftp
    ChrootDirectory $sff
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF
	chmod 644 "$sftp_cfg"

	mkdir -p "$sff"
	chown root:root "$sff"
	chmod 755 "$sff"
	mkdir -p "$sff/upload"
	chown "$sfu:$sfu" "$sff/upload"
	chmod 755 "$sff/upload"

	if ! sshd -t 2>&1 | tee -a "$LOG_FILE"; then
		log_err "Ошибка в конфиге SSH!"
		rm -f "$sftp_cfg"
		return 1
	fi
	systemctl restart "$SSH_SERVICE"

	echo ""
	echo "  SSH-ключ для $sfu:"
	echo "  1) Вставить    2) Скопировать    3) Пропустить"
	read -rp "  ${ICON_ARROW} " ka
	case "$ka" in
	1)
		read -rp "  Ключ: " pk
		[[ -n "$pk" ]] && {
			mkdir -p /etc/ssh/keys.d
			echo "$pk" >"/etc/ssh/keys.d/$sfu.pub"
			chmod 600 "/etc/ssh/keys.d/$sfu.pub"
			echo "    AuthorizedKeysFile /etc/ssh/keys.d/%u.pub" >>"$sftp_cfg"
			systemctl restart "$SSH_SERVICE"
			log_ok "Ключ установлен"
		}
		;;
	2)
		echo "  Пользователи с ключами:"
		local sus=() si=1
		while IFS=: read -r user uid groups home; do
			[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] || continue
			echo "    $si) $user"
			sus+=("$user")
			si=$((si + 1))
		done < <(get_regular_users)
		[[ ${#sus[@]} -eq 0 ]] && { log_warn "Нет ключей"; } || {
			read -rp "  Номер: " sn
			if [[ "$sn" =~ ^[0-9]+$ && $sn -ge 1 && $sn -le ${#sus[@]} ]]; then
				local su="${sus[$((sn - 1))]}"
				local sh
				sh=$(getent passwd "$su" | cut -d: -f6)
				mkdir -p /etc/ssh/keys.d
				cp "$sh/.ssh/authorized_keys" "/etc/ssh/keys.d/$sfu.pub"
				chmod 600 "/etc/ssh/keys.d/$sfu.pub"
				echo "    AuthorizedKeysFile /etc/ssh/keys.d/%u.pub" >>"$sftp_cfg"
				systemctl restart "$SSH_SERVICE"
				log_ok "Ключ от $su скопирован"
			fi
		}
		;;
	esac

	log_ok "SFTP пользователь ${C_BOLD}$sfu${C_RESET} создан"
	echo -e "  Подключение: ${C_GREEN}sftp${C_RESET} -P $CURRENT_SSH_PORT $sfu@<server_ip>"
	echo -e "  ${C_YELLOW}${ICON_WARN}  Сохраните пароль!${C_RESET}"
	update_stage_status "stage6_sftp_user" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 7: UFW
# ═══════════════════════════════════════════════════════════════════

_firewalld_menu() {
	stage_banner "$ICON_FIRE" "7" "Настройка firewalld"

	command -v firewall-cmd &>/dev/null || {
		pkg_install_retry "firewalld" || {
			update_stage_status "stage7_ufw" "failed"
			return 1
		}
	}
	systemctl enable --now firewalld 2>/dev/null

	local sp
	sp=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -1)
	sp=${sp:-22}

	while true; do
		echo ""
		echo -e "${C_BOLD}▸ firewalld (зона public):${C_RESET}"
		if firewall-cmd --state 2>/dev/null | grep -q running; then
			echo -e "  ${C_GREEN}● активен${C_RESET}"
		else
			echo -e "  ${C_RED}● не активен${C_RESET}"
		fi
		firewall-cmd --list-all 2>/dev/null | sed 's/^/  /'

		echo ""
		printf "  ${C_BOLD}1${C_RESET}) SSH (%s)    ${C_BOLD}5${C_RESET}) Включить\n" "$sp"
		echo "  2) HTTP+HTTPS     6) Отключить"
		echo "  3) Произв. порт   7) Очистить порты"
		echo "  4) Удалить порт   8) Справка"
		echo "  S) Завершить"
		echo ""
		read -rp "  ${ICON_ARROW} " ua

		case "$ua" in
		1) firewall-cmd --permanent --add-port="${sp}/tcp" && log_ok "Порт $sp/tcp открыт" ;;
		2) firewall-cmd --permanent --add-service=http --add-service=https && log_ok "80+443 открыты" ;;
		3)
			read -rp "  Порт: " cp
			[[ "$cp" =~ ^[0-9]+$ && $cp -ge 1 && $cp -le 65535 ]] || {
				log_err "Порт 1-65535"
				continue
			}
			read -rp "  Протокол [tcp]: " proto
			proto=${proto:-tcp}
			firewall-cmd --permanent --add-port="${cp}/${proto}" && log_ok "Порт $cp/$proto открыт"
			;;
		4)
			read -rp "  Порт/протокол (напр. 8080/tcp): " pp
			firewall-cmd --permanent --remove-port="$pp" 2>/dev/null && log_ok "$pp удалён" || log_err "Не удалось"
			;;
		5) systemctl enable --now firewalld && log_ok "firewalld включён" ;;
		6)
			echo -e "  ${C_YELLOW}Сервер останется без фаервола!${C_RESET}"
			confirm "Отключить firewalld?" && {
				systemctl disable --now firewalld
				log_ok "firewalld отключён"
			}
			;;
		7)
			confirm "Убрать ВСЕ порты/сервисы, кроме ssh и dhcpv6-client?" && {
				local p sv
				for p in $(firewall-cmd --list-ports 2>/dev/null); do
					[[ "$p" == "${sp}/tcp" ]] && continue
					firewall-cmd --permanent --remove-port="$p"
				done
				for sv in $(firewall-cmd --list-services 2>/dev/null); do
					[[ "$sv" == ssh || "$sv" == dhcpv6-client ]] && continue
					firewall-cmd --permanent --remove-service="$sv"
				done
				firewall-cmd --reload && log_ok "Правила очищены"
			}
			;;
		8)
			echo ""
			echo -e "${C_BOLD}  firewalld — фаервол RHEL/Fedora/Rocky/Alma${C_RESET}"
			echo "  firewall-cmd --state               — статус"
			echo "  firewall-cmd --list-all            — все правила"
			echo "  firewall-cmd --permanent --add-port=8080/tcp"
			echo "  firewall-cmd --permanent --remove-port=8080/tcp"
			echo "  firewall-cmd --reload              — применить"
			echo "  ВАЖНО: --permanent действует только после --reload (скрипт делает сам)."
			echo ""
			read -rp "  Enter..."
			;;
		[Ss] | "") break ;;
		*) log_err "Неверный выбор" ;;
		esac
		# --permanent накапливает изменения, reload применяет их пачкой
		firewall-cmd --reload 2>/dev/null
	done
	update_stage_status "stage7_ufw" "completed"
}

stage_ufw() {
	# на RHEL-семействе ufw и firewalld воюют за netfilter — там только firewalld
	[[ "$(_fw_cmd)" == firewalld ]] && {
		_firewalld_menu
		return $?
	}
	stage_banner "$ICON_FIRE" "7" "Настройка UFW"

	if ! command -v ufw &>/dev/null; then
		pkg_install_retry "ufw" || {
			update_stage_status "stage7_ufw" "failed"
			return 1
		}
	else
		log_info "UFW уже установлен"
	fi

	backup_file "/etc/default/ufw" "stage7_ufw"
	backup_file "/etc/ufw/ufw.conf" "stage7_ufw"

	local sp
	sp=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -1)
	sp=${sp:-22}

	while true; do
		echo ""
		echo -e "${C_BOLD}▸ UFW:${C_RESET}"
		if ufw status 2>/dev/null | grep -q "Status: active"; then
			echo -e "  ${C_GREEN}● активен${C_RESET}"
		else
			echo -e "  ${C_RED}● не активен${C_RESET}"
		fi
		ufw status numbered 2>/dev/null | sed 's/^/  /'

		echo ""
		printf "  ${C_BOLD}1${C_RESET}) SSH (%s)    ${C_BOLD}5${C_RESET}) Включить\n" "$sp"
		echo "  2) HTTP+HTTPS     6) Отключить"
		echo "  3) Произв. порт   7) Сбросить всё"
		echo "  4) Удалить        8) Справка"
		echo "  S) Завершить"
		echo ""
		read -rp "  ${ICON_ARROW} " ua

		case "$ua" in
		1)
			ufw allow "${sp}/tcp" comment "SSH"
			log_ok "Порт $sp открыт"
			;;
		2)
			ufw allow 80/tcp comment "HTTP"
			ufw allow 443/tcp comment "HTTPS"
			log_ok "80+443 открыты"
			;;
		3)
			read -rp "  Порт: " cp
			[[ "$cp" =~ ^[0-9]+$ && $cp -ge 1 && $cp -le 65535 ]] || {
				log_err "Порт 1-65535"
				continue
			}
			read -rp "  Протокол [tcp]: " proto
			proto=${proto:-tcp}
			read -rp "  Комментарий: " comment
			[[ -n "$comment" ]] && ufw allow "${cp}/${proto}" comment "$comment" || ufw allow "${cp}/${proto}"
			log_ok "Порт $cp/$proto открыт"
			;;
		4)
			ufw status numbered 2>/dev/null
			read -rp "  Номер правила: " rn
			ufw delete "$rn" 2>/dev/null && log_ok "Правило $rn удалено" || log_err "Не удалось"
			;;
		5)
			echo ""
			echo -e "  ${C_YELLOW}Убедитесь, что SSH-порт ($sp) открыт ПЕРЕД включением UFW!${C_RESET}"
			if confirm "Включить UFW?"; then
				ufw --force enable
				log_ok "UFW включён"
			fi
			;;
		6)
			ufw disable
			log_ok "UFW отключён"
			;;
		7) confirm "Сбросить ВСЕ правила?" && {
			ufw --force reset
			log_ok "Правила сброшены"
		} ;;
		8)
			echo ""
			echo -e "${C_BOLD}  UFW — Uncomplicated Firewall${C_RESET}"
			echo "  ufw status             — статус и правила"
			echo "  ufw status numbered    — правила с номерами"
			echo "  ufw allow 22/tcp       — открыть порт"
			echo "  ufw delete 3           — удалить правило по номеру"
			echo "  ufw reset              — сбросить всё"
			echo "  По умолчанию: входящие блокируются, исходящие разрешены."
			echo ""
			read -rp "  Enter..."
			;;
		[Ss] | "") break ;;
		*) log_err "Неверный выбор" ;;
		esac
	done
	update_stage_status "stage7_ufw" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 8: АВТООБНОВЛЕНИЯ
# ═══════════════════════════════════════════════════════════════════

stage_autoupdate() {
	stage_banner "$ICON_GEAR" "8" "Автообновления безопасности"

	case "$PKG_MGR" in
	apt)
		backup_file "/etc/apt/apt.conf.d/20auto-upgrades" "stage8_autoupdate"
		backup_file "/etc/apt/apt.conf.d/50unattended-upgrades" "stage8_autoupdate"
		apt update &>/dev/null
		pkg_install_retry "unattended-upgrades"
		cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF
		;;
	dnf | yum)
		backup_file "/etc/dnf/automatic.conf" "stage8_autoupdate"
		pkg_install_retry "dnf-automatic" || {
			update_stage_status "stage8_autoupdate" "failed"
			return 1
		}
		cat >/etc/dnf/automatic.conf <<'EOF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
random_sleep = 0
reboot = when-needed
[emitters]
emit_via = motd
EOF
		systemctl enable dnf-automatic.timer 2>/dev/null || true
		systemctl start dnf-automatic.timer 2>/dev/null || true
		;;
	esac

	echo ""
	read -rp "  Время авто-перезагрузки (HH:MM, Enter=отключить): " reboot_time
	[[ -n "$reboot_time" ]] && ! [[ "$reboot_time" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]] && {
		log_err "Неверный формат (03:00)"
		reboot_time=""
	}

	case "$PKG_MGR" in
	apt)
		if [[ -n "$reboot_time" ]]; then
			cat >/etc/apt/apt.conf.d/50unattended-upgrades-local <<EOF
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$reboot_time";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
			log_info "Авто-перезагрузка: ежедневно в $reboot_time"
		else
			cat >/etc/apt/apt.conf.d/50unattended-upgrades-local <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
		fi
		systemctl enable apt-daily-upgrade.timer 2>/dev/null || true
		systemctl start apt-daily-upgrade.timer 2>/dev/null || true
		;;
	dnf | yum)
		if [[ -n "$reboot_time" ]]; then
			cat >/etc/systemd/system/reboot-after-updates.timer <<EOF
[Unit]
Description=Reboot after security updates
[Timer]
OnCalendar=*-*-* $reboot_time
Persistent=true
[Install]
WantedBy=timers.target
EOF
			cat >/etc/systemd/system/reboot-after-updates.service <<'EOF'
[Unit]
Description=Reboot system
[Service]
Type=oneshot
ExecStart=/usr/sbin/reboot
EOF
			systemctl daemon-reload
			systemctl enable reboot-after-updates.timer 2>/dev/null || true
			systemctl start reboot-after-updates.timer 2>/dev/null || true
			log_info "Авто-перезагрузка: ежедневно в $reboot_time"
		fi
		;;
	esac

	log_ok "Автообновления настроены"
	update_stage_status "stage8_autoupdate" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 9: ЗАЩИТА ОТ БРУТФОРСА (CrowdSec / Fail2Ban)
# ═══════════════════════════════════════════════════════════════════

stage_intrusion() {
	stage_banner "$ICON_SHIELD" "9" "Защита от брутфорса"

	# Проверяем что уже установлено
	local has_cs=false has_f2b=false
	command -v cscli &>/dev/null && has_cs=true
	systemctl is-active --quiet fail2ban 2>/dev/null && has_f2b=true

	if $has_cs; then log_info "CrowdSec уже установлен"; fi
	if $has_f2b; then log_info "Fail2Ban уже установлен"; fi
	if $has_cs || $has_f2b; then
		update_stage_status "stage9_intrusion" "completed"
		return 0
	fi

	echo ""
	echo -e "  ${C_BOLD}Выберите систему защиты:${C_RESET}"
	echo ""
	echo -e "  ${C_BOLD}1)${C_RESET} CrowdSec  ${C_DIM}— облачная, умная, требует интернет, сложнее${C_RESET}"
	echo -e "  ${C_BOLD}2)${C_RESET} Fail2Ban  ${C_DIM}— локальная, простая, не требует интернета, легковесная${C_RESET}"
	echo ""
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1) _install_crowdsec ;;
	2) _install_fail2ban ;;
	*)
		log_info "Пропущено"
		update_stage_status "stage9_intrusion" "skipped"
		return 0
		;;
	esac

	update_stage_status "stage9_intrusion" "completed"
}

_install_crowdsec() {
	log_info "Проверка сети..."
	if ! curl -s --connect-timeout 10 --max-time 15 https://install.crowdsec.net -o /dev/null 2>/dev/null; then
		log_warn "install.crowdsec.net недоступен"
		confirm "Вместо CrowdSec установить Fail2Ban?" && {
			_install_fail2ban
			return 0
		}
		confirm "Пропустить этап?" && {
			update_stage_status "stage9_intrusion" "skipped"
			return 0
		}
	fi

	local max=3 retry=0
	while [[ $retry -lt $max ]]; do
		log_info "Установка CrowdSec (попытка $((retry + 1))/$max)..."
		spinner_start "Устанавливаем CrowdSec..."
		if curl -s --connect-timeout 15 --max-time 60 https://install.crowdsec.net | sh &>/dev/null; then
			spinner_stop
			break
		fi
		spinner_stop
		retry=$((retry + 1))
		[[ $retry -lt $max ]] && {
			log_warn "Повтор через 10 сек..."
			sleep 10
		}
	done
	[[ $retry -ge $max ]] && {
		log_err "Не удалось установить CrowdSec"
		update_stage_status "stage9_intrusion" "failed"
		return 1
	}

	case "$PKG_MGR" in
	apt) apt update &>/dev/null ;;
	dnf | yum) $PKG_MGR makecache &>/dev/null ;;
	esac

	pkg_install_retry "crowdsec" || {
		log_err "Установка crowdsec провалилась"
		update_stage_status "stage9_intrusion" "failed"
		return 1
	}
	# у CrowdSec нет firewalld-бонсера, а iptables-бонсер затирает правила firewalld.
	# На RHEL-семействе banning нативно делает Fail2Ban (firewalld banaction).
	if [[ "$(_fw_cmd)" == firewalld ]]; then
		log_warn "firewalld: iptables-бонсер CrowdSec конфликтует с firewalld"
		log_warn "Ставлю CrowdSec-движок (детект), а банить будет Fail2Ban"
		systemctl enable --now crowdsec 2>/dev/null || true
		sleep 2
		systemctl is-active --quiet crowdsec && log_ok "CrowdSec запущен (без бонсера)" || log_warn "CrowdSec не запустился"
		_install_fail2ban
		cscli version 2>/dev/null || true
		return 0
	fi

	pkg_install_retry "crowdsec-firewall-bouncer-iptables" || log_warn "Без bouncer'а — установите вручную"

	systemctl enable crowdsec 2>/dev/null || true
	systemctl start crowdsec 2>/dev/null || true
	systemctl enable crowdsec-firewall-bouncer 2>/dev/null || true
	systemctl start crowdsec-firewall-bouncer 2>/dev/null || true
	sleep 2
	systemctl is-active --quiet crowdsec && log_ok "CrowdSec запущен" || log_warn "CrowdSec не запустился"
	cscli version 2>/dev/null || true
}

_install_fail2ban() {
	pkg_install_retry "fail2ban" || {
		log_err "Не удалось установить fail2ban"
		update_stage_status "stage9_intrusion" "failed"
		return 1
	}

	# Базовый jail.local для SSH
	local f2b_jail="/etc/fail2ban/jail.local"
	backup_file "$f2b_jail" "stage9_intrusion"
	local sp
	sp=$(sshd -T 2>/dev/null | grep "^port " | awk '{print $2}' | head -1)
	sp=${sp:-22}

	# на firewalld-системах iptables-banaction конфликтует — банить через firewalld+ipset
	local banaction=""
	[[ "$(_fw_cmd)" == firewalld ]] && banaction="banaction = firewallcmd-ipset"

	cat >"$f2b_jail" <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
${banaction}

[sshd]
enabled = true
port = $sp
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 3
bantime = 24h
EOF

	systemctl enable fail2ban 2>/dev/null || true
	systemctl restart fail2ban 2>/dev/null || true
	sleep 2
	systemctl is-active --quiet fail2ban && log_ok "Fail2Ban запущен (SSH: порт $sp, 3 попытки → бан 24ч)" || log_warn "Fail2Ban не запустился"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 11: FISH SHELL
# ═══════════════════════════════════════════════════════════════════

stage_fish() {
	stage_banner "🐟" "11" "Установка Fish shell"

	if command -v fish &>/dev/null; then
		log_info "Fish уже установлен: $(fish --version 2>/dev/null)"
		update_stage_status "stage11_fish" "completed"
		return 0
	fi

	pkg_install_retry "fish" || {
		update_stage_status "stage11_fish" "failed"
		return 1
	}

	echo ""
	echo -e "  Fish установлен: ${C_GREEN}$(fish --version 2>/dev/null)${C_RESET}"
	echo ""
	echo "  Чтобы сделать fish шеллом по умолчанию:"
	echo "    chsh -s \$(which fish)"
	echo "  Или запустить прямо сейчас:"
	echo "    fish"
	echo ""
	log_ok "Fish shell установлен"
	update_stage_status "stage11_fish" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 12: ЧАСОВОЙ ПОЯС + NTP
# ═══════════════════════════════════════════════════════════════════

stage_timezone() {
	stage_banner "🕐" "12" "Часовой пояс и синхронизация времени"

	# Текущее состояние
	echo -e "${C_BOLD}Текущее:${C_RESET}"
	echo "  Часовой пояс: $(timedatectl show --property=Timezone --value 2>/dev/null || echo 'не определён')"
	echo "  NTP sync:     $(timedatectl show --property=NTP --value 2>/dev/null || echo 'неизвестно')"
	echo "  Время:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
	echo ""

	echo "  1) Сменить часовой пояс"
	echo "  2) Включить NTP синхронизацию"
	echo "  3) И то и другое"
	echo "  S) Пропустить"
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1 | 2 | 3)
		if [[ "$choice" == 1 || "$choice" == 3 ]]; then
			echo ""
			echo "  Популярные зоны:"
			echo "    Europe/Moscow      Europe/London      Europe/Berlin"
			echo "    America/New_York   America/Chicago    America/Los_Angeles"
			echo "    Asia/Tokyo         Asia/Singapore     Asia/Dubai"
			echo ""
			echo "  Полный список: timedatectl list-timezones"
			echo ""
			read -rp "  Часовой пояс: " tz
			if [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]]; then
				timedatectl set-timezone "$tz" && log_ok "Часовой пояс → $tz"
			else
				log_err "Неверный часовой пояс: $tz"
			fi
		fi
		if [[ "$choice" == 2 || "$choice" == 3 ]]; then
			timedatectl set-ntp true 2>/dev/null && log_ok "NTP синхронизация включена" || log_warn "Не удалось включить NTP"
		fi
		update_stage_status "stage12_timezone" "completed"
		;;
	*)
		log_info "Пропущено"
		update_stage_status "stage12_timezone" "skipped"
		;;
	esac
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 13: LYNIS — АУДИТ БЕЗОПАСНОСТИ
# ═══════════════════════════════════════════════════════════════════

stage_lynis() {
	stage_banner "🔍" "13" "Аудит безопасности (Lynis)"

	if ! command -v lynis &>/dev/null; then
		pkg_install_retry "lynis" || {
			update_stage_status "stage13_lynis" "failed"
			return 1
		}
	fi

	echo ""
	echo -e "  ${C_BOLD}Запуск Lynis audit system...${C_RESET}"
	echo "  Это займёт 1-2 минуты. Вывод будет сокращён."
	echo ""

	spinner_start "Сканируем систему..."
	local report
	report=$(lynis audit system --quick 2>/dev/null || true)
	spinner_stop

	# Извлекаем hardening index
	local index
	index=$(echo "$report" | grep -i "hardening index" | tail -1 | grep -oE '[0-9]+' | head -1)
	local index_color="$C_RED"
	[[ -n "$index" ]] && [[ "$index" -ge 80 ]] && index_color="$C_GREEN"
	[[ -n "$index" ]] && [[ "$index" -ge 60 && "$index" -lt 80 ]] && index_color="$C_YELLOW"

	echo ""
	echo -e "  ${C_BOLD}Hardening Index:${C_RESET} ${index_color}${index:-?}/100${C_RESET}"
	echo ""

	# Warnings
	local warnings
	warnings=$(echo "$report" | grep -i "^\s*\[WARNING\]" | head -15)
	if [[ -n "$warnings" ]]; then
		echo -e "  ${C_YELLOW}Найденные проблемы (первые 15):${C_RESET}"
		echo "$warnings" | sed 's/^/  /'
		echo ""
	fi

	# Suggestions
	local sugg
	sugg=$(echo "$report" | grep -i "^\s*\[SUGGESTION\]" | head -10)
	if [[ -n "$sugg" ]]; then
		echo -e "  ${C_BLUE}Рекомендации (первые 10):${C_RESET}"
		echo "$sugg" | sed 's/^/  /'
		echo ""
	fi

	echo -e "  ${C_DIM}Полный отчёт: /var/log/lynis-report.dat${C_RESET}"
	echo -e "  ${C_DIM}Подробный вывод: lynis audit system${C_RESET}"
	echo ""

	read -rp "  Enter..."
	update_stage_status "stage13_lynis" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 14: МОНИТОРИНГ ДИСКА
# ═══════════════════════════════════════════════════════════════════

stage_disk() {
	stage_banner "💾" "14" "Мониторинг диска и поиск больших файлов"

	echo -e "${C_BOLD}▸ Использование диска:${C_RESET}"
	echo ""
	df -h --type=ext4 --type=xfs --type=btrfs 2>/dev/null || df -h 2>/dev/null | head -20
	echo ""

	# Проверка на >80%
	local _critical=false
	while IFS=' ' read -r _fs _size _used _avail pct mount; do
		[[ "$pct" =~ ^[0-9]+%$ ]] || continue
		local pct_n=${pct%\%}
		if [[ $pct_n -ge 90 ]]; then
			echo -e "  ${C_RED}${ICON_WARN}  КРИТИЧЕСКИ: $mount заполнен на $pct${C_RESET}"
			_critical=true
		elif [[ $pct_n -ge 80 ]]; then
			echo -e "  ${C_YELLOW}${ICON_WARN}  $mount заполнен на $pct${C_RESET}"
		else
			echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  $mount: $pct"
		fi
	done < <(df --type=ext4 --type=xfs --type=btrfs 2>/dev/null | tail -n +2 || df | tail -n +2)

	echo ""
	echo "  1) Найти большие файлы (>100MB)"
	echo "  2) Найти большие файлы (>1GB)"
	echo "  3) Найти файлы по имени"
	echo "  S) Назад"
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1)
		echo ""
		echo -e "  ${C_BOLD}Файлы >100MB (топ-20):${C_RESET}"
		find / -xdev -type f -size +100M -exec du -h {} \; 2>/dev/null | sort -rh | head -20 | nl -w2 -s') '
		;;
	2)
		echo ""
		echo -e "  ${C_BOLD}Файлы >1GB (топ-20):${C_RESET}"
		find / -xdev -type f -size +1G -exec du -h {} \; 2>/dev/null | sort -rh | head -20 | nl -w2 -s') '
		;;
	3)
		read -rp "  Имя или маска (например *.log): " pattern
		echo ""
		find / -xdev -type f -name "$pattern" -exec du -h {} \; 2>/dev/null | sort -rh | head -20 | nl -w2 -s') '
		;;
	*) log_info "Назад" ;;
	esac

	echo ""
	read -rp "  Enter..."
	update_stage_status "stage14_disk" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 15: BBR CONGESTION CONTROL
# ═══════════════════════════════════════════════════════════════════

stage_bbr() {
	stage_banner "🚀" "15" "BBR congestion control"

	# Текущее состояние
	local current_cc
	current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
	local current_qdisc
	current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "неизвестно")
	local bbr_available=false
	modprobe tcp_bbr 2>/dev/null && bbr_available=true || true

	echo ""
	echo -e "  ${C_BOLD}Текущее:${C_RESET}"
	echo "    congestion control: $current_cc"
	echo "    default qdisc:      $current_qdisc"
	echo "    BBR модуль:         $($bbr_available && echo -e "${C_GREEN}доступен${C_RESET}" || echo -e "${C_RED}недоступен${C_RESET}")"
	echo ""

	if [[ "$current_cc" == "bbr" ]]; then
		echo -e "  ${C_GREEN}BBR уже включён${C_RESET}"
		echo ""
		echo "  1) Отключить BBR (вернуть cubic)"
		echo "  S) Назад"
		read -rp "  ${ICON_ARROW} " choice
		if [[ "$choice" == "1" ]]; then
			cat >/etc/sysctl.d/90-bbr.conf <<'EOF'
# BBR отключён (seq_vps)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = cubic
EOF
			sysctl -p /etc/sysctl.d/90-bbr.conf &>/dev/null
			log_ok "BBR отключён, congestion control → cubic"
		fi
	else
		echo -e "  BBR (Bottleneck Bandwidth and RTT) ускоряет TCP,"
		echo -e "  снижает задержки и потери пакетов."
		echo -e "  ${C_DIM}Подробнее: https://github.com/google/bbr${C_RESET}"
		echo ""
		echo "  1) Включить BBR"
		echo "  S) Назад"
		read -rp "  ${ICON_ARROW} " choice
		if [[ "$choice" == "1" ]]; then
			if ! $bbr_available; then
				log_err "Модуль tcp_bbr не найден. Обновите ядро (>= 4.9)."
				update_stage_status "stage15_bbr" "failed"
				return 1
			fi
			backup_file "/etc/sysctl.d/90-bbr.conf" "stage15_bbr"
			cat >/etc/sysctl.d/90-bbr.conf <<'EOF'
# BBR congestion control (seq_vps)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
			sysctl -p /etc/sysctl.d/90-bbr.conf &>/dev/null
			sleep 1
			local new_cc
			new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
			if [[ "$new_cc" == "bbr" ]]; then
				log_ok "BBR включён. congestion control: bbr, qdisc: fq"
			else
				log_err "BBR не активировался. Текущий: $new_cc"
				update_stage_status "stage15_bbr" "failed"
				return 1
			fi
		fi
	fi

	update_stage_status "stage15_bbr" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 10: DNS
# ═══════════════════════════════════════════════════════════════════

stage_dns() {
	stage_banner "$ICON_GLOBE" "10" "Настройка DNS"
	backup_file "/etc/resolv.conf" "stage10_dns"

	echo -e "${C_BOLD}Текущие DNS:${C_RESET}"
	grep "^nameserver" /etc/resolv.conf 2>/dev/null || echo "  ${C_DIM}(нет)${C_RESET}"

	echo ""
	echo "  1) Заменить    2) Добавить    3) Пропустить"
	read -rp "  ${ICON_ARROW} " da
	case "$da" in
	1)
		read -rp "  Серверы (через пробел): " srv
		{
			echo "# seq_vps"
			for s in $srv; do echo "nameserver $s"; done
		} >/etc/resolv.conf
		log_ok "DNS заменены"
		;;
	2)
		read -rp "  Серверы (через пробел): " srv
		for s in $srv; do echo "nameserver $s" >>/etc/resolv.conf; done
		log_ok "DNS добавлены"
		;;
	*) log_info "Пропущено" ;;
	esac
	echo ""
	grep "^nameserver" /etc/resolv.conf 2>/dev/null
	update_stage_status "stage10_dns" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП R: ОТКАТ
# ═══════════════════════════════════════════════════════════════════

stage_rollback() {
	stage_banner "↩" "R" "Откат этапа"

	echo "  1) Обновление          9) Защита (CrowdSec/F2B)"
	echo "  2) Пользователи       10) DNS"
	echo "  3) Пароль root        11) Fish shell"
	echo "  4) SSH-ключ           12) Часовой пояс"
	echo "  5) SSH-конфиг         13) Lynis аудит"
	echo "  6) SFTP               14) Мониторинг диска"
	echo "  7) UFW                15) BBR"
	echo "  8) Автообновления"
	read -rp "  ${ICON_ARROW} " sn

	local stage
	case "$sn" in
	1) stage="stage1_update" ;; 2) stage="stage2_admin_user" ;;
	3) stage="stage3_root_password" ;; 4) stage="stage4_ssh_key" ;;
	5) stage="stage5_ssh_config" ;; 6) stage="stage6_sftp_user" ;;
	7) stage="stage7_ufw" ;; 8) stage="stage8_autoupdate" ;;
	9) stage="stage9_intrusion" ;; 10) stage="stage10_dns" ;;
	11) stage="stage11_fish" ;; 12) stage="stage12_timezone" ;;
	13) stage="stage13_lynis" ;; 14) stage="stage14_disk" ;;
	15) stage="stage15_bbr" ;;
	*)
		log_err "Неверный выбор"
		return 1
		;;
	esac

	# бэкапы всех сессий, а не только текущей: берём последний каталог с этим этапом
	local bdir=""
	local cand
	for cand in $(find "${DATA_DIR}/backups" -maxdepth 2 -type d -name "$stage" 2>/dev/null | sort -r); do
		bdir="$cand"
		break
	done
	[[ -n "$bdir" ]] || {
		log_err "Бэкапы для $stage не найдены"
		return 1
	}
	log_info "Бэкап: ${C_DIM}$bdir${C_RESET}"
	echo ""
	ls -la "$bdir/"
	echo ""
	confirm "Откатить этап?" || {
		log_info "Отмена"
		return 0
	}

	for bf in "$bdir"/*; do
		[[ -f "$bf" ]] || continue
		local bn
		bn=$(basename "$bf")
		local op=""
		case "$stage" in
		stage1_update)
			[[ "$bn" == "sources.list" ]] && op="/etc/apt/sources.list"
			[[ "$bn" == "sources.list.d" ]] && op="/etc/apt/sources.list.d"
			[[ "$bn" == "yum.repos.d" ]] && op="/etc/yum.repos.d"
			;;
		stage4_ssh_key)
			read -rp "  Пользователь для отката ключа: " ru
			local rh
			rh=$(getent passwd "$ru" | cut -d: -f6)
			[[ -n "$rh" ]] && op="$rh/.ssh/authorized_keys"
			;;
		stage5_ssh_config | stage6_sftp_user)
			case "$bn" in
			sshd_config) op="/etc/ssh/sshd_config" ;;
			*.conf) op="$SSHD_CONFIG_D/$bn" ;;
			esac
			;;
		stage7_ufw) op="/etc/default/ufw" ;;
		stage8_autoupdate)
			[[ "$bn" == "20auto-upgrades" ]] && op="/etc/apt/apt.conf.d/20auto-upgrades"
			[[ "$bn" == "50unattended-upgrades" ]] && op="/etc/apt/apt.conf.d/50unattended-upgrades"
			[[ "$bn" == "automatic.conf" ]] && op="/etc/dnf/automatic.conf"
			;;
		stage10_dns) op="/etc/resolv.conf" ;;
		esac
		[[ -n "$op" ]] && {
			cp -a "$bf" "$op"
			log_ok "Откачено: $op"
		}
	done

	if [[ "$stage" == stage5_ssh_config || "$stage" == stage6_sftp_user ]]; then
		if sshd -t 2>&1 | tee -a "$LOG_FILE"; then
			systemctl restart "$SSH_SERVICE" 2>/dev/null && log_ok "SSH перезапущен"
		else
			log_err "Откаченный конфиг невалиден — SSH НЕ перезапущен, проверьте вручную"
		fi
	fi
	update_stage_status "$stage" "not_started"
	log_ok "Этап $stage откачен"
}

# ═══════════════════════════════════════════════════════════════════
#  ГЛАВНОЕ МЕНЮ
# ═══════════════════════════════════════════════════════════════════

main_menu() {
	while true; do
		printf '\n%.0s' {1..4}

		echo -e "${C_BOLD}${C_CYAN}╔══ Seq VPS Security${C_RESET} ${C_DIM}— ${DISTRO_NAME}${C_RESET} ${C_BOLD}${C_CYAN}══════════════════════════════════╗${C_RESET}"
		echo ""

		show_server_summary

		echo -e "${C_BOLD}${C_GREEN}  Действия:${C_RESET}"
		echo ""
		menu_item 0 "" "Установка утилит (micro, mc)"
		menu_item 1 "stage1_update" "Обновление системы"
		menu_item 2 "stage2_admin_user" "Управление пользователями"
		menu_item 3 "stage3_root_password" "Изменение пароля root"
		menu_item 4 "stage4_ssh_key" "Установка SSH-ключа"
		menu_item 5 "stage5_ssh_config" "Настройка SSH"
		menu_item 6 "stage6_sftp_user" "Создание SFTP пользователя"
		menu_item 7 "stage7_ufw" "Настройка UFW"
		menu_item 8 "stage8_autoupdate" "Автообновления безопасности"
		menu_item 9 "stage9_intrusion" "Защита от брутфорса (CrowdSec/Fail2Ban)"
		menu_item 10 "stage10_dns" "Настройка DNS"
		menu_item 11 "stage11_fish" "Установка Fish shell"
		menu_item 12 "stage12_timezone" "Часовой пояс и синхронизация времени"
		menu_item 13 "stage13_lynis" "Аудит безопасности (Lynis)"
		menu_item 14 "stage14_disk" "Мониторинг диска и большие файлы"
		menu_item 15 "stage15_bbr" "BBR congestion control"
		echo ""
		echo -e "  ${C_YELLOW}R${C_RESET}) Откат          ${C_RED}Q${C_RESET}) Выход"
		echo ""

		# Прогресс-бар: сколько этапов выполнено
		local total=15 done=0 s
		for s in stage1_update stage2_admin_user stage3_root_password stage4_ssh_key \
			stage5_ssh_config stage6_sftp_user stage7_ufw stage8_autoupdate stage9_intrusion \
			stage10_dns stage11_fish stage12_timezone stage13_lynis stage14_disk stage15_bbr; do
			[[ "$(get_stage_status "$s")" == "completed" ]] && done=$((done + 1))
		done
		if [[ $done -gt 0 ]]; then
			printf "  Прогресс: "
			progress_bar "$done" "$total" ""
			echo ""
		fi
		echo ""

		read -rp "  ${C_BOLD}${ICON_ARROW}${C_RESET} " choice

		case "${choice,,}" in
		0) stage_utilities ;;
		1) stage_update ;;
		2) stage_users ;;
		3) stage_root_password ;;
		4) stage_ssh_key ;;
		5) stage_ssh_config ;;
		6) stage_sftp_user ;;
		7) stage_ufw ;;
		8) stage_autoupdate ;;
		9) stage_intrusion ;;
		10) stage_dns ;;
		11) stage_fish ;;
		12) stage_timezone ;;
		13) stage_lynis ;;
		14) stage_disk ;;
		15) stage_bbr ;;
		r) stage_rollback ;;
		q)
			echo ""
			log_info "Выход. Лог: ${C_DIM}$LOG_FILE${C_RESET}"
			exit 0
			;;
		*) log_err "Неверный выбор" ;;
		esac

		echo ""
		read -rp "  ${C_DIM}Enter — в меню...${C_RESET} "
	done
}

# ═══════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ═══════════════════════════════════════════════════════════════════

show_help() {
	echo "Seq VPS Security Script"
	echo ""
	echo "  Комплексная настройка безопасности VPS сервера."
	echo "  Поддерживает: Debian, Ubuntu, Fedora, RHEL, CentOS, Rocky, AlmaLinux."
	echo ""
	echo "  Использование:"
	echo "    sudo ./seq_vps.sh          — интерактивное меню"
	echo "    sudo ./seq_vps.sh --help   — эта справка"
	echo ""
	echo "  Этапы:"
	echo "    1. Обновление системы"
	echo "    2. Управление пользователями (создание, sudo, удаление)"
	echo "    3. Смена пароля root"
	echo "    4. Установка SSH-ключа"
	echo "    5. Настройка SSH (порт, аутентификация, root-доступ)"
	echo "    6. Создание SFTP пользователя (chroot)"
	echo "    7. Настройка UFW (фаервол)"
	echo "    8. Автообновления безопасности"
	echo "    9. Защита от брутфорса (CrowdSec или Fail2Ban)"
	echo "   10. Настройка DNS"
	echo "   11. Установка Fish shell"
	echo "   12. Часовой пояс и синхронизация времени (NTP)"
	echo "   13. Аудит безопасности (Lynis)"
	echo "   14. Мониторинг диска и поиск больших файлов"
	echo "   15. BBR congestion control (ускорение TCP)"
	echo "    R. Откат этапа из бэкапа"
	echo ""
	echo "  Данные: /opt/seq_vps/"
	echo ""
	exit 0
}

main() {
	[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

	detect_distro
	check_root

	[[ -d "$DATA_DIR" ]] || {
		mkdir -p "$DATA_DIR"
		chmod 700 "$DATA_DIR"
	}
	init_status_file

	log_info "Seq VPS Security · ${C_BOLD}$DISTRO_NAME${C_RESET}"
	log_info "Лог: ${C_DIM}$LOG_FILE${C_RESET}"
	log_info "Бэкапы: ${C_DIM}$BACKUP_DIR${C_RESET}"

	main_menu
}

# запуск только при прямом исполнении (позволяет source'ить для тестов)
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
