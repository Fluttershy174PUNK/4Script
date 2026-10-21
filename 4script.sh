#!/bin/bash
#
# 4script.sh — 4Script: простой скрипт защиты сервера (simple-server-security-script)
# Debian/Ubuntu · Fedora/RHEL/CentOS · Rocky · AlmaLinux · Alpine
# Сервисы: systemd (systemctl) либо OpenRC (rc-service/rc-update) — определяется автоматически.
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
INIT_SYSTEM=""
HAS_SYSTEMD=false
HAS_OPENRC=false
APK_TOOLS_DONE=false
# true только если sshd собран с PAM (Alpine: пакет openssh-server-pam).
# Без него pam_faillock на SSH не действует вообще.
SSHD_HAS_PAM=false
# Пути стеков PAM: задаёт _pam_file_names (Alpine — base-*, Debian/Ubuntu — common-*).
PAM_AUTH_FILE=""
PAM_ACCOUNT_FILE=""
PAM_PASSWORD_FILE=""

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
	"21|stage21_console|🖥|Локальный вход (консоль)|protect|stage_console"
	"22|stage22_docker|🐳|Docker: установка и состояние|protect|stage_docker"
	"23|stage23_autostart|🔄|Автозапуск: что стартует с системой|system|stage_autostart"
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

# ── Показ выполняемых команд ─────────────────────────────────────────
# Лучшая практика CLI-интерфейсов: человек должен видеть, что именно делает
# скрипт, а не смотреть на мигающий курсор. Поэтому каждый шаг печатает себя
# (и саму команду), крутит спиннер и оставляет на его месте результат со
# временем. Полный вывод команды уходит в лог; в --verbose льётся и на экран.
#
# Почему не whiptail/dialog: это внешняя зависимость (newt), которого нет ни на
# голом Alpine, ни в минимальном контейнере. Свой ANSI-интерфейс работает
# везде, где есть bash и терминал.
UI_VERBOSE=false
UI_QUIET=false
STEP_TOTAL=0
STEP_NO=0
STEP_OUT="" # вывод последнего шага (нужен вызывающему для диагностики)

# Микросекунды для замера времени шага. EPOCHREALTIME есть в bash 5,
# иначе считаем в секундах (обычно этого достаточно)
_now_us() {
	if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "${EPOCHREALTIME/./}"; else printf '%s' "$((SECONDS * 1000000))"; fi
}

# steps_total N — сколько шагов будет в этапе, чтобы нумеровать «2 из 5».
# Имя без префикса stage_: иначе тест «каждая stage_* есть в реестре» считал бы
# эту утилиту этапом.
steps_total() {
	STEP_TOTAL="${1:-0}"
	STEP_NO=0
}

# step_run "что делаем" команда [аргументы...] → 0 успех, 1 провал
# При провале текст вывода остаётся в $STEP_OUT и печатаются последние строки.
step_run() {
	local desc="$1"
	shift
	STEP_NO=$((STEP_NO + 1))
	# если шагов оказалось больше обещанного, лучше молчать, чем писать «4/3»
	local counter=""
	((STEP_TOTAL > 0 && STEP_NO <= STEP_TOTAL)) && counter="${STEP_NO}/${STEP_TOTAL} "

	local t0 t1 rc=0 cmd=""
	# %q сохраняет кавычки: строку можно скопировать и выполнить как есть,
	# а «$*» от неё оставлял только слова без границ аргументов
	local a
	for a in "$@"; do cmd+="$(printf '%q ' "$a")"; done
	cmd=${cmd% }
	t0=$(_now_us)
	if ! $UI_QUIET; then
		printf '  %b%s%b%s\n' "$C_DIM" "$counter" "$desc" "$C_RESET"
		printf '    %b$ %s%b\n' "$C_DIM" "$cmd" "$C_RESET"
	fi

	STEP_OUT=""
	if $UI_VERBOSE; then
		# живой вывод: удобно, когда что-то пошло не так и хочется видеть детали
		"$@" 2>&1 | tee -a "$LOG_FILE"
		rc=${PIPESTATUS[0]}
	else
		spinner_start "$desc"
		STEP_OUT=$("$@" 2>&1)
		rc=$?
		spinner_stop
		printf '%s\n' "${STEP_OUT:-}" >>"$LOG_FILE" 2>/dev/null || true
	fi

	t1=$(_now_us)
	local ms=$(((t1 - t0) / 1000))
	local tm
	if ((ms >= 1000)); then tm="$((ms / 1000)).$(((ms % 1000) / 100))s"; else tm="${ms}ms"; fi

	if ((rc == 0)); then
		$UI_QUIET || printf '  %b%s%b %s %b(%s)%b\n' "$C_GREEN" "$ICON_OK" "$C_RESET" "$desc" "$C_DIM" "$tm" "$C_RESET"
		return 0
	fi

	log_err "$desc — не получилось ($tm)"
	if [[ -n "$STEP_OUT" ]]; then
		local l
		while IFS= read -r l; do printf '    %b%s%b\n' "$C_DIM" "$l" "$C_RESET"; done \
			< <(printf '%s\n' "$STEP_OUT" | grep -v '^[[:space:]]*$' | tail -5)
	fi
	hint "полный вывод: $LOG_FILE"
	return 1
}

# step_note "текст" — пояснение без команды (единый отступ со шагами)
step_note() { $UI_QUIET || printf '  %b%s%b\n' "$C_DIM" "$1" "$C_RESET"; }

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

# Дополнить строку пробелами до ширины w ПО СИМВОЛАМ.
# printf '%-20s' в bash считает ширину в БАЙТАХ (на musl/Alpine — даже с
# LC_ALL=C.UTF-8), а кириллица занимает два байта на символ: колонки разъезжаются.
# ${#var} считает символы, от них и считаем отступ.
pad() {
	local s="$1" w="$2" n
	n=$((w - ${#s}))
	((n > 0)) || n=0
	printf '%s%*s' "$s" "$n" ''
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

# Пояснение под пунктом меню — для тех, кто видит эти слова впервые.
# Цвета через %b: в C_* лежит литерал \033, а не готовый escape.
hint() { printf '    %b%s%b\n' "$C_DIM" "$1" "$C_RESET"; }

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

# Чистая функция без побочных эффектов: ID из /etc/os-release → имя пакетного
# менеджера. Вынесена, чтобы её можно было проверять тестом (detect_distro делает
# ещё и systemctl/rc-service и завершает скрипт на неизвестном дистрибутиве).
_pkg_mgr_for_id() {
	case "$1" in
	debian | ubuntu | linuxmint | pop | raspbian) echo apt ;;
	fedora | rhel | centos | rocky | almalinux | ol)
		command -v dnf &>/dev/null && echo dnf || echo yum
		;;
	alpine | postmarketos) echo apk ;;
	*) return 1 ;;
	esac
}

detect_distro() {
	if [[ -f /etc/os-release ]]; then
		source /etc/os-release
	fi

	PKG_MGR=$(_pkg_mgr_for_id "${ID:-}") || {
		echo -e "${C_RED}${ICON_FAIL}  Неподдерживаемый дистрибутив: ${ID:-неизвестно}${C_RESET}"
		echo "  Поддерживаются: Debian, Ubuntu, Fedora, RHEL, CentOS, Rocky, AlmaLinux, Alpine"
		exit 1
	}
	DISTRO_NAME="${PRETTY_NAME:-$ID}"

	case "$PKG_MGR" in
	apt | dnf | yum) SUDO_GROUP="$([[ "$PKG_MGR" == apt ]] && echo sudo || echo wheel)" ;;
	apk) SUDO_GROUP="wheel" ;;
	esac

	# init: на Alpine systemd нет вообще, сервисами рулит OpenRC.
	INIT_SYSTEM="openrc"
	HAS_SYSTEMD=false
	if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
		INIT_SYSTEM="systemd"
		HAS_SYSTEMD=true
	fi
	HAS_OPENRC=false
	command -v rc-service &>/dev/null && command -v rc-update &>/dev/null && HAS_OPENRC=true
	# Ни systemd, ни OpenRC: скрипт отработает, но сервисы запускать нечем —
	# об этом лучше сказать сразу, чем падать на середине этапа
	if ! $HAS_SYSTEMD && ! $HAS_OPENRC; then
		INIT_SYSTEM="none"
		log_warn "Не найден ни systemd, ни OpenRC: сервисы (sshd, UFW, Fail2Ban) придётся запускать вручную"
	fi

	if $HAS_SYSTEMD; then
		if systemctl list-unit-files 2>/dev/null | grep -q "^ssh\.service"; then
			SSH_SERVICE="ssh"
		elif systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
			SSH_SERVICE="sshd"
		else
			SSH_SERVICE="ssh"
		fi
	else
		# в OpenRC имя сервиса = имя init-скрипта, на Alpine это sshd
		SSH_SERVICE="sshd"
	fi

	# sshd с PAM: только тогда pam_faillock реально влияет на вход по SSH
	if [[ "${ID:-}" == alpine ]] && apk info -e openssh-server-pam &>/dev/null; then
		SSHD_HAS_PAM=true
	elif [[ -f /etc/pam.d/sshd ]]; then
		SSHD_HAS_PAM=true
	fi

	# SELinux: на RHEL-семействе без semanage sshd не поднимется на нестандартном порту
	if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
		HAS_SELINUX=true
	fi

	# Адаптируем ширину под терминал. На Alpine нет tput (ncurses) — тогда 80.
	TERM_WIDTH=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}
	((TERM_WIDTH > 100)) && TERM_WIDTH=100
	((TERM_WIDTH < 60)) && TERM_WIDTH=60
}

# ═══════════════════════════════════════════════════════════════════
#  СЕРВИСЫ: systemd (systemctl) либо OpenRC (rc-service/rc-update)
# ═══════════════════════════════════════════════════════════════════
# Всё, что раньше звало systemctl напрямую, идёт через этот слой: на Alpine
# systemctl отсутствует, а имя сервиса в OpenRC — это имя файла /etc/init.d/X.
# systemd-only вещи (сокет-активация ssh.socket, таймеры) остаются под
# проверкой $HAS_SYSTEMD.

svc_is_active() { # svc_is_active <имя>
	if $HAS_SYSTEMD; then
		systemctl is-active --quiet "$1" 2>/dev/null
	else
		rc-service "$1" status &>/dev/null
	fi
}

svc_is_enabled() { # включён в автозагрузку
	if $HAS_SYSTEMD; then
		systemctl is-enabled --quiet "$1" 2>/dev/null
	else
		# rc-update show печатает «  имя | runlevel»
		rc-update show 2>/dev/null | grep -qE "^[[:space:]]*$1[[:space:]]*\|"
	fi
}

svc_start() {
	if $HAS_SYSTEMD; then
		systemctl start "$1" 2>/dev/null
	else
		rc-service "$1" start &>/dev/null
	fi
}

svc_stop() {
	if $HAS_SYSTEMD; then
		systemctl stop "$1" 2>/dev/null
	else
		rc-service "$1" stop &>/dev/null
	fi
}

svc_restart() {
	if $HAS_SYSTEMD; then
		systemctl restart "$1" 2>/dev/null
	else
		rc-service "$1" restart &>/dev/null
	fi
}

svc_reload() {
	if $HAS_SYSTEMD; then
		systemctl reload "$1" 2>/dev/null
	else
		rc-service "$1" reload &>/dev/null
	fi
}

svc_enable() {
	if $HAS_SYSTEMD; then
		systemctl enable "$1" 2>/dev/null
	else
		rc-update add "$1" default &>/dev/null
	fi
}

svc_disable() {
	if $HAS_SYSTEMD; then
		systemctl disable "$1" 2>/dev/null
	else
		rc-update del "$1" default &>/dev/null
	fi
}

svc_enable_now() { svc_enable "$1" || true; svc_start "$1" || true; }

svc_disable_now() { svc_stop "$1" || true; svc_disable "$1" || true; }

svc_daemon_reload() {
	$HAS_SYSTEMD && systemctl daemon-reload 2>/dev/null || true
}

# Есть ли init-скрипт/юнит вообще (иначе rc-service шумит «does not exist»)
svc_exists() {
	if $HAS_SYSTEMD; then
		systemctl list-unit-files 2>/dev/null | grep -q "^$1\.\(service\|timer\|socket\)"
	else
		[[ -x "/etc/init.d/$1" ]]
	fi
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

# Имена файлов по маске одной строкой (замена find -printf '%f ')
_conf_names() {
	local d="$1" f
	shopt -s nullglob
	for f in "$d"/*.conf; do printf '%s ' "$(basename "$f")"; done
	shopt -u nullglob
}

# Первый IPv4-адрес сервера. hostname -I есть в GNU-hostname, но не в busybox
# (Alpine) — там выручает ip из iproute2. Печатает пусто, если узнать нечем.
_server_ip() {
	local ip
	ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	[[ -n "$ip" ]] || ip=$(ip -4 addr show scope global 2>/dev/null |
		awk '/^[[:space:]]*inet /{sub(/\/.*/,"",$2); print $2; exit}')
	printf '%s' "$ip"
}

get_regular_users() {
	local with_root="${1:-}"
	while IFS=: read -r user _ uid _ _ home shell; do
		if [[ "$user" == root ]]; then
			# root нужен там, где речь о входе (SSH-ключи): на свежем сервере
			# он вообще единственная учётка, которой можно положить ключ
			[[ "$with_root" == "--with-root" ]] || continue
		else
			# 65534 — nobody: он >= 1000, но это не живая учётка
			[[ $uid -ge 1000 && $uid -lt 65534 ]] || continue
		fi
		# nologin на разных ОС лежит по разному пути (/sbin, /usr/sbin, /usr/bin),
		# поэтому шаблон, а не список — иначе учётка попадает в меню входа
		[[ "$shell" == */nologin || "$shell" == */false ]] && continue
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
		[[ "$shell" == */nologin || "$shell" == "/bin/false" ]] || continue
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
	# busybox find не умеет -printf: откатываемся на basename в цикле
		[[ $confs -gt 0 ]] && echo -e "  drop-in: ${C_DIM}$(_conf_names "$SSHD_CONFIG_D")${C_RESET}"
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
	svc_is_active fail2ban && {
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
	ip_addr=$(_server_ip)
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
	if ! command -v cscli &>/dev/null && ! svc_is_active fail2ban; then
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
	# apk возвращает ненулевой код и когда пакет реально установлен: например
	# не может выставить владельца служебного каталога в контейнере. Верить
	# только коду возврата нельзя — иначе этап Fail2Ban «проваливается» при
	# живом fail2ban-client. Поэтому на Alpine проверяем сам факт установки.
	if [[ "$PKG_MGR" == apk ]] && apk info -e "$pkg" &>/dev/null; then
		log_info "$pkg уже установлен"
		return 0
	fi
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
		# apk без --no-cache обновляет индекс отдельно; -q чтобы не сыпать версии
		apk) apk add --no-cache -q "$pkg" &>/dev/null && {
			spinner_stop
			return 0
		}
			apk info -e "$pkg" &>/dev/null && {
				spinner_stop
				log_warn "$pkg установлен, но apk вернул ошибку (владельцы файлов) — продолжаем"
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
	apk) apk update &>/dev/null || true ;;
	esac
}

