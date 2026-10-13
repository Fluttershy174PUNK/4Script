#!/bin/bash
#
# 4script.sh — 4Script: простой скрипт защиты сервера (simple-server-security-script)
# Debian/Ubuntu · Fedora/RHEL/CentOS · Rocky · AlmaLinux
#
# Использование: sudo ./4script.sh [--help]
#

# ponytail: без -e — это интерактивное меню, любой `return 1` из этапа
# (неверный номер, несовпавшие пароли) убивал бы весь скрипт вместо возврата в меню.
# Критичные операции проверяются явно (sshd -t перед рестартом).
set -uo pipefail

# ═══════════════════════════════════════════════════════════════════
#  ЛОКАЛЬ: ШИРИНА КИРИЛЛИЦЫ
# ═══════════════════════════════════════════════════════════════════
# При пустом LANG (частый случай для неинтерактивного ssh и супервизоров)
# bash считает длину строки в БАЙТАХ. Видимые последствия:
#   - printf '%-20s' выравнивает колонки криво;
#   - ${var:0:N} режет многобайтный символ пополам и печатает «битый» символ.
# Переключаемся на C.UTF-8, если текущая локаль не UTF-8; C.UTF-8 есть
# практически везде и не требует генерации.
if [[ "${LC_ALL:-${LANG:-}}" != *UTF-8* && "${LC_ALL:-${LANG:-}}" != *utf8* ]]; then
	if command -v locale &>/dev/null && locale -a 2>/dev/null | grep -qiE '^C\.(UTF-8|utf8)$'; then
		export LC_ALL=C.UTF-8
	fi
fi

# ═══════════════════════════════════════════════════════════════════
#  ЦВЕТА И СТИЛИ
# ═══════════════════════════════════════════════════════════════════
if [[ -t 1 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
	readonly C_RESET='\033[0m' C_BOLD='\033[1m' C_DIM='\033[2m'
	readonly C_RED='\033[0;31m' C_GREEN='\033[0;32m' C_YELLOW='\033[1;33m'
	readonly C_BLUE='\033[0;34m' C_CYAN='\033[0;36m'
	readonly C_BG_RED='\033[41m' C_BG_GREEN='\033[42m'
else
	readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
	readonly C_BLUE='' C_CYAN='' C_BG_RED='' C_BG_GREEN=''
fi

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
# Каталог данных. Проект раньше назывался seq_vps: на уже настроенных серверах
# остался /opt/seq_vps с бэкапами и статусом, и его надо продолжать использовать —
# иначе потеряются все откаты. Новые установки идут в /opt/4script.
_OLD_DATA_DIR="/opt/seq_vps"
_NEW_DATA_DIR="/opt/4script"
if [[ -d "$_OLD_DATA_DIR" ]]; then
	readonly DATA_DIR="$_OLD_DATA_DIR"
else
	readonly DATA_DIR="$_NEW_DATA_DIR"
fi
# одна метка времени на прогон — иначе бэкап и лог могут разойтись на секунду
RUN_TS="$(date +%Y%m%d_%H%M%S)"
readonly RUN_TS
readonly BACKUP_DIR="${DATA_DIR}/backups/${RUN_TS}"
readonly LOG_FILE="${DATA_DIR}/4script_${RUN_TS}.log"
readonly STAGE_STATUS_FILE="${DATA_DIR}/.seq_vps_status"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
# 00-, а не 99-: sshd берёт ПЕРВОЕ найденное значение, а на облачных образах
# лежит 50-cloud-init.conf с PasswordAuthentication yes, который перебьёт 99-*.
readonly SEQ_SSHD_DROPIN="00-seq-vps.conf"
# Маркеры своих блоков в чужих конфигах (PAM, faillock, pwquality, sysctl).
# Историческое имя оставлено намеренно: на настроенных серверах эти блоки уже
# помечены seq_vps, и смена маркера заставила бы скрипт писать дубли.
readonly OWN_MARK="# seq_vps"
readonly OWN_MARK_PAM="seq_vps faillock"
CURRENT_SSH_PORT=22
# Порт, который надо закрыть в фаерволе после успешного рестарта SSH
_wanted_close_port=""
SSH_KEY_USER=""
TERM_WIDTH=${COLUMNS:-80}
SPINNER_PID=""

PKG_MGR=""
DISTRO_NAME=""
SSH_SERVICE=""
SUDO_GROUP=""
HAS_SELINUX=false

readonly SCRIPT_VERSION="2.0"

# ═══════════════════════════════════════════════════════════════════
#  РЕЕСТР ЭТАПОВ — единственный источник правды для меню, прогресса,
#  справки, шаблона статус-файла и диспетчера выбора.
#    номер|ключ статуса|иконка|название|категория|функция
#  Пустой ключ = этап без статуса (утилиты).
# ═══════════════════════════════════════════════════════════════════
readonly STAGE_DEFS=(
	"0||${ICON_GEAR}|Установка утилит (micro, mc)|setup|stage_utilities"
	"1|stage1_update|${ICON_GEAR}|Обновление системы|setup|stage_update"
	"2|stage2_admin_user|${ICON_USER}|Управление пользователями|access|stage_users"
	"3|stage3_root_password|${ICON_KEY}|Изменение пароля root|access|stage_root_password"
	"4|stage4_ssh_key|${ICON_KEY}|Установка SSH-ключа|access|stage_ssh_key"
	"5|stage5_ssh_config|${ICON_KEY}|Настройка SSH (порт, вход, root)|access|stage_ssh_config"
	"6|stage6_sftp_user|${ICON_LOCK}|Создание SFTP пользователя|access|stage_sftp_user"
	"7|stage7_ufw|${ICON_FIRE}|Фаервол (UFW / firewalld)|protect|stage_ufw"
	"8|stage8_autoupdate|${ICON_GEAR}|Автообновления безопасности|protect|stage_autoupdate"
	"9|stage9_intrusion|${ICON_SHIELD}|Защита от брутфорса (CrowdSec/Fail2Ban)|protect|stage_intrusion"
	"10|stage10_dns|${ICON_GLOBE}|Настройка DNS|protect|stage_dns"
	"11|stage11_fish|🐟|Установка Fish shell|system|stage_fish"
	"12|stage12_timezone|🕐|Часовой пояс и синхронизация времени|system|stage_timezone"
	"13|stage13_lynis|🔍|Аудит безопасности (Lynis)|system|stage_lynis"
	"14|stage14_disk|💾|Мониторинг диска и большие файлы|system|stage_disk"
	"15|stage15_bbr|🚀|BBR congestion control|system|stage_bbr"
	"16|stage16_sysctl|🧩|Харденинг ядра (sysctl)|system|stage_sysctl"
	"17|stage17_audit|🔎|Аудит: порты, учётки, SUID, LSM|system|stage_audit"
	"18|stage18_pam|🔐|Пароли и блокировки (PAM)|protect|stage_pam"
	"19|stage19_auditd|📋|Аудит событий (auditd)|protect|stage_auditd"
	"20|stage20_ipv6|🌐|IPv6: включить или отключить|protect|stage_ipv6"
)
readonly CATEGORY_ORDER=(setup access protect system)

category_title() {
	case "$1" in
	setup) echo "Подготовка" ;;
	access) echo "Доступ и вход" ;;
	protect) echo "Защита" ;;
	system) echo "Система и сеть" ;;
	*) echo "$1" ;;
	esac
}

# Запись реестра по номеру либо ключу этапа: stage_def <0|stage1_update>
stage_def() {
	local def num key
	for def in "${STAGE_DEFS[@]}"; do
		IFS='|' read -r num key _ _ _ _ <<<"$def"
		[[ "$num" == "$1" || ( -n "$1" && "$key" == "$1" ) ]] && {
			printf '%s' "$def"
			return 0
		}
	done
	return 1
}

# Запуск этапа по его номеру (диспетчер меню)
run_stage() {
	local def fn
	def=$(stage_def "$1") || return 1
	fn=$(cut -d'|' -f6 <<<"$def")
	[[ -n "$fn" ]] || return 1
	"$fn"
}

# ═══════════════════════════════════════════════════════════════════
#  БАЗОВЫЕ УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

# Спиннер — запуск/остановка
# ponytail: фон-сабшелл НЕ видит изменения переменной родителя, поэтому
# останавливаем по PID (kill), а не флагом — иначе вечный hang.
spinner_start() {
	local msg="${1:-}"
	[[ -t 1 ]] || return 0
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
	local cur=$1 total=$2 label="${3:-}" w=30 filled empty pct bar
	((total > 0)) || return 1
	pct=$((cur * 100 / total))
	filled=$((cur * w / total))
	empty=$((w - filled))
	printf "\r  ${C_BLUE}%s${C_RESET} [${C_GREEN}" "$label"
	printf -v bar '%*s' "$filled" ''
	printf '%s' "${bar// /█}"
	printf "${C_RESET}${C_DIM}"
	printf -v bar '%*s' "$empty" ''
	printf '%s' "${bar// /░}"
	printf "${C_RESET}] %3d%%" "$pct"
}

# tee падает, если каталога/лога нет (например при source в тестах) — тогда только stdout
log() {
	if [[ -w "$LOG_FILE" || -w "${LOG_FILE%/*}" ]]; then
		echo -e "$*" | tee -a "$LOG_FILE"
	else
		echo -e "$*"
	fi
}
log_info() { log "${C_BLUE}${ICON_INFO}${C_RESET} $1"; }
log_ok() { log "${C_GREEN}${ICON_OK}${C_RESET} $1"; }
log_warn() { log "${C_YELLOW}${ICON_WARN}${C_RESET} $1"; }
log_err() { log "${C_RED}${ICON_FAIL}${C_RESET} $1"; }

# Визуальные элементы
hr() {
	local line
	printf -v line '%*s' "$TERM_WIDTH" ''
	printf "${C_DIM}%s${C_RESET}\n" "${line// /─}"
}
hr_thick() {
	local line
	printf -v line '%*s' "$TERM_WIDTH" ''
	printf "${C_BLUE}%s${C_RESET}\n" "${line// /═}"
}

# Обрезка строки по СИМВОЛАМ, а не байтам: без UTF-8 в locale bash режет
# многобайтные символы посередине и в терминал уходит битый «�».
text_truncate() {
	local s="$1" max="$2"
	LC_ALL=C.UTF-8 bash -c 's="$1"; printf "%s" "${s:0:$2}"' _ "$s" "$max" 2>/dev/null || printf '%s' "$s"
}

# Заголовок раздела в меню — ширина не зависит от эмодзи
repeat_hdr() {
	local icon="$1" title="$2" color="${3:-$C_CYAN}"
	local text="${icon}  ${title}" pad line
	pad=$((TERM_WIDTH - ${#text} - 4))
	((pad < 1)) && pad=1
	printf -v line '%*s' "$pad" ''
	printf "${C_BOLD}${color}├─ %s %s${C_RESET}\n" "$text" "${line// /─}"
}

category_icon() {
	case "$1" in
	setup) echo "$ICON_GEAR" ;;
	access) echo "$ICON_USER" ;;
	protect) echo "$ICON_SHIELD" ;;
	system) echo "$ICON_GEAR" ;;
	*) echo "$ICON_BULLET" ;;
	esac
}

category_color() {
	case "$1" in
	access) echo "$C_YELLOW" ;;
	protect) echo "$C_GREEN" ;;
	*) echo "$C_CYAN" ;;
	esac
}

# Заголовок этапа с иконкой
stage_banner() {
	local icon="$1" num="$2" title="$3"
	echo ""
	hr_thick
	printf "  ${C_BOLD}${C_CYAN}${icon}  ЭТАП %s: %s${C_RESET}\n" "$num" "$title"
	hr_thick
	echo ""
}

