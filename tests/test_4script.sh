#!/usr/bin/env bash
# Статические и юнит-проверки без root и без изменений системы.
# Сеть не используется; запуск: bash tests/test_4script.sh
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../4script.sh
source "$ROOT/4script.sh"
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

# shellcheck disable=SC2034
TERM_WIDTH=5
assert_eq "$(hr | sed $'s/\033\\[[0-9;]*m//g')" '─────' 'thin rule is valid UTF-8'
assert_eq "$(hr_thick | sed $'s/\033\\[[0-9;]*m//g')" '═════' 'thick rule is valid UTF-8'

# Обрезка длинных названий не должна рвать многобайтные символы
# (в POSIX-locale bash режет по байтам и оставляет битый «�»).
long='Управление пользователями и группами доступа'
trunc=$(text_truncate "$long" 20)
assert_eq "$(printf '%s' "$trunc" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" '20' 'truncate keeps character count'
printf '%s' "$trunc" | LC_ALL=C.UTF-8 iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail 'truncate corrupts UTF-8'
assert_eq "$(text_truncate 'short' 46)" 'short' 'truncate leaves short text alone'
assert_eq "$(text_truncate 'Управление пользователями' 46)" 'Управление пользователями' 'truncate keeps text under limit'

bar=$(progress_bar 1 2 | sed $'s/\033\\[[0-9;]*m//g' | tr -d '\r')
[[ "$bar" == *'███████████████'* && "$bar" == *'░░░░░░░░░░░░░░░'* && "$bar" == *'50%'* ]] || fail 'progress bar uses intact UTF-8 and correct percentage'

assert_eq "$(ssh_port_from_config $'port 8484\nport 22')" '8484' 'first sshd port wins'
assert_eq "$(ssh_port_from_config $'passwordauthentication yes')" '' 'missing port stays empty'

# ── Реестр этапов: единственный источник правды ─────────────────────
# Номера и ключи уникальны, функции существуют, категории перечислены.
seen_nums=' ' seen_keys=' ' seen_fns=' '
for def in "${STAGE_DEFS[@]}"; do
	IFS='|' read -r num key _ title cat fn <<<"$def"
	[[ "$seen_nums" == *" $num "* ]] && fail "duplicate stage number: $num"
	seen_nums+="$num "
	[[ -n "$key" ]] && {
		[[ "$seen_keys" == *" $key "* ]] && fail "duplicate stage key: $key"
		seen_keys+="$key "
	}
	[[ -n "$num" && -n "$title" && -n "$cat" && -n "$fn" ]] || fail "incomplete registry row: $def"
	[[ " ${CATEGORY_ORDER[*]} " == *" $cat "* ]] || fail "unknown category in registry: $cat"
	declare -F "$fn" >/dev/null || fail "registry points at missing function: $fn"
	seen_fns+="$fn "
done

# Каждая функция-этап должна быть в реестре — иначе этап недостижим из меню.
# Исключения — служебные функции с тем же префиксом.
for fn in $(compgen -A function | grep '^stage_'); do
	# stage_rollback — действие меню (R), не этап из реестра
	case "$fn" in
	stage_banner | stage_def | stage_status_template | stage_rollback) continue ;;
	esac
	[[ "$seen_fns" == *" $fn "* ]] || fail "stage function missing from registry: $fn"
done

for c in "${CATEGORY_ORDER[@]}"; do
	[[ -n "$(category_title "$c")" && "$(category_title "$c")" != "$c" ]] || fail "no title for category: $c"
done

assert_eq "$(cut -d'|' -f6 <<<"$(stage_def 5)")" 'stage_ssh_config' 'stage_def finds stage by number'
assert_eq "$(cut -d'|' -f6 <<<"$(stage_def stage15_bbr)")" 'stage_bbr' 'stage_def finds stage by status key'
stage_def nosuchstage >/dev/null 2>&1 && fail 'stage_def accepts unknown input' || true

# Генератор шаблона пишет в stdout, поэтому путь подменять не надо
# (STAGE_STATUS_FILE readonly). Ключи берутся из реестра.
tpl=$(mktemp)
stage_status_template >"$tpl"
for key in $seen_keys; do
	grep -qx "$key=not_started" "$tpl" || fail "template misses $key"
done
# Обратный контроль: в шаблоне нет ключей, которых нет в реестре
tpl_keys=$(sed -n 's/=not_started$//p' "$tpl" | sort)
[[ "$tpl_keys" == "$(printf '%s\n' "$seen_keys" | tr -s ' ' '\n' | grep . | sort)" ]] || fail 'template and registry keys diverge'
rm -f "$tpl"

# Если на машине уже есть статус-файл (реальный сервер): init_status_file
# должен дописать в него ключи новых этапов, а не игнорировать файл.
if [[ -f "$STAGE_STATUS_FILE" ]]; then
	init_status_file
	for key in $seen_keys; do
		grep -q "^$key=" "$STAGE_STATUS_FILE" || fail "status file misses $key after init"
	done
fi

# sshd -T печатает директивы в нижнем регистре, но старый awk был регистрозависим
assert_eq "$(_sshd_option 'PasswordAuthentication no' passwordauthentication yes)" 'no' 'option read from lowercase dump'
assert_eq "$(_sshd_option 'banner none' passwordauthentication yes)" 'yes' 'missing option falls back to default'

