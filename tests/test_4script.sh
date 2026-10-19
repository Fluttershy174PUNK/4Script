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

# ── Удалённый режим: разбор адреса сервера ───────────────────────────
# 6 рабочих форматов из справки должны разбираться без обращения к сети.
while IFS='|' read -r spec want_user want_host want_port; do
	[[ -n "$spec" ]] || continue
	REMOTE_USER="" REMOTE_HOST="" REMOTE_PORT="22"
	remote_parse_target "$spec" 2>/dev/null || fail "remote_parse_target rejected valid spec: $spec"
	assert_eq "$REMOTE_USER@$REMOTE_HOST:$REMOTE_PORT" "$want_user@$want_host:$want_port" "remote spec $spec"
done <<'SPECS'
root@10.0.20.205|root|10.0.20.205|22
root@10.0.20.205:8484|root|10.0.20.205|8484
root@10.0.20.205@8484|root|10.0.20.205|8484
admin@example.com:2222|admin|example.com|2222
10.0.20.205|root|10.0.20.205|22
test-ubuntu.lan|root|test-ubuntu.lan|22
SPECS

# Плохие адреса должны отклоняться, а не превращаться в «root@root@»
for spec in '' 'root@' '@host' 'host:0' 'host:99999' 'host:abc' 'user@ho st' 'us er@host'; do
	REMOTE_USER="" REMOTE_HOST="" REMOTE_PORT="22"
	remote_parse_target "$spec" >/dev/null 2>&1 && fail "remote_parse_target accepted bad spec: '$spec'" || true
done

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

# ── Alpine: выбор пакетного менеджера ────────────────────────────────
# Сама detect_distro завершает скрипт на неизвестном ID, поэтому тестируем
# чистую _pkg_mgr_for_id и проверяем, что detect_distro её действительно зовёт.
assert_eq "$(_pkg_mgr_for_id debian)" 'apt' 'debian -> apt'
assert_eq "$(_pkg_mgr_for_id ubuntu)" 'apt' 'ubuntu -> apt'
assert_eq "$(_pkg_mgr_for_id alpine)" 'apk' 'alpine -> apk'
assert_eq "$(_pkg_mgr_for_id postmarketos)" 'apk' 'postmarketos -> apk'
_pkg_mgr_for_id gentoo >/dev/null && fail 'unknown distro must not resolve a package manager' || true
grep -q '_pkg_mgr_for_id "${ID:-}"' 4script.sh || fail 'detect_distro no longer uses _pkg_mgr_for_id'
grep -q 'alpine | postmarketos)' 4script.sh || fail 'alpine missing from package-manager mapping'

# Alpine не должен нигде требовать systemd напрямую: все сервисные операции
# обязаны идти через svc_*, иначе init-agnostic-обещание — ложь.
for fn in svc_is_active svc_is_enabled svc_start svc_stop svc_restart svc_enable svc_disable svc_enable_now svc_disable_now svc_daemon_reload svc_exists; do
	declare -F "$fn" >/dev/null || fail "missing service helper: $fn"
done
grep -q 'rc-update add "\$1" default' 4script.sh || fail 'svc_enable does not use rc-update on OpenRC'
grep -q 'rc-service "\$1" status' 4script.sh || fail 'svc_is_active does not use rc-service on OpenRC'
# systemctl допустим только внутри самого слоя (функции svc_*) и под проверкой
# $HAS_SYSTEMD. Ищем вызовы вне body svc_*-функций, а не по подстроке — иначе
# тест ловит собственные строки слоя и комментарии.
bare=$(awk '
	/^svc_[a-z_]*\(\)/ { inlayer=1 }
	inlayer && /^\}/ { inlayer=0; next }
	systemctl { if (!inlayer) print NR": "$0 }
' 4script.sh | grep -vE 'HAS_SYSTEMD|ssh\.socket|systemd-resolved|list-unit-files' || true)
[[ -z "$bare" ]] || fail "systemctl used outside the service layer: $bare"