# Построчное подтверждение не оставляет Enter в буфере для следующего вопроса.
confirm() {
	local prompt="${1:-Продолжить?}" default="${2:-n}" answer=""
	[[ "$default" == "y" ]] && prompt+=" [Y/n] " || prompt+=" [y/N] "
	printf "  ${C_YELLOW}%s${C_RESET}" "$prompt"
	read -r answer || return 1
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
	printf "  %b %b%-50s%b\n" "$num_fmt" "$mark" "$(text_truncate "$text" 46)" "$color"
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

# Шаблон статус-файла в stdout: генератор отдельно от файла, чтобы можно было
# проверять без root — STAGE_STATUS_FILE readonly.
stage_status_template() {
	echo "# Статус этапов 4script (completed / failed / skipped / not_started)"
	local def num key
	for def in "${STAGE_DEFS[@]}"; do
		IFS='|' read -r num key _ _ _ _ <<<"$def"
		[[ -n "$key" ]] && echo "$key=not_started"
	done
}

# Статус-файл создаётся шаблоном, а при обновлении скрипта новые этапы
# дописываются в существующий файл: иначе после апдейта в нём не окажется
# stage16/17/18/19, и меню будет показывать неполный прогресс.
init_status_file() {
	if [[ ! -f "$STAGE_STATUS_FILE" ]]; then
		stage_status_template >"$STAGE_STATUS_FILE"
		return 0
	fi
	local def num key _
	for def in "${STAGE_DEFS[@]}"; do
		IFS='|' read -r num key _ <<<"$def"
		[[ -n "$key" ]] || continue
		grep -q "^${key}=" "$STAGE_STATUS_FILE" 2>/dev/null || echo "${key}=not_started" >>"$STAGE_STATUS_FILE"
	done
}

check_root() {
	if [[ $EUID -ne 0 ]]; then
		echo -e "${C_RED}${ICON_FAIL}  Запустите от root:  sudo ./4script.sh${C_RESET}"
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

# Порт sshd одним способом: Port из эффективного конфига, иначе 22.
# Только печатает — присваивание делает вызывающий (CURRENT_SSH_PORT=$(_ssh_port)),
# потому что из $(...) внутреннее присваивание до родителя не доходит.
_ssh_port() {
	local cfg port
	cfg=$(sshd -T 2>/dev/null) || cfg=""
	port=$(ssh_port_from_config "$cfg")
	printf '%s' "${port:-22}"
}

# Синхронизация CURRENT_SSH_PORT. Ничего не печатает и НЕ оборачивается
# в $( ) — иначе присваивание осталось бы в subshell и подсказки показывали бы 22.
# Вызов: _ssh_port_refresh; local sp=$CURRENT_SSH_PORT
_ssh_port_refresh() {
	CURRENT_SSH_PORT=$(_ssh_port)
}

# Значение директивы из вывода sshd -T (имена там в нижнем регистре): _sshd_option "<дамп>" name default
_sshd_option() {
	local v
	v=$(awk -v k="$2" 'tolower($1) == k { print $2; exit }' <<<"$1")
	printf '%s' "${v:-$3}"
}

# Двойной ввод пароля с проверкой. Пароль возвращается в переменную с именем $1.
# Имена здесь с префиксом: локальная переменная, совпадающая с именем
# переменной вызывающего, перехватила бы printf -v, и пароль потерялся бы
# (а chpasswd получил бы пустой пароль).
_read_new_password() {
	local var="$1" label="${2:-Пароль}"
	local _rnp_pw _rnp_pw2
	read -rsp "  ${label}: " _rnp_pw
	echo
	read -rsp "  Подтвердите: " _rnp_pw2
	echo
	[[ "$_rnp_pw" == "$_rnp_pw2" ]] || {
		log_err "Пароли не совпадают"
		return 1
	}
	[[ -n "$_rnp_pw" ]] || {
		log_err "Пароль не может быть пустым"
		return 1
	}
	printf -v "$var" '%s' "$_rnp_pw"
}

# Минимальная версия OpenSSH, с которой доступна директива (её нет в старых
# sshd и _sshd_config_ok отклонит кандидата).
_sshd_version_at_least() {
	local need="$1" ver
	ver=$(sshd -V 2>&1 | head -1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | cut -d_ -f2)
	[[ -n "$ver" ]] || return 1
	printf '%s\n%s\n' "$need" "$ver" | sort -V -C
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

ssh_port_from_config() {
	awk '$1 == "port" { print $2; exit }' <<<"$1"
}

show_server_summary() {
	echo -e "${C_BOLD}${C_CYAN}┌─${C_RESET} ${C_BOLD}СВОДКА СЕРВЕРА${C_RESET} ${C_DIM}— 4Script${C_RESET}"

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
	_ssh_port_refresh
	local sp=$CURRENT_SSH_PORT
	local pa
	pa=$(_sshd_option "$ssh_cfg" passwordauthentication yes)
	local rl
	rl=$(_sshd_option "$ssh_cfg" permitrootlogin yes)
	local ma
	ma=$(_sshd_option "$ssh_cfg" maxauthtries 6)
	local ep
	ep=$(_sshd_option "$ssh_cfg" permitemptypasswords no)

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

	# ── DNS ── (у resolved в resolv.conf всегда 127.0.0.53 — берём реальные)
	echo -e "\n${C_BOLD}${ICON_GLOBE}  DNS:${C_RESET}"
	local dns_list
	dns_list=$(_dns_current)
	[[ -n "$dns_list" ]] && echo "$dns_list" | sed 's/^/  /' || echo -e "  ${C_DIM}(не настроены)${C_RESET}"

	# ── Подключение ──
	local ip_addr
	ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
	echo -e "\n${C_BOLD}${ICON_ARROW}  Подключение:${C_RESET}"
	echo -e "  ${C_GREEN}ssh${C_RESET} -p $CURRENT_SSH_PORT user@${ip_addr:-<server_ip>}"

	# Если есть проблемы — подсказка
	if [[ $ssh_score -le 2 ]]; then
		echo -e "\n  ${C_YELLOW}${ICON_WARN}  SSH нуждается в усилении — этапы 4 и 5${C_RESET}"
	fi
	# проверка по реальному фаерволу: на RHEL ufw не установлен вовсе,
	# и старая проверка вечно показывала «неактивен» на включённом firewalld
	local fw_active=false
	if [[ "$fw" == firewalld ]]; then
		firewall-cmd --state 2>/dev/null | grep -q running && fw_active=true
	elif command -v ufw &>/dev/null; then
		ufw status 2>/dev/null | grep -q "Status: active" && fw_active=true
	fi
	$fw_active || echo -e "  ${C_YELLOW}${ICON_WARN}  Фаервол неактивен — этап 7${C_RESET}"
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
		apt) apt-get install -y -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 "$pkg" &>/dev/null && {
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
#  ЭТАП 0: УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

stage_utilities() {
	stage_banner "$ICON_GEAR" "0" "Установка утилит"

	echo "  ${C_BOLD}1)${C_RESET} micro  ${C_DIM}— удобный редактор${C_RESET}"
	echo "  ${C_BOLD}2)${C_RESET} mc     ${C_DIM}— файловый менеджер${C_RESET}"
	echo "  ${C_BOLD}3)${C_RESET} Обе утилиты"
	echo "  ${C_BOLD}0)${C_RESET} Пропустить"
	echo ""
	read -rp "  ${ICON_ARROW} " choice
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
		apt) apt-get update &>/dev/null && break ;;
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
		apt-get upgrade -y &>/dev/null || true
		apt-get full-upgrade -y &>/dev/null || true
		apt-get autoremove --purge -y &>/dev/null || true
		;;
	dnf | yum)
		$PKG_MGR upgrade -y &>/dev/null || true
		$PKG_MGR autoremove -y &>/dev/null || true
		;;
	esac
	spinner_stop

	log_ok "Система обновлена"
	# без перезагрузки работает старое ядро/библиотеки — скажем об этом явно
	if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
		log_warn "Требуется перезагрузка (обновлено ядро или системные пакеты): reboot"
	fi
	update_stage_status "stage1_update" "completed"
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
	read -rp "  ${ICON_ARROW} " action
	echo ""

	case "${action,,}" in
	c)
		read -rp "  Имя пользователя: " username
		[[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
			log_err "Имя: латиница в нижнем регистре, цифры, _ и -"
			return 1
		}
		id "$username" &>/dev/null && {
			log_err "Уже существует: $username"
			return 1
		}
		local pw
		_read_new_password pw || return 1
		useradd -m -s /bin/bash "$username"
		echo "$username:$pw" | chpasswd
		usermod -aG "$SUDO_GROUP" "$username"
		log_ok "Пользователь ${C_BOLD}$username${C_RESET} создан (группа $SUDO_GROUP)"
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
		local pw
		_read_new_password pw "Новый пароль для $u" || return 1
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
		read -rp "  ${ICON_ARROW} " ga
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
	local pw
	_read_new_password pw "Новый пароль root" || {
		update_stage_status "stage3_root_password" "failed"
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

# Ubuntu 22.10+ и Debian 13 используют systemd-сокет активацию: слушает
# ssh.socket, а Port из sshd_config игнорируется. Без правки сокета смена
# порта «проходит», но старый порт продолжает слушать — а новый нет.
_ssh_socket_active() {
	systemctl is-active --quiet ssh.socket 2>/dev/null && return 0
	systemctl is-enabled --quiet ssh.socket 2>/dev/null && return 0
	return 1
}

# Порт в сокет-активации. Двух вещей мало:
#  1) override в ssh.socket.d с ListenStream= не поможет: sshd-socket-generator
#     собирает ListenStream из ВСЕХ директив Port в sshd_config.d/*, а
#     дропин-файл юнита применяется раньше сгенерированного файла,
#     поэтому старый порт всё равно продолжит слушаться;
#  2) недостаточно создать свой файл — соседний «10-port.conf»
#     (его пишет cloud-init/провайдер) задаёт прежний порт и он тоже попадает в генератор.
# Поэтому: явный Port в drop-in + замена всех чужих Port-файлов (бэкап сохранён).
_ssh_socket_port() {
	local port="$1"
	systemctl is-active --quiet ssh.socket 2>/dev/null || return 0

   # 1. новое значение в сокете (сброс предыдущих ListenStream)
	local dir="/etc/systemd/system/ssh.socket.d"
	local f="$dir/10-seq-vps.conf"
	mkdir -p "$dir"
	backup_file "$f" "stage5_ssh_config"
	cat >"$f" <<EOF
# 4script: порт сокет-активации
[Socket]
ListenStream=
ListenStream=$port
EOF

	# 2. убрать чужие Port из drop-in каталога sshd: иначе генератор добавит их снова
	local pc f_base st
	shopt -s nullglob
	for pc in "$SSHD_CONFIG_D"/*.conf; do
		f_base=$(basename "$pc")
		[[ "$f_base" == "$SEQ_SSHD_DROPIN" ]] && continue
		grep -qE '^[[:space:]]*Port[[:space:]]' "$pc" 2>/dev/null || continue
		st="stage5_ssh_config"
		backup_file "$pc" "$st"
		# закомментировать, а не удалять: файл может принадлежать провайдеру
		sed -i 's/^[[:space:]]*Port[[:space:]]/# 4script: отключено (порт перенесён в 00-seq-vps.conf): &/I' "$pc"
		log_info "Порт в $f_base отключён (иначе слушался бы параллельно)"
	done
	shopt -u nullglob

	systemctl daemon-reload 2>/dev/null || true
}

_ssh_validate() {
	sshd -t 2>&1 | tee -a "$LOG_FILE"
}

# Проверка кандидата в drop-in ДО его установки. Сам drop-in через sshd -t
# не проверить: без HostKey sshd всегда падает, а валидность зависит от
# основного конфига и соседних файлов. Поэтому собираем пробу:
# Include <кандидат> + реальный sshd_config (первое значение побеждает).
_sshd_config_ok() {
	local cand="$1" probe rc
	probe=$(mktemp)
	{
		echo "Include $cand"
		cat /etc/ssh/sshd_config 2>/dev/null
	} >"$probe"
	sshd -t -f "$probe" 2>&1 | tee -a "$LOG_FILE"
	rc=${PIPESTATUS[0]}
	rm -f "$probe"
	return "$rc"
}

# Перезапуск SSH (с сокетом, если он есть) + проверка, что порт реально слушается
_ssh_restart() {
	systemctl restart "$SSH_SERVICE" 2>/dev/null || {
		log_err "Не удалось перезапустить $SSH_SERVICE"
		return 1
	}
	# при сокет-активации ssh.service сам не слушает — нужен рестарт сокета
	if _ssh_socket_active; then
		systemctl restart ssh.socket 2>/dev/null || log_warn "ssh.socket не перезапустился"
	fi
	log_ok "SSH перезапущен ($SSH_SERVICE)"
	sleep 2
	# Какие порты SSH реально слушает сейчас (из ядра, а не из файлов)
	_ssh_listen_ports
	local new_port_live=false
	if [[ " $_seen_ports " == *" ${CURRENT_SSH_PORT} "* ]]; then
		new_port_live=true
		log_ok "SSH слушает на порту $CURRENT_SSH_PORT"
	else
		if _ssh_socket_active; then
			log_warn "Порт $CURRENT_SSH_PORT не слушается — проверьте: systemctl cat ssh.socket"
		else
			log_warn "Не удалось проверить порт $CURRENT_SSH_PORT"
		fi
	fi
	# Порт, оставшийся от прежних настроек — фактически открытая дверь:
	# sshd-socket-generator делает ListenStream из КАЖДОЙ директивы Port в sshd_config.d/*.
	local extra=""
	for p in $_seen_ports; do
		[[ "$p" == "$CURRENT_SSH_PORT" ]] && continue
		extra+="$p "
	done
	[[ -n "$extra" ]] && log_warn "Кроме $CURRENT_SSH_PORT слушаются порты ${extra% } — уберите чужие 'Port' из $SSHD_CONFIG_D"

	# Прежний порт закрываем только после того, как новый реально пускает.
	# Рестарт sshd этого не доказывает, а локальная проба видит только фаервол
	# хоста (не NAT/security group). Поэтому решает пользователь: сначала
	# понятная проба, затем явное подтверждение входа из новой сессии.
	if [[ -n "${_wanted_close_port:-}" && "$_wanted_close_port" != "$CURRENT_SSH_PORT" ]]; then
		local probe_ok=false
		if $new_port_live && _ssh_port_reachable "$CURRENT_SSH_PORT"; then
			probe_ok=true
			log_ok "Локальная проба: порт $CURRENT_SSH_PORT принимает соединения (фаервол хоста пропускает)"
		else
			log_warn "Порт $CURRENT_SSH_PORT не отвечает на локальную пробу"
		fi
		log_warn "Проба не заменяет внешнюю проверку: NAT, security group и маршрутизация не видны изнутри"
		echo -e "  ${C_BOLD}Проверьте вход в НОВОМ окне: ssh -p $CURRENT_SSH_PORT root@<адрес>${C_RESET}"
		if $probe_ok && confirm "Вход по новому порту $CURRENT_SSH_PORT проверен? Закрыть старый $_wanted_close_port"; then
			_fw_close_ssh_port "$_wanted_close_port"
			_wanted_close_port=""
		else
			log_warn "Старый порт $_wanted_close_port оставлен открытым"
			log_info "  Закрыть вручную: ufw delete <номер>  /  firewall-cmd --permanent --remove-port=$_wanted_close_port/tcp"
		fi
	fi
}

# Локальная проба: проходит ли TCP-соединение на свой адрес (цепочка INPUT,
# то есть фаервол хоста). Это НЕ проверка внешней доступности: NAT, security
# group облака и маршрутизация остаются непроверенными.
# Если проверить нечем — возвращаем ошибку, а не успех: ложное «доступен»
# закрыло бы старый порт без основания.
_ssh_port_reachable() {
	local port="$1" ip
	ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	[[ -n "$ip" ]] || return 1
	if command -v nc &>/dev/null; then
		nc -z -w 3 "$ip" "$port" &>/dev/null
		return $?
	fi
	timeout 3 bash -c ": >/dev/tcp/$ip/$port" 2>/dev/null
}

# Какие SSH-порты реально слушаются (в _seen_ports — список через пробел).
# Кандидаты — из конфига sshd и из сокета, результат пересечён с живыми
# слушателями: только так видны «висящие» порты и нет ложных срабатываний
# на DNS/mDNS и прочих чужих портах.
_ssh_listen_ports() {
	_seen_ports=""
	local p candidates=""

	while read -r p; do
		[[ -n "$p" ]] && candidates+="$p"$'\n'
	done < <(sshd -T 2>/dev/null | awk 'tolower($1) == "port" {print $2}')

	if _ssh_socket_active; then
		while read -r p; do
			[[ -n "$p" ]] && candidates+="$p"$'\n'
		done < <({ systemctl show ssh.socket -p Listen 2>/dev/null; systemctl cat ssh.socket 2>/dev/null; } |
			grep -oE '(Listen|ListenStream)=([^ ]+ )?[^ ]*:[0-9]+|[0-9]+$' | grep -oE '[0-9]+$')
	fi

	# пересечение «что объявлено» × «что слушается»
	local live
	live=" $(ss -tln 2>/dev/null | awk 'NR>1 {print $4}' | sed 's/.*://' | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ') "
	while read -r p; do
		[[ -n "$p" ]] && [[ "$live" == *" $p "* ]] && _seen_ports+="$p "
	done <<<"$(sort -u <<<"$candidates")"
	_seen_ports=$(tr ' ' '\n' <<<"$_seen_ports" | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')
}

# AuthorizedKeysFile внутри Match-блока SFTP. Идемпотентно: повторный выбор
# ключа не добавляет строку второй раз.
_sftp_add_authorized_keys() {
	local cfg="$1" line="    AuthorizedKeysFile /etc/ssh/keys.d/%u.pub"
	grep -qF "$line" "$cfg" && return 0
	local tmp
	tmp=$(mktemp)
	cp "$cfg" "$tmp"
	printf '%s\n' "$line" >>"$tmp"
	if ! _sshd_config_ok "$tmp"; then
		log_err "AuthorizedKeysFile не проходит sshd -t — конфиг не изменён"
		rm -f "$tmp"
		return 1
	fi
	mv "$tmp" "$cfg"
}

# Аудит правил sudo. Доп. файлы в /etc/sudoers.d — любимый способ тихой
# эскалации: NOPASSWD, лишние команды, root-эквиваленты вроде chmod/chown/vi.
_audit_sudoers() {
	echo ""
	echo -e "${C_BOLD}▸ Синтаксис sudoers:${C_RESET}"
	if visudo -c 2>&1 | tee -a "$LOG_FILE"; then
		log_ok "visudo -c: ошибок нет"
	else
		log_err "visudo -c нашёл ошибку — проверьте правила вручную"
	fi

	echo ""
	echo -e "${C_BOLD}▸ Файлы правил:${C_RESET}"
	local f n
	shopt -s nullglob
	for f in /etc/sudoers /etc/sudoers.d/*; do
		[[ -f "$f" ]] || continue
		# README из пакета sudo правил не содержит
		[[ "$(basename "$f")" == "README" ]] && continue
		n=$(grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || echo 0)
		printf '  %s (%s строк правил)\n' "$f" "$n"
	done
	shopt -u nullglob

	# CVE-2025-32463 (эскалация через sudo --chroot) закрыт в 1.9.17p1.
	# Внимание: Ubuntu 26.04 ставит sudo-rs — другая реализация и другая
	# нумерация (0.2.x), сравнивать её с 1.9.x нельзя: 0.2.13 < 1.9.17p1
	# дало бы ложное «уязвим».
	local vline
	vline=$(sudo -V 2>/dev/null | head -1 || true)
	if [[ -n "$vline" ]]; then
		echo ""
		echo -e "  ${C_DIM}$vline${C_RESET}"
		if [[ "$vline" == *sudo-rs* ]]; then
			if printf '0.2.4\n%s\n' "${vline#sudo-rs }" | sort -V -C; then
				echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  sudo-rs с CVE-2025-32463 не подвержен (--chroot не поддерживается)"
			else
				echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  Старый sudo-rs — обновите пакет sudo-rs"
			fi
		else
			local v
			v=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z0-9]*' <<<"$vline")
			if printf '1.9.17p1\n%s\n' "$v" | sort -V -C; then
				echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  sudo $v (CVE-2025-32463 закрыт)"
			else
				echo -e "  ${C_RED}${ICON_WARN}${C_RESET}  sudo $v < 1.9.17p1 — есть LPE CVE-2025-32463, обновите пакет"
			fi
		fi
	fi

	echo ""
	echo -e "${C_BOLD}▸ Подозрительные правила (NOPASSWD / оболочки / редакторы):${C_RESET}"
	local hits
	hits=$(grep -rnE 'NOPASSWD|/bin/(ba|z|k|c)?sh$|/usr/bin/(vi|vim|nano|less|man|find|awk|python[0-9.]*)$|ALL[[:space:]]*=[[:space:]]*ALL' \
		/etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
	if [[ -n "$hits" ]]; then
		echo "$hits" | sed 's/^/  /' | head -20
		log_warn "Каждое такое правило фактически даёт root — проверьте, что оно нужно"
	else
		echo -e "  ${C_DIM}ничего похожего не найдено${C_RESET}"
	fi

	echo ""
	echo -e "  ${C_DIM}Отключить всё содержимое /etc/sudoers.d можно переносом файлов,
  но сначала проверьте: часть правил может быть нужна для работы сервисов.${C_RESET}"
	echo ""
	read -rp "  Enter..." _
}

# Открыть порт SSH в активном фаерволе. Менять порт, не открыв его, —
# гарантированная потеря доступа: sshd уже слушает новый порт, а фаервол
# его режет. Возвращает 0, если фаервол неактивен (тогда блокировать нечем).
_fw_allow_ssh_port() {
	local port="$1"
	if [[ "$(_fw_cmd)" == firewalld ]]; then
		command -v firewall-cmd &>/dev/null || return 0
		firewall-cmd --state 2>/dev/null | grep -q running || return 0
		firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null || return 1
		firewall-cmd --reload &>/dev/null || return 1
		log_ok "Фаервол firewalld: порт $port/tcp открыт"
		return 0
	fi
	command -v ufw &>/dev/null || return 0
	ufw status 2>/dev/null | grep -q "Status: active" || return 0
	ufw allow "${port}/tcp" comment "SSH" &>/dev/null || return 1
	log_ok "Фаервол UFW: порт $port/tcp открыт"
}

# Закрыть прежний SSH-порт в фаерволе. Правило ufw удаляем целиком (cause
# «SSH»), для firewalld — убираем порт; если команда не проходит — просто предупреждаем:
# оставить лишнее правило безопаснее, чем потерять доступ к серверу.
_fw_close_ssh_port() {
	local port="$1"
	[[ -n "$port" ]] || return 0
	if [[ "$(_fw_cmd)" == firewalld ]]; then
		command -v firewall-cmd &>/dev/null || return 0
		firewall-cmd --state 2>/dev/null | grep -q running || return 0
		firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null || {
			log_warn "Не удалось закрыть $port/tcp в firewalld — закройте вручную"
			return 0
		}
		firewall-cmd --reload &>/dev/null || true
		log_info "Фаервол firewalld: порт $port/tcp закрыт"
		return 0
	fi
	command -v ufw &>/dev/null || return 0
	ufw status 2>/dev/null | grep -q "Status: active" || return 0
	# У одного порта две строки (IPv4 и IPv6), и удаление сдвигает нумерацию,
	# поэтому собираем все номера и удаляем от большего к меньшему.
	# В выводе номер печатается как «[ 1]» — с выравниванием пробелами.
	local n removed=0
	while read -r n; do
		[[ -n "$n" ]] || continue
		ufw --force delete "$n" &>/dev/null && removed=$((removed + 1))
	done < <(ufw status numbered 2>/dev/null | grep -E "^\[ *[0-9]+\].*${port}/tcp" |
		sed -n 's/^\[ *\([0-9]\+\)\].*/\1/p' | sort -rn)
	if [[ $removed -gt 0 ]]; then
		log_info "Фаервол UFW: правило $port/tcp закрыто ($removed шт.)"
	else
		log_warn "Не удалось закрыть правило для $port/tcp — проверьте: ufw status numbered"
	fi
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

	backup_file "/etc/ssh/sshd_config" "stage5_ssh_config"
	if ! grep -q "^Include $SSHD_CONFIG_D" /etc/ssh/sshd_config 2>/dev/null; then
		local tf
		tf=$(mktemp)
		# candidates содержит и старый конфиг (с HostKey), поэтому sshd -t -f его принимает
		{
			echo "Include $SSHD_CONFIG_D/*.conf"
			cat /etc/ssh/sshd_config 2>/dev/null
		} >"$tf"
		if ! sshd -t -f "$tf" 2>&1 | tee -a "$LOG_FILE"; then
			log_err "sshd_config с Include не проходит sshd -t — файл не изменён"
			rm -f "$tf"
			return 1
		fi
		mv "$tf" /etc/ssh/sshd_config
		log_info "Include $SSHD_CONFIG_D → sshd_config"
	fi

	local cfg="$SSHD_CONFIG_D/$SEQ_SSHD_DROPIN"
	# миграция со старого имени 99-seq-vps.conf, если оно осталось
	[[ -f "$SSHD_CONFIG_D/99-seq-vps.conf" ]] && {
		backup_file "$SSHD_CONFIG_D/99-seq-vps.conf" "stage5_ssh_config"
		rm -f "$SSHD_CONFIG_D/99-seq-vps.conf"
		log_info "Старый drop-in 99-seq-vps.conf удалён (заменён на 00-)"
	}
	backup_file "$cfg" "stage5_ssh_config"
	[[ ! -f "$cfg" ]] && echo "# 4script drop-in config" >"$cfg"

	# Хелпер — пишет drop-in через буфер и валидирует ДО установки:
	# невалидная правка (опечатка, системный лимит) не превратит живой конфиг в мёртвый.
	_ssh_set() {
		local tmp
		tmp=$(mktemp)
		if grep -q "^$1 " "$cfg"; then
			sed "s/^$1 .*/$1 $2/" "$cfg" >"$tmp"
		else
			cp "$cfg" "$tmp"
			echo "$1 $2" >>"$tmp"
		fi
		if ! _sshd_config_ok "$tmp"; then
			log_err "$1 $2 не проходит sshd -t — конфиг не изменён"
			rm -f "$tmp"
			return 1
		fi
		mv "$tmp" "$cfg"
	}

	# Правка drop-in с отчётом: «готово» печатает только если приняты все значения,
	# иначе пункт меню возвращает 1 и не даёт вызывающему коду считать шаг выполненным.
	_ssh_apply() {
		local label="$1" kv
		shift
		for kv in "$@"; do
			_ssh_set "${kv%%=*}" "${kv#*=}" || {
				log_err "$label: не применено"
				return 1
			}
		done
		log_ok "$label"
	}

	local sc
	sc=$(sshd -T 2>/dev/null)
	_ssh_port_refresh
	local sp=$CURRENT_SSH_PORT
	local pa
	pa=$(_sshd_option "$sc" passwordauthentication yes)
	local rl
	rl=$(_sshd_option "$sc" permitrootlogin yes)
	local ma
	ma=$(_sshd_option "$sc" maxauthtries 6)
	local ep
	ep=$(_sshd_option "$sc" permitemptypasswords no)

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
	local psp
	psp=$(_sshd_option "$sc" persourcepenalties enabled)
	if [[ "$psp" == disabled ]]; then
		echo "  7) Rate-limit атакующих (PerSourcePenalties): ${C_DIM}нет (OpenSSH < 9.8)${C_RESET}"
	else
		echo "  7) Rate-limit атакующих (PerSourcePenalties): ${C_GREEN}встроенный${C_RESET}"
	fi
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
		local old_port=$CURRENT_SSH_PORT
		_ssh_apply "Порт → $np" "Port=$np" || return 1
		_selinux_ssh_port "$np"
		if _ssh_socket_active; then
			_ssh_socket_port "$np"
			log_info "Сокет-активация (ssh.socket) — порт прописан и в сокете"
		fi
		# Порядок важен: сначала открыть новый порт в фаерволе, потом менять
		# sshd, иначе между рестартом и правилом сервер недоступен.
		if ! _fw_allow_ssh_port "$np"; then
			log_err "Не удалось открыть порт $np в фаерволе — смена отменена"
			_ssh_apply "Порт → $old_port" "Port=$old_port" >/dev/null 2>&1 || true
			if _ssh_socket_active; then _ssh_socket_port "$old_port" >/dev/null 2>&1 || true; fi
			return 1
		fi
		CURRENT_SSH_PORT=$np
		# Старый порт закрываем только после успешного рестарта — отложенно,
		# чтобы при провале осталась рабочая дверь (см. _ssh_restart).
		_wanted_close_port=$old_port
		;;
	2)
		echo "  1) yes  2) no"
		read -rp "  ${ICON_ARROW} " c
		[[ "$c" == "2" ]] && {
			# без KbdInteractive пароль всё равно принимается через PAM
			_ssh_apply "Парольный вход отключён (password + keyboard-interactive)" \
				"PasswordAuthentication=no" "KbdInteractiveAuthentication=no" || return 1
			echo -e "  ${C_YELLOW}${ICON_WARN}  Убедитесь, что SSH-ключ установлен!${C_RESET}"
		}
		[[ "$c" == "1" ]] && {
			_ssh_apply "Парольный вход включён" \
				"PasswordAuthentication=yes" "KbdInteractiveAuthentication=yes" || return 1
		}
		;;
	3)
		echo "  1) prohibit-password (рекомендуется)  2) no  3) yes (небезопасно)"
		read -rp "  ${ICON_ARROW} " c
		case "$c" in
		1 | "") _ssh_apply "PermitRootLogin → prohibit-password" "PermitRootLogin=prohibit-password" || return 1 ;;
		2) _ssh_apply "PermitRootLogin → no" "PermitRootLogin=no" || return 1 ;;
		3)
			echo -e "  ${C_RED}${ICON_WARN}  Прямой вход root по паролю/ключу — самый частый вектор атак.${C_RESET}"
			confirm "Точно включить PermitRootLogin yes?" || {
				log_info "Отменено"
				return 0
			}
			_ssh_apply "PermitRootLogin → yes" "PermitRootLogin=yes" || return 1
			;;
		esac
		;;
	4)
		read -rp "  Макс. попыток (1-10): " nm
		[[ "$nm" =~ ^[0-9]+$ && $nm -ge 1 && $nm -le 10 ]] || {
			log_err "1-10"
			return 1
		}
		_ssh_apply "MaxAuthTries → $nm" "MaxAuthTries=$nm" || return 1
		;;
	5)
		echo "  1) no (рекомендуется)  2) yes"
		read -rp "  ${ICON_ARROW} " c
		[[ "$c" == "1" ]] && {
			_ssh_apply "Пустые пароли запрещены" "PermitEmptyPasswords=no" || return 1
		}
		[[ "$c" == "2" ]] && {
			_ssh_apply "PermitEmptyPasswords yes" "PermitEmptyPasswords=yes" || return 1
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
	7)
		# OpenSSH 9.8+ сам штрафует источники (authfail, noauth, crash) — это
		# встроенная защита от брутфорса до Fail2Ban. По умолчанию включена;
		# имеет смысл явно закрепить и посмотреть, как выглядит политика.
		if ! _sshd_version_at_least 9.8; then
			log_warn "OpenSSH < 9.8: PerSourcePenalties недоступны"
			log_info "Защита от брутфорса — этап 9 (Fail2Ban/CrowdSec)"
		else
			echo ""
			echo -e "  ${C_DIM}Условия: authfail, noauth, invaliduser, crash; далее минуты бана и потолок${C_RESET}"
			echo "  Текущая политика: $(_sshd_option "$sc" persourcepenalties '(по умолчанию)')"
			echo -e "  ${C_DIM}Это встроенный rate-limit: источник с ошибками входа временно
  перестаёт получать соединения. Дополняет Fail2Ban (этап 9), не заменяет.${C_RESET}"
			echo ""
			if confirm "Включить PerSourcePenalties явно?"; then
				_ssh_apply "PerSourcePenalties включены" "PerSourcePenalties=yes" || return 1
			fi
		fi
		;;
	*) log_info "Пропущено" ;;
	esac

	echo ""
	log_info "Валидация конфигурации..."
	if ! _ssh_validate; then
		log_err "Ошибка в конфиге SSH! Перезапуск отменён."
		return 1
	fi

	echo ""
	if confirm "Перезапустить SSH?"; then
		_ssh_restart
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
	[[ "$sfu" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
		log_err "Имя пользователя: латиница в нижнем регистре, цифры, _ и -"
		return 1
	}
	id "$sfu" &>/dev/null && {
		log_err "Пользователь $sfu уже существует"
		update_stage_status "stage6_sftp_user" "failed"
		return 1
	}
	local sfpw
	_read_new_password sfpw || {
		update_stage_status "stage6_sftp_user" "failed"
		return 1
	}
	local chroot_dir="/srv/sftp/$sfu"
	local nologin_shell
	nologin_shell=$(command -v nologin || echo /usr/sbin/nologin)
	install -d -o root -g root -m 755 /srv/sftp "$chroot_dir"
	useradd -M -s "$nologin_shell" -d /upload "$sfu" || {
		log_err "Не удалось создать пользователя $sfu"
		return 1
	}
	install -d -o "$sfu" -g "$sfu" -m 755 "$chroot_dir/upload"
	printf '%s:%s\n' "$sfu" "$sfpw" | chpasswd || {
		userdel "$sfu" 2>/dev/null || true
		rm -rf "$chroot_dir"
		log_err "Не удалось задать пароль"
		return 1
	}

	local sftp_cfg="$SSHD_CONFIG_D/98-sftp-$sfu.conf"
	backup_file "$sftp_cfg" "stage6_sftp_user"
	backup_file "/etc/ssh/sshd_config" "stage6_sftp_user"
	local new_cfg
	new_cfg=$(mktemp)
	cat >"$new_cfg" <<EOF
# SFTP: $sfu (4script)
Match User $sfu
    ForceCommand internal-sftp
    ChrootDirectory $chroot_dir
    PermitTunnel no
    AllowAgentForwarding no
    AllowTcpForwarding no
    X11Forwarding no
    PasswordAuthentication yes
EOF
	if ! _sshd_config_ok "$new_cfg"; then
		log_err "Конфиг SFTP не проходит sshd -t"
		rm -f "$new_cfg"
		userdel "$sfu" 2>/dev/null || true
		rm -rf "$chroot_dir"
		return 1
	fi
	mv "$new_cfg" "$sftp_cfg"
	chmod 644 "$sftp_cfg"

	if ! _ssh_validate; then
		log_err "Ошибка в конфиге SSH!"
		rm -f "$sftp_cfg"
		userdel "$sfu" 2>/dev/null || true
		rm -rf "$chroot_dir"
		return 1
	fi
	# SELinux enforcing: файлы в /srv получают user_home_t, sshd не читает chroot
	if $HAS_SELINUX && command -v restorecon &>/dev/null; then
		restorecon -R "$chroot_dir" 2>/dev/null || true
	fi
	if ! _ssh_restart; then
		rm -f "$sftp_cfg"
		userdel "$sfu" 2>/dev/null || true
		rm -rf "$chroot_dir"
		return 1
	fi

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
			_sftp_add_authorized_keys "$sftp_cfg" && _ssh_restart && log_ok "Ключ установлен"
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
				_sftp_add_authorized_keys "$sftp_cfg" && _ssh_restart && log_ok "Ключ от $su скопирован"
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

	_ssh_port_refresh
	local sp=$CURRENT_SSH_PORT

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

	# IPv6=no — тихая дыра: правила UFW не покрывают IPv6, а сервер с
	# AAAA-записью остаётся доступным по всем портам в обход фаервола.
	if grep -qE '^IPV6=no' /etc/default/ufw 2>/dev/null; then
		log_warn "UFW отключён IPv6 (IPV6=no) — правила не действуют для IPv6"
		if confirm "Включить фильтрацию IPv6 (IPV6=yes)?"; then
			sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
			ufw reload &>/dev/null || true
			log_ok "IPV6=yes — правила UFW теперь покрывают и IPv6"
		fi
	fi

	# Docker публикует порты напрямую в netfilter (цепочка DOCKER-USER),
	# поэтому правила UFW на них не действуют — контейнеры видны извне.
	if command -v docker &>/dev/null; then
		log_warn "Установлен Docker: опубликованные порты обходят правила UFW"
		log_info "  ограничить: правила в цепочке DOCKER-USER или ufw-docker"
	fi

	_ssh_port_refresh
	local sp=$CURRENT_SSH_PORT

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
		echo "  9) Аудит sudo-правил"
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
		9)
			_audit_sudoers
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
		apt-get update &>/dev/null
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
	apt) apt-get update &>/dev/null ;;
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
		_crowdsec_collections
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
	_crowdsec_collections
	cscli version 2>/dev/null || true
}

