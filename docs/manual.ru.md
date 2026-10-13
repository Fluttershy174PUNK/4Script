# Инструкции: как сделать всё то же руками

Каждый этап 4Script можно выполнить вручную. Это версия для новичка: что
набрать, что должно появиться на экране и как проверить, что получилось.
Пробуй сначала на VM и **не закрывай текущую SSH-сессию**, пока не войдёшь из
нового окна.

Где нужен root — команда написана с `sudo`. Если ты уже root, `sudo` можно
опустить.

- [1. SSH-ключи](#1-ssh-ключи)
- [2. Смена порта SSH](#2-смена-порта-ssh)
- [3. Отключение входа по паролю](#3-отключение-входа-по-паролю)
- [4. Ограничение входа root](#4-ограничение-входа-root)
- [5. Фаервол](#5-фаервол)
- [6. Автообновления безопасности](#6-автообновления-безопасности)
- [7. Защита от брутфорса](#7-защита-от-брутфорса)
- [8. Харденинг ядра (sysctl)](#8-харденинг-ядра-sysctl)
- [9. Пароли и блокировка учёток (PAM)](#9-пароли-и-блокировка-учёток-pam)
- [10. Аудит событий (auditd)](#10-аудит-событий-auditd)
- [11. Отключить или включить IPv6](#11-отключить-или-включить-ipv6)
- [12. Потерял доступ](#12-потерял-доступ)

---

## Перед началом

Определи, какая у тебя система: команды отличаются у Debian/Ubuntu (`apt`) и
RHEL/Fedora (`dnf`).

```bash
cat /etc/os-release | head -3
```

Перед правкой любого файла сделай копию. Эта одна привычка спасает больше
серверов, чем всё остальное в этом документе:

```bash
sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)
```

---

## 1. SSH-ключи

Ключ — это два файла: **приватный** остаётся на твоём компьютере и никуда не
копируется, **публичный** (`.pub`) кладётся на сервер.

### Сгенерировать ключ

```bash
ssh-keygen -t ed25519 -C "you@laptop"
```

Нажми Enter, чтобы согласиться с путём по умолчанию (`~/.ssh/id_ed25519`). Про
парольную фразу: если задашь — будешь вводить её при использовании ключа
(безопаснее); если оставишь пустой — ключ работает без запроса (удобнее, и
именно это ожидают большинство скриптов).

### Своё имя для ключа

Полезно, когда серверов несколько и их надо различать:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/server1_key -C "server1"
```

Теперь `~/.ssh/server1_key` — приватный ключ, а `~/.ssh/server1_key.pub` —
публичный. Подключение указывает приватный явно:

```bash
ssh -i ~/.ssh/server1_key root@IP_СЕРВЕРА
```

### Положить публичный ключ на сервер

Простой способ — копирует ключ и сам выставляет права:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@IP_СЕРВЕРА
```

Вручную, если `ssh-copy-id` недоступен:

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@IP_СЕРВЕРА \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

### Проверить, что работает

Открой **новое** окно терминала и войди. Если просит пароль — ключ ещё не
используется, дальше идти нельзя.

```bash
ssh root@IP_СЕРВЕРА
```

Частая причина неудачи — неправильные права на стороне сервера:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown -R "$(id -u):$(id -g)" ~/.ssh
```

### Посмотреть, какие ключи на сервере

```bash
cat -n ~/.ssh/authorized_keys
```

Одна строка — один ключ. Комментарий в конце (`you@laptop`) подсказывает, чей он.

### Удалить ключ

```bash
sed -i '3d' ~/.ssh/authorized_keys     # удаляет строку 3
```

---

## 2. Смена порта SSH

Зачем: автоматические сканеры круглосуточно долбят порт 22. Смена порта убирает
большую часть шума (сама по себе это не безопасность).

Сначала открой новый порт в фаерволе, **потом** меняй SSH. В обратном порядке
потеряешь доступ.

```bash
sudo ufw allow 2222/tcp
```

На RHEL-семействе открывай через firewalld:

```bash
sudo firewall-cmd --permanent --add-port=2222/tcp && sudo firewall-cmd --reload
```

Ещё надо сообщить о новом порте SELinux, иначе sshd откажется стартовать:

```bash
sudo semanage port -a -t ssh_port_t -p tcp 2222    # если порт уже занят — с ключом -m
```

Теперь правь SSH. Настройки лучше держать в отдельном файле, чтобы основной
конфиг оставался чистым:

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
Port 2222
EOF
```

Проверь файл **до** перезапуска — сломанный конфиг означает, что SSH не
поднимется вообще:

```bash
sudo sshd -t && echo "конфиг OK"
sudo systemctl restart ssh
```

### Подвох на Ubuntu 22.10+ и Debian 13

Там слушает не sshd, а `ssh.socket`, и он игнорирует `Port` из конфига. Проверь:

```bash
systemctl is-active ssh.socket
```

Если `active`, нужно сказать и сокету:

```bash
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo tee /etc/systemd/system/ssh.socket.d/10-myhost.conf >/dev/null <<'EOF'
[Socket]
ListenStream=
ListenStream=2222
EOF
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket ssh
```

Пустой `ListenStream=` важен: без него сокет продолжит слушать и 22, и у тебя
окажется два открытых порта.

### Проверка

```bash
ss -tlnp | grep -E '2222|:22 '
```

Хочется увидеть новый порт и **не увидеть** старый. Потом зайди из нового окна:

```bash
ssh -p 2222 root@IP_СЕРВЕРА
```

И только после этого закрой старый порт в фаерволе:

```bash
sudo ufw delete allow 22/tcp
```

### Если в конфиге несколько строк Port

sshd и генератор сокета собирают **все** `Port`/`ListenStream`, поэтому файл,
оставшийся от провайдера (например `10-port.conf`), продолжит держать старый
порт открытым. Найди лишние:

```bash
grep -rn '^\s*Port' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

---

## 3. Отключение входа по паролю

Делай только после того, как вход по ключу **точно работает** — иначе запрёшь
себя снаружи.

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

Вторая строка не для красоты. С одним только `PasswordAuthentication no` PAM всё
равно пускает пароль через «keyboard-interactive», и вход по паролю продолжает
работать, пока ты думаешь, что он отключён.

Проверь из нового окна: вход по паролю должен теперь не проходить.

---

## 4. Ограничение входа root

`prohibit-password` — золотая середина: root может войти по ключу, но не по
паролю.

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
PermitRootLogin prohibit-password
MaxAuthTries 3
PermitEmptyPasswords no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

Ещё лучше — завести обычного пользователя с sudo и ходить под ним:

```bash
sudo adduser admin
sudo usermod -aG sudo admin        # на RHEL-семействе — wheel
```

Затем `PermitRootLogin no`, когда убедишься, что `admin` входит и умеет `sudo`.

---

## 5. Фаервол

### Ubuntu / Debian (ufw)

```bash
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

Правила дублируются для IPv4 и IPv6 — это то, что нужно, но только если IPv6
включён в самом ufw:

```bash
grep '^IPV6=' /etc/default/ufw      # должно быть yes
```

Если `no`, правила просто не покрывают IPv6, и сервер с AAAA-записью остаётся
доступен по IPv6 в обход фаервола. Исправление:

```bash
sudo sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw && sudo ufw reload
```

### RHEL / Fedora (firewalld)

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=2222/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

Используй что-то одно: `ufw` и `firewalld` воюют за одни и те же правила ядра.

### Предупреждение про Docker

Если установлен Docker, опубликованные порты контейнеров обходят фаервол
целиком. Посмотреть и ограничить:

```bash
sudo iptables -L DOCKER-USER -n
```

---

## 6. Автообновления безопасности

### Ubuntu / Debian

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Проверь, что ему разрешено ставить: на Ubuntu по умолчанию это шире, чем
«только безопасность»:

```bash
grep -A3 Allowed-Origins /etc/apt/apt.conf.d/50unattended-upgrades
```

Автоперезагрузка в выбранное время (по желанию, но ядру перезагрузка нужна):

```bash
sudo tee /etc/apt/apt.conf.d/51myhost-reboot >/dev/null <<'EOF'
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
EOF
```

### RHEL / Fedora

```bash
sudo dnf install -y dnf-automatic
sudo sed -i 's/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
```

Проверка позже:

```bash
sudo tail -30 /var/log/unattended-upgrades/unattended-upgrades.log   # Debian/Ubuntu
systemctl list-timers dnf-automatic.timer                            # RHEL-семейство
```

---

## 7. Защита от брутфорса

### Fail2Ban (простой, работает без интернета)

```bash
sudo apt-get install -y fail2ban python3-systemd
sudo tee /etc/fail2ban/jail.local >/dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = 2222
backend = systemd
maxretry = 3
bantime  = 24h
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status sshd
```

`backend = systemd` требует `python3-systemd`. Без него используй
`backend = polling` и убедись, что существует `/var/log/auth.log`.

### Проверить, что банит

```bash
sudo fail2ban-client status sshd
```

Разбанить себя после ошибки:

```bash
sudo fail2ban-client set sshd unbanip ТВОЙ_IP
```

### Встроенная альтернатива (OpenSSH 9.8+)

Современный sshd сам штрафует шумные источники:

```bash
sshd -T | grep -i persourcepenalties
```

Ставить ничего не нужно — но это ограничение скорости, а не настоящий бан-лист.

---

## 8. Харденинг ядра (sysctl)

sysctl — это настройки работающего ядра. Свои значения держи в отдельном файле,
чтобы их можно было чисто удалить:

```bash
sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
# Не давать непривилегированным читать адреса ядра (ломает часть эксплойтов)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# Никаких core-дампов от setuid-программ
fs.suid_dumpable = 0

# Атаки через ссылки в /tmp
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2

# Трассировка только своих процессов
kernel.yama.ptrace_scope = 1

# Не принимать и не отправлять ICMP-redirect (MITM), без source routing
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# Защита от SYN-flood, лог поддельных адресов, фильтр обратного пути
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sudo sysctl --system
```

### Проверить, что реально применилось

`sysctl -p` не сообщает, когда значение отвергли (в контейнерах так часто).
Сравни напрямую:

```bash
for k in kernel.kptr_restrict fs.suid_dumpable net.ipv4.conf.all.rp_filter; do
  printf '%-38s %s\n' "$k" "$(sysctl -n $k)"
done
```

Если значение не держится — ядро или контейнер его не разрешает. Это нормально:
файл всё равно правильный для настоящей VM.

Осторожно с `net.ipv4.ip_forward = 0`: это ломает маршрутизацию, VPN и Docker.
Не трогай, если не уверен, что сервер не роутер.

---

## 9. Пароли и блокировка учёток (PAM)

Это две разные вещи:

- `pam_faillock` **блокирует учётную запись** после нескольких неудачных входов
  (локальный аналог fail2ban, который блокирует адрес);
- `pam_pwquality` требует **более сложные пароли** при их установке.

### Блокировка

Политика лежит в отдельном файле на современных системах:

```bash
sudo tee /etc/security/faillock.conf >/dev/null <<'EOF'
deny = 5
unlock_time = 900
EOF
```

Теперь подключи модуль к аутентификации. Сначала бэкап:

```bash
sudo cp -a /etc/pam.d/common-auth /etc/pam.d/common-auth.bak
sudo cp -a /etc/pam.d/common-account /etc/pam.d/common-account.bak
```

Добавь две строки в **начало** `/etc/pam.d/common-auth` (порядок важен —
проверка должна произойти до проверки пароля):

```text
auth    required        pam_faillock.so preauth
auth    [default=die]   pam_faillock.so authfail
```

и одну строку в начало `/etc/pam.d/common-account`:

```text
account required        pam_faillock.so
```

Не добавляй `even_deny_root`, если не понимаешь: с ним блокируется и root, а на
сервере с доступом только по ключу это может оставить тебя ни с чем.

Посмотреть счётчики и разблокировать пользователя:

```bash
sudo faillock --user admin
sudo faillock --user admin --reset
```

### Сложность паролей

```bash
sudo apt-get install -y libpam-pwquality
sudo tee /etc/security/pwquality.conf >/dev/null <<'EOF'
minlen = 12
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
EOF
```

Добавь в начало `/etc/pam.d/common-password`:

```text
password requisite      pam_pwquality.so retry=3
```

Проверь в **новом** окне, не закрывая своё:

```bash
passwd          # короткий пароль теперь должен быть отклонён
```

Сломанный наполовину PAM означает, что войти не сможет никто. Если так вышло —
верни бэкап:

```bash
sudo cp -a /etc/pam.d/common-auth.bak /etc/pam.d/common-auth
```

---

## 10. Аудит событий (auditd)

auditd записывает, кто что изменил. Без него после инцидента читать нечего.

```bash
sudo apt-get install -y auditd          # или: dnf install -y auditd
sudo mkdir -p /etc/audit/rules.d
sudo tee /etc/audit/rules.d/99-hardening.rules >/dev/null <<'EOF'
# Идентификация и полномочия
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Конфигурация SSH
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Команды от root, запущенные реальным пользователем
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands

# Модули ядра, смена времени, монтирования
-a always,exit -F arch=b64 -S init_module,delete_module -k modules
-a always,exit -F arch=b64 -S settimeofday,clock_settime -k time_change
-a always,exit -F arch=b64 -S mount -k mounts

# Правила неизменяемы до перезагрузки
-e 2
EOF
sudo augenrules --load
sudo systemctl enable --now auditd
```

Чтение следа:

```bash
sudo ausearch -k identity -ts recent      # кто трогал /etc/passwd и прочее
sudo aureport --summary                   # сводка
sudo aureport -l                          # входы
```

В контейнерах auditd обычно не запускается (нужны привилегии ядра). Это
ожидаемо; правила останутся готовыми для настоящей VM.

Локальные логи может стереть тот, кто получит root — для серьёзных задач
отправляй их с машины на другой хост.

---

## 11. Отключить или включить IPv6

Зачем отключать: нет AAAA-записи, а фаервол настроен только под IPv4.
Зачем оставлять: современные клиенты, и часть провайдерских сетей на нём.

**Сначала проверь, не подключён ли ты сам по IPv6** — если да, отключение
мгновенно оборвёт сессию, и вернуться можно будет только через консоль
провайдера:

```bash
echo "$SSH_CONNECTION"      # первое поле с двоеточиями = IPv6
ip -6 addr show scope global
```

### Отключить

```bash
sudo tee /etc/sysctl.d/98-ipv6-off.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sudo sysctl --system
```

Интерфейсы, у которых адреса уже есть, не всегда сбрасывают их сразу. Чтобы
применить немедленно:

```bash
for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  case "$i" in */all/*|*/default/*) continue ;; esac
  echo 1 | sudo tee "$i" >/dev/null
done
```

Проверка: `sysctl -n net.ipv6.conf.all.disable_ipv6` печатает `1`, а
`ip -6 addr show scope global` пуст.

### Включить

Удали свой файл (иначе `disable_ipv6=1` вернётся при следующей загрузке) и
включи обратно:

```bash
sudo rm -f /etc/sysctl.d/98-ipv6-off.conf
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
```

Адреса вернутся через SLAAC/DHCPv6 или из конфигурации провайдера; надёжнее
всего — перезагрузка.

---

## 12. Потерял доступ

Первое: воспользуйся консолью провайдера (VNC/IPMI/KVM в панели хостера). Она
работает, даже когда SSH — нет.

Дальше смотри по тому, что сломал:

```bash
# SSH вообще не стартует: читаем ошибку, затем проверяем конфиг
sudo sshd -t
sudo journalctl -u ssh -n 50

# Не тот порт? Смотрим, что реально слушается
sudo ss -tlnp | grep sshd
sudo systemctl cat ssh.socket

# Фаервол блокирует? Смотрим и открываем свой порт
sudo ufw status numbered
sudo ufw allow 22/tcp

# SELinux мешает нестандартному порту
sudo semanage port -l | grep ssh_port_t
sudo semanage port -a -t ssh_port_t -p tcp 2222

# Сломан PAM: войти не может никто
sudo cp -a /etc/pam.d/common-auth.bak /etc/pam.d/common-auth

# Вернуть файл из сделанного ранее бэкапа
sudo cp -a /etc/ssh/sshd_config.bak.2026-01-01 /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh
```

Если ты запускал 4Script, откат (`R`) восстановит файлы этапа из бэкапа в
`/opt/4script/backups/` (или `/opt/seq_vps/backups/` на старых установках).