# Alpine-пакеты: имена, которых нет в apk (проверены вручную), не должны
# оставаться в коде как безусловные установки.
grep -q 'libpwquality' 4script.sh || fail 'Alpine pwquality package name missing'
grep -q 'libpam-pwquality' 4script.sh || fail 'Debian pwquality package name lost'
grep -q 'ufw-openrc' 4script.sh || fail 'ufw-openrc is required for UFW autostart on Alpine'
grep -q '/etc/periodic/daily/4script-security-update' 4script.sh || fail 'Alpine autoupdate script missing'

# PAM-стеки: Alpine base-*, Debian/Ubuntu common-*. Пути не должны быть
# захардкожены в теле функций (иначе Alpine правит несуществующие файлы).
grep -q 'PAM_AUTH_FILE="/etc/pam.d/base-auth"' 4script.sh || fail 'Alpine PAM auth stack missing'
grep -q 'PAM_AUTH_FILE="/etc/pam.d/common-auth"' 4script.sh || fail 'Debian PAM auth stack missing'

# Откат: этап 18 бэкапит несколько файлов и имена стеков различаются между
# Alpine и Debian — общая ветка должна покрывать оба набора имён.
grep -q 'stage18_pam | stage19_auditd | stage9_intrusion)' 4script.sh || fail 'rollback lost the multi-file PAM/f2b/audit branch'
grep -q 'base-account' 4script.sh || fail 'rollback does not restore Alpine PAM stacks'
_pam_restore_body=$(sed -n '/^_pam_restore()/,/^}/p' 4script.sh)
grep -q 'base-password' <<<"$_pam_restore_body" || fail '_pam_restore cannot restore Alpine base-password'
grep -q 'common-password' <<<"$_pam_restore_body" || fail '_pam_restore cannot restore Debian common-password'

# apk возвращает 1 и когда пакет реально установлен (артефакты chown в
# контейнере) — поэтому успех обязан проверяться через apk info -e.
grep -q 'apk info -e' 4script.sh || fail 'apk install success must be verified with apk info -e'

# Alpine без syslog-демона: init-скрипт даёт только busybox-openrc
grep -q 'busybox-openrc' 4script.sh || fail 'Alpine syslog needs busybox-openrc (init script)'

# _server_ip — замена hostname -I, которого нет в busybox
grep -q 'hostname -I' 4script.sh || fail '_server_ip lost its fast path'
declare -F _server_ip >/dev/null || fail 'missing _server_ip helper'

# ── Цвета не должны печататься текстом ────────────────────────────────
# C_* объявлены в ОДИНАРНЫХ кавычках, то есть содержат литерал «\033[1m», а не
# настоящий escape. Такой литерал превращают в цвет только echo -e и printf %b;
# обычный echo печатает «\033[1m» прямо на экране. Оба случая уже случались.
bad=$(grep -nE '^[[:space:]]*echo "[^"]*\$\{C_' 4script.sh || true)
[[ -z "$bad" ]] || fail "echo without -e prints colour escapes literally: $bad"
# \${C_ должен встречаться ВНУТРИ одинарного формата (до закрывающей кавычки):
# в корректной строке цвета идут аргументами и через %b, вне формата.
bad=$(grep -nE "^[[:space:]]*printf '[^']*\\\$\\{C_" 4script.sh || true)
[[ -z "$bad" ]] || fail "single-quoted printf format keeps \${C_...} as text: $bad"
# обратная проверка: объявления остались в одинарных кавычках, иначе тесты выше
# перестали бы ловить именно этот класс ошибок
grep -qF "C_BOLD='\033[1m'" 4script.sh || fail 'colour declarations changed shape — re-check escape tests'

# ── Этап 21: локальный вход ───────────────────────────────────────────
# Отключение консоли ломается тише всего: /etc/inittab легко склеить в одну
# строку или оставить сервер без единого входа.
for fn in _virt_type _console_getty_state _console_root_state _console_disable _console_enable _console_report stage_console; do
	declare -F "$fn" >/dev/null || fail "missing console helper: $fn"
done
grep -q 'stage21_console' 4script.sh || fail 'stage 21 (console) missing from the registry'
grep -q 'stage21_console)$' 4script.sh || fail 'stage 21 missing from the rollback mapping'
grep -q '^_CONSOLE_MARK=' 4script.sh || fail 'console marker must be its own constant (OWN_MARK has a #)'
grep -qF 'sed -i "s|^${_CONSOLE_MARK}||"' 4script.sh ||
	fail 'inittab restore must strip the marker with | as delimiter'