# Без коллекции sshd движок работает, но SSH-атаки не видит.
_crowdsec_collections() {
	command -v cscli &>/dev/null || return 0
	if cscli collections list 2>/dev/null | grep -q "crowdsecurity/sshd"; then
		log_ok "CrowdSec: коллекция crowdsecurity/sshd установлена"
		return 0
	fi
	log_info "CrowdSec: ставлю коллекцию crowdsecurity/sshd..."
	if cscli collections install crowdsecurity/sshd &>>"$LOG_FILE"; then
		systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
		log_ok "CrowdSec: коллекция crowdsecurity/sshd установлена"
	else
		log_warn "Не удалось поставить crowdsecurity/sshd (нет сети?) — вручную: cscli collections install crowdsecurity/sshd"
	fi
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
	_ssh_port_refresh
	local sp=$CURRENT_SSH_PORT

	# на firewalld-системах iptables-banaction конфликтует — банить через firewalld+ipset
	local banaction=""
	[[ "$(_fw_cmd)" == firewalld ]] && banaction="banaction = firewallcmd-ipset"

	# Fail2Ban с systemd-journal требует python3-systemd (на Debian не в
	# зависимостях), а polling требует живого /var/log/auth.log (нет без rsyslog).
	# Если нет ни того, ни другого — jail не стартует и падает весь сервис,
	# поэтому лучше честно отключить jail, чем оставить молча мёртвый fail2ban.
	local sshd_jail=""
	local has_journal=false
	dpkg -s python3-systemd &>/dev/null 2>&1 || rpm -q python3-systemd &>/dev/null 2>&1 || pkg_install_retry "python3-systemd" || true
	if dpkg -s python3-systemd &>/dev/null 2>&1 || rpm -q python3-systemd &>/dev/null 2>&1; then
		has_journal=true
	fi
	if $has_journal; then
		sshd_jail="enabled = true
port = $sp
backend = systemd
maxretry = 3
bantime = 24h"
	elif [[ -e /var/log/auth.log ]]; then
		sshd_jail="enabled = true
port = $sp
logpath = %(sshd_log)s
backend = polling
maxretry = 3
bantime = 24h"
		log_info "python3-systemd нет — Fail2Ban читает /var/log/auth.log напрямую"
	else
		log_warn "Нет python3-systemd и нет /var/log/auth.log — jail SSH отключён"
		log_warn "  включить: apt-get install python3-systemd  (или rsyslog)"
	fi

	{
		cat <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
${banaction}

[sshd]
EOF
		[[ -n "$sshd_jail" ]] && echo "$sshd_jail"
	} >"$f2b_jail"

	systemctl enable fail2ban 2>/dev/null || true
	systemctl restart fail2ban 2>/dev/null || true
	sleep 2
	if systemctl is-active --quiet fail2ban; then
		if [[ -n "$sshd_jail" ]]; then
			log_ok "Fail2Ban запущен (SSH: порт $sp, 3 попытки → бан 24ч)"
		else
			log_warn "Fail2Ban запущен, но SSH не защищён — см. предупреждение выше"
		fi
	else
		log_warn "Fail2Ban не запустился: systemctl status fail2ban"
	fi
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 10: DNS
# ═══════════════════════════════════════════════════════════════════

# Кто владеет DNS: systemd-resolved или сам файл /etc/resolv.conf.
# Прямая запись в файл на resolved-системах бесполезна: он симлинк на stub,
# а перегенерация затрёт ручные nameserver при следующем boot.
_dns_backend() {
	if command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		echo resolved
	elif command -v netplan &>/dev/null; then
		# только бинарь: каталог /etc/netplan есть и там, где netplan не используется
		echo netplan
	elif [[ -L /etc/resolv.conf ]]; then
		echo symlink
	else
		echo file
	fi
}

_dns_current() {
	local b
	b=$(_dns_backend)
	if [[ "$b" == resolved ]]; then
		resolvectl dns 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u
	else
		grep "^nameserver" /etc/resolv.conf 2>/dev/null | awk '{print $2}'
	fi
}

_dns_apply() {
	local servers="$1" b
	b=$(_dns_backend)
	case "$b" in
	resolved)
		local dir="/etc/systemd/resolved.conf.d"
		mkdir -p "$dir"
		backup_file "$dir/10-seq-vps.conf" "stage10_dns"
		{
			echo "# 4script"
			echo "[Resolve]"
			echo "DNS=$servers"
		} >"$dir/10-seq-vps.conf"
		systemctl restart systemd-resolved 2>/dev/null || log_warn "systemd-resolved не перезапустился"
		log_ok "DNS через systemd-resolved: $servers"
		;;
	netplan)
		log_warn "DNS управляется netplan — правка /etc/resolv.conf будет затёрта при boot"
		log_info "Задайте nameservers в /etc/netplan/*.yaml и выполните: netplan apply"
		;;
	*)
		backup_file "/etc/resolv.conf" "stage10_dns"
		{
			echo "# 4script"
			local s
			for s in $servers; do echo "nameserver $s"; done
		} >/etc/resolv.conf
		log_ok "DNS записаны в /etc/resolv.conf"
		;;
	esac
}