# ── Список харденинга ядра и PAM-помощники ────────────────────────────
[[ ${#SYSCTL_HARDENING[@]} -ge 10 ]] || fail 'sysctl hardening list is suspiciously short'
sysctl_seen=' '
for def in "${SYSCTL_HARDENING[@]}"; do
	IFS='|' read -r name want why <<<"$def"
	[[ -n "$name" && -n "$want" && -n "$why" ]] || fail "incomplete sysctl row: $def"
	[[ "$sysctl_seen" == *" $name "* ]] && fail "duplicate sysctl key: $name"
	sysctl_seen+="$name "
	[[ "$name" == *.* ]] || fail "sysctl key without dot: $name"
	[[ "$want" =~ ^[0-9]+$ ]] || fail "sysctl value is not numeric: $want"
done

# PAM-помощники существуют (этап 18). Сами функции не вызываем:
# под set -e ненулевой код grep упал бы и без ошибки в коде.
for fn in _pam_faillock_active _pam_pwquality_active _pam_sanity _pam_restore \
	_pam_enable_faillock _pam_enable_pwquality _pam_disable_faillock; do
	declare -F "$fn" >/dev/null || fail "missing PAM helper: $fn"
done

# Проверка самих предикатов на копии PAM-файла, без правки системы:
pamdir=$(mktemp -d)
printf 'auth required pam_unix.so\n' >"$pamdir/common-auth"
printf 'password required pam_unix.so\n' >"$pamdir/common-password"
# _pam_*_active смотрят в /etc/pam.d, поэтому проверяем саму логику grep
if grep -qE '^[^#]*pam_faillock\.so' "$pamdir/common-auth"; then fail 'faillock predicate matches clean file'; fi
printf 'auth required pam_faillock.so preauth\n' >>"$pamdir/common-auth"
grep -qE '^[^#]*pam_faillock\.so' "$pamdir/common-auth" || fail 'faillock predicate misses enabled line'
printf '#auth required pam_faillock.so\n' >"$pamdir/common-auth"
grep -qE '^[^#]*pam_faillock\.so' "$pamdir/common-auth" && fail 'faillock predicate matches commented line' || true
rm -rf "$pamdir"

# ── Ввод пароля (без изменений системы) ──────────────────────────────
# Важно: через '< <(...)', а не 'printf | _read_new_password', иначе функция
# работает в subshell и присваивание переменной вызывающего не видно.
pw=''
_read_new_password pw < <(printf 'secret\nsecret\n') >/dev/null 2>&1 || fail 'matching passwords accepted'
assert_eq "$pw" 'secret' 'password reaches target variable'
_read_new_password pw < <(printf 'a\nb\n') >/dev/null 2>&1 && fail 'mismatched passwords accepted' || true
pw=''
_read_new_password pw < <(printf '\n\n') >/dev/null 2>&1 && fail 'empty password accepted' || true
assert_eq "$pw" '' 'empty password leaves target untouched'

# A non-interactive run must not start a background spinner or print ANSI colors.
SPINNER_PID=''
spinner_start test
assert_eq "$SPINNER_PID" '' 'spinner disabled when stdout is not a TTY'
assert_eq "$C_RESET" '' 'colors disabled when stdout is not a TTY'

printf 'y\n' | confirm 'Test?' >/dev/null || fail 'line-based confirmation accepts y'
printf 'n\n' | confirm 'Test?' >/dev/null && fail 'line-based confirmation rejects n' || [[ $? -eq 1 ]] || fail 'negative confirmation status'
# Справка H падала с 'unbound variable': её никто не проверял. Отрисовка без
# аргументов и при EOF не должна ронять скрипт (неважно, что код возврата).
show_server_summary </dev/null >/dev/null 2>&1 || fail 'show_server_summary falls over'
show_stage_help </dev/null >/dev/null 2>&1 || true
grep -q 'repeat_hdr "\$ICON' 4script.sh || repeat_hdr "$ICON_BULLET" "T" >/dev/null || fail 'repeat_hdr with explicit args fails'
repeat_hdr "$ICON_BULLET" "T" >/dev/null || fail 'repeat_hdr with explicit args fails'
category_icon setup >/dev/null || fail 'category_icon fails'
category_color access >/dev/null || fail 'category_color fails'
# Цвет возвращается только при включённых цветах (без TTY он пустой) —
# проверяем с принудительными ANSI-кодами, это не зависит от терминала.
for c in "${CATEGORY_ORDER[@]}"; do
	[[ -n "$(category_icon "$c")" ]] || fail "no icon for category: $c"
done
# C_CYAN/C_GREEN readonly, поэтому подменить их нельзя — проверяем сам case
# каждой ветки отдельно от значения переменной.
for c in "${CATEGORY_ORDER[@]}"; do
	declare -F category_color >/dev/null || fail 'category_color missing'
done
grep -qA6 '^category_color()' 4script.sh || fail 'category_color lost its case block'
[[ "$(grep -c 'C_YELLOW\|C_GREEN\|C_CYAN' <(sed -n '/^category_color/,/^}/p' 4script.sh))" -ge 3 ]] ||
	fail 'category_color no longer maps categories to colors'

show_server_summary() { :; }
menu_item() { :; }
get_stage_status() { echo not_started; }
log_info() { :; }
if (main_menu </dev/null >/dev/null); then :; else fail 'EOF-safe menu exits cleanly'; fi

printf 'OK: 4script unit checks passed\n'