# литерал «\n» в printf склеивает файл в одну строку — уже случалось
bad=$(grep -nE "printf '[^']*\\\\\\\\n" 4script.sh || true)
[[ -z "$bad" ]] || fail "printf with a doubled backslash prints literal \\n: $bad"

# ── Перезапуск SSH после правки ключей ───────────────────────────────
declare -F _ssh_after_keys_change >/dev/null || fail 'missing _ssh_after_keys_change'
grep -q '_ssh_after_keys_change "Ключи обновлены"' 4script.sh || fail 'stage 4 does not restart SSH after key changes'
# рестарт без валидации конфига добил бы работающий sshd
ssh_diag=$(sed -n '/^_ssh_after_keys_change()/,/^}/p' 4script.sh)
grep -q 'sshd -t' <<<"$ssh_diag" || fail '_ssh_after_keys_change does not validate sshd config before restart'
grep -q 'svc_is_active "$SSH_SERVICE"' <<<"$ssh_diag" || fail '_ssh_after_keys_change does not start a stopped SSH service'

# ── Удаление / замена защиты от брутфорса (этап 9) ────────────────────
for fn in _intrusion_state pkg_remove _remove_fail2ban _remove_crowdsec; do
	declare -F "$fn" >/dev/null || fail "missing intrusion helper: $fn"
done
grep -q 'Заменить на другую' 4script.sh || fail 'stage 9 has no replace option'
grep -q 'Оставить как есть' 4script.sh || fail 'stage 9 has no keep option'

# ── root должен быть в списке для ключей ─────────────────────────────
grep -q 'get_regular_users --with-root' 4script.sh || fail 'root missing from the SSH key user list'
sshsel=$(sed -n '/^stage_ssh_key()/,/^}/p' 4script.sh)
grep -q -- '--with-root' <<<"$sshsel" || fail 'stage 4 does not use --with-root'
userssel=$(sed -n '/^stage_users()/,/^}/p' 4script.sh)
grep -q -- '--with-root' <<<"$userssel" && fail 'stage 2 must not list root as an ordinary user'

# ── Единый стиль клавиш ─────────────────────────────────────────────
# Договорённость: пункты меню — цифры, выход/пропуск — S. Буквы остаются только
# для сервисных действий, как P/H/R/Q в главном меню.
bad=$(grep -nE '^[[:space:]]*echo( -e)? "  [0-9]\) Пропустить' 4script.sh || true)
[[ -z "$bad" ]] || fail "skip/exit must be S, not a digit: $bad"
# этап 2 раньше выбивался из всех остальных меню буквами C/P/G/D
bad=$(grep -nE '\$\{C_BOLD\}[CPGD]\)' 4script.sh || true)
[[ -z "$bad" ]] || fail "stage 2 still uses letter action keys: $bad"
# выход есть в каждом меню и он всегда S
for fn in stage_utilities stage_users stage_ssh_key stage_ssh_config stage_sftp_user stage_ufw stage_dns stage_timezone stage_ipv6 stage_pam stage_disk stage_console; do
	body=$(sed -n "/^$fn()/,/^}/p" 4script.sh)
	grep -qE 'S\).*(Пропустить|Назад|Завершить|отмена|Пропуск)' <<<"$body" ||
		fail "$fn has no 'S) ...' exit key"
done

# ── Подсказки для новичков ───────────────────────────────────────────
declare -F hint >/dev/null || fail 'missing hint helper'
grep -q 'prohibit-password — по ключу можно' 4script.sh ||
	fail 'the SSH root-login menu lost its plain-language hint'
grep -q '«Connection refused»' 4script.sh || fail 'SSH diagnostics lost the Connection refused hint'
declare -F _ssh_diagnose >/dev/null || fail 'missing _ssh_diagnose'
grep -q 'Почему не пускает SSH' 4script.sh || fail 'stage 5 has no diagnostics menu item'