stage_dns() {
	stage_banner "$ICON_GLOBE" "10" "Настройка DNS"

	local b
	b=$(_dns_backend)
	echo -e "${C_BOLD}Текущие DNS:${C_RESET}"
	local cur
	cur=$(_dns_current)
	[[ -n "$cur" ]] && echo "$cur" | sed 's/^/  /' || echo -e "  ${C_DIM}(нет)${C_RESET}"
	echo -e "  ${C_DIM}Управление: $b${C_RESET}"

	echo ""
	echo "  1) Заменить    3) Пропустить"
	read -rp "  ${ICON_ARROW} " da
	case "$da" in
	1)
		read -rp "  Серверы (через пробел): " srv
		[[ -n "$srv" ]] || {
			log_err "Пустой список"
			return 1
		}
		_dns_apply "$srv"
		;;
	*) log_info "Пропущено" ;;
	esac
	echo ""
	_dns_current | sed 's/^/  /'
	update_stage_status "stage10_dns" "completed"
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

	while IFS=' ' read -r _fs _size _used _avail pct mount; do
		[[ "$pct" =~ ^[0-9]+%$ ]] || continue
		local pct_n=${pct%\%}
		if [[ $pct_n -ge 90 ]]; then
			echo -e "  ${C_RED}${ICON_WARN}  КРИТИЧЕСКИ: $mount заполнен на $pct${C_RESET}"
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
# BBR отключён (4script)
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
# BBR congestion control (4script)
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
#  ЭТАП 16: ХАРДЕНИНГ ЯДРА (SYSCTL)
# ═══════════════════════════════════════════════════════════════════

# name|рекомендуемое|что даёт
# Значения собраны из актуальных чек-листов (CIS, kernel-hardening):
# защита от чтения адресов ядра (обход KASLR), info-leak через dmesg,
# дампы setuid-программ, спуфинг адресов источника, MITM через ICMP-redirect,
# hardlink/symlink-атаки в /tmp, повышение прав через user namespaces.
readonly SYSCTL_HARDENING=(
	"fs.suid_dumpable|0|запрет core-дампов setuid-программ"
	"kernel.kptr_restrict|2|скрытие адресов символов ядра от непривилегированных"
	"kernel.dmesg_restrict|1|dmesg только для root"
	"fs.protected_hardlinks|1|защита от hardlink-атак в world-writable каталогах"
	"fs.protected_symlinks|1|защита от symlink-атак"
	"fs.protected_regular|2|запрет открывать чужие файлы в sticky-каталогах на запись"
	"kernel.yama.ptrace_scope|1|ptrace только у своих потомков"
	"kernel.unprivileged_bpf_disabled|2|eBPF только для root"
	"net.ipv4.conf.all.accept_redirects|0|отклонять ICMP-redirect (MITM)"
	"net.ipv4.conf.all.send_redirects|0|не отправлять ICMP-redirect"
	"net.ipv4.conf.all.accept_source_route|0|отклонять source-routing"
	"net.ipv6.conf.all.accept_redirects|0|то же для IPv6"
	"net.ipv6.conf.all.accept_source_route|0|то же для IPv6"
	"net.ipv4.tcp_syncookies|1|защита от SYN-flood"
	"net.ipv4.conf.all.log_martians|1|логировать пакеты с невозможными адресами"
	"net.ipv4.conf.all.rp_filter|1|фильтрация по обратному пути (антиспуфинг)"
	"net.ipv4.icmp_echo_ignore_broadcasts|1|игнорировать broadcast-ICMP"
)

_sysctl_conf() { printf '%s' "/etc/sysctl.d/99-seq-vps.conf"; }

