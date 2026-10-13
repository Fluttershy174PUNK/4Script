# Manual: doing it by hand

Every stage of 4Script can be done manually. This is the version for someone who
is new to servers: what to type, what it should print, and how to check it
worked. Do these on a VM first, and **never close your current SSH session**
until you have logged in from a new one.

Where a command needs root, it is written with `sudo`. If you are already root,
drop the `sudo`.

- [1. SSH keys](#1-ssh-keys)
- [2. Change the SSH port](#2-change-the-ssh-port)
- [3. Turn off password login](#3-turn-off-password-login)
- [4. Restrict root login](#4-restrict-root-login)
- [5. Firewall](#5-firewall)
- [6. Automatic security updates](#6-automatic-security-updates)
- [7. Brute-force protection](#7-brute-force-protection)
- [8. Kernel hardening (sysctl)](#8-kernel-hardening-sysctl)
- [9. Passwords and account lockout (PAM)](#9-passwords-and-account-lockout-pam)
- [10. Event audit (auditd)](#10-event-audit-auditd)
- [11. Turn IPv6 off or on](#11-turn-ipv6-off-or-on)
- [12. Locked yourself out](#12-locked-yourself-out)

---

## Before you start

Check which system you have — commands differ between Debian/Ubuntu (`apt`) and
RHEL/Fedora (`dnf`).

```bash
cat /etc/os-release | head -3
```

Make a copy of any file before you edit it. This single habit saves more servers
than anything else in this document:

```bash
sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F)
```

---

## 1. SSH keys

A key is two files: a **private** one that stays on your computer and is never
copied anywhere, and a **public** one (`.pub`) that you put on the server.

### Generate a key

```bash
ssh-keygen -t ed25519 -C "you@laptop"
```

Press Enter to accept the default path (`~/.ssh/id_ed25519`). For the passphrase:
if you set one, you will type it to unlock the key (safer); if you leave it empty,
the key works without any prompt (more convenient, and what most scripts assume).

### Custom name for the key

Useful when you have several servers and want to keep them apart:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/server1_key -C "server1"
```

Now `~/.ssh/server1_key` is the private key and `~/.ssh/server1_key.pub` is the
public one. Connect with the private one explicitly:

```bash
ssh -i ~/.ssh/server1_key root@SERVER_IP
```

### Put the public key on the server

The easy way — it copies the key and fixes permissions:

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@SERVER_IP
```

The manual way, if `ssh-copy-id` is not available:

```bash
cat ~/.ssh/id_ed25519.pub | ssh root@SERVER_IP \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

### Check it works

Open a **new** terminal and log in. If it asks for a password, the key is not
being used yet — do not continue until it works.

```bash
ssh root@SERVER_IP
```

Common reason it fails: wrong permissions on the server side.

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
chown -R "$(id -u):$(id -g)" ~/.ssh
```

### See which keys are on the server

```bash
cat -n ~/.ssh/authorized_keys
```

Each line is one key. The comment at the end (`you@laptop`) tells you whose it is.

### Remove a key

```bash
sed -i '3d' ~/.ssh/authorized_keys     # deletes line 3
```

---

## 2. Change the SSH port

Why: automated scanners hammer port 22 all day. Moving the port removes most
noise (it is not real security on its own).

First, allow the new port in the firewall, **then** change SSH. The other order
locks you out.

```bash
sudo ufw allow 2222/tcp
```

On RHEL-family systems allow it with firewalld instead:

```bash
sudo firewall-cmd --permanent --add-port=2222/tcp && sudo firewall-cmd --reload
```

Also tell SELinux about the new port, or sshd will refuse to start:

```bash
sudo semanage port -a -t ssh_port_t -p tcp 2222    # use -m if the port already has a mapping
```

Now edit SSH. Put your settings in a separate file so the main config stays clean:

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
Port 2222
EOF
```

Check the file is valid **before** restarting — a broken config means no SSH at
all:

```bash
sudo sshd -t && echo "config OK"
sudo systemctl restart ssh
```

### The catch on Ubuntu 22.10+ and Debian 13

There, sshd does not listen itself — `ssh.socket` does, and it ignores `Port`
from the config. Check:

```bash
systemctl is-active ssh.socket
```

If it says `active`, you must also tell the socket:

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

The empty `ListenStream=` matters: without it the socket keeps listening on 22
as well, and you end up with two open ports.

### Verify

```bash
ss -tlnp | grep -E '2222|:22 '
```

You want to see the new port and **not** the old one. Then log in from a new
terminal:

```bash
ssh -p 2222 root@SERVER_IP
```

Only after that, close the old port in the firewall:

```bash
sudo ufw delete allow 22/tcp
```

### If the config has several Port lines

sshd and its socket generator collect **every** `Port`/`ListenStream`, so a file
left over from the provider (for example `10-port.conf`) keeps the old port open.
Check and comment the extras:

```bash
grep -rn '^\s*Port' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
```

---

## 3. Turn off password login

Only do this after a key login **works** — otherwise you lock yourself out.

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

The second line matters. With only `PasswordAuthentication no`, PAM can still
let a password in through "keyboard-interactive", so the password login keeps
working while you think it is off.

Verify from a new terminal: logging in with a password should now fail.

---

## 4. Restrict root login

`prohibit-password` is the safe middle ground: root can log in with a key, but
not with a password.

```bash
sudo tee /etc/ssh/sshd_config.d/00-myhost.conf >/dev/null <<'EOF'
PermitRootLogin prohibit-password
MaxAuthTries 3
PermitEmptyPasswords no
EOF
sudo sshd -t && sudo systemctl restart ssh
```

Better still: create a normal user, give it sudo, and use that.

```bash
sudo adduser admin
sudo usermod -aG sudo admin        # wheel on RHEL-family
```

Then `PermitRootLogin no` once you have confirmed `admin` can log in and run
`sudo`.

---

## 5. Firewall

### Ubuntu / Debian (ufw)

```bash
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

Rules are duplicated for IPv4 and IPv6, which is what you want — but only if IPv6
is enabled in ufw:

```bash
grep '^IPV6=' /etc/default/ufw      # should be yes
```

If it is `no`, rules simply do not cover IPv6, and a server with an AAAA record
stays reachable over IPv6 past your firewall. Fix:

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

Use one or the other, not both: `ufw` and `firewalld` fight over the same kernel
rules.

### Docker warning

If Docker is installed, published container ports bypass the firewall entirely.
Check and limit them:

```bash
sudo iptables -L DOCKER-USER -n
```

---

## 6. Automatic security updates

### Ubuntu / Debian

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Check what it is allowed to install — on Ubuntu the default is broader than
"security only":

```bash
grep -A3 Allowed-Origins /etc/apt/apt.conf.d/50unattended-upgrades
```

Automatic reboot at a chosen time (optional, but kernels need reboots):

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

Check it later:

```bash
sudo tail -30 /var/log/unattended-upgrades/unattended-upgrades.log   # Debian/Ubuntu
systemctl list-timers dnf-automatic.timer                            # RHEL-family
```

---

## 7. Brute-force protection

### Fail2Ban (simple, works without internet)

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

`backend = systemd` needs `python3-systemd`. Without it, use
`backend = polling` and check that `/var/log/auth.log` exists.

### Check it actually bans

Look at who has been banned:

```bash
sudo fail2ban-client status sshd
```

Unban yourself after a mistake:

```bash
sudo fail2ban-client set sshd unbanip YOUR_IP
```

### Built-in alternative (OpenSSH 9.8+)

Modern sshd already penalizes noisy sources by itself:

```bash
sshd -T | grep -i persourcepenalties
```

Nothing to install — but it is a rate limit, not a real ban list.

---

## 8. Kernel hardening (sysctl)

sysctl settings are how you tune the running kernel. Put yours in a separate
file so you can remove them cleanly:

```bash
sudo tee /etc/sysctl.d/99-hardening.conf >/dev/null <<'EOF'
# Do not let unprivileged users read kernel addresses (defeats some exploits)
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# No core dumps from setuid programs
fs.suid_dumpable = 0

# Time-of-check attacks through links in /tmp
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_regular = 2

# Trace only your own processes
kernel.yama.ptrace_scope = 1

# Do not accept or send ICMP redirects (MITM), no source routing
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0

# SYN flood protection, log spoofed packets, reverse-path filter
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
sudo sysctl --system
```

### Check what actually applied

`sysctl -p` does not tell you when a value was refused (containers often do
refuse some). Compare directly:

```bash
for k in kernel.kptr_restrict fs.suid_dumpable net.ipv4.conf.all.rp_filter; do
  printf '%-38s %s\n' "$k" "$(sysctl -n $k)"
done
```

If a value does not stick, the kernel or the container does not allow it. That is
fine — the file is still correct for a real VM.

Careful with `net.ipv4.ip_forward = 0`: it breaks routing, VPNs and Docker.
Leave it alone unless you know this server is not a router.

---

## 9. Passwords and account lockout (PAM)

Two different things:

- `pam_faillock` **blocks the account** after several failed logins (local
  analogue of fail2ban, which blocks the address).
- `pam_pwquality` requires **stronger passwords** when they are set.

### Lockout

The policy lives in its own file on modern systems:

```bash
sudo tee /etc/security/faillock.conf >/dev/null <<'EOF'
deny = 5
unlock_time = 900
EOF
```

Then wire the module into authentication. Keep a backup first:

```bash
sudo cp -a /etc/pam.d/common-auth /etc/pam.d/common-auth.bak
sudo cp -a /etc/pam.d/common-account /etc/pam.d/common-account.bak
```

Add two lines at the **top** of `/etc/pam.d/common-auth` (order matters — the
check has to happen before the password is verified):

```text
auth    required        pam_faillock.so preauth
auth    [default=die]   pam_faillock.so authfail
```

and one line at the top of `/etc/pam.d/common-account`:

```text
account required        pam_faillock.so
```

Do not add `even_deny_root` unless you mean it: with it, root can be locked out
too, and on a server with key-only access that can leave you stuck.

Check the counters and unlock a user:

```bash
sudo faillock --user admin
sudo faillock --user admin --reset
```

### Password strength

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

Add to the top of `/etc/pam.d/common-password`:

```text
password requisite      pam_pwquality.so retry=3
```

Test in a **new** session before closing yours:

```bash
passwd          # a short password must now be rejected
```

Half-broken PAM means nobody can log in. If that happens, restore the backup:

```bash
sudo cp -a /etc/pam.d/common-auth.bak /etc/pam.d/common-auth
```

---

## 10. Event audit (auditd)

auditd records who changed what. Without it, after an incident there is nothing
to read.

```bash
sudo apt-get install -y auditd          # or: dnf install -y auditd
sudo mkdir -p /etc/audit/rules.d
sudo tee /etc/audit/rules.d/99-hardening.rules >/dev/null <<'EOF'
# Identity and privileges
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# SSH configuration
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config

# Commands run as root by a real user
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root_commands

# Kernel modules, time changes, mounts
-a always,exit -F arch=b64 -S init_module,delete_module -k modules
-a always,exit -F arch=b64 -S settimeofday,clock_settime -k time_change
-a always,exit -F arch=b64 -S mount -k mounts

# Make rules immutable until reboot
-e 2
EOF
sudo augenrules --load
sudo systemctl enable --now auditd
```

Read the trail:

```bash
sudo ausearch -k identity -ts recent      # who touched /etc/passwd etc.
sudo aureport --summary                   # overview
sudo aureport -l                          # logins
```

In containers auditd usually refuses to start (it needs kernel privileges).
That is expected; the rules stay ready for a real VM.

Local logs can be wiped by whoever gets root — for anything serious, ship them
off the machine to another host.

---

## 11. Turn IPv6 off or on

Reasons to turn it off: no AAAA record, and a firewall that only covers IPv4.
Reasons to keep it: modern clients, and some provider networks use it.

**Check first whether you are connected over IPv6** — if you are, turning it off
drops your session instantly and you will be back only via the provider console:

```bash
echo "$SSH_CONNECTION"      # first field starting with a colon-ish form = IPv6
ip -6 addr show scope global
```

### Off

```bash
sudo tee /etc/sysctl.d/98-ipv6-off.conf >/dev/null <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sudo sysctl --system
```

Interfaces that already have addresses do not always drop them immediately. To
apply now:

```bash
for i in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  case "$i" in */all/*|*/default/*) continue ;; esac
  echo 1 | sudo tee "$i" >/dev/null
done
```

Verify: `sysctl -n net.ipv6.conf.all.disable_ipv6` prints `1` and
`ip -6 addr show scope global` is empty.

### On

Remove your file (otherwise `disable_ipv6=1` comes back on the next boot), then
re-enable:

```bash
sudo rm -f /etc/sysctl.d/98-ipv6-off.conf
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
```

Addresses come back through SLAAC/DHCPv6 or provider configuration; a reboot is
the reliable way to get a clean state.

---

## 12. Locked yourself out

First: use your provider's console (VNC/IPMI/KVM in the panel). It works even
when SSH does not.

Then, depending on what you broke:

```bash
# SSH will not start at all: read the error, then check the config
sudo sshd -t
sudo journalctl -u ssh -n 50

# Wrong port? Find out what is actually listening
sudo ss -tlnp | grep sshd
sudo systemctl cat ssh.socket

# Firewall blocking you? Look, then open your port
sudo ufw status numbered
sudo ufw allow 22/tcp

# SELinux blocking a non-standard port
sudo semanage port -l | grep ssh_port_t
sudo semanage port -a -t ssh_port_t -p tcp 2222

# PAM broken: nobody can log in
sudo cp -a /etc/pam.d/common-auth.bak /etc/pam.d/common-auth

# Restore a file you backed up
sudo cp -a /etc/ssh/sshd_config.bak.2026-01-01 /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh
```

If you ran 4Script, rollback (`R`) restores the files of a stage from its backup
in `/opt/4script/backups/` (or `/opt/seq_vps/backups/` on older installs).