# ── Показ выполняемых команд (UI) ────────────────────────────────────
for fn in step_run step_note steps_total pad _now_us; do
	declare -F "$fn" >/dev/null || fail "missing UI helper: $fn"
done
# шаг обязан показать и описание, и саму команду, и результат со временем
step_body=$(sed -n '/^step_run()/,/^}/p' 4script.sh)
grep -q '\$ %s' <<<"$step_body" || fail 'step_run does not print the command it runs'
grep -q 'ICON_OK' <<<"$step_body" || fail 'step_run does not print a success mark'
grep -q 'STEP_OUT' <<<"$step_body" || fail 'step_run does not keep output for diagnostics'
grep -q 'UI_VERBOSE' <<<"$step_body" || fail 'step_run ignores --verbose'
grep -q 'UI_QUIET' <<<"$step_body" || fail 'step_run ignores --quiet'
grep -q -- '--verbose' 4script.sh || fail '--verbose flag missing from main'
grep -q -- '--quiet' 4script.sh || fail '--quiet flag missing from main'
# команда должна печататься копипастабельно (%q), а не склеенной через $*
grep -q "printf '%q '" <<<"$step_body" || fail 'step_run must quote arguments with %q'
# счётчик шагов не должен переполняться
grep -q 'STEP_NO <= STEP_TOTAL' <<<"$step_body" || fail 'step counter can print 4/3'

# pad(): printf %-Ns в bash считает БАЙТЫ, поэтому кириллица в колонках
# разъезжается. Свой pad считает символы.
assert_eq "$(printf '%s' "$(pad 'аб' 6)" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" '6' 'pad counts characters'
assert_eq "$(pad 'abc' 2)" 'abc' 'pad never truncates'
[[ "$(printf '%s' "$(pad 'Служба:' 22)" | LC_ALL=C.UTF-8 wc -m | tr -d ' ')" == '22' ]] ||
	fail 'pad does not pad Cyrillic to the requested width'

# _pick_from: меню обязано идти в stderr, иначе pick=$(...) захватит текст меню
pick_body=$(sed -n '/^_pick_from()/,/^}/p' 4script.sh)
grep -q '>&2' <<<"$pick_body" || fail '_pick_from leaks its menu into stdout'

# ── Этап 22 (Docker) и 23 (автозапуск) ───────────────────────────────
grep -q 'stage22_docker' 4script.sh || fail 'stage 22 (docker) missing from the registry'
grep -q 'stage23_autostart' 4script.sh || fail 'stage 23 (autostart) missing from the registry'
for fn in _docker_state _docker_report _docker_install _docker_remove stage_docker; do
	declare -F "$fn" >/dev/null || fail "missing docker helper: $fn"
done
# установка идёт из официального репозитория, а не docker.io из дистрибутива
grep -q 'download.docker.com' 4script.sh || fail 'docker install must use the official repository'
grep -q 'docker-ce docker-ce-cli containerd.io' 4script.sh || fail 'docker package list lost its core packages'
grep -q 'docker-buildx-plugin docker-compose-plugin' 4script.sh || fail 'docker buildx/compose plugins missing'
grep -q '/etc/apt/keyrings/docker.asc' 4script.sh || fail 'docker GPG key step missing'
grep -q 'docker.sources' 4script.sh || fail 'docker deb822 sources file missing'
# apk отдаёт 1 и при удачной установке — проверяем факт, как в pkg_install_retry
docker_apk=$(sed -n '/^_docker_install_apk()/,/^}/p' 4script.sh)
grep -q '_apk_all_installed' <<<"$docker_apk" || fail 'docker apk install trusts apk exit code'
# состояние проверяется фактом (docker info), а не только статусом службы
grep -q 'docker info' 4script.sh || fail 'docker state is not verified via docker info'
for fn in _autostart_enabled _autostart_disabled _autostart_level _pick_from stage_autostart; do
	declare -F "$fn" >/dev/null || fail "missing autostart helper: $fn"
done
grep -q 'svc_disable "\$pick"' 4script.sh || fail 'autostart cannot disable an item'
grep -q 'svc_enable "\$pick"' 4script.sh || fail 'autostart cannot enable an item'

printf 'OK: 4script unit checks passed\n' 