# Применяет только те значения, которые вообще существуют на этом ядре
# (например, kernel.yama есть не везде, а unprivileged_userns_clone — только в Debian/Ubuntu)
stage_sysctl() {
	stage_banner "🧩" "16" "Харденинг ядра (sysctl)"

	echo -e "${C_BOLD}▸ Рекомендуемые параметры:${C_RESET}"
	local def name want why cur mark
	local to_apply=()
	for def in "${SYSCTL_HARDENING[@]}"; do
		IFS='|' read -r name want why <<<"$def"
		cur=$(sysctl -n "$name" 2>/dev/null) || cur=""
		if [[ -z "$cur" ]]; then
			printf '  %b%-40s%b %s\n' "${C_DIM}" "$name" "${C_RESET}" "нет на этом ядре — пропуск"
			continue
		fi
		if [[ "$cur" == "$want" ]]; then
			printf '  ${C_GREEN}%s${C_RESET} %-40s ${C_GREEN}%s${C_RESET} %s\n' "$ICON_OK" "$name" "$cur" "$why"
		else
			printf '  ${C_YELLOW}%s${C_RESET} %-40s ${C_YELLOW}%s${C_RESET} → ${C_GREEN}%s${C_RESET}\n' "$ICON_WARN" "$name" "$cur" "$want"
			to_apply+=("$name=$want")
		fi
	done

	echo ""
	if [[ ${#to_apply[@]} -eq 0 ]]; then
		log_ok "Все рекомендуемые параметры уже выставлены"
		update_stage_status "stage16_sysctl" "completed"
		return 0
	fi

	echo -e "  ${C_DIM}Будет изменено параметров: ${#to_apply[@]}${C_RESET}"
	echo -e "  ${C_DIM}Файл: $(_sysctl_conf) (откат — через этап R или удаление файла)${C_RESET}"
	confirm "Применить?" || {
		log_info "Пропущено"
		return 0
	}

	local conf
	conf=$(_sysctl_conf)
	backup_file "$conf" "stage16_sysctl"

	# Пишем полный снимок ВСЕХ действующих рекомендаций, а не только тех,
	# что меняются сейчас: иначе файл превращается в огрызок — при первом
	# применении выставил 17 параметров, а при повторном прогоне остался один,
	# и все остальные значения после перезагрузки откатились бы.
	{
		echo "# 4script: харденинг ядра (набор целиком, идемпотентно)"
		for def in "${SYSCTL_HARDENING[@]}"; do
			IFS='|' read -r name want _ <<<"$def"
			[[ -n "$(sysctl -n "$name" 2>/dev/null)" ]] || continue
			printf '%s = %s\n' "$name" "$want"
		done
	} >"$conf"

	# Применяем и проверяем каждый параметр: sysctl -p не сообщает, что не применилось
	local applied=0 failed=()
	while read -r name want; do
		sysctl -q -w "$name=$want" 2>/dev/null || true
		cur=$(sysctl -n "$name" 2>/dev/null)
		if [[ "$cur" == "$want" ]]; then
			applied=$((applied + 1))
		else
			failed+=("$name (сейчас $cur, надо $want)")
		fi
	done < <(printf '%s\n' "${to_apply[@]}" | tr ' ' '\n' | sed 's/=/ /')

	log_ok "Применено параметров: $applied из ${#to_apply[@]}"
	if [[ ${#failed[@]} -gt 0 ]]; then
		log_warn "Не применились (обычно locked значением в /proc от ядра или контейнера):"
		for f in "${failed[@]}"; do echo -e "    ${C_DIM}$f${C_RESET}"; done
		log_info "Файл записан — значения применятся при следующей загрузке, если ядро позволит"
		update_stage_status "stage16_sysctl" "failed"
		return 1
	fi

	update_stage_status "stage16_sysctl" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 17: АУДИТ (только чтение, ничего не меняет)
# ═══════════════════════════════════════════════════════════════════

# Что слушает наружу, какие учётки опасны, какие файлы дают root и в каком
# состоянии LSM. Всё только читается — этап безопасно запускать на живом сервере.
stage_audit() {
	stage_banner "🔎" "17" "Аудит: порты, учётки, SUID, LSM"

	# ── Прослушиваемые порты ──
	echo -e "${C_BOLD}▸ Слушают порты:${C_RESET}"
	if command -v ss &>/dev/null; then
		ss -tulpn 2>/dev/null | awk 'NR==1 || $1 == "tcp" || $1 == "udp"' | head -25 | sed 's/^/  /'
	else
		echo -e "  ${C_DIM}ss не найден${C_RESET}"
	fi

	# Порты, открытые в фаерволе, для сопоставления
	local fw_list=""
	if [[ "$(_fw_cmd)" == firewalld ]] && command -v firewall-cmd &>/dev/null; then
		fw_list=$(firewall-cmd --list-ports 2>/dev/null; firewall-cmd --list-services 2>/dev/null)
	elif command -v ufw &>/dev/null; then
		fw_list=$(ufw status 2>/dev/null | grep -oE '[0-9]+/(tcp|udp)')
	fi
	[[ -n "$fw_list" ]] && {
		echo ""
		echo -e "  ${C_DIM}Разрешено фаерволом: $(tr '\n' ' ' <<<"$fw_list")${C_RESET}"
	}

	# ── Учётные записи ──
	echo ""
	echo -e "${C_BOLD}▸ Учётные записи:${C_RESET}"
	local extra_root
	extra_root=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd)
	if [[ -n "$extra_root" ]]; then
		echo -e "  ${C_RED}${ICON_WARN}${C_RESET}  UID 0 кроме root: $(tr '\n' ' ' <<<"$extra_root") — это второй root"
	else
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  UID 0 только у root"
	fi

	# Пустые пароли и заблокированные учётки с шеллом
	local empty_pw=() users_with_shell=0 u st
	while IFS=: read -r u _ uid _ _ _ sh; do
		[[ $uid -ge 1000 && $uid -lt 65534 ]] || continue
		[[ "$sh" == */nologin || "$sh" == */false ]] && continue
		users_with_shell=$((users_with_shell + 1))
		st=$(passwd -S "$u" 2>/dev/null | awk '{print $2}')
		# NP = no password; L = locked
		[[ "$st" == "NP" ]] && empty_pw+=("$u")
	done </etc/passwd
	if [[ ${#empty_pw[@]} -gt 0 ]]; then
		echo -e "  ${C_RED}${ICON_WARN}${C_RESET}  Без пароля, но с шеллом: ${empty_pw[*]}"
	else
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  Учёток без пароля с шеллом нет (проверено: $users_with_shell)"
	fi

	# Пользователи с sudo
	local sudoers_list
	sudoers_list=$(getent group "$SUDO_GROUP" 2>/dev/null | cut -d: -f4)
	echo -e "  ${C_DIM}В группе $SUDO_GROUP: ${sudoers_list:-—}${C_RESET}"

	# ── SUID/SGID ──
	echo ""
	echo -e "${C_BOLD}▸ Файлы с SUID/SGID (дают root при ошибке в них):${C_RESET}"
	local suid_files
	suid_files=$(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | sort)
	if [[ -n "$suid_files" ]]; then
		local cnt
		cnt=$(wc -l <<<"$suid_files")
		echo "$suid_files" | sed 's/^/  /' | head -25
		[[ $cnt -gt 25 ]] && echo -e "  ${C_DIM}… всего $cnt${C_RESET}"
	else
		echo -e "  ${C_DIM}не найдено${C_RESET}"
	fi

	# ── Мир-записываемые файлы вне /tmp ──
	local ww
	ww=$(find /etc /usr /var -xdev -type f -perm -0002 2>/dev/null | head -15)
	if [[ -n "$ww" ]]; then
		echo ""
		echo -e "${C_BOLD}▸ Файлы, доступные на запись всем (вне /tmp):${C_RESET}"
		echo "$ww" | sed 's/^/  /'
	fi

	# ── LSM / целостность ──
	echo ""
	echo -e "${C_BOLD}▸ Защита ядра и целостность:${C_RESET}"
	if [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  SELinux: Enforcing"
	elif command -v aa-status &>/dev/null; then
		local aa
		aa=$(aa-status 2>/dev/null | grep -E 'profiles are loaded|profiles are in enforce|profiles are in complain' | tr '\n' ' ')
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  AppArmor: ${aa:-активен}"
	else
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  LSM (SELinux/AppArmor) не обнаружен"
	fi

	local tr_inst=false
	command -v rkhunter &>/dev/null && tr_inst=true || true
	command -v aide &>/dev/null && tr_inst=true || true
	$tr_inst || echo -e "  ${C_DIM}Проверки целостности (rkhunter/aide) не установлены${C_RESET}"

	if [[ "$PKG_MGR" == apt ]] && command -v debsums &>/dev/null; then
		local changed
		changed=$(debsums -s 2>/dev/null | head -10)
		[[ -n "$changed" ]] && {
			echo ""
			echo -e "${C_BOLD}▸ Изменённые файлы пакетов (debsums):${C_RESET}"
			echo "$changed" | sed 's/^/  /'
		}
	fi

	echo ""
	echo -e "  ${C_DIM}Этап только читает систему — ничего не изменено.${C_RESET}"
	read -rp "  Enter..." _
	update_stage_status "stage17_audit" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 18: ПАРОЛИ И БЛОКИРОВКА УЧЁТОК (PAM)
# ═══════════════════════════════════════════════════════════════════

# pam_faillock блокирует учётку после N неудач (локальный аналог fail2ban,
# который банит адрес, а не аккаунт). pam_pwquality требует сложные пароли.
# Оба модуля меняют аутентификацию, поэтому здесь строгий порядок:
# бэкап → правка → проверка, что вход реально работает → иначе авто-откат.
_pam_faillock_active() {
	grep -qE '^[^#]*pam_faillock\.so' /etc/pam.d/common-auth 2>/dev/null
}

_pam_pwquality_active() {
	grep -qE '^[^#]*pam_pwquality\.so' /etc/pam.d/common-password 2>/dev/null
}

# Проверка, что изменение PAM не сломало аутентификацию:
# pam_faillock/pwquality должны хотя бы загружаться
_pam_sanity() {
	local f
	for f in /etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password; do
		[[ -f "$f" ]] || continue
		[[ -r "$f" ]] || return 1
		done
	# pam_faillock хранит счётчики в /var/run/faillock — каталог должен создаваться
	return 0
}

stage_pam() {
	stage_banner "🔐" "18" "Пароли и блокировка учёток (PAM)"

	if [[ "$PKG_MGR" != apt ]]; then
		log_warn "Этап реализован для Debian/Ubuntu (pam_faillock через common-auth)"
		log_info "RHEL-семейство: authselect select sssd with-faillock"
		update_stage_status "stage18_pam" "skipped"
		return 0
	fi

	local fl=false pq=false
	_pam_faillock_active && fl=true
	_pam_pwquality_active && pq=true

	echo -e "${C_BOLD}▸ Текущее состояние:${C_RESET}"
	$fl && echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  pam_faillock: включён (блокировка учётки после неудач)" ||
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  pam_faillock: выключен"
	if command -v pam_pwquality.so >/dev/null 2>&1 || ls /usr/lib/*/security/pam_pwquality.so &>/dev/null; then
		$pq && echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  pam_pwquality: включён" ||
			echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  pam_pwquality: выключен"
	else
		echo -e "  ${C_DIM}pam_pwquality не установлен (пакет libpam-pwquality)${C_RESET}"
	fi

	# Текущие настройки faillock
	if [[ -f /etc/security/faillock.conf ]]; then
		local deny unlock
		deny=$(awk -F= '/^[[:space:]]*deny[[:space:]]*=/ {gsub(/ /,"",$2); print $2}' /etc/security/faillock.conf)
		unlock=$(awk -F= '/^[[:space:]]*unlock_time[[:space:]]*=/ {gsub(/ /,"",$2); print $2}' /etc/security/faillock.conf)
		echo -e "  ${C_DIM}faillock.conf: deny=${deny:-не задан} unlock_time=${unlock:-не задан}${C_RESET}"
	fi

	echo ""
	echo "  1) Включить блокировку после неудачных попыток (pam_faillock)"
	echo "  2) Требовать сложные пароли (pam_pwquality)"
	echo "  3) Выключить pam_faillock"
	echo "  S) Назад"
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1) _pam_enable_faillock ;;
	2) _pam_enable_pwquality ;;
	3) _pam_disable_faillock ;;
	*) log_info "Пропущено" ;;
	esac

	update_stage_status "stage18_pam" "completed"
}

# prepend-строка в common-auth: pam_faillock должен считаться ДО pam_unix
_pam_enable_faillock() {
	local deny="${1:-5}" unlock="${2:-900}"

	if _pam_faillock_active; then
		log_info "pam_faillock уже включён — обновляю лимиты"
	else
		backup_file "/etc/pam.d/common-auth" "stage18_pam"
	fi
	backup_file "/etc/pam.d/common-account" "stage18_pam"
	backup_file "/etc/security/faillock.conf" "stage18_pam"

	# Политика
	if [[ ! -f /etc/security/faillock.conf ]]; then
		: >/etc/security/faillock.conf
	fi
	# правим только свои строки внутри файла
	if grep -q "^$OWN_MARK" /etc/security/faillock.conf 2>/dev/null; then
		sed -i "/^$OWN_MARK/,+3d" /etc/security/faillock.conf
	fi
	{
		echo "$OWN_MARK: блокировка после $deny неудач на $unlock сек"
		echo "deny = $deny"
		echo "unlock_time = $unlock"
		echo "$OWN_MARK: конец блока"
	} >>/etc/security/faillock.conf

	# auth: preauth + authfail вокруг pam_unix
	# account: счётчик ведётся при входе (строка preauth в account)
	if ! grep -q "$OWN_MARK_PAM preauth" /etc/pam.d/common-auth 2>/dev/null; then
		local tmp
		tmp=$(mktemp)
		{
			echo "$OWN_MARK faillock preauth (проверка блокировки до пароля)"
			echo "auth	required			pam_faillock.so preauth"
			echo "$OWN_MARK faillock authfail (счетчик неудач)"
			echo "auth	[default=die]		pam_faillock.so authfail"
		} >"$tmp"
		cat /etc/pam.d/common-auth >>"$tmp"
		mv "$tmp" /etc/pam.d/common-auth
	fi
	if ! grep -q "$OWN_MARK_PAM account" /etc/pam.d/common-account 2>/dev/null; then
		local tmp
		tmp=$(mktemp)
		{
			echo "$OWN_MARK faillock account (счётчик неудач при входе)"
			echo "account	required		pam_faillock.so"
		} >"$tmp"
		cat /etc/pam.d/common-account >>"$tmp"
		mv "$tmp" /etc/pam.d/common-account
	fi

	if ! _pam_sanity; then
		log_err "PAM повреждён — восстанавливаю из бэкапа"
		_pam_restore
		update_stage_status "stage18_pam" "failed"
		return 1
	fi

	log_ok "pam_faillock включён: $deny попыток → блокировка на $((unlock / 60)) мин"
	log_info "Разблокировать: faillock --user <имя> --reset"
	echo -e "  ${C_YELLOW}${ICON_WARN}  Проверь вход в НОВОМ окне, не закрывая текущую сессию!${C_RESET}"
}

_pam_disable_faillock() {
	_pam_faillock_active || {
		log_info "pam_faillock уже выключен"
		return 0
	}
	backup_file "/etc/pam.d/common-auth" "stage18_pam"
	backup_file "/etc/pam.d/common-account" "stage18_pam"
	sed -i "/pam_faillock\.so/d; /$OWN_MARK_PAM/d" /etc/pam.d/common-auth /etc/pam.d/common-account
	log_ok "pam_faillock выключен (счётчики в /var/run/faillock можно удалить)"
}

_pam_enable_pwquality() {
	if ! ls /usr/lib/*/security/pam_pwquality.so &>/dev/null; then
		log_info "Устанавливаю libpam-pwquality..."
		pkg_install_retry "libpam-pwquality" || {
			log_err "Пакет libpam-pwquality недоступен"
			return 1
		}
	fi
	backup_file "/etc/pam.d/common-password" "stage18_pam"
	backup_file "/etc/security/pwquality.conf" "stage18_pam"

	# pam_pwquality вызывается из pam_unix через „nullok“ — проще включить
	# отдельной строкой перед pam_unix и задать политику в pwquality.conf.
	if ! _pam_pwquality_active; then
		local tmp
		tmp=$(mktemp)
		{
			echo "$OWN_MARK pwquality"
			echo "password	requisite		pam_pwquality.so retry=3"
		} >"$tmp"
		cat /etc/pam.d/common-password >>"$tmp"
		mv "$tmp" /etc/pam.d/common-password
	fi

	if [[ ! -f /etc/security/pwquality.conf ]]; then : >/etc/security/pwquality.conf; fi
	if grep -q "^$OWN_MARK" /etc/security/pwquality.conf 2>/dev/null; then
		sed -i "/^$OWN_MARK/,+5d" /etc/security/pwquality.conf
	fi
	{
		echo "$OWN_MARK: требования к паролям"
		echo "minlen = 12"
		echo "dcredit = -1"
		echo "ucredit = -1"
		echo "lcredit = -1"
		echo "ocredit = -1"
	} >>/etc/security/pwquality.conf

	if ! _pam_sanity; then
		log_err "PAM повреждён — восстанавливаю из бэкапа"
		_pam_restore
		update_stage_status "stage18_pam" "failed"
		return 1
	fi
	log_ok "pam_pwquality включён: мин. длина 12 + цифра/строчная/прописная/символ"
	log_warn "Проверь смену пароля в НОВОМ окне — политика применяется и к root"
}

# Откат PAM-правок до последнего бэкапа (используется, если проверка не прошла)
_pam_restore() {
	local bdir cand
	for cand in $(find "${DATA_DIR}/backups" -maxdepth 2 -type d -name "stage18_pam" 2>/dev/null | sort -r); do
		bdir="$cand"
		break
	done
	[[ -n "$bdir" ]] || {
		log_err "Бэкапов PAM нет — правьте /etc/pam.d вручную"
		return 1
	}
	local bf bn
	for bf in "$bdir"/*; do
		[[ -f "$bf" ]] || continue
		bn=$(basename "$bf")
		case "$bn" in
		common-auth) cp -a "$bf" /etc/pam.d/common-auth ;;
		common-account) cp -a "$bf" /etc/pam.d/common-account ;;
		common-password) cp -a "$bf" /etc/pam.d/common-password ;;
		faillock.conf) cp -a "$bf" /etc/security/faillock.conf ;;
		pwquality.conf) cp -a "$bf" /etc/security/pwquality.conf ;;
		esac
		done
	log_ok "PAM восстановлен из $bdir"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 19: АУДИТ СОБЫТИЙ (auditd)
# ═══════════════════════════════════════════════════════════════════

# Без аудиторского следа разбор инцидента невозможен: видно, кто менял
# /etc/passwd и sudoers, кто запускал команды от root, загрузку модулей.
stage_auditd() {
	stage_banner "📋" "19" "Аудит событий (auditd)"

	if ! command -v auditctl &>/dev/null; then
		log_info "auditd не установлен — устанавливаю..."
		pkg_install_retry "auditd" || {
			update_stage_status "stage19_auditd" "failed"
			return 1
		}
	fi

	local rules_dir="/etc/audit/rules.d"
	local rules="$rules_dir/99-seq-vps.rules"
	mkdir -p "$rules_dir"

	echo -e "${C_BOLD}▸ Текущее состояние:${C_RESET}"
	if systemctl is-active --quiet auditd 2>/dev/null; then
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  auditd запущен"
	else
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  auditd не запущен"
	fi
	local cur_rules
	cur_rules=$(auditctl -l 2>/dev/null | grep -c . || true)
	echo -e "  ${C_DIM}активных правил сейчас: ${cur_rules:-0}${C_RESET}"
	[[ -f "$rules" ]] && echo -e "  ${C_DIM}файл 4script: есть${C_RESET}" || echo -e "  ${C_DIM}файл 4script: нет${C_RESET}"

	echo ""
	echo -e "  ${C_BOLD}Правила, которые будут добавлены:${C_RESET}"
	echo "    - изменения /etc/passwd, /etc/shadow, /etc/group, /etc/sudoers*"
	echo "    - изменения SSH-конфигов и authorized_keys"
	echo "    - команды от имени root (execve с euid=0)"
	echo "    - загрузка/выгрузка модулей ядра"
	echo "    - изменения времени (timedatectl/settimeofday)"
	echo "    - монтирования"
	echo ""
	confirm "Применить правила?" || {
		log_info "Пропущено"
		return 0
	}

	backup_file "$rules" "stage19_auditd"
	cat >"$rules" <<'EOF'
# 4script: базовый аудит — ключевые файлы, root-команды, модули ядра
# Просмотр: ausearch -k <ключ>   |   aureport --summary

# Идентификация и полномочия
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Вход по SSH и ключи
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Команды от root (потенциальная эскалация)
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands
-a always,exit -F arch=b32 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands

# Модули ядра
-w /sbin/insmod -p x -k modules
-w /sbin/rmmod -p x -k modules
-w /sbin/modprobe -p x -k modules
-a always,exit -F arch=b64 -S init_module,delete_module -k modules

# Время и монтирование
-a always,exit -F arch=b64 -S settimeofday,clock_settime -k time_change
-a always,exit -F arch=b64 -S mount -k mounts

# Файловая система: делать неизменяемым после загрузки правил
-e 2
EOF

	# Догрузка правил: augenrules собирает rules.d/*.rules в audit.rules
	if command -v augenrules &>/dev/null; then
		augenrules --load &>>"$LOG_FILE" || log_warn "augenrules --load сообщил об ошибке (см. лог)"
	else
		log_warn "augenrules не найден — правила применятся после перезагрузки"
	fi

	systemctl enable auditd 2>/dev/null || true
	systemctl restart auditd 2>/dev/null || systemctl start auditd 2>/dev/null || true
	sleep 2

	local active now_rules
	active=false
	systemctl is-active --quiet auditd && active=true
	now_rules=$(auditctl -l 2>/dev/null | grep -c . || true)

	if ! $active; then
		# Частая причина в контейнерах (LXC/OpenVZ/Docker): нет прав на
		# cap_sys_nice/аудит, и auditd падает при старте. Сообщаем точно.
		local why=""
		if journalctl -u auditd -n 20 --no-pager 2>/dev/null | grep -qi 'Cannot change priority\|Operation not permitted'; then
			why="контейнер не даёт прав на аудит (нет cap_sys_nice/audit_control)"
		else
			why="смотрите: systemctl status auditd"
		fi
		log_err "auditd не запустился: $why"
		log_info "Правила остались в $rules — на хосте (или в VM) они заведутся"
		# не оставляем неработающий сервис в цикле перезапусков
		systemctl reset-failed auditd 2>/dev/null || true
		update_stage_status "stage19_auditd" "failed"
		return 1
	fi
	log_ok "auditd запущен, правил: ${now_rules:-0}"

	# Проверяем, что правило действительно работает: трогаем файл из-под аудита
	if command -v ausearch &>/dev/null && auditctl -l 2>/dev/null | grep -q 'key=identity'; then
		log_info "Проверка правила: меняю /etc/group (временная запись) и ищу след..."
		local before after
		before=$(ausearch -k identity -ts recent 2>/dev/null | grep -c 'type=' || true)
		groupadd seq_audit_probe 2>/dev/null || true
		groupdel seq_audit_probe 2>/dev/null || true
		sleep 1
		after=$(ausearch -k identity -ts recent 2>/dev/null | grep -c 'type=' || true)
		if [[ "${after:-0}" -gt "${before:-0}" ]]; then
			log_ok "Аудит фиксирует события (/etc/group: было $before записей, стало $after)"
		else
			log_info "Новых записей не видно — проверьте: ausearch -k identity -ts recent"
		fi
	fi

	echo ""
	echo -e "  ${C_DIM}Посмотреть события: ausearch -k identity${C_RESET}"
	echo -e "  ${C_DIM}Сводка:            aureport --summary${C_RESET}"
	echo -e "  ${C_DIM}Отчёты по входу:   aureport -l${C_RESET}"
	echo -e "  ${C_YELLOW}${ICON_WARN}  Локальные логи root может очистить — для продакшена настройте
  отправку на внешний syslog (rsyslog/vector/journald upload).${C_RESET}"

	update_stage_status "stage19_auditd" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 20: IPv6 — ВКЛЮЧИТЬ ИЛИ ОТКЛЮЧИТЬ
# ═══════════════════════════════════════════════════════════════════

# IPv6 не нужен на сервере без AAAA-записи, но его наличие расширяет
# поверхность атаки и ломает часть правил фаервола, если тот настроен
# только для IPv4. Отключение делается через sysctl (переживает перезагрузку)
# и, где есть GRUB, через параметр ядра — sysctl достаточно на практике.
_ipv6_conf() { printf '%s' "/etc/sysctl.d/98-4script-ipv6.conf"; }

_ipv6_disabled_now() {
	[[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]]
}

# Считает адреса и слушающие IPv6-сокеты — это то, что реально видно снаружи
_ipv6_state() {
	_ipv6_addrs=$(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6' || true)
	_ipv6_listen=$(ss -tln 2>/dev/null | grep -c '\[::\]' || true)
	_ipv6_conn=$(ss -tn 2>/dev/null | grep -cE '\[::[0-9a-f:]*\]:' || true)
}

# Живые интерфейсы с поддержкой IPv6. Исключаем all/default и транзитные
# записи вида eth0@if5; точки в именах (eth0.100) допустимы.
_ipv6_live_ifaces() {
	local f name
	for f in /proc/sys/net/ipv6/conf/*; do
		[[ -d "$f" ]] || continue
		name=$(basename "$f")
		case "$name" in
		all | default | *@*) continue ;;
		esac
		printf '%s\n' "$name"
	done
}

# Активная сессия по IPv6 — отключение IPv6 оборвёт её насмерть
# (человек потеряет доступ и вернётся только через консоль провайдера).
_ipv6_session_risk() {
	local conn="${SSH_CONNECTION:-}"
	[[ -n "$conn" ]] || return 1
	[[ "${conn%% *}" == *:* ]]
}

stage_ipv6() {
	stage_banner "$ICON_GLOBE" "20" "IPv6: включить или отключить"

	local cur
	cur=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
	_ipv6_state

	echo -e "${C_BOLD}▸ Сейчас:${C_RESET}"
	if _ipv6_disabled_now; then
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  IPv6: отключён (net.ipv6.conf.all.disable_ipv6=$cur)"
	else
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  IPv6: включён"
	fi
	echo -e "  глобальных адресов: $_ipv6_addrs   слушающих IPv6-сокетов: $_ipv6_listen"
	[[ -f "$(_ipv6_conf)" ]] && echo -e "  ${C_DIM}файл 4script: $(_ipv6_conf)${C_RESET}" || echo -e "  ${C_DIM}файл 4script: нет${C_RESET}"

	if _ipv6_session_risk; then
		echo ""
		log_warn "Текущая SSH-сессия идёт по IPv6 (${SSH_CONNECTION%% *})"
		log_warn "Отключение IPv6 оборвёт её немедленно — доступ понадобится восстанавливать из консоли"
	fi

	echo ""
	echo "  1) Отключить IPv6"
	echo "  2) Включить IPv6"
	echo "  S) Назад"
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1) _ipv6_disable ;;
	2) _ipv6_enable ;;
	*) log_info "Пропущено" ;;
	esac

	update_stage_status "stage20_ipv6" "completed"
}

_ipv6_disable() {
	local conf
	conf=$(_ipv6_conf)

	if _ipv6_disabled_now; then
		log_info "IPv6 уже отключён"
		return 0
	fi

	# Предупреждения о том, что именно сломается
	echo ""
	log_warn "Отключение IPv6 влияет на:"
	echo "    - сервисы, слушающие только [::] (ss показывает такие сокеты выше)"
	echo "    - правила фаервола, привязанные к IPv6-адресам"
	echo "    - клиенты, ходящие на ваш AAAA-адрес, если он у вас есть"
	echo ""
	if _ipv6_session_risk; then
		log_err "ВНИМАНИЕ: ты в сессии по IPv6 — отключение разорвёт соединение"
	fi
	confirm "Отключить IPv6 на этом сервере?" || {
		log_info "Отменено"
		return 0
	}

	backup_file "$conf" "stage20_ipv6"
	# all + default покрывают будущие интерфейсы; disable_ipv6 по интерфейсам
	# ставить не нужно — достаточно этих двух (ядро применяет к новым)
	cat >"$conf" <<'EOF'
# 4script: IPv6 отключён
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF

	sysctl -q -p "$conf" 2>/dev/null || sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1 2>/dev/null

	# Живые интерфейсы не сбрасывают адреса сами: применяем принудительно,
	# иначе до перезагрузки IPv6 продолжит работать через уже настроенные адреса
	local iface
	while read -r iface; do
		[[ -n "$iface" ]] || continue
		sysctl -q -w "net.ipv6.conf.$iface.disable_ipv6=1" 2>/dev/null || true
	done < <(_ipv6_live_ifaces)

	sleep 1
	_ipv6_state
	if _ipv6_disabled_now && [[ "${_ipv6_addrs:-0}" -eq 0 ]]; then
		log_ok "IPv6 отключён (адресов: 0, слушающих IPv6-сокетов: ${_ipv6_listen:-0})"
		[[ "${_ipv6_listen:-0}" -gt 0 ]] && log_warn "Некоторые сервисы ещё держат IPv6-сокеты — они закроются после их перезапуска"
	else
		log_warn "Не всё применилось: disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6), адресов $_ipv6_addrs"
		log_info "Перезагрузка доведёт состояние до нужного"
	fi
}

_ipv6_enable() {
	local conf
	conf=$(_ipv6_conf)

	if ! _ipv6_disabled_now; then
		log_info "IPv6 уже включён"
		return 0
	fi

	backup_file "$conf" "stage20_ipv6"

	# Убираем свои строки и файл целиком: иначе после файл с disable_ipv6=1
	# применится снова при следующей загрузке
	if [[ -f "$conf" ]]; then
		rm -f "$conf"
		log_info "Файл $conf удалён"
	fi

	sysctl -q -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true
	local iface
	while read -r iface; do
		[[ -n "$iface" ]] || continue
		sysctl -q -w "net.ipv6.conf.$iface.disable_ipv6=0" 2>/dev/null || true
	done < <(_ipv6_live_ifaces)

	sleep 1
	_ipv6_state
	if ! _ipv6_disabled_now; then
		log_ok "IPv6 включён (глобальных адресов: ${_ipv6_addrs:-0})"
		[[ "${_ipv6_addrs:-0}" -eq 0 ]] && log_info "Адреса появятся по SLAAC/DHCPv6 или из конфигурации провайдера"
	else
		log_err "Не удалось включить IPv6 (disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6))"
	fi
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП R: ОТКАТ
# ═══════════════════════════════════════════════════════════════════

stage_rollback() {
	stage_banner "↩" "R" "Откат этапа"

	# список этапов берём из реестра — не расходится с меню
	local def num key icon title cat fn
	for def in "${STAGE_DEFS[@]}"; do
		IFS='|' read -r num key icon title cat fn <<<"$def"
		[[ -n "$key" ]] || continue
		printf '  %2s) %s\n' "$num" "$title"
	done
	echo "  ${C_DIM}Откат восстанавливает файлы этапа из последнего бэкапа.${C_RESET}"
	read -rp "  ${ICON_ARROW} " sn

	local stage=""
	def=$(stage_def "$sn") || {
		log_err "Неверный выбор"
		return 1
	}
	stage=$(cut -d'|' -f2 <<<"$def")
	[[ -n "$stage" ]] || {
		log_err "У этого этапа нет бэкапов"
		return 1
	}

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
		stage16_sysctl)
			[[ "$bn" == "99-seq-vps.conf" ]] && op="/etc/sysctl.d/99-seq-vps.conf"
			;;
		stage20_ipv6)
			[[ "$bn" == "98-4script-ipv6.conf" ]] && op="/etc/sysctl.d/98-4script-ipv6.conf"
			;;
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

# Справка по этапам прямо из меню — те же данные, что и в --help
show_stage_help() {
	local def num key icon title cat fn done_total=0 done_done=0
	echo ""
	repeat_hdr "$ICON_BULLET" "Этапы и порядок"
	local c
	for c in "${CATEGORY_ORDER[@]}"; do
		printf "  ${C_BOLD}${C_CYAN}▸ %s${C_RESET}\n" "$(category_title "$c")"
		for def in "${STAGE_DEFS[@]}"; do
			IFS='|' read -r num key icon title cat fn <<<"$def"
			[[ "$cat" == "$c" ]] || continue
			printf "   %b%-3s%b %s\n" "${C_DIM}" "$num)" "$C_RESET" "$title"
			[[ -n "$key" ]] && {
				done_total=$((done_total + 1))
				[[ "$(get_stage_status "$key")" == "completed" ]] && done_done=$((done_done + 1))
			}
		done
		echo ""
	done
	echo "  ${C_DIM}Порядок для нового сервера: 0, 1, 2, 4 → проверь вход по ключу…"
	echo "  ${C_DIM}→ 7 (фаервол) → 5 (порт и пароли) → 8, 9 → 3 (пароль root) → остальное.${C_RESET}"
	printf "  ${C_DIM}Выполнено: %d из %d этапов${C_RESET}\n" "$done_done" "$done_total"
	echo ""
	read -rp "  Enter — в меню... " _
}

main_menu() {
	while true; do
		printf '\n%.0s' {1..3}

		{
			local line pad
			printf -v line '%*s' "$TERM_WIDTH" ''
			printf "${C_BOLD}${C_CYAN}╔══ ${C_RESET}${C_BOLD}4Script${C_RESET} ${C_DIM}simple-server-security-script · v%s · %s${C_RESET}\n" "$SCRIPT_VERSION" "$DISTRO_NAME"
			pad=$((TERM_WIDTH - 4))
			((pad > 1)) && printf "${C_BOLD}${C_CYAN}╚%s${C_RESET}\n" "${line:0:pad}" | sed "s/ /═/g"
		}

		show_server_summary

		local def num key icon title cat fn c
		local cat_done cat_total done_total=0 done_done=0
		for c in "${CATEGORY_ORDER[@]}"; do
			cat_done=0
			cat_total=0
			for def in "${STAGE_DEFS[@]}"; do
				IFS='|' read -r num key icon title cat fn <<<"$def"
				[[ "$cat" == "$c" && -n "$key" ]] || continue
				cat_total=$((cat_total + 1))
				[[ "$(get_stage_status "$key")" == "completed" ]] && cat_done=$((cat_done + 1))
			done
			done_total=$((done_total + cat_total))
			done_done=$((done_done + cat_done))

			repeat_hdr "$(category_icon "$c")" "$(category_title "$c")" "$(category_color "$c")"
			[[ $cat_total -gt 0 ]] && printf "  ${C_DIM}%d из %d выполнено${C_RESET}\n" "$cat_done" "$cat_total"
			for def in "${STAGE_DEFS[@]}"; do
				IFS='|' read -r num key icon title cat fn <<<"$def"
				[[ "$cat" == "$c" ]] || continue
				menu_item "$num" "$key" "$title"
			done
			echo ""
		done

		echo -e "  ${C_YELLOW}P${C_RESET}) Настройки     ${C_YELLOW}H${C_RESET}) Справка      ${C_YELLOW}R${C_RESET}) Откат      ${C_RED}Q${C_RESET}) Выход"
		echo ""

		if [[ $done_done -gt 0 ]]; then
			printf "  Прогресс: "
			progress_bar "$done_done" "$done_total" ""
			echo ""
			echo ""
		fi

		if ! read -rp "  ${ICON_ARROW} " choice; then
			log_info "Ввод завершён"
			return 0
		fi

		case "${choice,,}" in
		p) show_profiles ;;
		h) show_stage_help ;;
		r) stage_rollback ;;
		q)
			echo ""
			log_info "Выход. Лог: ${C_DIM}$LOG_FILE${C_RESET}"
			exit 0
			;;
		*)
			if stage_def "${choice,,}" >/dev/null 2>&1; then
				run_stage "${choice,,}"
			else
				log_err "Неверный выбор"
			fi
			;;
		esac

		echo ""
		read -rp "  Enter — в меню... " _ || return 0
	done
}

# ═══════════════════════════════════════════════════════════════════
#  ТЕКУЩИЕ НАСТРОЙКИ (что именно сейчас применяется)
# ═══════════════════════════════════════════════════════════════════

# Показывает файл целиком, если он есть. Второй аргумент — заголовок.
_show_conf_file() {
	local f="$1" title="$2" lines
	printf "  ${C_BOLD}%s${C_RESET}  ${C_DIM}%s${C_RESET}\n" "$title" "$f"
	if [[ ! -f "$f" ]]; then
		echo -e "    ${C_DIM}(не создан)${C_RESET}"
		return 0
	fi
	# содержимое без комментариев, отступ, ограничение по строкам
	lines=$(grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)
	if [[ -z "$lines" ]]; then
		echo -e "    ${C_DIM}(файл есть, активных строк нет)${C_RESET}"
	else
		echo "$lines" | head -12 | sed 's/^/    /'
		local n
		n=$(wc -l <<<"$lines")
		[[ $n -gt 12 ]] && echo -e "    ${C_DIM}… ещё $((n - 12)) строк${C_RESET}"
	fi
}

# Одна строка «параметр: значение» для быстрых проверок
_show_kv() {
	printf "    %-38s %b%s%b\n" "$1" "${3:-}" "$2" "$C_RESET"
}

show_profiles() {
	printf '\n%.0s' {1..2}
	repeat_hdr "$ICON_GEAR" "Текущие настройки (что применяется сейчас)"

	# ── SSH ──
	echo ""
	echo -e "${C_BOLD}${ICON_KEY}  SSH${C_RESET}"
	_ssh_port_refresh
	local sc
	sc=$(sshd -T 2>/dev/null)
	_show_kv "Порт" "$CURRENT_SSH_PORT"
	_show_kv "Парольный вход" "$(_sshd_option "$sc" passwordauthentication yes)" \
		"$([[ "$(_sshd_option "$sc" passwordauthentication yes)" == "no" ]] && echo "$C_GREEN" || echo "$C_RED")"
	_show_kv "Keyboard-interactive" "$(_sshd_option "$sc" kbdinteractiveauthentication yes)"
	_show_kv "Вход root" "$(_sshd_option "$sc" permitrootlogin yes)"
	_show_kv "MaxAuthTries" "$(_sshd_option "$sc" maxauthtries 6)"
	_show_kv "Пустые пароли" "$(_sshd_option "$sc" permitemptypasswords no)"
	_show_kv "PerSourcePenalties" "$(_sshd_option "$sc" persourcepenalties 'нет (OpenSSH < 9.8)')"
	_show_conf_file "$SSHD_CONFIG_D/$SEQ_SSHD_DROPIN" "drop-in SSH"

	# ── Фаервол ──
	echo ""
	echo -e "${C_BOLD}${ICON_FIRE}  Фаервол ($(_fw_cmd))${C_RESET}"
	if [[ "$(_fw_cmd)" == firewalld ]]; then
		if firewall-cmd --state 2>/dev/null | grep -q running; then
			_show_kv "Состояние" "active" "$C_GREEN"
			firewall-cmd --list-ports 2>/dev/null | sed 's/^/    порты: /'
		else
			_show_kv "Состояние" "не активен" "$C_YELLOW"
		fi
	elif command -v ufw &>/dev/null; then
		if ufw status 2>/dev/null | grep -q "Status: active"; then
			_show_kv "Состояние" "active" "$C_GREEN"
			ufw status 2>/dev/null | grep -E '^[0-9]' | head -8 | sed 's/^/    /'
		else
			_show_kv "Состояние" "не активен" "$C_YELLOW"
		fi
	else
		_show_kv "Состояние" "не установлен" "$C_DIM"
	fi
	[[ -f /etc/default/ufw ]] && _show_kv "UFW IPv6" "$(grep -E '^IPV6=' /etc/default/ufw | cut -d= -f2)"

	# ── Ядро ──
	echo ""
	echo -e "${C_BOLD}🧩  Ядро (sysctl)${C_RESET}"
	_show_kv "congestion control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
	_show_kv "IPv6" "$([[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == "1" ]] && echo отключён || echo включён)"
	_show_conf_file "$(_sysctl_conf)" "харденинг"
	_show_conf_file "$(_ipv6_conf)" "IPv6"
	_show_conf_file "/etc/sysctl.d/90-bbr.conf" "BBR"

	# ── PAM / блокировки ──
	echo ""
	echo -e "${C_BOLD}🔐  Пароли и блокировки (PAM)${C_RESET}"
	if _pam_faillock_active; then
		_show_kv "pam_faillock" "включён" "$C_GREEN"
		grep -A2 "^$OWN_MARK" /etc/security/faillock.conf 2>/dev/null | grep -E 'deny|unlock_time' | sed 's/^/    /'
	else
		_show_kv "pam_faillock" "выключен" "$C_DIM"
	fi
	if _pam_pwquality_active; then
		_show_kv "pam_pwquality" "включён" "$C_GREEN"
	else
		_show_kv "pam_pwquality" "выключен" "$C_DIM"
	fi

	# ── Аудит событий ──
	echo ""
	echo -e "${C_BOLD}📋  Аудит событий (auditd)${C_RESET}"
	if systemctl is-active --quiet auditd 2>/dev/null; then
		_show_kv "auditd" "запущен, правил $(auditctl -l 2>/dev/null | grep -c .)" "$C_GREEN"
	else
		_show_kv "auditd" "не запущен" "$C_DIM"
	fi
	_show_conf_file "/etc/audit/rules.d/99-seq-vps.rules" "правила 4script"

	# ── Обновления и DNS ──
	echo ""
	echo -e "${C_BOLD}⬆  Обновления и DNS${C_RESET}"
	local au="не настроены"
	if [[ "$PKG_MGR" == apt ]] && [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]]; then
		au="unattended-upgrades: $(grep -c 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades) настроек"
	elif [[ -f /etc/dnf/automatic.conf ]]; then
		au="dnf-automatic"
	fi
	_show_kv "Автообновления" "$au"
	local rt="выключена"
	if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades-local ]]; then
		rt=$(grep -oE 'Automatic-Reboot "true"' /etc/apt/apt.conf.d/50unattended-upgrades-local &>/dev/null && echo "включена" || echo "выключена")
	fi
	_show_kv "Авто-перезагрузка" "$rt"
	_show_kv "DNS ($(_dns_backend))" "$(tr '\n' ' ' <<<"$(_dns_current)")"
	_show_conf_file "/etc/systemd/resolved.conf.d/10-seq-vps.conf" "DNS через resolved"

	# ── Где данные и что файл 4script создал ──
	echo ""
	echo -e "${C_BOLD}📁  Данные${C_RESET}"
	_show_kv "Каталог" "$DATA_DIR"
	_show_kv "Лог текущего запуска" "$LOG_FILE"
	local nconf=0 f
	for f in "$SSHD_CONFIG_D/$SEQ_SSHD_DROPIN" "$(_sysctl_conf)" "$(_ipv6_conf)" \
		/etc/systemd/resolved.conf.d/10-seq-vps.conf /etc/audit/rules.d/99-seq-vps.rules \
		/etc/fail2ban/jail.local; do
		[[ -e "$f" ]] && nconf=$((nconf + 1))
	done
	_show_kv "Файлов настроек 4script" "$nconf"

	echo ""
	echo -e "  ${C_DIM}Изменения откатываются через R (файлы этапов лежат в бэкапах).${C_RESET}"
	echo ""
	read -rp "  Enter — в меню... " _
}

# ═══════════════════════════════════════════════════════════════════
#  УДАЛЁННЫЙ РЕЖИМ
# ═══════════════════════════════════════════════════════════════════
# Смысл: запустить настройку с ноутбука против удалённого сервера.
# Пароль нужен ОДИН раз — чтобы установить SSH-ключ; дальше всё по ключу.
# Сам прогон идёт внутри screen на сервере, поэтому обрыв связи клиента
# не убивает настройку на середине этапа.

REMOTE_USER=""
REMOTE_HOST=""
REMOTE_PORT="22"
REMOTE_KEY=""
REMOTE_SESSION="4script"
REMOTE_ATTACH_ONLY=false
REMOTE_SUDO=""

_remote_ssh_opts() {
	# BatchMode только для неинтерактивных проверок; для ssh-copy-id и attach
	# он не подходит (нельзя ввести пароль).
	printf '%s\0' -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30 \
		-o ServerAliveCountMax=6 -p "$REMOTE_PORT"
	if [[ "$1" == batch ]]; then
		printf '%s\0' -o BatchMode=yes
	fi
}

_remote_target() { printf '%s@%s' "$REMOTE_USER" "$REMOTE_HOST"; }

# Парсит user@host, host, user@host:port, user@host@port (форма из запроса)
remote_parse_target() {
	local spec="$1"
	# user@host@port — третий @ отделяет порт
	if [[ "$spec" =~ ^([^@]+)@([^@]+)@([0-9]+)$ ]]; then
		REMOTE_USER="${BASH_REMATCH[1]}"
		REMOTE_HOST="${BASH_REMATCH[2]}"
		REMOTE_PORT="${BASH_REMATCH[3]}"
	elif [[ "$spec" =~ ^([^@]+)@([^:@]+):([0-9]+)$ ]]; then
		REMOTE_USER="${BASH_REMATCH[1]}"
		REMOTE_HOST="${BASH_REMATCH[2]}"
		REMOTE_PORT="${BASH_REMATCH[3]}"
	elif [[ "$spec" =~ ^([^@]+)@([^:@]+)$ ]]; then
		REMOTE_USER="${BASH_REMATCH[1]}"
		REMOTE_HOST="${BASH_REMATCH[2]}"
	elif [[ "$spec" =~ ^([^:@]+):([0-9]+)$ ]]; then
		REMOTE_HOST="${BASH_REMATCH[1]}"
		REMOTE_PORT="${BASH_REMATCH[2]}"
	elif [[ -n "$spec" ]]; then
		REMOTE_HOST="$spec"
	fi
	[[ -n "$REMOTE_USER" ]] || REMOTE_USER="root"
	# Пустая или нераспознанная спецификация не должна превращаться в адрес
	# «root@root@» — отклоняем всё, что не похоже на имя хоста.
	if [[ -z "$REMOTE_HOST" || ! "$REMOTE_HOST" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
		echo "Ошибка: не удалось разобрать адрес сервера: '${1}'" >&2
		echo "  Ожидается: [user@]host[:port] или user@host@port" >&2
		return 1
	fi
	case "$REMOTE_USER" in
	*[!A-Za-z0-9._@-]* | "")
		echo "Ошибка: неправильное имя пользователя: '${REMOTE_USER}'" >&2
		return 1
		;;
	esac
	if [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ ]] || ((REMOTE_PORT < 1 || REMOTE_PORT > 65535)); then
		echo "Ошибка: неправильный порт: ${REMOTE_PORT}" >&2
		return 1
	fi
	return 0
}

# Есть ли терминал для ввода пароля. При запуске из скрипта/CI stdin занят,
# и ssh-copy-id вместо запроса пароля пытается запустить ssh-askpass и падает
# с «No such file or directory» — непонятной ошибкой на ровном месте.
remote_have_tty() {
	[[ -c /dev/tty ]] && { exec 9<>/dev/tty; } 2>/dev/null || return 1
	exec 9>&- 2>/dev/null
	return 0
}

# Пароль спрашиваем с /dev/tty, а не со stdin: stdin может быть heredoc,
# трубой или /dev/null, и тогда ssh-copy-id не сможет запросить пароль.
remote_copy_id() {
	local pub="$1"
	if remote_have_tty; then
		ssh-copy-id -i "$pub" -p "$REMOTE_PORT" -o StrictHostKeyChecking=accept-new "$(_remote_target)" </dev/tty
	else
		log_err "Нет терминала для ввода пароля (stdin перенаправлен)"
		log_info "Варианты: запустить из интерактивного терминала, использовать уже"
		log_info "  авторизованный ключ (--key) либо добавить ключ на сервер вручную"
		return 1
	fi
}

# Проверяет, пускает ли сервер уже по ключу (без пароля)
remote_key_auth_works() {
	local -a opts=()
	while IFS= read -r -d '' o; do opts+=("$o"); done < <(_remote_ssh_opts batch)
	local -a ka=()
	[[ -n "$REMOTE_KEY" ]] && ka=(-i "$REMOTE_KEY" -o IdentitiesOnly=yes)
	ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" 'exit 0' &>/dev/null
}

remote_run_remote() { # remote_run_remote '<команда>' [interactive|pipe]
	local cmd="$1" mode="${2:-pipe}"
	local -a opts=()
	[[ "$mode" == pipe ]] && {
		while IFS= read -r -d '' o; do opts+=("$o"); done < <(_remote_ssh_opts batch)
	} || {
		while IFS= read -r -d '' o; do opts+=("$o"); done < <(_remote_ssh_opts any)
	}
	local -a ka=()
	[[ -n "$REMOTE_KEY" ]] && ka=(-i "$REMOTE_KEY" -o IdentitiesOnly=yes)
	# shellcheck disable=SC2029 # удалённая команда должна собираться на клиенте
	ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" "$cmd"
}

# Выбор ключа: список локальных публичных ключей или генерация нового
remote_pick_key() {
	local -a pubs=()
	local f
	shopt -s nullglob
	for f in "$HOME"/.ssh/*.pub; do pubs+=("$f"); done
	shopt -u nullglob

	echo ""
	echo -e "${C_BOLD}▸ SSH-ключи на этой машине:${C_RESET}"
	local i=1
	for f in "${pubs[@]:-}"; do
		[[ -n "$f" ]] || continue
		printf '  %2d) %-32s %s\n' "$i" "$(basename "$f")" "$(ssh-keygen -lf "$f" 2>/dev/null | awk '{print $1, $2}')"
		i=$((i + 1))
	done
	[[ ${#pubs[@]} -eq 0 ]] && echo -e "  ${C_DIM}(публичных ключей нет)${C_RESET}"
	echo ""
	echo "  N) сгенерировать новый ключ"
	[[ ${#pubs[@]} -gt 0 ]] && echo "  (номер) использовать существующий"
	echo "  S) отмена"
	read -rp "  ${ICON_ARROW} " ans

	case "${ans,,}" in
	n)
		local name
		read -rp "  Имя ключа [4script_ed25519]: " name
		name=${name:-4script_ed25519}
		local path="$HOME/.ssh/$name"
		[[ -e "$path" ]] && {
			log_err "Ключ $path уже существует"
			return 1
		}
		local comment
		read -rp "  Комментарий [$(whoami)@$(hostname -s)]: " comment
		comment=${comment:-$(whoami)@$(hostname -s)}
		mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
		log_info "Генерирую ed25519-ключ без парольной фразы..."
		if ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$path"; then
			REMOTE_KEY="$path"
			log_ok "Ключ создан: $path"
			log_info "Публичная часть: ${C_DIM}${path}.pub${C_RESET}"
			return 0
		fi
		log_err "Не удалось создать ключ"
		return 1
		;;
	s | "") return 1 ;;
	*)
		if [[ "$ans" =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#pubs[@]})); then
			REMOTE_KEY="${pubs[$((ans - 1))]%.pub}"
			log_ok "Выбран ключ: $REMOTE_KEY"
			return 0
		fi
		log_err "Неверный выбор"
		return 1
		;;
	esac
}

remote_bootstrap_key() {
	local pub="${REMOTE_KEY}.pub"
	[[ -f "$pub" ]] || {
		log_err "Нет публичной части: $pub"
		return 1
	}

	echo ""
	log_info "Устанавливаю ключ на сервер — пароль спросят ${C_BOLD}один раз${C_RESET} (это последний раз, когда он нужен)"
	if ! remote_copy_id "$pub"; then
		log_err "Авторизовать ключ не удалось (неверный пароль, запрет входа или закрыт порт)"
		return 1
	fi

	if remote_key_auth_works; then
		log_ok "Ключ установлен, вход по ключу работает"
		return 0
	fi
	log_err "Ключ скопирован, но вход по нему не проходит — проверь настройки sshd на сервере"
	return 1
}

# Копирует сам скрипт на сервер (и тесты не нужны: работаем одним файлом)
remote_deliver() {
	local self
	self=$(readlink -f "${BASH_SOURCE[0]}")
	local -a opts=( -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 -P "$REMOTE_PORT" )
	local -a ka=()
	[[ -n "$REMOTE_KEY" ]] && ka=(-i "$REMOTE_KEY" -o IdentitiesOnly=yes)
	log_info "Копирую скрипт на сервер..."
	scp "${opts[@]}" "${ka[@]}" "$self" "$(_remote_target):/tmp/4script.sh" || {
		log_err "Не удалось скопировать скрипт"
		return 1
	}
	log_ok "Скрипт на сервере: /tmp/4script.sh"
}

# Запуск внутри screen (чтобы обрыв клиента не убил настройку).
# Возвращает: 0 — запущено в mux, 1 — mux нет (запуск привязан к сессии).
remote_start_server_run() {
	local cmd='cd /tmp && chmod +x 4script.sh && '
	local mux=""
	if remote_run_remote 'command -v screen >/dev/null' &>/dev/null; then
		mux=screen
	elif remote_run_remote 'command -v tmux >/dev/null' &>/dev/null; then
		mux=tmux
	fi

	if [[ "$mux" == screen ]]; then
		log_info "Запускаю внутри screen (сессия $REMOTE_SESSION) — обрыв связи не прервёт настройку"
		# -d -m: сразу в фоне; остающийся pty даёт меню нормальный терминал
		remote_run_remote "screen -dmS $REMOTE_SESSION bash -c 'cd /tmp && exec bash ./4script.sh'" || return 1
		return 0
	elif [[ "$mux" == tmux ]]; then
		log_info "Запускаю внутри tmux (сессия $REMOTE_SESSION)"
		remote_run_remote "tmux new-session -d -s $REMOTE_SESSION 'cd /tmp && bash ./4script.sh'" || return 1
		return 0
	fi
	return 1
}

remote_attach() {
	local mux
	mux=$(remote_run_remote 'command -v screen >/dev/null && echo screen || (command -v tmux >/dev/null && echo tmux)')
	echo ""

	# Если сессии нет, screen/tmux ругаются «Must be connected to a terminal»,
	# и это выглядит как проблема с локальным терминалом, а не как «прогон не запущен».
	if [[ "$mux" == screen ]] && ! remote_run_remote "screen -ls 2>/dev/null | grep -qE '\\.${REMOTE_SESSION}[[:space:]]'" &>/dev/null; then
		log_err "Сессия $REMOTE_SESSION на сервере не найдена"
		log_info "Запустите настройку: bash 4script.sh --remote $(_remote_target) --key ..."
		remote_run_remote 'screen -ls 2>&1 | head -5'
		return 1
	fi
	if [[ "$mux" == tmux ]] && ! remote_run_remote "tmux has-session -t $REMOTE_SESSION" &>/dev/null; then
		log_err "Сессия $REMOTE_SESSION на сервере не найдена"
		log_info "Запустите настройку: bash 4script.sh --remote $(_remote_target) --key ..."
		return 1
	fi

	local -a opts=(-t -o StrictHostKeyChecking=accept-new -p "$REMOTE_PORT")
	local -a ka=()
	[[ -n "$REMOTE_KEY" ]] && ka=(-i "$REMOTE_KEY" -o IdentitiesOnly=yes)

	case "$mux" in
	screen)
		# -t обязателен: меню требует терминал
		log_info "Подключаюсь к screen-сессии $REMOTE_SESSION (отключиться — Ctrl-A d, выйти — Q в меню)"
		# shellcheck disable=SC2029
		ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" "screen -r $REMOTE_SESSION"
		;;
	tmux)
		log_info "Подключаюсь к tmux-сессии $REMOTE_SESSION (отключиться — Ctrl-B d)"
		# shellcheck disable=SC2029
		ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" "tmux attach -t $REMOTE_SESSION"
		;;
	*)
		log_err "На сервере нет screen и tmux — подключиться к фоновой сессии нечем"
		return 1
		;;
	esac
}

remote_usage() {
	cat <<'EOF'
Удалённый режим: настройка сервера с этой машины.

  bash 4script.sh --remote ПОЛЬЗОВАТЕЛЬ@АДРЕС[:ПОРТ] [опции]
  bash 4script.sh --remote root@192.0.2.10 --port 8484

Опции:
  --remote СПЕЦ     сервер: user@host, user@host:port, user@host@port или host
  --user ИМЯ        пользователь (если не указан в --remote), по умолчанию root
  --port ПОРТ       порт SSH (по умолчанию 22)
  --key ФАЙЛ        приватный ключ для входа (по умолчанию — подбор/ssh-agent)
  --name ИМЯ        имя сессии screen/tmux на сервере (по умолчанию 4script)
  --attach          только подключиться к уже идущей сессии
  --no-attach       запустить и не подключаться (сразу вернуть управление)

Пароль спрашивается один раз — для установки ключа (ssh-copy-id).
Дальше всё работает по ключу, пароль больше не нужен.

После запуска настройка идёт внутри screen на сервере: если связь оборвётся
или ноутбук уснёт, прогон продолжится. Вернуться:
  bash 4script.sh --remote ПОЛЬЗОВАТЕЛЬ@АДРЕС --attach
EOF
}

remote_main() {
	for t in ssh scp ssh-copy-id ssh-keygen; do
		command -v "$t" &>/dev/null || {
			log_err "Нужна утилита $t, но её нет в PATH"
			return 1
		}
	done

	echo ""
	echo -e "${C_BOLD}${C_CYAN}  Удалённая настройка: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PORT}${C_RESET}"

	# 1. Есть ли уже доступ по ключу?
	if remote_key_auth_works; then
		log_ok "Доступ по ключу уже настроен (пароль не нужен)"
	else
		log_info "Доступа по ключу пока нет — установим ключ (пароль потребуется один раз)"
		if ! remote_pick_key; then
			log_info "Отменено"
			return 1
		fi
		remote_bootstrap_key || return 1
	fi

	# 2. Кто мы на сервере: root или нам нужен sudo
	if [[ "$(remote_run_remote 'id -u')" == "0" ]]; then
		REMOTE_SUDO=""
	else
		REMOTE_SUDO="sudo"
		if ! remote_run_remote 'command -v sudo >/dev/null' &>/dev/null; then
			log_err "Пользователь не root и sudo на сервере нет"
			return 1
		fi
		log_info "Пользователь не root — запуск будет через sudo"
	fi

	if $REMOTE_ATTACH_ONLY; then
		remote_attach
		return $?
	fi

	# 3. Доставляем скрипт и запускаем
	remote_deliver || return 1
	if remote_start_server_run; then
		if $REMOTE_ATTACH; then
			remote_attach
		else
			echo ""
			log_ok "Настройка запущена на сервере (сессия $REMOTE_SESSION)"
			log_info "Подключиться: bash 4script.sh --remote $(_remote_target) --attach"
			log_info "Лог на сервере: ${C_DIM}/opt/4script/ или /opt/seq_vps/${C_RESET}"
		fi
		return 0
	fi

	# mux нет — запускаем прямо в этой сессии (обрыв прервёт настройку)
	log_warn "На сервере нет screen/tmux: запускаю напрямую — обрыв связи прервёт настройку"
	local -a opts=()
	while IFS= read -r -d '' o; do opts+=("$o"); done < <(_remote_ssh_opts any)
	local -a ka=()
	[[ -n "$REMOTE_KEY" ]] && ka=(-i "$REMOTE_KEY" -o IdentitiesOnly=yes)
	# shellcheck disable=SC2029
	ssh -t "${opts[@]}" "${ka[@]}" "$(_remote_target)" "${REMOTE_SUDO:+$REMOTE_SUDO }bash /tmp/4script.sh"
}

# ═══════════════════════════════════════════════════════════════════
#  ТОЧКА ВХОДА
# ═══════════════════════════════════════════════════════════════════

show_help() {
	echo "4Script — simple-server-security-script · v${SCRIPT_VERSION}"
	echo ""
	echo "  Комплексная настройка безопасности VPS сервера."
	echo "  Поддерживает: Debian, Ubuntu, Fedora, RHEL, CentOS, Rocky, AlmaLinux."
	echo ""
	echo "  Использование:"
	echo "    sudo ./4script.sh                     — интерактивное меню на этом сервере"
	echo "    bash ./4script.sh --remote user@host  — настроить УДАЛЁННЫЙ сервер отсюда"
	echo "    sudo ./4script.sh --help              — эта справка"
	echo "    bash ./4script.sh --remote-help       — справка по удалённому режиму"
	echo ""
	echo "  Этапы:"
	local def num key icon title cat fn c
	for c in "${CATEGORY_ORDER[@]}"; do
		echo "   $(category_title "$c"):"
		for def in "${STAGE_DEFS[@]}"; do
			IFS='|' read -r num key icon title cat fn <<<"$def"
			[[ "$cat" == "$c" ]] || continue
			printf '    %2s. %s\n' "$num" "$title"
		done
	done
	echo "     R. Откат этапа из бэкапа"
	echo ""
	echo "  Данные: $DATA_DIR/  (на обновлённых серверах сохраняется старый /opt/seq_vps/)"
	echo ""
	exit 0
}

main() {
	# ── Разбор аргументов ──
	# Удалённый режим использует только клиентские утилиты (ssh/scp/ssh-keygen),
	# поэтому до проверки root и дистрибутива.
	local remote_spec="" attach=false no_attach=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-h | --help)
			show_help
			;;
		--remote | -r)
			remote_spec="${2:-}"
			shift 2 || shift
			;;
		--remote=*)
			remote_spec="${1#*=}"
			shift
			;;
		--user)
			REMOTE_USER="${2:-}"
			shift 2 || shift
			;;
		--port | -p)
			REMOTE_PORT="${2:-}"
			shift 2 || shift
			;;
		--key)
			REMOTE_KEY="${2:-}"
			shift 2 || shift
			;;
		--name)
			REMOTE_SESSION="${2:-}"
			shift 2 || shift
			;;
		--attach)
			attach=true
			shift
			;;
		--no-attach)
			no_attach=true
			shift
			;;
		--remote-help)
			remote_usage
			exit 0
			;;
		*)
			echo "Неизвестный аргумент: $1" >&2
			echo "Справка: bash 4script.sh --help или --remote-help" >&2
			exit 2
			;;
		esac
	done

	if [[ -n "$remote_spec" ]]; then
		remote_parse_target "$remote_spec" || exit 2
		REMOTE_ATTACH_ONLY=$attach
		# по умолчанию после запуска подключаемся к сессии, кроме --no-attach
		if $no_attach; then REMOTE_ATTACH=false; else REMOTE_ATTACH=true; fi
		remote_main
		exit $?
	fi

	detect_distro
	check_root

	[[ -d "$DATA_DIR" ]] || {
		mkdir -p "$DATA_DIR"
		chmod 700 "$DATA_DIR"
	}
	init_status_file

	log_info "4Script · ${C_BOLD}$DISTRO_NAME${C_RESET}"
	log_info "Лог: ${C_DIM}$LOG_FILE${C_RESET}"
	log_info "Бэкапы: ${C_DIM}$BACKUP_DIR${C_RESET}"

	main_menu
}

# запуск только при прямом исполнении (позволяет source'ить для тестов)
[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
