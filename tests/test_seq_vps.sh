#!/usr/bin/env bash
# Статические и юнит-проверки без root и без изменений системы.
# Сеть не используется; запуск: bash tests/test_seq_vps.sh
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../seq_vps.sh
source "$ROOT/seq_vps.sh"
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "$3: expected <$2>, got <$1>"; }

# shellcheck disable=SC2034
TERM_WIDTH=5
assert_eq "$(hr | sed $'s/\033\\[[0-9;]*m//g')" '─────' 'thin rule is valid UTF-8'
assert_eq "$(hr_thick | sed $'s/\033\\[[0-9;]*m//g')" '═════' 'thick rule is valid UTF-8'

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

# Каждая stage_* функция должна быть в реестре — иначе этап недостижим из меню
for fn in $(compgen -A function | grep '^stage_' | grep -v '^stage_banner$'); do
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

# Если на машине уже есть статус-файл (реальный сервер), в нём должны быть все ключи
if [[ -f "$STAGE_STATUS_FILE" ]]; then
	for key in $seen_keys; do
		grep -qx "$key=.*" "$STAGE_STATUS_FILE" || fail "status file misses $key"
	done
fi

# sshd -T печатает директивы в нижнем регистре, но старый awk был регистрозависим
assert_eq "$(_sshd_option 'PasswordAuthentication no' passwordauthentication yes)" 'no' 'option read from lowercase dump'
assert_eq "$(_sshd_option 'banner none' passwordauthentication yes)" 'yes' 'missing option falls back to default'

# ── Ввод пароля (без изменений системы) ──────────────────────────────
pw=''
printf 'secret\nsecret\n' | _read_new_password pw 2>/dev/null || fail 'matching passwords accepted'
assert_eq "$pw" 'secret' 'password reaches target variable'
printf 'a\nb\n' | _read_new_password pw 2>/dev/null && fail 'mismatched passwords accepted' || true
printf '\n\n' | _read_new_password pw 2>/dev/null && fail 'empty password accepted' || true

# A non-interactive run must not start a background spinner or print ANSI colors.
SPINNER_PID=''
spinner_start test
assert_eq "$SPINNER_PID" '' 'spinner disabled when stdout is not a TTY'
assert_eq "$C_RESET" '' 'colors disabled when stdout is not a TTY'

printf 'y\n' | confirm 'Test?' >/dev/null || fail 'line-based confirmation accepts y'
printf 'n\n' | confirm 'Test?' >/dev/null && fail 'line-based confirmation rejects n' || [[ $? -eq 1 ]] || fail 'negative confirmation status'
show_server_summary() { :; }
menu_item() { :; }
get_stage_status() { echo not_started; }
log_info() { :; }
if (main_menu </dev/null >/dev/null); then :; else fail 'EOF-safe menu exits cleanly'; fi

printf 'OK: seq_vps unit checks passed\n'