# Утилиты, которые есть в coreutils/findutils/iproute2, но НЕ в busybox Alpine:
#   find -printf, sort -h/-V, hostname -I
# Ставим один раз на первом этапе, который до них дотянется: иначе проверки
# молча дают пустой результат на живом сервере.
_ensure_base_tools() {
	[[ "$PKG_MGR" == apk ]] || return 0
	$APK_TOOLS_DONE && return 0
	APK_TOOLS_DONE=true
	local need=()
	# busybox find/sort/hostname не умеют нужных ключей — ставим GNU-версии
	[[ "$(find --version 2>/dev/null)" == *GNU* ]] || need+=(findutils)
	[[ "$(sort --version 2>/dev/null)" == *GNU* ]] || need+=(coreutils)
	command -v ss &>/dev/null || need+=(iproute2)
	[[ ${#need[@]} -eq 0 ]] && return 0
	log_info "Alpine: ставлю базовые утилиты (${need[*]})..."
	# код возврата apk ненадёжен (см. pkg_install_retry) — проверяем факт установки
	apk add --no-cache -q "${need[@]}" &>>"$LOG_FILE" || _apk_all_installed "${need[@]}" ||
		log_warn "Не удалось поставить: ${need[*]}"
}

# Установлен ли каждый пакет (независимо от кода возврата apk)
_apk_all_installed() {
	local p
	for p in "$@"; do apk info -e "$p" &>/dev/null || return 1; done
	return 0
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 0: УТИЛИТЫ
# ═══════════════════════════════════════════════════════════════════

stage_utilities() {
	stage_banner "$ICON_GEAR" "0" "Установка утилит"

	_ensure_base_tools

	echo -e "  ${C_BOLD}1)${C_RESET} micro  ${C_DIM}— удобный редактор${C_RESET}"
	echo -e "  ${C_BOLD}2)${C_RESET} mc     ${C_DIM}— файловый менеджер${C_RESET}"
	echo -e "  ${C_BOLD}3)${C_RESET} Обе утилиты"
	echo -e "  ${C_BOLD}S)${C_RESET} Пропустить"
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
	apk)
		backup_file "/etc/apk/repositories" "stage1_update"
		;;
	esac

	log_info "Обновление списка пакетов..."
	spinner_start "Обновляем списки пакетов..."
	local max=3 retry=0
	while [[ $retry -lt $max ]]; do
		case "$PKG_MGR" in
		apt) apt-get update &>/dev/null && break ;;
		dnf | yum) $PKG_MGR update -y &>/dev/null && break ;;
		apk) apk update &>/dev/null && break ;;
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
	# --available: «upgrade» на Alpine обновляет и ядро, и зависимости пакета
	apk) apk -U upgrade --available &>>"$LOG_FILE" || true ;;
	esac
	spinner_stop

	log_ok "Система обновлена"
	# без перезагрузки работает старое ядро/библиотеки — скажем об этом явно
	if [[ -f /var/run/reboot-required || -f /run/reboot-required ]]; then
		log_warn "Требуется перезагрузка (обновлено ядро или системные пакеты): reboot"
	fi
	# Alpine меняет ядро отдельным пакетом — признак именно linux-* в списке апгрейдов
	if [[ "$PKG_MGR" == apk ]] && grep -qE '^linux-[a-z0-9-]+ ' /var/log/apk.log 2>/dev/null; then
		log_warn "Обновлён пакет ядра — перезагрузка нужна: reboot"
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
	echo -e "  ${C_BOLD}1)${C_RESET} Создать нового"

	[[ ${#users[@]} -gt 0 ]] && {
		echo -e "  ${C_BOLD}2)${C_RESET} Сменить пароль"
		echo -e "  ${C_BOLD}3)${C_RESET} Группы"
		echo -e "  ${C_BOLD}4)${C_RESET} Удалить"
	}
	echo -e "  ${C_BOLD}S)${C_RESET} Пропустить"
	echo ""
	read -rp "  ${ICON_ARROW} " action
	echo ""

	case "${action,,}" in
	1)
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
		# на Alpine bash по умолчанию не установлен — /bin/bash не пустил бы никого
		local shell_f="/bin/bash"
		[[ -x /bin/bash ]] || shell_f="/bin/ash"
		useradd -m -s "$shell_f" "$username"
		echo "$username:$pw" | chpasswd
		usermod -aG "$SUDO_GROUP" "$username"
		log_ok "Пользователь ${C_BOLD}$username${C_RESET} создан (группа $SUDO_GROUP)"
		;;
	2)
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
	3)
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
			if command -v column &>/dev/null; then
				cut -d: -f1 /etc/group | sort | column | sed 's/^/  /'
			else
				cut -d: -f1 /etc/group | sort | sed 's/^/  /'
			fi
			echo """"
			;;
		*) log_info "Назад" ;;
		esac
		;;
	4)
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
			if [[ "$PKG_MGR" == apk ]]; then
				# busybox/shadow userdel на Alpine не чистит /home и cron — делаем сами
				userdel "$u" 2>/dev/null || true
				[[ -n "$u" ]] && rm -rf "/home/${u:?}" 2>/dev/null || true
				crontab -u "$u" -r 2>/dev/null || true
			else
				userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
			fi
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
	# меняли ли ключи: если да — в конце перезапустим SSH (см. _ssh_after_keys_change)
	local keys_changed=false
	while IFS=: read -r user uid groups home; do
		local ki="${C_DIM}нет${C_RESET}"
		[[ -f "$home/.ssh/authorized_keys" && -s "$home/.ssh/authorized_keys" ]] && ki="${C_GREEN}да ($(wc -l <"$home/.ssh/authorized_keys") шт.)${C_RESET}"
		echo -e "  ${C_BOLD}$idx)${C_RESET} ${C_BOLD}$user${C_RESET}  ключи: $ki"
		users+=("$user")
		idx=$((idx + 1))
	done < <(get_regular_users --with-root)
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
	srv_ip=$(_server_ip)
	srv_ip=${srv_ip:-<server_ip>}

	case "$ka" in
	1)
		echo ""
		echo "  Вставьте публичный ключ целиком, одной строкой (ssh-ed25519 AAAA...):"
		read -r pk
		[[ -z "$pk" ]] && {
			log_err "Ключ пуст"
			return 1
		}
		# Обрезанная при копировании строка выглядит «похоже на ключ», но sshd
		# её молча игнорирует — потом человек гадает, почему ключ не пускает.
		# Поэтому спрашиваем у ssh-keygen, разбирается ли строка вообще.
		if ! printf '%s\n' "$pk" | ssh-keygen -l -f - &>/dev/null; then
			log_err "Ключ не читается: скорее всего строка обрезана или склеена"
			hint "у ed25519 base64-часть — ровно 68 символов, плюс пробел и комментарий"
			hint "скопируйте строку из файла ~/.ssh/id_ed25519.pub целиком"
			confirm "Всё равно добавить?" || return 1
		elif ! printf '%s\n' "$pk" | grep -qE '^(ssh-|ecdsa-|sk-ssh|sk-ecdsa)'; then
			log_warn "Не похоже на SSH-ключ"
			confirm "Продолжить?" || return 1
		fi
		echo "$pk" >>"$ssh_dir/authorized_keys"
		chown "$SSH_KEY_USER:$SSH_KEY_USER" "$ssh_dir/authorized_keys"
		chmod 600 "$ssh_dir/authorized_keys"
		keys_changed=true
		log_ok "Ключ добавлен для ${C_BOLD}$SSH_KEY_USER${C_RESET}"
		echo -e "  ${C_DIM}Проверьте вход в НОВОМ окне: ssh -i <ключ> -p $CURRENT_SSH_PORT $SSH_KEY_USER@<адрес>${C_RESET}"
		hint "не пускает — этап 5, пункт 8 «Почему не пускает SSH»"
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
		done < <(get_regular_users --with-root)
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
		keys_changed=true
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
		done < <(get_regular_users --with-root)
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
		keys_changed=true
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
	$keys_changed && _ssh_after_keys_change "Ключи обновлены"
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
	$HAS_SYSTEMD || return 1
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
	_ssh_socket_active || return 0

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

	svc_daemon_reload
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
	svc_restart "$SSH_SERVICE" || {
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
			log_warn "Порт $CURRENT_SSH_PORT не слушается — проверьте: systemctl cat ssh.socket / rc-service sshd status"
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
	ip=$(_server_ip)
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

# После правки ключей SSH надо перезапустить — и вот почему это не формальность:
# если служба вообще не запущена (свежий сервер, сломанный автостарт), ключ не
# заработает никогда, и человек ищет причину в ключе. Плюс перезапуск снимает
# главный вопрос «а надо ли перезапускать SSH?».
#
# Для одного лишь authorized_keys перезапуск не обязателен: sshd читает файл на
# каждой попытке входа. Поэтому честно говорим и то, и другое.
_ssh_after_keys_change() {
	local label="${1:-Ключи обновлены}"
	if ! command -v sshd &>/dev/null; then
		log_warn "$label, но sshd не установлен — вход по ключу не заработает"
		return 1
	fi
	# Рестарт при невалидном конфиге добил бы работающий sshd. Поэтому сначала
	# проверка, и только потом трогаем службу.
	if ! sshd -t &>>"$LOG_FILE"; then
		log_err "sshd_config не проходит sshd -t — SSH НЕ перезапускаю (текущий процесс жив)"
		log_info "  проверьте: sshd -t  и  $SSHD_CONFIG_D/"
		return 1
	fi
	if ! svc_is_active "$SSH_SERVICE"; then
		log_warn "Служба SSH была НЕ запущена — именно поэтому вход не работал; запускаю"
		svc_enable "$SSH_SERVICE" || true
		if svc_start "$SSH_SERVICE" && svc_is_active "$SSH_SERVICE"; then
			log_ok "SSH запущен ($SSH_SERVICE)"
		else
			# svc_start может отдать 0 и не поднять демон (так ведёт себя OpenRC
			# в chroot) — поэтому проверяем факт, а не код возврата
			log_err "SSH не запустился — диагностика: этап 5, пункт 8"
			return 1
		fi
		return 0
	fi
	svc_daemon_reload
	if svc_restart "$SSH_SERVICE"; then
		log_ok "$label; SSH перезапущен ($SSH_SERVICE)"
		hint "для одного authorized_keys перезапуск не обязателен — sshd читает файл на каждом входе"
	else
		log_warn "$label, но SSH не перезапустился — см. этап 5, пункт 8"
		return 1
	fi
	return 0
}

# Права файла: GNU stat (-c) или BSD/busybox (-f). Тихий возврат пустой строки
# лучше выдуманного значения — дальше мы это отдельно обрабатываем.
_file_mode() {
	stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Почему SSH не пускает — самый частый вопрос после установки ключа. Смотрит
# обе стороны: что на сервере (sshd, порт, фаервол, права и читаемость ключей)
# и что видит клиент. Ничего не меняет — только читает.
_ssh_diagnose() {
	echo ""
	echo -e "${C_BOLD}▸ Проверка входа по SSH${C_RESET}"

	# 1) sshd: конфиг и служба
	if ! command -v sshd &>/dev/null; then
		log_err "sshd не установлен"
	elif sshd -t 2>&1 | tee -a "$LOG_FILE" | grep -q .; then
		log_err "Конфиг sshd не проходит проверку (вывод выше)"
	else
		log_ok "Конфиг sshd валиден (sshd -t)"
	fi
	svc_is_active "$SSH_SERVICE" && log_ok "Служба SSH запущена ($SSH_SERVICE)" ||
		log_err "Служба SSH НЕ запущена ($SSH_SERVICE) — это и даёт «Connection refused»"

	# 2) порт: что в конфиге и что реально слушается
	_ssh_port_refresh
	_ssh_listen_ports
	echo -e "  порт в конфиге: ${C_BOLD}$CURRENT_SSH_PORT${C_RESET}"
	if [[ " $_seen_ports " == *" $CURRENT_SSH_PORT "* ]]; then
		log_ok "sshd слушает $CURRENT_SSH_PORT"
	else
		log_err "sshd НЕ слушает $CURRENT_SSH_PORT (слушает: ${_seen_ports:-ничего})"
	fi

	# 3) фаервол: если он активен, а порта в нём нет — снаружи тишина
	local fw
	fw=$(_fw_cmd)
	if [[ "$fw" == firewalld ]]; then
		if firewall-cmd --state 2>/dev/null | grep -q running; then
			firewall-cmd --list-ports 2>/dev/null | grep -q "$CURRENT_SSH_PORT/tcp" &&
				log_ok "firewalld: порт $CURRENT_SSH_PORT открыт" ||
				log_err "firewalld активен, но порт $CURRENT_SSH_PORT не открыт"
		fi
	elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw status 2>/dev/null | grep -qE "^$CURRENT_SSH_PORT/tcp" &&
			log_ok "UFW: порт $CURRENT_SSH_PORT открыт" ||
			log_err "UFW активен, но порт $CURRENT_SSH_PORT не разрешён"
	else
		log_info "Фаервол неактивен — порт ничего не режет"
	fi

	# 4) ключи: владелец, права и читаемость. sshd молча игнорирует
	# authorized_keys, если владелец/права не те или строка битая.
	local u _uid _g uh kf n_keys bad line_no l
	while IFS=: read -r u _uid _g uh; do
		kf="$uh/.ssh/authorized_keys"
		[[ -f "$kf" ]] || continue
		n_keys=$(grep -cvE '^[[:space:]]*(#|$)' "$kf" 2>/dev/null || echo 0)
		if [[ "$(find "$kf" -maxdepth 0 -user "$u" 2>/dev/null)" != "$kf" ]]; then
			log_err "$u: владелец $kf не $u — sshd такой ключ игнорирует"
			log_info "  исправить: chown -R $u:$u $uh/.ssh && chmod 700 $uh/.ssh && chmod 600 $kf"
		fi
		local mode
		mode=$(_file_mode "$kf")
		case "$mode" in
		600 | 640 | 644) ;;
		"") ;;
		*) log_warn "$u: права $kf = $mode (обычно 600)" ;;
		esac
		bad=0
		line_no=0
		while IFS= read -r l; do
			line_no=$((line_no + 1))
			[[ -z "$l" || "$l" == \#* ]] && continue
			printf '%s\n' "$l" | ssh-keygen -l -f - &>/dev/null || {
				bad=$((bad + 1))
				log_warn "$u: строка $line_no в $kf не читается как ключ (обрезана?)"
			}
		done <"$kf"
		[[ $bad -eq 0 ]] && log_ok "$u: ключей $n_keys, все читаются ($kf)"
	done < <(get_regular_users --with-root)

	# 5) что видит клиент и что с этим делать
	echo ""
	echo -e "  ${C_DIM}Со стороны клиента:${C_RESET}"
	hint "«Connection refused» — на этом порту никто не слушает: не тот порт или sshd не запущен"
	hint "«Permission denied (publickey)» — ключ не приняли: смотрите владельца и права authorized_keys"
	hint "«SSH_AUTH_SOCK is not set» — клиент хочет ssh-agent, а агента нет; выберите ключ файлом:"
	hint "  ssh -i ~/.ssh/id_ed25519 -p $CURRENT_SSH_PORT <пользователь>@<адрес>"
	echo ""
	read -rp "  Enter..." _
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
		echo -e "  7) Rate-limit атакующих (PerSourcePenalties): ${C_DIM}нет (OpenSSH < 9.8)${C_RESET}"
	else
		echo -e "  7) Rate-limit атакующих (PerSourcePenalties): ${C_GREEN}встроенный${C_RESET}"
	fi
	echo "  8) Почему не пускает SSH (диагностика)"
	echo ""
	echo -e "  ${C_DIM}Что это значит:${C_RESET}"
	hint "парольный вход yes — к любому пользователю можно подобрать пароль по SSH"
	hint "prohibit-password у root — root пускают только по SSH-ключу, пароль не спросят"
	hint "вход root no — root по SSH не входит совсем (тогда админ — обычный пользователь)"
	hint "MaxAuthTries — сколько попыток пароля даётся за одно соединение (6 — норма)"
	hint "пустые пароли yes — учётка без пароля входит без пароля"
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
		echo -e "  ${C_BOLD}Вход по паролю (PasswordAuthentication):${C_RESET}"
		hint "1) yes — можно входить по паролю; удобно, но пароли подбирают боты (нужен этап 9)"
		hint "2) no  — только SSH-ключ; безопаснее, но сначала проверьте, что ключ работает"
		echo ""
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
		echo -e "  ${C_BOLD}Как root может входить:${C_RESET}"
		hint "1) prohibit-password — по ключу можно, по паролю нельзя (так и надо)   ← рекомендуется"
		hint "2) no                — root по SSH не входит совсем; нужен свой админ с ключом"
		hint "3) yes               — пускает root и по паролю: открытая дверь, только на время отладки"
		echo ""
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
		echo -e "  ${C_BOLD}Макс. попыток (MaxAuthTries):${C_RESET}"
		hint "сколько раз можно ошибиться с паролем в одном соединении; 3-6 — обычно достаточно"
		read -rp "  Макс. попыток (1-10): " nm
		[[ "$nm" =~ ^[0-9]+$ && $nm -ge 1 && $nm -le 10 ]] || {
			log_err "1-10"
			return 1
		}
		_ssh_apply "MaxAuthTries → $nm" "MaxAuthTries=$nm" || return 1
		;;
	5)
		echo -e "  ${C_BOLD}Пустые пароли (PermitEmptyPasswords):${C_RESET}"
		hint "1) no  — учётка без пароля не войдёт (норма)"
		hint "2) yes — пустой пароль пускает в систему: небезопасно"
		echo ""
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
			echo -e "  ${C_DIM}Условия: authfail, noauth, invaliduser, crash; далее минуты бана и потолок${C_RESET}"
			echo "  Текущая политика: $(_sshd_option "$sc" persourcepenalties '(по умолчанию)')"
			echo -e "  ${C_DIM}Это встроенный rate-limit: источник с ошибками входа временно
  перестаёт получать соединения. Дополняет Fail2Ban (этап 9), не заменяет.${C_RESET}"
			echo ""
			echo ""
			if confirm "Включить PerSourcePenalties явно?"; then
				_ssh_apply "PerSourcePenalties включены" "PerSourcePenalties=yes" || return 1
			fi
		fi
		;;
	8) _ssh_diagnose ;;
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
	echo "  1) Вставить    2) Скопировать    S) Пропустить"
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
		done < <(get_regular_users --with-root)
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
	svc_enable_now firewalld

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
			5)
			svc_enable_now firewalld
			# та же ловушка, что и с ufw enable: сообщать об успехе только по факту
			if firewall-cmd --state 2>/dev/null | grep -q running; then
				log_ok "firewalld включён"
			else
				log_err "firewalld НЕ запустился — проверьте: firewall-cmd --state"
			fi
			;;
		6)
			echo -e "  ${C_YELLOW}Сервер останется без фаервола!${C_RESET}"
			confirm "Отключить firewalld?" && {
				svc_disable_now firewalld
				if firewall-cmd --state 2>/dev/null | grep -q running; then
					log_warn "firewalld всё ещё запущен"
				else
					log_ok "firewalld отключён"
				fi
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
	# UFW на Alpine живёт только вместе с init-скриптом ufw-openrc:
	# без него правила запишутся, но не всплывут после перезагрузки.
	[[ "$PKG_MGR" == apk ]] && _ensure_base_tools
	stage_banner "$ICON_FIRE" "7" "Настройка UFW"

	if ! command -v ufw &>/dev/null; then
		pkg_install_retry "ufw" || {
			update_stage_status "stage7_ufw" "failed"
			return 1
		}
	else
		log_info "UFW уже установлен"
	fi
	[[ "$PKG_MGR" == apk ]] && { pkg_install_retry "ufw-openrc" || log_warn "ufw-openrc не установлен — ufw не поднимется сам"; }

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
				# ufw enable только пишет /etc/ufw/ufw.conf; автозапуск — дело init
				[[ "$PKG_MGR" == apk ]] && svc_enable ufw
				# "UFW включён" — только если он действительно активен: enable может
				# отработать наполовину (нет прав на netfilter, битые правила) и при этом
				# тихо оставить ENABLED=no — обещать защиту в этом случае нельзя
				if ufw status 2>/dev/null | grep -q "Status: active"; then
					log_ok "UFW включён"
				else
					log_err "UFW НЕ включился — проверьте: ufw status"
				fi
			fi
			;;
		6)
			ufw disable
			[[ "$PKG_MGR" == apk ]] && svc_disable ufw
			# disable переворачивает ENABLED в ufw.conf; если он остался yes —
			# фаервол вернётся после перезагрузки, о чём пользователь должен знать
			if grep -qE '^ENABLED=yes' /etc/ufw/ufw.conf 2>/dev/null; then
				log_warn "UFW всё ещё включён (ENABLED=yes в /etc/ufw/ufw.conf)"
			else
				log_ok "UFW отключён"
			fi
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

	# Alpine: unattended-upgrades/dnf-automatic не существует — безопасность
	# приезжает вместе с apk upgrade, а расписание делается периодическим cron.
	if [[ "$PKG_MGR" == apk ]]; then
		_stage_autoupdate_apk
		update_stage_status "stage8_autoupdate" "completed"
		return 0
	fi

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
		svc_enable dnf-automatic.timer || true
		svc_start dnf-automatic.timer || true
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
		svc_enable apt-daily-upgrade.timer || true
		svc_start apt-daily-upgrade.timer || true
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
			svc_daemon_reload
			svc_enable reboot-after-updates.timer || true
			svc_start reboot-after-updates.timer || true
			log_info "Авто-перезагрузка: ежедневно в $reboot_time"
		fi
		;;
	esac

	log_ok "Автообновления настроены"
	update_stage_status "stage8_autoupdate" "completed"
}

# Alpine: своего unattended-upgrades нет. Кладём ежедневный скрипт в
# /etc/periodic/daily (его запускает busybox crond / cronie) и включаем cron.
_stage_autoupdate_apk() {
	local script="/etc/periodic/daily/4script-security-update"
	backup_file "$script" "stage8_autoupdate"

	echo ""
	echo -e "  ${C_DIM}Обновление через apk: сначала индексы, затем пакеты. Перезагрузку
  автоматика не делает — только сообщает в лог.${C_RESET}"
	echo ""
	if ! confirm "Создать ежедневное обновление (/etc/periodic/daily)?"; then
		log_info "Пропущено"
		return 0
	fi

	cat >"$script" <<'EOF'
#!/bin/sh
# 4script: ежедневное обновление безопасности Alpine
# Лог: /var/log/4script-autoupdate.log
LOG=/var/log/4script-autoupdate.log
{
	echo "=== $(date -Iseconds) 4script: apk update && apk upgrade"
	apk update && apk -U upgrade --available
} >>"$LOG" 2>&1
EOF
	chmod 755 "$script"

	# Cron на Alpine есть не всегда: busybox crond входит в базовую систему,
	# но если стоит cronie — включаем его. Хотя бы один нужен.
	if svc_exists crond; then
		svc_enable crond || true
		svc_start crond || true
		svc_is_active crond && log_ok "cron запущен (busybox crond)" || log_warn "crond не запустился"
	elif svc_exists cronie; then
		svc_enable cronie || true
		svc_start cronie || true
		svc_is_active cronie && log_ok "cron запущен (cronie)" || log_warn "cronie не запустился"
	else
		log_warn "На Alpine нет crond/cronie — скрипт $script не будет запускаться сам"
		_pkg_hint_apk_cron
	fi
	log_ok "Ежедневное обновление установлено: $script"
	log_info "Лог обновлений: /var/log/4script-autoupdate.log"
}

# Подсказка о том, что cron надо просто поставить — с точным именем пакета
_pkg_hint_apk_cron() {
	log_info "Установить: apk add busybox-openrc  (или apk add cronie cronie-openrc)"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 9: ЗАЩИТА ОТ БРУТФОРСА (CrowdSec / Fail2Ban)
# ═══════════════════════════════════════════════════════════════════

# Что уже стоит из защиты от брутфорса. Печатает «crowdsec», «fail2ban» или оба.
# Считаем по бинарю, а не по активности службы: человек мог поставить защиту и
# не запустить её — про это честнее сказать отдельно.
_intrusion_state() {
	local out=()
	command -v cscli &>/dev/null && out+=(crowdsec)
	command -v fail2ban-client &>/dev/null && out+=(fail2ban)
	printf '%s' "${out[*]:-}"
}

# Удаление пакета: один вызов на все менеджеры, чтобы не плодить case по месту.
pkg_remove() {
	case "$PKG_MGR" in
	apt) apt-get remove -y --purge "$@" &>/dev/null ;;
	dnf | yum) $PKG_MGR remove -y "$@" &>/dev/null ;;
	apk) apk del -q "$@" &>/dev/null ;;
	esac
}

# Убрать Fail2Ban: сначала служба (иначе останутся живые баны и процессы),
# потом пакет. jail.local и его бэкапы не трогаем — там может быть своя правка.
_remove_fail2ban() {
	local dirty=false
	command -v fail2ban-client &>/dev/null || svc_exists fail2ban || {
		log_info "Fail2Ban не установлен"
		return 0
	}
	log_warn "Удаление Fail2Ban: правила банов на сервере снимутся, защита от брутфорса останется только у SSH"
	confirm "Удалить Fail2Ban?" || {
		log_info "Отменено"
		return 1
	}
	svc_disable_now fail2ban || true
	# на Alpine init-скрипт лежит в отдельном пакете
	if [[ "$PKG_MGR" == apk ]]; then
		pkg_remove fail2ban fail2ban-openrc || dirty=true
	else
		pkg_remove fail2ban || dirty=true
	fi
	$dirty && log_warn "Пакет удалён не полностью — проверьте вручную" ||
		log_ok "Fail2Ban удалён (конфиг и бэкапы остались в /etc/fail2ban)"
}

# Убрать CrowdSec: два сервиса (движок и бонсер), затем пакеты.
_remove_crowdsec() {
	command -v cscli &>/dev/null || svc_exists crowdsec || {
		log_info "CrowdSec не установлен"
		return 0
	}
	log_warn "Удаление CrowdSec: движок и бонсер будут остановлены, решения о банах — удалены"
	confirm "Удалить CrowdSec?" || {
		log_info "Отменено"
		return 1
	}
	local s
	for s in crowdsec-firewall-bouncer crowdsec; do
		svc_disable_now "$s" || true
	done
	local dirty=false
	pkg_remove crowdsec crowdsec-firewall-bouncer-iptables crowdsec-firewall-bouncer nftables || dirty=true
	$dirty && log_warn "Часть пакетов CrowdSec удалить не удалось (ставился своим скриптом?)" ||
		log_ok "CrowdSec удалён (данные остались в /var/lib/crowdsec)"
	# каталог со сценариями чистим только по отдельному подтверждению
	if [[ -d /etc/crowdsec ]]; then
		confirm "Удалить ещё и конфиги /etc/crowdsec?" && rm -rf /etc/crowdsec && log_ok "/etc/crowdsec удалён"
	fi
}

stage_intrusion() {
	stage_banner "$ICON_SHIELD" "9" "Защита от брутфорса"

	# Что уже стоит: даём выбрать — оставить, заменить или убрать вовсе,
	# а не просто выходим с «уже установлено», как было раньше.
	local inst
	inst=$(_intrusion_state)
	if [[ -n "$inst" ]]; then
		echo -e "${C_BOLD}▸ Уже установлено:${C_RESET} $inst"
		svc_is_active crowdsec && echo -e "  ${C_GREEN}●${C_RESET} CrowdSec запущен"
		svc_is_active fail2ban && echo -e "  ${C_GREEN}●${C_RESET} Fail2Ban запущен"
		echo ""
		echo "  1) Оставить как есть"
		echo "  2) Заменить на другую"
		echo "  3) Удалить"
		echo "  S) Назад"
		echo ""
		read -rp "  ${ICON_ARROW} " ia

		case "$ia" in
		1)
			log_info "Оставлено как есть"
			update_stage_status "stage9_intrusion" "completed"
			return 0
			;;
		2)
			# убираем то, что стоит, и идём к обычному выбору установки ниже
			[[ "$inst" == *crowdsec* ]] && _remove_crowdsec
			[[ "$inst" == *fail2ban* ]] && _remove_fail2ban
			inst=$(_intrusion_state)
			[[ -n "$inst" ]] && {
				log_warn "Удалить не удалось — старая защита осталась: $inst"
				return 1
			}
			log_info "Старая защита удалена — выбираем новую"
			;;
		3)
			local which="$inst"
			if [[ "$inst" == *crowdsec*fail2ban* || "$inst" == *fail2ban*crowdsec* ]]; then
				echo ""
				echo "  1) CrowdSec   2) Fail2Ban   3) обе"
				read -rp "  ${ICON_ARROW} " w
				case "$w" in
				1) which=crowdsec ;;
				2) which=fail2ban ;;
				3) which="$inst" ;;
				*) which="" ;;
				esac
			fi
			[[ "$which" == *crowdsec* ]] && _remove_crowdsec
			[[ "$which" == *fail2ban* ]] && _remove_fail2ban
			log_warn "Брутфорс по SSH остаётся прикрыт только встроенным PerSourcePenalties (OpenSSH 9.8+)"
			update_stage_status "stage9_intrusion" "skipped"
			return 0
			;;
		*)
			log_info "Пропущено"
			return 0
			;;
		esac
	fi

	echo ""
	echo -e "  ${C_BOLD}Выберите систему защиты:${C_RESET}"
	echo ""
	# CrowdSec в репозиториях Alpine нет (проверено: apk search -x crowdsec пусто).
	# Его install-скрипт рассчитан на apt/dnf, поэтому предлагать его нечестно.
	if [[ "$PKG_MGR" == apk ]]; then
		echo -e "  ${C_DIM}CrowdSec в репозиториях Alpine недоступен — доступен Fail2Ban${C_RESET}"
		echo ""
		echo -e "  ${C_BOLD}1)${C_RESET} Fail2Ban  ${C_DIM}— локальная, простая, легковесная${C_RESET}"
		echo ""
		read -rp "  ${ICON_ARROW} " choice
		case "$choice" in
		1) _install_fail2ban ;;
		*)
			log_info "Пропущено"
			update_stage_status "stage9_intrusion" "skipped"
			return 0
			;;
		esac
		update_stage_status "stage9_intrusion" "completed"
		return 0
	fi
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
		svc_enable_now crowdsec
		sleep 2
		svc_is_active crowdsec && log_ok "CrowdSec запущен (без бонсера)" || log_warn "CrowdSec не запустился"
		_crowdsec_collections
		_install_fail2ban
		cscli version 2>/dev/null || true
		return 0
	fi

	pkg_install_retry "crowdsec-firewall-bouncer-iptables" || log_warn "Без bouncer'а — установите вручную"

	svc_enable crowdsec || true
	svc_start crowdsec || true
	svc_enable crowdsec-firewall-bouncer || true
	svc_start crowdsec-firewall-bouncer || true
	sleep 2
	svc_is_active crowdsec && log_ok "CrowdSec запущен" || log_warn "CrowdSec не запустился"
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
		{ svc_reload crowdsec || svc_restart crowdsec; } || true
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
	if [[ "$PKG_MGR" == apk ]]; then
		# На Alpine нет journald: sshd пишет туда, куда его направит syslog.
		# Fail2Ban читает файл, поэтому нужен живой syslog-демон (busybox syslogd
		# штатно пишет в /var/log/messages) и путь именно к нему.
		# init-скрипт syslog даёт только busybox-openrc — без него демон не поднять.
		if ! svc_exists syslog && ! svc_exists rsyslog; then
			pkg_install_retry "busybox-openrc" || true
		fi
		local slog=""
		svc_exists syslog && slog=syslog
		svc_exists rsyslog && slog=rsyslog
		if [[ -n "$slog" ]] && ! svc_is_active "$slog"; then
			svc_enable "$slog" || true
			svc_start "$slog" || true
			sleep 1
		fi
		if [[ -e /var/log/messages ]] || svc_is_active "${slog:-syslog}"; then
			sshd_jail="enabled = true
port = $sp
logpath = /var/log/messages
backend = polling
maxretry = 3
bantime = 24h"
			log_info "Alpine: Fail2Ban читает /var/log/messages (busybox syslogd)"
			# без syslogd файла не будет и jail тихо не сработает
			[[ -e /var/log/messages ]] || log_warn "Проверьте: rc-service syslog status и /var/log/messages"
		else
			log_warn "Нет syslog-демона и нет /var/log/messages — jail SSH отключён"
			log_warn "  включить: apk add busybox-openrc && rc-update add syslog default && rc-service syslog start"
		fi
	else
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

	svc_enable fail2ban || true
	svc_restart fail2ban || true
	sleep 2
	if svc_is_active fail2ban; then
		if [[ -n "$sshd_jail" ]]; then
			log_ok "Fail2Ban запущен (SSH: порт $sp, 3 попытки → бан 24ч)"
		else
			log_warn "Fail2Ban запущен, но SSH не защищён — см. предупреждение выше"
		fi
	else
		log_warn "Fail2Ban не запустился: systemctl status fail2ban / rc-service fail2ban status"
	fi
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 10: DNS
# ═══════════════════════════════════════════════════════════════════

# Кто владеет DNS: systemd-resolved или сам файл /etc/resolv.conf.
# Прямая запись в файл на resolved-системах бесполезна: он симлинк на stub,
# а перегенерация затрёт ручные nameserver при следующем boot.
_dns_backend() {
	if $HAS_SYSTEMD && command -v resolvectl &>/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
		echo resolved
	elif command -v netplan &>/dev/null; then
		# только бинарь: каталог /etc/netplan есть и там, где netplan не используется
		echo netplan
	elif [[ "$PKG_MGR" == apk ]]; then
		# Alpine: резолвер — это либо /etc/resolv.conf напрямую, либо
		# openresolv, который переписывает тот же файл из /etc/resolvconf.conf
		if command -v resolvconf &>/dev/null; then echo resolvconf; else echo file; fi
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
	resolvconf)
		# openresolv: правки в /etc/resolv.conf он затирает, поэтому пишем его конфиг
		backup_file "/etc/resolvconf.conf" "stage10_dns"
		{
			echo "# 4script"
			echo "name_servers=\"$servers\""
		} >/etc/resolvconf.conf
		resolvconf -u 2>/dev/null || log_warn "resolvconf -u не сработал — проверьте /etc/resolv.conf"
		log_ok "DNS через openresolv: $servers"
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
	echo "  1) Заменить    S) Пропустить"
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

	# Alpine: timedatectl отсутствует (нет systemd) — правим /etc/localtime
	# и /etc/timezone напрямую, а время синхронизирует chrony.
	if ! command -v timedatectl &>/dev/null; then
		_stage_timezone_no_systemd
		return $?
	fi

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

# Нет systemd (Alpine): /etc/localtime — симлинк на файл зоны, /etc/timezone —
# текстовый файл, время синхронизирует chronyd или openntpd через init.
_stage_timezone_no_systemd() {
	echo -e "${C_BOLD}Текущее:${C_RESET}"
	local cur_tz="не определён"
	[[ -L /etc/localtime ]] && cur_tz=$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')
	[[ -f /etc/timezone ]] && cur_tz=$(< /etc/timezone)
	echo "  Часовой пояс: $cur_tz"
	local ntp_svc=""
	for s in chronyd ntpd; do
		svc_is_active "$s" && ntp_svc="$s" && break
	done
	echo "  NTP сервис:   ${ntp_svc:-не запущен}"
	echo "  Время:        $(date '+%Y-%m-%d %H:%M:%S %Z')"
	echo ""

	echo "  1) Сменить часовой пояс"
	echo "  2) Установить и включить chrony"
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
			read -rp "  Часовой пояс: " tz
			if [[ -n "$tz" && -f "/usr/share/zoneinfo/$tz" ]]; then
				# симлинк + копия файла: /etc/timezone читают не все, busybox date — читает
				ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime
				printf '%s\n' "$tz" >/etc/timezone
				log_ok "Часовой пояс → $tz"
			else
				log_err "Неверный часовой пояс: $tz (нет /usr/share/zoneinfo/$tz)"
				log_info "  Список зон: apk add tzdata && ls /usr/share/zoneinfo"
			fi
		fi
		if [[ "$choice" == 2 || "$choice" == 3 ]]; then
			pkg_install_retry "chrony" || log_err "Пакет chrony недоступен"
			if svc_exists chronyd; then
				svc_enable chronyd || true
				svc_restart chronyd || svc_start chronyd || true
				svc_is_active chronyd && log_ok "chrony запущен (сверка времени)" || log_warn "chronyd не запустился"
			fi
		fi
		update_stage_status "stage12_timezone" "completed"
		;;
	*)
		log_info "Пропущено"
		update_stage_status "stage12_timezone" "skipped"
		;;
	esac
	return 0
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 13: LYNIS — АУДИТ БЕЗОПАСНОСТИ
# ═══════════════════════════════════════════════════════════════════

stage_lynis() {
	stage_banner "🔍" "13" "Аудит безопасности (Lynis)"

	if ! command -v lynis &>/dev/null; then
		# пакета lynis в репозиториях Alpine нет — не притворяемся, что поставили
		if [[ "$PKG_MGR" == apk ]]; then
			log_warn "Lynis нет в репозиториях Alpine"
			log_info "  Альтернатива: собственный этап 17 (аудит портов, SUID, LSM) или docker-образ cisofy/lynis"
			log_info "  Вручную: docker run --rm -v /:/host cisofy/lynis"
			update_stage_status "stage13_lynis" "skipped"
			return 0
		fi
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
	# busybox df не знает --type, busybox sort не знает -h: без GNU-версий
	# команды не падают, но и не делают того, что нужно
	[[ "$PKG_MGR" == apk ]] && _ensure_base_tools
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
	echo -e "    BBR модуль:         $($bbr_available && echo -e "${C_GREEN}доступен${C_RESET}" || echo -e "${C_RED}недоступен${C_RESET}")"
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

	# sysctl -p по файлу работает в т.ч. с busybox; на Alpine /etc/sysctl.d
	# подхватывает init-скрипт sysctl при загрузке.

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
			# цвета передаём аргументами и печатаем через %b: в single-quoted формате
			# printf подстановки вида ${C_GREEN} остались бы текстом на экране
			printf '  %b%s%b %-40s %b%s%b %s\n' \
				"$C_GREEN" "$ICON_OK" "$C_RESET" "$name" "$C_GREEN" "$cur" "$C_RESET" "$why"
		else
			printf '  %b%s%b %-40s %b%s%b → %b%s%b\n' \
				"$C_YELLOW" "$ICON_WARN" "$C_RESET" "$name" "$C_YELLOW" "$cur" "$C_RESET" "$C_GREEN" "$want" "$C_RESET"
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

	# ss/ip на Alpine живут в iproute2, а не в busybox
	_ensure_base_tools

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
	# Alpine: целостность пакетов проверяется своим менеджером, а не debsums
	if [[ "$PKG_MGR" == apk ]]; then
		local apkv_changed
		apkv_changed=$(apk audit --system 2>/dev/null | head -10)
		[[ -n "$apkv_changed" ]] && {
			echo ""
			echo -e "${C_BOLD}▸ Изменённые файлы пакетов (apk audit):${C_RESET}"
			echo "$apkv_changed" | sed 's/^/  /'
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
	_pam_file_names
	grep -qE '^[^#]*pam_faillock\.so' "$PAM_AUTH_FILE" 2>/dev/null
}

_pam_pwquality_active() {
	_pam_file_names
	grep -qE '^[^#]*pam_pwquality\.so' "$PAM_PASSWORD_FILE" 2>/dev/null
}

# pam modules can be in /lib/security, /lib/<triplet>/security, or /usr/lib/<triplet>/security.
# `ls existing missing` still returns failure, so use -f over candidates instead.
_pam_pwquality_module_available() {
	local f
	for f in /lib/security/pam_pwquality.so /lib/*/security/pam_pwquality.so \
		/usr/lib/security/pam_pwquality.so /usr/lib/*/security/pam_pwquality.so; do
		[[ -f "$f" ]] && return 0
	done
	return 1
}

# Проверка, что изменение PAM не сломало аутентификацию:
# pam_faillock/pwquality должны хотя бы загружаться
_pam_sanity() {
	local f
	# Alpine держит базовые стеки в base-* (login/sshd/su их включают), Debian — в common-*
	local files=(
		/etc/pam.d/common-auth /etc/pam.d/common-account /etc/pam.d/common-password
		/etc/pam.d/base-auth /etc/pam.d/base-account /etc/pam.d/base-password
	)
	local seen=0
	for f in "${files[@]}"; do
		[[ -f "$f" ]] || continue
		seen=1
		[[ -r "$f" ]] || return 1
	done
	# ни одного файла — конфигурация PAM нестандартная, править наугад нельзя
	((seen == 1)) || return 1
	# pam_faillock хранит счётчики в /var/run/faillock — каталог должен создаваться
	return 0
}

stage_pam() {
	stage_banner "🔐" "18" "Пароли и блокировка учёток (PAM)"

	# Alpine — тоже PAM (linux-pam), но стеки называются base-*. Ветка отдельная
	# не из-за имён файлов, а из-за sshd: в базовой поставке он собран БЕЗ PAM,
	# поэтому pam_faillock на вход по SSH не влияет (для этого openssh-server-pam).
	if [[ "$PKG_MGR" == apk ]]; then
		_stage_pam_apk
		return $?
	fi

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
	if _pam_pwquality_module_available; then
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

	local rc=0
	case "$choice" in
	1) _pam_enable_faillock || rc=$? ;;
	2) _pam_enable_pwquality || rc=$? ;;
	3) _pam_disable_faillock || rc=$? ;;
	*) log_info "Пропущено" ;;
	esac

	if ((rc != 0)); then
		update_stage_status "stage18_pam" "failed"
		return "$rc"
	fi
	update_stage_status "stage18_pam" "completed"
}

# Имена стеков PAM: на Alpine base-auth/base-account, в Debian/Ubuntu common-*.
# Заполняются один раз в _pam_file_names, чтобы остальные функции не знали о разнице.
_pam_file_names() {
	if [[ "$PKG_MGR" == apk ]]; then
		PAM_AUTH_FILE="/etc/pam.d/base-auth"
		PAM_ACCOUNT_FILE="/etc/pam.d/base-account"
		PAM_PASSWORD_FILE="/etc/pam.d/base-password"
	else
		PAM_AUTH_FILE="/etc/pam.d/common-auth"
		PAM_ACCOUNT_FILE="/etc/pam.d/common-account"
		PAM_PASSWORD_FILE="/etc/pam.d/common-password"
	fi
}

# Установить faillock вокруг ровно одного pam_unix в стандартном auth-стеке.
# pam_faillock требует preauth ДО проверки пароля, authfail ПОСЛЕ неё, authsucc
# при успехе. authfail перед pam_unix ломает ВСЕ входы — включая правильный
# пароль. Контроль [success=1 default=bad] пропускает authfail при успехе и
# передаёт неудачу в него; authsucc очищает счётчик после валидного пароля.
# Неизвестный/нестандартный стек (в т.ч. auth-модуль перед pam_unix) не угадываем.
_pam_apply_faillock_auth() {
	local file="$1" tmp out rc
	[[ -f "$file" ]] || return 1
	if grep -qE '^[[:space:]]*auth[[:space:]].*pam_faillock\.so' "$file" &&
		! grep -qF "# $OWN_MARK_PAM " "$file"; then
		log_err "В $file уже есть сторонний pam_faillock — не меняю стек наугад"
		return 2
	fi
	tmp=$(mktemp) && out=$(mktemp) || return 1
	awk -v marker="$OWN_MARK_PAM" '
	function emit_unix(line) {
		print "# " marker " preauth"
		print "auth required pam_faillock.so preauth silent"
		print "# " marker " original-pam-unix: " line
		if (line ~ /^[[:space:]]*auth[[:space:]]+\[[^]]+\]/) {
			sub(/\[[^]]+\]/, "[success=1 default=bad]", line)
		} else if (line ~ /^[[:space:]]*auth[[:space:]]+(required|requisite|sufficient|optional)[[:space:]]+/) {
			sub(/^[[:space:]]*auth[[:space:]]+(required|requisite|sufficient|optional)[[:space:]]+/, "auth [success=1 default=bad] ", line)
		} else {
			bad_control=1
			return
		}
		print line
		print "# " marker " authfail"
		print "auth [default=die] pam_faillock.so authfail"
		print "# " marker " authsucc"
		print "auth sufficient pam_faillock.so authsucc"
	}
	BEGIN { original_prefix="# " marker " original-pam-unix: " }
	{
		if (index($0, original_prefix) == 1) {
			original=substr($0, length(original_prefix)+1)
			next
		}
		if (index($0, "# " marker " ") == 1) next
		if ($0 ~ /^[[:space:]]*auth[[:space:]].*pam_faillock\.so/) next
		if ($0 ~ /^[[:space:]]*auth[[:space:]].*pam_unix\.so([[:space:]]|$)/) {
			count++
			if (count > 1 || auth_before_unix) bad_order=1
			line=$0
			if (original != "") { line=original; original="" }
			emit_unix(line)
			next
		}
		if ($0 ~ /^[[:space:]]*auth[[:space:]]/ && count == 0) auth_before_unix=1
		print
	}
	END {
		if (count != 1 || original != "" || bad_control || bad_order || auth_before_unix) exit 1
	}
	' "$file" >"$out"
	rc=$?
	if ((rc != 0)); then
		rm -f "$tmp" "$out"
		log_err "Не удалось безопасно разместить faillock: нужен один pam_unix без предшествующих auth-модулей в $file"
		return 1
	fi
	# Новый файл не должен менять права существующего PAM-конфига.
	cat "$out" >"$tmp" && cat "$tmp" >"$file"
	rc=$?
	rm -f "$tmp" "$out"
	return "$rc"
}

_pam_remove_faillock_auth() {
	local file="$1" tmp out
	[[ -f "$file" ]] || return 0
	if grep -qE '^[[:space:]]*auth[[:space:]].*pam_faillock\.so' "$file" &&
		! grep -qF "# $OWN_MARK_PAM " "$file"; then
		log_err "В $file есть сторонний pam_faillock — не удаляю его"
		return 1
	fi
	tmp=$(mktemp) && out=$(mktemp) || return 1
	awk -v marker="$OWN_MARK_PAM" '
	BEGIN { prefix="# " marker " original-pam-unix: " }
	{
		if (index($0,prefix)==1) { original=substr($0,length(prefix)+1); next }
		if (index($0,"# " marker " ")==1) next
		if ($0 ~ /^[[:space:]]*auth[[:space:]].*pam_faillock\.so/) next
		if (original!="" && $0 ~ /^[[:space:]]*auth[[:space:]].*pam_unix\.so([[:space:]]|$)/) {
			print original
			original=""
			next
		}
		print
	}
	END { if (original!="") exit 1 }
	' "$file" >"$out"
	if (($? != 0)); then
		rm -f "$tmp" "$out"
		log_err "Не удалось восстановить исходную строку pam_unix в $file"
		return 1
	fi
	cat "$out" >"$tmp" && cat "$tmp" >"$file"
	local rc=$?
	rm -f "$tmp" "$out"
	return "$rc"
}

_pam_enable_faillock() {
	local deny="${1:-5}" unlock="${2:-900}"
	_pam_file_names

	backup_file "$PAM_AUTH_FILE" "stage18_pam"
	backup_file "$PAM_ACCOUNT_FILE" "stage18_pam"
	backup_file "/etc/security/faillock.conf" "stage18_pam"

	# Сначала проверяем и устанавливаем правильный auth-порядок; если стек не
	# распознан, политику ещё не меняли и безопасно остановиться.
	if ! _pam_apply_faillock_auth "$PAM_AUTH_FILE"; then
		local auth_backup
		auth_backup="${BACKUP_DIR}/stage18_pam/$(basename "$PAM_AUTH_FILE")"
		[[ -f "$auth_backup" ]] && cp -a "$auth_backup" "$PAM_AUTH_FILE"
		update_stage_status "stage18_pam" "failed"
		return 1
	fi
	# account-вызов прежней версии мог остаться; удаляем только свой.
	if grep -qF "$OWN_MARK_PAM account" "$PAM_ACCOUNT_FILE" 2>/dev/null; then
		sed -i "/pam_faillock\\.so/d; /$OWN_MARK_PAM/d" "$PAM_ACCOUNT_FILE"
	fi

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
	_pam_file_names
	backup_file "$PAM_AUTH_FILE" "stage18_pam"
	backup_file "$PAM_ACCOUNT_FILE" "stage18_pam"
	_pam_remove_faillock_auth "$PAM_AUTH_FILE" || return 1
	# Мигрируем собственную account-строку прежней версии; сторонние строки не трогаем.
	if grep -qF "$OWN_MARK_PAM account" "$PAM_ACCOUNT_FILE" 2>/dev/null; then
		sed -i "/pam_faillock\\.so/d; /$OWN_MARK_PAM/d" "$PAM_ACCOUNT_FILE"
	fi
	log_ok "pam_faillock выключен (счётчики в /var/run/faillock можно удалить)"
}

_pam_enable_pwquality() {
	_pam_file_names
	# ВАЖНО: сохранить common-password ДО установки пакета. На Debian postinst
	# libpam-pwquality вызывает pam-auth-update и сам включает модуль в стек.
	# Если бэкапить после apt install, откат будет считать модуль «исходным».
	backup_file "$PAM_PASSWORD_FILE" "stage18_pam"
	backup_file "/etc/security/pwquality.conf" "stage18_pam"

	# путь к модулю тоже разный: Debian — /usr/lib/<triplet>/security, Alpine — /lib/security
	if ! _pam_pwquality_module_available; then
		if [[ "$PKG_MGR" == apk ]]; then
			log_info "Устанавливаю libpwquality..."
			pkg_install_retry "libpwquality" || {
				log_err "Пакет libpwquality недоступен"
				return 1
			}
		else
			log_info "Устанавливаю libpam-pwquality..."
			pkg_install_retry "libpam-pwquality" || {
				local snap
				snap="${BACKUP_DIR}/stage18_pam/$(basename "$PAM_PASSWORD_FILE")"
				[[ -f "$snap" ]] && cp -a "$snap" "$PAM_PASSWORD_FILE"
				log_err "Пакет libpam-pwquality недоступен; PAM-файл восстановлен"
				return 1
			}
		fi
	fi

	# Debian-пакет управляет модулем через штатный профиль pam-auth-update.
	# Он уже включён postinst'ом при обычной установке; если профиль есть,
	# просим включить его штатно, не форсируя перезапись локальных изменений.
	if [[ "$PKG_MGR" == apt ]] && ! _pam_pwquality_active && command -v pam-auth-update &>/dev/null; then
		DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwquality &>>"$LOG_FILE" || true
	fi

	# Alpine (и нестандартный Debian без профиля): явная строка перед pam_unix.
	if ! _pam_pwquality_active; then
		local tmp
		tmp=$(mktemp)
		{
			echo "$OWN_MARK pwquality"
			echo "password\trequisite\t\tpam_pwquality.so retry=3"
		} >"$tmp"
		cat "$PAM_PASSWORD_FILE" >>"$tmp"
		cat "$tmp" >"$PAM_PASSWORD_FILE"
		rm -f "$tmp"
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
		# имена файлов различаются (Alpine base-*, Debian/Ubuntu common-*), поэтому
		# восстанавливаем по имени бэкапа, а не по списку известных файлов
		local bf bn
		for bf in "$bdir"/*; do
				[[ -f "$bf" ]] || continue
				bn=$(basename "$bf")
				case "$bn" in
				common-auth | common-account | common-password | base-auth | base-account | base-password)
						cp -a "$bf" "/etc/pam.d/$bn"
						;;
				faillock.conf | pwquality.conf) cp -a "$bf" "/etc/security/$bn" ;;
				esac
		done
		log_ok "PAM восстановлен из $bdir"
}

# Alpine-ветка этапа 18. Отличие от Debian не в имени файла, а в sshd:
# штатный пакет openssh-server не слинкован с PAM, и pam_faillock там мёртв.
_stage_pam_apk() {
	local fl=false pq=false
	_pam_faillock_active && fl=true
	_pam_pwquality_active && pq=true

	echo -e "${C_BOLD}▸ Текущее состояние:${C_RESET}"
	$fl && echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  pam_faillock: включён" ||
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  pam_faillock: выключен"
	if _pam_pwquality_module_available; then
		$pq && echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  pam_pwquality: включён" ||
			echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  pam_pwquality: выключен"
	else
		echo -e "  ${C_DIM}pam_pwquality не установлен (пакет libpwquality)${C_RESET}"
	fi
	# Главная оговорка этапа: без PAM в sshd блокировка учётки на SSH не работает
	if $SSHD_HAS_PAM; then
		echo -e "  ${C_GREEN}${ICON_OK}${C_RESET}  sshd с PAM — faillock действует и на вход по SSH"
	else
		echo -e "  ${C_YELLOW}${ICON_WARN}${C_RESET}  sshd собран БЕЗ PAM: faillock подействует только на локальный вход"
		echo -e "  ${C_DIM}    вход по SSH прикрывает Fail2Ban (этап 9), а не pam_faillock${C_RESET}"
		echo -e "  ${C_DIM}    PAM для SSH: apk add openssh-server-pam и перезапуск sshd${C_RESET}"
	fi

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
	echo "  4) Показать, собран ли sshd с PAM, и как это исправить"
	echo "  S) Назад"
	read -rp "  ${ICON_ARROW} " choice

	case "$choice" in
	1)
		_pam_enable_faillock
		# без PAM в sshd предупреждаем сразу, а не после «успеха»
		$SSHD_HAS_PAM || log_warn "SSH-вход это не защитит: sshd без PAM (см. пункт 4)"
		;;
	2) _pam_enable_pwquality ;;
	3) _pam_disable_faillock ;;
	4)
		echo ""
		echo -e "  ${C_BOLD}PAM в sshd${C_RESET}"
		if $SSHD_HAS_PAM; then
			echo "    sshd слинкован с PAM — pam_faillock учитывается при входе"
			[[ -f /etc/pam.d/sshd ]] && echo "    /etc/pam.d/sshd: есть"
		else
			echo "    Сейчас: sshd без PAM, /etc/pam.d/sshd отсутствует"
			echo ""
			echo "    apk add openssh-server-pam"
			echo "    rc-service sshd restart"
			echo ""
			echo -e "    ${C_YELLOW}Ставьте этот пакет только имея под рукой консоль:${C_RESET}"
			echo "    новый sshd читает PAM, а сломанный PAM-стек закрывает вход совсем."
		fi
		echo ""
		read -rp "  Enter..." _
		;;
	*) log_info "Пропущено" ;;
	esac

	update_stage_status "stage18_pam" "completed"
	return 0
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
	if svc_is_active auditd; then
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
	echo "    - изменения времени (settimeofday/clock_settime)"
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

	svc_enable auditd || true
	svc_restart auditd || svc_start auditd || true
	sleep 2

	local active now_rules
	active=false
	svc_is_active auditd && active=true
	now_rules=$(auditctl -l 2>/dev/null | grep -c . || true)

	if ! $active; then
		# Частая причина в контейнерах (LXC/OpenVZ/Docker): нет прав на
		# cap_sys_nice/аудит, и auditd падает при старте. Сообщаем точно.
		local why=""
		# journalctl есть только на systemd-системах; на Alpine смотрим syslog
		local alog=""
		if $HAS_SYSTEMD; then
			alog=$(journalctl -u auditd -n 20 --no-pager 2>/dev/null)
		else
			alog=$(tail -n 50 /var/log/messages 2>/dev/null | grep -i auditd)
		fi
		if grep -qi 'Cannot change priority\|Operation not permitted' <<<"$alog"; then
			why="контейнер не даёт прав на аудит (нет cap_sys_nice/audit_control)"
		else
			why="смотрите: systemctl status auditd / rc-service auditd status"
		fi
		log_err "auditd не запустился: $why"
		log_info "Правила остались в $rules — на хосте (или в VM) они заведутся"
		# не оставляем неработающий сервис в цикле перезапусков
		$HAS_SYSTEMD && systemctl reset-failed auditd 2>/dev/null || true
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

	# ip -6 addr show требует iproute2 (busybox ip не умеет scope global)
	_ensure_base_tools

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
#  ЭТАП 23: АВТОЗАПУСК — ЧТО СТАРТУЕТ ВМЕСТЕ С СИСТЕМОЙ
# ═══════════════════════════════════════════════════════════════════
# Каждый включённый юнит — это служба, которая работает после перезагрузки.
# Лишнее в автозапуске = лишняя поверхность атаки и лишняя память. Здесь видно
# что включено и что выключено, и можно переключить конкретный пункт.
#
# systemd: список юнитов (enabled/disabled) и целевой target по умолчанию.
# OpenRC: runlevels (default/boot) и rc-update.

# Включённые в автозапуск юниты (по одному в строке)
_autostart_enabled() {
	if $HAS_SYSTEMD; then
		systemctl list-unit-files --no-legend --plain --type=service --state=enabled 2>/dev/null |
			awk '{print $1}' | sort
	else
		local lvl
		for lvl in default boot; do
			rc-update show "$lvl" 2>/dev/null | awk -v l="$lvl" '$2=="|" && $3==l {print $1}'
		done | sort -u
	fi
}

# Выключенные, но установленные юниты (кандидаты на включение)
_autostart_disabled() {
	if $HAS_SYSTEMD; then
		systemctl list-unit-files --no-legend --plain --type=service --state=disabled 2>/dev/null |
			awk '{print $1}' | sort
	else
		local d
		for d in /etc/init.d/*; do
			[[ -x "$d" ]] && basename "$d"
		done | sort
	fi
}

_autostart_level() {
	if $HAS_SYSTEMD; then
		printf 'target по умолчанию: %s' "$(systemctl get-default 2>/dev/null)"
	else
		printf 'уровень: default (rc-update add <служба> default)'
	fi
}

# Порядковый выбор из списка: _pick_from "Заголовок" <список>
# Печатает выбранное имя в stdout, возвращает 1 при отказе.
_pick_from() {
	local title="$1"
	shift
	local items=("$@") i=0 it
	# ВАЖНО: меню печатаем в stderr, а наружу (в $()) уходит только выбранное
	# имя — иначе pick=$(...) захватил бы весь текст меню вместе с результатом.
	echo "" >&2
	echo -e "${C_BOLD}▸ $title${C_RESET}" >&2
	for it in "${items[@]}"; do
		i=$((i + 1))
		printf '  %b%3d)%b %s\n' "$C_DIM" "$i" "$C_RESET" "$it" >&2
	done
	echo -e "  ${C_BOLD}S)${C_RESET} Назад" >&2
	echo "" >&2
	local ans
	read -rp "  ${ICON_ARROW} " ans
	[[ "${ans,,}" == "s" || -z "$ans" ]] && return 1
	[[ "$ans" =~ ^[0-9]+$ && $ans -ge 1 && $ans -le ${#items[@]} ]] || {
		log_err "Нет такого номера"
		return 1
	}
	printf '%s' "${items[$((ans - 1))]}"
	return 0
}

stage_autostart() {
	stage_banner "🔄" "23" "Автозапуск: что стартует с системой"

	local -a enabled=()
	while IFS= read -r l; do [[ -n "$l" ]] && enabled+=("$l"); done < <(_autostart_enabled)

	echo -e "${C_BOLD}▸ Сейчас:${C_RESET}"
	printf '  %s %s\n' "$(pad "Init:" 22)" "$INIT_SYSTEM ($(_autostart_level))"
	printf '  %s %s\n' "$(pad "В автозапуске:" 22)" "${#enabled[@]} служб"
	echo ""
	if [[ ${#enabled[@]} -gt 0 ]]; then
		echo -e "  ${C_BOLD}Включено:${C_RESET}"
		printf '    %s\n' "${enabled[@]}" | head -25
		[[ ${#enabled[@]} -gt 25 ]] && echo -e "    ${C_DIM}… всего ${#enabled[@]}${C_RESET}"
	fi
	echo ""
	echo "  1) Показать полный список включённых"
	echo "  2) Выключить из автозапуска"
	echo "  3) Включить в автозапуск"
	echo "  4) Найти службу в списке"
	echo "  S) Назад"
	echo ""
	read -rp "  ${ICON_ARROW} " ac

	case "$ac" in
	1)
		echo ""
		printf '    %s\n' "${enabled[@]}" 2>/dev/null || echo -e "    ${C_DIM}пусто${C_RESET}"
		echo ""
		n=$(printf '%s\n' "${enabled[@]}" 2>/dev/null | grep -c . || true)
		log_info "Всего в автозапуске: ${n:-0}"
		read -rp "  Enter..." _
		;;
	2)
		[[ ${#enabled[@]} -eq 0 ]] && {
			log_warn "Автозапуск пуст"
			return 0
		}
		local pick
		pick=$(_pick_from "Выключить из автозапуска?" "${enabled[@]}") || return 0
		echo ""
		log_warn "Служба $pick останется установленной, но не будет стартовать сама"
		hint "выключаем только автозапуск — уже запущенный процесс не тронем"
		confirm "Выключить $pick из автозапуска?" || return 0
		if step_run "Выключаю $pick из автозапуска" svc_disable "$pick"; then
			log_ok "$pick больше не стартует сам"
		else
			log_warn "Не получилось — проверьте вручную: systemctl disable $pick"
		fi
		;;
	3)
		local -a disabled=()
		while IFS= read -r l; do [[ -n "$l" ]] && disabled+=("$l"); done < <(_autostart_disabled)
		# убираем то, что уже включено, чтобы список не путал
		local -a only=() d
		for d in "${disabled[@]}"; do
			[[ " ${enabled[*]} " == *" $d "* ]] && continue
			only+=("$d")
		done
		[[ ${#only[@]} -eq 0 ]] && {
			log_info "Все установленные службы уже в автозапуске"
			return 0
		}
		local pick
		pick=$(_pick_from "Включить в автозапуск (первые 30)" "${only[@]:0:30}") || return 0
		if step_run "Включаю $pick в автозапуск" svc_enable "$pick"; then
			log_ok "$pick будет стартовать вместе с системой"
			hint "запустить сейчас: systemctl start $pick"
		else
			log_warn "Не получилось — проверьте вручную: systemctl enable $pick"
		fi
		;;
	4)
		read -rp "  Часть имени: " q
		[[ -n "$q" ]] || return 0
		echo ""
		echo -e "${C_BOLD}▸ Совпадения:${C_RESET}"
		if $HAS_SYSTEMD; then
			systemctl list-unit-files --no-legend --plain --type=service 2>/dev/null |
				grep -i -- "$q" | awk '{printf "    %-45s %s\n", $1, $2}'
		else
			rc-update show 2>/dev/null | grep -i -- "$q" | sed 's/^/    /'
		fi
		echo ""
		read -rp "  Enter..." _
		;;
	*) log_info "Пропущено" ;;
	esac

	update_stage_status "stage23_autostart" "completed"
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 22: DOCKER — УСТАНОВКА И СОСТОЯНИЕ
# ═══════════════════════════════════════════════════════════════════
# Ставим официальный Docker Engine по инструкции
# https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
# (Debian — та же схема с /linux/debian, RHEL-семейство — repo-файл + dnf,
# Alpine — свой docker из apk). Репозиторий, а не docker.io из дистрибутива:
# там версия старее и обновляется медленно.
#
# Про фаервол помним: опубликованные порты контейнеров обходят правила UFW
# через цепочку DOCKER-USER — этап 7 об этом предупреждает.

_docker_state() {
	# short | running | stopped | absent
	if ! command -v docker &>/dev/null; then
		echo absent
		return
	fi
	if svc_is_active docker; then
		# служба может быть жива, а демон не отвечать — проверяем фактом
		docker info &>/dev/null && echo running || echo stopped
	else
		echo stopped
	fi
}

_docker_report() {
	local st ver
	st=$(_docker_state)
	case "$st" in
	absent)
		echo -e "  ${C_DIM}Docker не установлен${C_RESET}"
		return 0
		;;
	running) ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null) ;;
	*) ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1) ;;
	esac
	printf '  %s %s\n' "$(pad "Docker Engine:" 22)" "${ver:-?}"
	case "$st" in
	running) printf '  %s %s\n' "$(pad "Служба:" 22)" "запущена (docker)" ;;
	stopped) printf '  %s %s\n' "$(pad "Служба:" 22)" "НЕ запущена" ;;
	esac
	if [[ "$st" == running ]]; then
		local n_cont n_img
		n_cont=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
		n_img=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
		printf '  %s %s (всего запущено; образов: %s)\n' "$(pad "Контейнеры:" 22)" "$n_cont" "$n_img"
		printf '  %s %s\n' "$(pad "Автозапуск:" 22)" "$(svc_is_enabled docker && echo "включён" || echo "выключен")"
	fi
	if command -v docker compose &>/dev/null || docker compose version &>/dev/null; then
		printf '  %s %s\n' "$(pad "Compose (plugin):" 22)" "$(docker compose version --short 2>/dev/null || echo есть)"
	fi
	if [[ "$st" != absent ]] && ! docker info &>/dev/null; then
		hint "демон не отвечает: чаще всего служба не запущена или нет прав у пользователя"
	fi
}

# Список поддерживаемых кодовых имён Docker для этого дистрибутива лежит в
# его репозитории; проверять его угадыванием не будем — просто ставим репо и
# смотрим, нашёлся ли в нём docker-ce. Если нет — откатываем свои файлы.
_docker_install_apt() {
	local codename arch repo_url
	codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
	arch=$(dpkg --print-architecture)
	case "$ID" in
	ubuntu | linuxmint | pop) repo_url="https://download.docker.com/linux/ubuntu" ;;
	debian | raspbian) repo_url="https://download.docker.com/linux/debian" ;;
	*) repo_url="https://download.docker.com/linux/${ID}" ;;
	esac
	[[ -n "$codename" ]] || {
		log_err "Не удалось определить кодовое имя дистрибутива (VERSION_CODENAME отсутствует)"
		return 1
	}

	step_run "Ставлю пакеты для ключа и репозитория" \
		apt-get install -y ca-certificates curl || return 1
	step_run "Ключ Docker (docker.asc)" bash -c "
		install -m 0755 -d /etc/apt/keyrings &&
		curl -fsSL '$repo_url/gpg' -o /etc/apt/keyrings/docker.asc &&
		chmod a+r /etc/apt/keyrings/docker.asc" || return 1

	# формат deb822 (docker.sources) — как в текущей инструкции Docker
	backup_file "/etc/apt/sources.list.d/docker.sources" "stage22_docker"
	{
		echo "Types: deb"
		echo "URIs: $repo_url"
		echo "Suites: $codename"
		echo "Components: stable"
		echo "Architectures: $arch"
		echo "Signed-By: /etc/apt/keyrings/docker.asc"
	} >/etc/apt/sources.list.d/docker.sources
	# чистим старый однострочный формат, если остался от прежних установок
	[[ -f /etc/apt/sources.list.d/docker.list ]] && {
		backup_file "/etc/apt/sources.list.d/docker.list" "stage22_docker"
		rm -f /etc/apt/sources.list.d/docker.list
	}

	step_run "Обновляю индекс пакетов с репозиторием Docker" apt-get update || {
		log_err "Репозиторий Docker не принят apt — файл sources удаляю, чтобы не ломать обновления"
		rm -f /etc/apt/sources.list.d/docker.sources
		hint "проверьте кодовое имя '$codename' в $repo_url/dists/"
		return 1
	}
	step_run "Устанавливаю Docker Engine, CLI, containerd, buildx и compose" \
		apt-get install -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin || return 1
}

_docker_install_dnf() {
	step_run "Добавляю репозиторий Docker" \
		"$PKG_MGR" config-manager --add-repo \
		"https://download.docker.com/linux/centos/docker-ce.repo" || return 1
	step_run "Устанавливаю Docker Engine и плагины" \
		"$PKG_MGR" install -y docker-ce docker-ce-cli containerd.io \
		docker-buildx-plugin docker-compose-plugin || return 1
}

_docker_install_apk() {
	# на Alpine Docker — обычный пакет; docker-openrc даёт init-скрипт.
	# Код возврата apk ненадёжен (отдаёт 1 и при успешной установке), поэтому
	# успех проверяем по факту — как в pkg_install_retry.
	if ! step_run "Устанавливаю docker из apk" apk add --no-cache docker docker-cli-compose; then
		_apk_all_installed docker docker-cli-compose || return 1
		log_info "пакеты docker установлены (apk пожаловался только на владельцев файлов)"
	fi
	pkg_install_retry docker-openrc || true
	step_run "Включаю автозапуск и запускаю docker" bash -c \
		"rc-update add docker default >/dev/null 2>&1; rc-service docker start >/dev/null 2>&1" || true
}

_docker_install() {
	echo ""
	log_warn "Docker ставится из официального репозитория (не docker.io из дистрибутива)"
	log_info "  так версия свежее и обновляется вместе с системой"
	echo ""
	# Пакеты-конкуренты из дистрибутива конфликтуют с официальными
	local conflict=() p
	for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
		if [[ "$PKG_MGR" == apt ]]; then
			dpkg -s "$p" &>/dev/null && conflict+=("$p")
		elif [[ "$PKG_MGR" == apk ]]; then
			apk info -e "$p" &>/dev/null && conflict+=("$p")
		else
			rpm -q "$p" &>/dev/null && conflict+=("$p")
		fi
	done
	if [[ ${#conflict[@]} -gt 0 ]]; then
		log_warn "Установлены несовместимые пакеты: ${conflict[*]}"
		hint "они конфликтуют с официальным Docker и должны быть удалены"
		confirm "Удалить их и продолжить?" || {
			log_info "Отменено"
			return 1
		}
		pkg_remove "${conflict[@]}" || log_warn "Часть пакетов удалить не удалось"
	fi

	steps_total 4
	case "$PKG_MGR" in
	apt) _docker_install_apt || return 1 ;;
	dnf | yum) _docker_install_dnf || return 1 ;;
	apk) _docker_install_apk || return 1 ;;
	esac

	step_run "Включаю автозапуск и запускаю службу docker" bash -c \
		"$([[ $HAS_SYSTEMD == true ]] && echo 'systemctl enable --now docker' || echo 'rc-update add docker default >/dev/null 2>&1; rc-service docker start >/dev/null 2>&1')" || true
	svc_is_enabled docker || svc_enable docker || true

	# Проверка состояния — это и есть «проверка Docker» из инструкции
	if svc_is_active docker && docker info &>/dev/null; then
		log_ok "Docker установлен и запущен ($(docker --version 2>/dev/null))"
	else
		log_err "Docker установлен, но демон не отвечает"
		hint "смотрите: systemctl status docker  (или rc-service docker status)"
		update_stage_status "stage22_docker" "failed"
		return 1
	fi
	if confirm "Проверить работу контейнером hello-world (нужна сеть)?"; then
		if step_run "Запускаю hello-world" docker run --rm hello-world; then
			log_ok "Docker работает: контейнер запустился"
		else
			log_warn "hello-world не прошёл — проверьте сеть и настройки демона"
		fi
	fi
	log_warn "Помните: опубликованные порты контейнеров обходят правила UFW (этап 7)"
	update_stage_status "stage22_docker" "completed"
	return 0
}

_docker_remove() {
	local st
	st=$(_docker_state)
	[[ "$st" == absent ]] && {
		log_info "Docker не установлен"
		return 0
	}
	echo ""
	log_warn "Удаление Docker остановит все контейнеры и снимет автозапуск"
	hint "образы, контейнеры и тома в /var/lib/docker останутся на диске"
	confirm "Удалить Docker?" || {
		log_info "Отменено"
		return 1
	}
	svc_disable_now docker || true
	case "$PKG_MGR" in
	apt)
		pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
			docker-compose-plugin docker-ce-rootless-extras || true
		;;
	dnf | yum) pkg_remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true ;;
	apk) pkg_remove docker docker-cli-compose docker-openrc || true ;;
	esac
	log_ok "Docker удалён"
	if confirm "Удалить ещё и данные (/var/lib/docker, /var/lib/containerd)?"; then
		rm -rf /var/lib/docker /var/lib/containerd && log_ok "Данные Docker удалены"
	fi
	log_info "Файлы репозитория остались: /etc/apt/sources.list.d/docker.sources и ключ"
	update_stage_status "stage22_docker" "skipped"
	return 0
}

stage_docker() {
	stage_banner "🐳" "22" "Docker: установка и состояние"

	echo -e "${C_BOLD}▸ Сейчас:${C_RESET}"
	_docker_report
	echo ""
	echo "  1) Установить Docker (официальный репозиторий)"
	echo "  2) Проверить состояние"
	echo "  3) Обновить Docker"
	echo "  4) Удалить Docker"
	echo "  S) Назад"
	echo ""
	read -rp "  ${ICON_ARROW} " dk

	case "$dk" in
	1)
		if [[ "$(_docker_state)" != absent ]]; then
			log_info "Docker уже установлен — состояние выше"
			log_info "  обновить: пункт 3, переустановить: сначала пункт 4"
			return 0
		fi
		_docker_install
		;;
	2)
		echo ""
		_docker_report
		if [[ "$(_docker_state)" == running ]]; then
			echo ""
			echo -e "${C_BOLD}▸ Контейнеры:${C_RESET}"
			docker ps --format '  {{.Names}}  {{.Image}}  {{.Status}}  {{.Ports}}' 2>/dev/null | head -15
			echo -e "${C_BOLD}▸ Занято на диске:${C_RESET}"
			docker system df 2>/dev/null | sed 's/^/  /'
		fi
		echo ""
		read -rp "  Enter..." _
		;;
	3)
		[[ "$(_docker_state)" == absent ]] && {
			log_err "Docker не установлен"
			return 1
		}
		case "$PKG_MGR" in
		apt)
			step_run "Обновляю списки пакетов" apt-get update || true
			step_run "Обновляю Docker" apt-get install -y --only-upgrade \
				docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
			;;
		dnf | yum) step_run "Обновляю Docker" "$PKG_MGR" update -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ;;
		apk) step_run "Обновляю Docker" apk -U upgrade --available docker docker-cli-compose ;;
		esac
		svc_restart docker || true
		log_ok "Обновление завершено"
		;;
	4) _docker_remove ;;
	*) log_info "Пропущено" ;;
	esac
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП 21: ЛОКАЛЬНЫЙ ВХОД (КОНСОЛЬ ПРОВАЙДЕРА)
# ═══════════════════════════════════════════════════════════════════
# У VPS кроме SSH есть «внутренняя консоль»: VNC/веб-терминал у провайдера
# или последовательный порт. Это второй вход в систему — пароли там можно
# подбирать без Fail2Ban, а root по умолчанию туда пускают. Этап закрывает
# локальные getty и вход root на консоли, оставляя только SSH.
#
# Честные границы, о которых скрипт говорит вслух:
#  - локальный вход закрывается изнутри и возвращается пунктом 2 того же этапа;
#  - в LXC/incus `pct enter` и `lxc-attach` идут в обход getty — это доступ с
#    хоста от root, а не вход в систему, и изнутри контейнера не закрывается;
#  - rescue/recovery режим провайдера — отдельная загрузка, её это не касается;
#  - SSH не ломается: pam_securetty трогает только /etc/pam.d/login.
#
# Два init: systemd — getty-юниты (mask + stop), OpenRC (Alpine) — строки
# respawn в /etc/inittab.

_state_console_file() { printf '%s' "${DATA_DIR}/.console_state"; }

# Маркер выключенной консоли в /etc/inittab — свой, а не $OWN_MARK («# seq_vps»):
# с ним вышло бы «# # seq_vps ...», а sed с разделителем # падает на решётке
# внутри шаблона.
_CONSOLE_MARK="# 4script: локальный вход отключён: "

_virt_type() {
	[[ -f /.dockerenv ]] && { echo docker; return; }
	local c=""
	[[ -r /run/systemd/container ]] && c=$(</run/systemd/container)
	case "$c" in
	lxc | incus) echo lxc; return ;;
	docker | podman) echo docker; return ;;
	systemd-nspawn) echo nspawn; return ;;
	esac
	grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && { echo lxc; return; }
	grep -qa 'container=systemd-nspawn' /proc/1/environ 2>/dev/null && { echo nspawn; return; }
	echo host
}

_virt_title() {
	case "$1" in
	host) echo "VPS/железо" ;;
	lxc) echo "LXC/incus контейнер" ;;
	docker) echo "Docker" ;;
	nspawn) echo "systemd-nspawn" ;;
	*) echo "$1" ;;
	esac
}

# Что сейчас может пустить в систему с консоли. Пусто = локальный вход закрыт.
# Важно: getty обычно не запущен заранее (VNC никто не открывал) — поэтому
# смотрим и активные, и включённые в автозагрузку инстансы, а закрытым
# считаем только замаскированный шаблон getty@.service (маска закрывает всё).
_console_getty_state() {
	local active=() n
	if $HAS_SYSTEMD; then
		[[ "$(systemctl is-enabled getty@.service 2>/dev/null)" == masked ]] && return 0
		while read -r n; do
			[[ -n "$n" ]] && active+=("$n")
		done < <(systemctl list-units --no-legend --plain --type=service --state=active \
			'getty@*.service' 'serial-getty@*.service' 'console-getty.service' 2>/dev/null |
			awk '{print $1}')
		if [[ ${#active[@]} -eq 0 ]]; then
			while read -r n; do
				[[ -n "$n" ]] && active+=("$n")
			done < <(systemctl list-unit-files --no-legend --plain --state=enabled \
				'getty@*.service' 'serial-getty@*.service' 2>/dev/null | awk '{print $1}')
		fi
	elif [[ -f /etc/inittab ]]; then
		while read -r n; do
			[[ -n "$n" ]] && active+=("$n")
		done < <(awk -F: '/^tty[0-9S]+::respawn:/ && /getty/ {print $1}' /etc/inittab)
	fi
	printf '%s' "${active[*]:-}"
}

# Пускает ли root на локальной консоли: allowed | denied | n/a
_console_root_state() {
	local login=/etc/pam.d/login
	if [[ ! -f "$login" ]] || ! grep -qE '^[^#]*pam_securetty\.so' "$login" 2>/dev/null; then
		echo n/a
		return
	fi
	if [[ -s /etc/securetty ]]; then echo allowed; else echo denied; fi
}

# root на консоли: pam_securetty читает /etc/securetty, и пустой файл значит
# «ни один tty не пускает root». Файл есть в Debian/RHEL, там модуль уже
# подключён в /etc/pam.d/login. На Alpine файла нет — там вход закрывает
# отключение getty, и придумывать лишнее не нужно.
_console_root_disable() {
	if [[ ! -f /etc/securetty ]]; then
		log_info "root на консоли: /etc/securetty нет — вопрос закрыт отключением getty"
		return 0
	fi
	if ! grep -qE '^[^#]*pam_securetty\.so' /etc/pam.d/login 2>/dev/null; then
		log_warn "pam_securetty не подключён в /etc/pam.d/login — root на консоли прикрыт только отключением getty"
		return 0
	fi
	backup_file "/etc/securetty" "stage21_console"
	: >/etc/securetty
	log_ok "root больше не входит с локальной консоли (/etc/securetty пуст)"
}

# Возврат состояния getty: то, что было активно до отключения, лежит в
# .console_state — иначе пришлось бы угадывать, включать tty2-tty6 или нет.
_console_disable() {
	local virt
	virt=$(_virt_type)
	_ssh_port_refresh
	local state
	state=$(_state_console_file)

	echo ""
	if [[ "$virt" == lxc || "$virt" == docker ]]; then
		log_warn "Это контейнер ($(_virt_title "$virt")):"
		log_info "  вход с консоли провайдера закроется, но 'pct enter' / 'lxc-attach'"
		log_info "  работают в обход getty — это доступ с хоста от root, изнутри его не закрыть"
	fi
	log_warn "После этого войти можно будет ТОЛЬКО по SSH:"
	echo "    - виртуальные консоли (tty1-tty6) и последовательный порт отключаются"
	echo "    - root с консоли провайдера входить не сможет"
	echo ""
	if $HAS_SYSTEMD && ! svc_is_active "$SSH_SERVICE"; then
		log_err "SSH сейчас НЕ запущен — отключение консоли оставит сервер без входа вообще"
	elif ! _ssh_port_reachable "$CURRENT_SSH_PORT"; then
		log_warn "Порт $CURRENT_SSH_PORT не отвечает на локальную пробу"
	else
		log_ok "SSH отвечает на порту $CURRENT_SSH_PORT"
	fi
	log_warn "Проверьте вход из ДРУГОГО окна: ssh -p $CURRENT_SSH_PORT root@<адрес>"
	log_info "Вернуть доступ: этот же этап, пункт 2 (или клавиша R). Rescue у провайдера тоже работает."
	confirm "Отключить локальный вход?" || {
		log_info "Отменено"
		return 0
	}

	if $HAS_SYSTEMD; then
		local was masks=(getty@.service serial-getty@.service console-getty.service autovt@.service) ok=() m
		was=$(_console_getty_state)
		for m in "${masks[@]}"; do
			systemctl mask "$m" &>/dev/null && ok+=("$m")
		done
		svc_daemon_reload
		# уже запущенный getty маска не останавливает — гасим его отдельно
		for m in $was; do systemctl stop "$m" &>/dev/null || true; done
		{
			echo "init=systemd"
			echo "getty_was=$was"
			echo "masks=${ok[*]}"
		} >"$state"
		log_info "getty-юниты замаскированы (${ok[*]})"
	else
		backup_file "/etc/inittab" "stage21_console"
		local tmp n
		tmp=$(mktemp)
		while IFS= read -r n; do
			if [[ "$n" =~ ^tty[0-9S]+::respawn: ]] && [[ "$n" == *getty* ]]; then
				printf '%s\n' "$_CONSOLE_MARK$n"
			else
				printf '%s\n' "$n"
			fi
		done </etc/inittab >"$tmp"
		cp "$tmp" /etc/inittab
		rm -f "$tmp"
		# init перечитает inittab по telinit q; уже работающие getty надо погасить
		telinit q &>/dev/null || true
		pkill -x getty &>/dev/null || true
		printf 'init=openrc\n' >"$state"
		log_info "Локальные getty выключены в /etc/inittab"
	fi

	_console_root_disable

	sleep 1
	local left
	left=$(_console_getty_state)
	if [[ -z "$left" ]]; then
		log_ok "Локальный вход закрыт — остался только SSH"
	else
		log_warn "Ещё активны: $left (закроются после перезагрузки)"
	fi
	update_stage_status "stage21_console" "completed"
}

# Вернуть локальный вход: снять маски (или наши комментарии) и восстановить
# /etc/securetty. Вызывается и пунктом 2, и откатом этапа (клавиша R).
_console_enable() {
	local state
	state=$(_state_console_file)
	# ключи читаем в отдельные имена: masks/getty_was — массивы в _console_disable,
	# путать их с одноимёнными строками не стоит
	local getty_list="" mask_list="" key val
	if [[ -f "$state" ]]; then
		while IFS='=' read -r key val; do
			case "$key" in
			getty_was) getty_list="$val" ;;
			masks) mask_list="$val" ;;
			esac
		done <"$state"
	fi

	if $HAS_SYSTEMD; then
		# счётчики названы иначе, чем массив ok в _console_disable: общие имена
		# в разных функциях сбивают и shellcheck, и читателя
		local m n_unmasked=0
		for m in ${mask_list:-getty@.service serial-getty@.service console-getty.service autovt@.service}; do
			systemctl unmask "$m" &>/dev/null && n_unmasked=$((n_unmasked + 1))
		done
		svc_daemon_reload
		# возвращаем ровно те консоли, что были активны до отключения
		local u n_started=0
		for u in ${getty_list:-getty@tty1.service}; do
			systemctl start "$u" &>/dev/null && n_started=$((n_started + 1))
		done
		log_ok "Маски сняты ($n_unmasked), запущено консолей: $n_started"
	elif [[ -f /etc/inittab ]]; then
		backup_file "/etc/inittab" "stage21_console"
		sed -i "s|^${_CONSOLE_MARK}||" /etc/inittab
		telinit q &>/dev/null || true
		log_ok "Локальные getty возвращены в /etc/inittab"
		hint "работающие getty поднимутся заново после telinit q или перезагрузки"
	fi

	_console_root_enable
	rm -f "$state"
	log_info "Проверьте: переключитесь на консоль провайдера (VNC/веб-терминал)"
}

_console_root_enable() {
	local bf
	for bf in $(find "${DATA_DIR}/backups" -maxdepth 2 -name "securetty" -type f 2>/dev/null | sort -r); do
		cp -a "$bf" /etc/securetty
		log_ok "Восстановлен /etc/securetty из бэкапа"
		return 0
	done
	return 0
}

# Короткая расшифровка состояния для меню и для клавиши P
_console_report() {
	local virt getty root_state
	virt=$(_virt_type)
	getty=$(_console_getty_state)
	root_state=$(_console_root_state)
	printf '  %s %s\n' "$(pad "Виртуализация:" 20)" "$(_virt_title "$virt")"
	if [[ -n "$getty" ]]; then
		printf '  %s %s\n' "$(pad "Локальный вход:" 20)" "$getty"
	else
		printf '  %s %s\n' "$(pad "Локальный вход:" 20)" "закрыт (вход только по SSH)"
	fi
	case "$root_state" in
	allowed) printf '  %s %s\n' "$(pad "root на консоли:" 20)" "разрешён" ;;
	denied) printf '  %s %s\n' "$(pad "root на консоли:" 20)" "запрещён" ;;
	*) printf '  %s %s\n' "$(pad "root на консоли:" 20)" "не проверяется (нет pam_securetty)" ;;
	esac
}

stage_console() {
	stage_banner "🖥" "21" "Локальный вход (консоль провайдера)"

	echo -e "${C_BOLD}▸ Сейчас:${C_RESET}"
	_console_report
	echo ""
	echo -e "  ${C_DIM}Консоль провайдера — это второй вход в систему мимо SSH: пароли там
  подбираются без Fail2Ban, а root туда пускают по умолчанию.${C_RESET}"
	echo ""
	echo "  1) Отключить локальный вход (оставить только SSH)"
	echo "  2) Вернуть локальный вход"
	echo "  3) Показать, что именно будет изменено"
	echo "  S) Назад"
	echo ""
	read -rp "  ${ICON_ARROW} " cchoice

	case "$cchoice" in
	1)
		local virt
		virt=$(_virt_type)
		if [[ -z "$(_console_getty_state)" ]] && [[ "$(_console_root_state)" != "allowed" ]]; then
			log_info "Локальный вход уже закрыт"
			update_stage_status "stage21_console" "completed"
			return 0
		fi
		if [[ "$virt" == lxc || "$virt" == docker ]]; then
			log_warn "Контейнер: 'pct enter'/'lxc-attach' останутся доступны с хоста (обход getty)"
		fi
		_console_disable
		;;
	2) _console_enable ;;
	3)
		echo ""
		if $HAS_SYSTEMD; then
			echo -e "  ${C_BOLD}systemd:${C_RESET} будут замаскированы юниты консолей"
			echo "    getty@.service, serial-getty@.service, console-getty.service, autovt@.service"
			echo "    и остановлены уже запущенные getty"
		elif [[ -z "$(_console_getty_state)" ]]; then
			echo -e "  ${C_BOLD}OpenRC:${C_RESET} консоли уже отключены — строк для правки нет"
		else
			echo -e "  ${C_BOLD}OpenRC (/etc/inittab):${C_RESET} строки запуска getty будут закомментированы"
			grep -nE '^tty[0-9S]+::respawn:' /etc/inittab 2>/dev/null | sed 's/^/    /'
		fi
		echo ""
		if [[ -f /etc/securetty ]] && grep -qE '^[^#]*pam_securetty\.so' /etc/pam.d/login 2>/dev/null; then
			echo -e "  ${C_BOLD}root на консоли:${C_RESET} /etc/securetty будет очищен"
			echo -e "    ${C_DIM}(файл резервируется, вход по SSH не затрагивается)${C_RESET}"
		else
			echo -e "  ${C_BOLD}root на консоли:${C_RESET} отдельно не трогаем — getty выключается целиком"
		fi
		echo ""
		read -rp "  Enter..." _
		;;
	*) log_info "Пропущено" ;;
	esac
}

# ═══════════════════════════════════════════════════════════════════
#  ЭТАП R: ОТКАТ
# ═══════════════════════════════════════════════════════════════════

stage_rollback() {

	# список этапов берём из реестра — не расходится с меню
	local def num key icon title cat fn
	for def in "${STAGE_DEFS[@]}"; do
		IFS='|' read -r num key icon title cat fn <<<"$def"
		[[ -n "$key" ]] || continue
		printf '  %2s) %s\n' "$num" "$title"
	done
	echo -e "  ${C_DIM}Откат восстанавливает файлы этапа из последнего бэкапа.${C_RESET}"
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
			[[ "$bn" == "repositories" ]] && op="/etc/apk/repositories"
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
			[[ "$bn" == "4script-security-update" ]] && op="/etc/periodic/daily/4script-security-update"
			;;
		stage10_dns)
			[[ "$bn" == "resolv.conf" ]] && op="/etc/resolv.conf"
			[[ "$bn" == "resolvconf.conf" ]] && op="/etc/resolvconf.conf"
			;;
		stage18_pam | stage19_auditd | stage9_intrusion)
			# в этих этапах бэкапится несколько файлов с разными путями, причём
			# PAM-стеки на Alpine и Debian называются по-разному — поэтому
			# восстанавливаем по имени бэкапа, а не по списку известных файлов
			case "$bn" in
			common-auth | common-account | common-password | base-auth | base-account | base-password)
				op="/etc/pam.d/$bn"
				;;
			faillock.conf | pwquality.conf) op="/etc/security/$bn" ;;
			jail.local) op="/etc/fail2ban/jail.local" ;;
			99-seq-vps.rules) op="/etc/audit/rules.d/99-seq-vps.rules" ;;
			esac
			;;
		stage22_docker)
			[[ "$bn" == "docker.sources" ]] && op="/etc/apt/sources.list.d/docker.sources"
			[[ "$bn" == "docker.list" ]] && op="/etc/apt/sources.list.d/docker.list"
			;;
		stage21_console)
			# маски systemd — не файлы: их снимает _console_enable после копирования
			case "$bn" in
			inittab) op="/etc/inittab" ;;
			securetty) op="/etc/securetty" ;;
			esac
			;;
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

	if [[ "$stage" == stage21_console ]]; then
		# файлы уже вернулись из бэкапа, осталось снять маски getty и включить консоли
		_console_enable
	fi

	if [[ "$stage" == stage5_ssh_config || "$stage" == stage6_sftp_user ]]; then
		if sshd -t 2>&1 | tee -a "$LOG_FILE"; then
			svc_restart "$SSH_SERVICE" && log_ok "SSH перезапущен"
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
	echo -e "  ${C_DIM}Порядок для нового сервера: 0, 1, 2, 4 → проверь вход по ключу…"
	echo -e "  ${C_DIM}→ 7 (фаервол) → 5 (порт и пароли) → 8, 9 → 3 (пароль root) → остальное.${C_RESET}"
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
	printf "    %s %b%s%b\n" "$(pad "$1" 38)" "${3:-}" "$2" "$C_RESET"
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

	# ── Локальный вход ──
	echo ""
	echo -e "${C_BOLD}🖥  Локальный вход (консоль)${C_RESET}"
	local cgetty croot
	cgetty=$(_console_getty_state)
	croot=$(_console_root_state)
	if [[ -n "$cgetty" ]]; then
		_show_kv "getty" "активны: $cgetty" "$C_YELLOW"
	else
		_show_kv "getty" "выключены (вход только по SSH)" "$C_GREEN"
	fi
	case "$croot" in
	allowed) _show_kv "root на консоли" "разрешён" "$C_YELLOW" ;;
	denied) _show_kv "root на консоли" "запрещён" "$C_GREEN" ;;
	*) _show_kv "root на консоли" "не проверяется (нет pam_securetty)" "$C_DIM" ;;
	esac

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
	if [[ "$PKG_MGR" != apt && "$PKG_MGR" != apk ]]; then
		_show_kv "PAM" "правится только вручную (${PKG_MGR})" "$C_DIM"
	elif [[ "$PKG_MGR" == apk && "$SSHD_HAS_PAM" != true ]]; then
		_show_kv "sshd с PAM" "нет — faillock не влияет на SSH-вход" "$C_YELLOW"
	fi
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
	if svc_is_active auditd; then
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
	elif [[ -f /etc/periodic/daily/4script-security-update ]]; then
		au="ежедневный apk upgrade (periodic/daily)"
	fi
	_show_kv "Автообновления" "$au"
	local rt="выключена"
	if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades-local ]]; then
		rt=$(grep -oE 'Automatic-Reboot "true"' /etc/apt/apt.conf.d/50unattended-upgrades-local &>/dev/null && echo "включена" || echo "выключена")
	fi
	_show_kv "Авто-перезагрузка" "$rt"
	# init системы: важно видеть, чем скрипт управляет сервисами (systemctl или rc-*)
	_show_kv "Init / сервисы" "$INIT_SYSTEM ($([[ $HAS_SYSTEMD == true ]] && echo systemctl || echo rc-service/rc-update))"
	if [[ "$PKG_MGR" == apk ]]; then
		_show_kv "NTP (chrony)" "$(svc_is_active chronyd && echo "запущен" || echo "не запущен")"
		_show_conf_file "/etc/timezone" "часовой пояс"
	fi
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

	# LC_ALL=C.UTF-8 и screen -U обязательны: по неинтерактивному ssh локаль
	# пустая, screen считает терминал 8-битным и перекодирует многобайтные
	# символы (рамки, блоки прогресса, галочки) в мусор. Проверено замерами:
	# без -U в каждом прогоне 2 битых байта, с -U — ноль.
	local env_prefix="LC_ALL=C.UTF-8 LANG=C.UTF-8"
	if [[ "$mux" == screen ]]; then
		log_info "Запускаю внутри screen (сессия $REMOTE_SESSION) — обрыв связи не прервёт настройку"
		remote_run_remote "$env_prefix screen -U -dmS $REMOTE_SESSION bash -c 'cd /tmp && exec bash ./4script.sh'" || return 1
		return 0
	elif [[ "$mux" == tmux ]]; then
		log_info "Запускаю внутри tmux (сессия $REMOTE_SESSION)"
		remote_run_remote "$env_prefix tmux new-session -d -s $REMOTE_SESSION 'cd /tmp && bash ./4script.sh'" || return 1
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
		# -t обязателен: меню требует терминал. Локаль и -U — по той же причине,
		# что при запуске: иначе кириллица и рамки приходят битыми.
		log_info "Подключаюсь к screen-сессии $REMOTE_SESSION (отключиться — Ctrl-A d, выйти — Q в меню)"
		# shellcheck disable=SC2029
		ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" "LC_ALL=C.UTF-8 LANG=C.UTF-8 screen -U -r $REMOTE_SESSION"
		;;
	tmux)
		log_info "Подключаюсь к tmux-сессии $REMOTE_SESSION (отключиться — Ctrl-B d)"
		# shellcheck disable=SC2029
		ssh "${opts[@]}" "${ka[@]}" "$(_remote_target)" "LC_ALL=C.UTF-8 LANG=C.UTF-8 tmux attach -t $REMOTE_SESSION"
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

	# 2a. Скрипт написан на bash, а на голом Alpine его нет (там /bin/sh — ash).
	# Без этой проверки удалённый прогон падает первой же строкой
	# «bash: not found» — и выглядит это как непонятная ошибка ssh.
	if ! remote_run_remote 'command -v bash >/dev/null' &>/dev/null; then
		if remote_run_remote 'command -v apk >/dev/null' &>/dev/null; then
			log_warn "На сервере нет bash (Alpine) — ставлю его"
			if remote_run_remote "${REMOTE_SUDO:+$REMOTE_SUDO }apk add --no-cache bash" &>/dev/null &&
				remote_run_remote 'command -v bash >/dev/null' &>/dev/null; then
				log_ok "bash установлен на сервере"
			else
				log_err "Не удалось поставить bash на сервере (нужен доступ в сеть)"
				log_info "Вручную на сервере: apk add bash"
				return 1
			fi
		else
			log_err "На сервере нет bash — запустить скрипт нечем"
			log_info "Установите bash пакетным менеджером сервера и повторите"
			return 1
		fi
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
	# alpine-base не содержит screen/tmux, но у скрипта есть свои пакеты: в фоне
	# сессия не оборвётся при потере связи
	log_info "  Поставьте на сервере: apk add screen  (или tmux)"
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
	echo "  Поддерживает: Debian, Ubuntu, Fedora, RHEL, CentOS, Rocky, AlmaLinux, Alpine."
	echo "  Init: systemd (Debian/RHEL) либо OpenRC (Alpine)."
	echo ""
	echo "  Использование:"
	echo "    sudo ./4script.sh                     — интерактивное меню на этом сервере"
	echo "    sudo ./4script.sh --verbose           — показывать вывод команд на экране"
	echo "    sudo ./4script.sh --quiet             — только ошибки"
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
		-v | --verbose)
			# показывать вывод команд прямо на экране, а не только в логе
			UI_VERBOSE=true
			shift
			;;
		-q | --quiet)
			# только ошибки: удобно для запуска из другого скрипта
			UI_QUIET=true
			shift
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
