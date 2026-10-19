# 4Script

**simple-server-security-script** — one Bash script that hardens a fresh VPS and
keeps it maintainable: interactive menu on the server or fully remote setup from
your laptop, backups before every change, config validation before every restart.

```text
Debian · Ubuntu · Fedora · RHEL · CentOS · Rocky · AlmaLinux · Oracle Linux · Alpine
```

Init: `systemd` (Debian/RHEL family) or `OpenRC` (Alpine) — the script detects
which one it is and drives services through the matching tool.

[Русская версия](README.ru.md) · [Manual (how to do it by hand)](docs/manual.md) · [Ручные инструкции](docs/manual.ru.md)

---

## Quick start

### Remote: harden a server from your machine (recommended)

```bash
wget -qO 4script.sh https://raw.githubusercontent.com/Fluttershy174PUNK/4Script/main/4script.sh
bash 4script.sh --remote root@YOUR_SERVER
```

The password is asked **once**, to install your SSH key; after that everything
runs over the key. The setup itself runs inside `screen` on the server, so a
dropped connection or a sleeping laptop does not kill it halfway.

```bash
bash 4script.sh --remote root@YOUR_SERVER --attach      # come back to a running setup
bash 4script.sh --remote admin@10.0.0.5:2222            # non-root user, custom port
bash 4script.sh --remote-help                           # all remote options
```

### On the server

```bash
wget -qO 4script.sh https://raw.githubusercontent.com/Fluttershy174PUNK/4Script/main/4script.sh
sudo bash 4script.sh
```

The server summary and the menu open; `Q` exits. `chmod +x` is not needed.

> **This is a security script — do not run it blind.**
>
> ```bash
> less 4script.sh      # read what you downloaded (q to quit)
> ```
>
> That is why these are two separate commands, not `wget … | sudo bash`.

**If `wget` is missing** (minimal images):

```bash
sudo apt-get install -y wget || sudo dnf install -y wget || sudo yum install -y wget
```

**No internet on the server?** Copy the file yourself:

```bash
scp 4script.sh root@YOUR_SERVER:~/
ssh root@YOUR_SERVER
sudo bash 4script.sh
```

---

## What it does

Stages are grouped; each one can be run alone, and status is remembered in
`$DATA_DIR/.seq_vps_status`, so an unfinished run can be resumed.

| # | Stage | What it does |
| :- | :--- | :----------- |
|  | **Setup** |  |
| 0 | Utilities | `micro` (editor), `mc` (file manager) |
| 1 | System update | `apt-get update/upgrade/full-upgrade`, `dnf upgrade`, `apk -U upgrade`, warns when a reboot is required |
|  | **Access** |  |
| 2 | Users | create, change password, groups (sudo), delete |
| 3 | Root password | change the root password |
| 4 | SSH key | paste / copy / list / remove keys (root included), key format checked on paste, SSH restarted afterwards, client instructions for Linux, macOS, Windows |
| 5 | SSH config | port, password login, root login, MaxAuthTries, empty passwords, `PerSourcePenalties`; plain-language hints and a "why is SSH refusing me" check |
| 6 | SFTP user | chroot user in `/srv/sftp/<name>`, writable `upload/` |
|  | **Protection** |  |
| 7 | Firewall | UFW (Debian/Ubuntu/Alpine) or firewalld (RHEL family); IPv6 check, Docker warning, sudo audit |
| 8 | Auto-updates | `unattended-upgrades` / `dnf-automatic` + reboot window; on Alpine a daily `/etc/periodic/daily` job |
| 9 | Brute force | CrowdSec or Fail2Ban (Alpine: Fail2Ban only — CrowdSec is not in `apk`); if one is already installed you can keep it, replace it or remove it |
| 10 | DNS | replace resolvers (systemd-resolved aware) |
| 18 | Passwords and lockout | `pam_faillock` (locks the account, not the address) and `pam_pwquality` |
| 19 | Event audit | `auditd` with baseline rules: identity files, `sudoers`, SSH config, root commands, kernel modules |
| 20 | IPv6 | turn IPv6 on or off (survives reboot, detects an IPv6 SSH session before cutting it) |
| 21 | Local login (console) | close the provider's console: virtual ttys and the serial port, plus root on the console — SSH stays the only way in, with a one-key way back |
|  | **System and network** |  |
| 11 | Fish shell | install fish |
| 12 | Time | timezone + NTP |
| 13 | Lynis | security audit, hardening index (skipped on Alpine — not packaged) |
| 14 | Disk | usage, large files |
| 15 | BBR | TCP congestion control |
| 16 | Kernel hardening | sysctl: KASLR/dmesg/core dumps, hardlink/symlink guards, ICMP redirects, rp_filter, SYN cookies |
| 17 | Audit | listen ports, accounts (UID 0, no password, sudo), SUID/SGID, world-writable files, LSM state (read-only) |
| R | Rollback | restore a stage from its backup |
| P | Profiles | show what settings are actually in effect right now |
| H | Help | stage list and recommended order |
| Q | Quit | |

### Recommended order on a new server

The one rule: **firewall and SSH key before you change the port**, otherwise
you lock yourself out.

```text
 1. Stage 0   Utilities
 2. Stage 1   System update
 3. Stage 2   Create an admin user with sudo
 4. Stage 4   Install that user's SSH key
 5. CHECK: open a NEW terminal, log in as the admin user with the key
 6. Stage 7   Firewall: allow the SSH port and enable it
 7. CHECK: your current session is still alive
 8. Stage 5   Change the SSH port, disable password login
 9. Stage 7   Allow the new port (item 1 picks it up)
10. CHECK: open a NEW terminal, log in on the new port
11. Stage 8   Security auto-updates
12. Stage 9   Brute-force protection
13. Stage 3   Change the root password (last)
14. Everything else as needed: 6, 10-20
```

Do not continue until the new way in actually works, and do not close the
current session before that.

---

## How it works under the hood

**Drop-in instead of editing the main config.** SSH settings go to
`/etc/ssh/sshd_config.d/00-seq-vps.conf`; `sshd_config` itself is left alone.

> The name starts with `00-`, not `99-`: sshd applies the **first** value it
> finds. Cloud images ship `50-cloud-init.conf` with `PasswordAuthentication yes`,
> which overrides any `99-*` file — disabling passwords would silently not take
> effect.

**Socket activation (Ubuntu 22.10+, Debian 13).** There sshd does not listen
itself: `ssh.socket` does, and `Port` from `sshd_config` is ignored. The script
detects the socket, writes an override with an empty `ListenStream=` (which drops
the default 22), and — because `sshd-socket-generator` reads **every** `Port` in
`sshd_config.d/*` — comments out foreign `Port` lines so the old port does not
stay open.

**Password login off in both places.** `PasswordAuthentication no` alone still
lets PAM admit a password through keyboard-interactive, so
`KbdInteractiveAuthentication no` is set together with it.

**Validation before every write.** Each SSH change is built in a temporary file
and checked with `sshd -t` *before* replacing the real file; a rejected value
never reaches the live config and the menu item reports failure. `sshd -t` also
runs before every restart.

**Old port is closed only after the new one is confirmed.** The script opens the
new port in the firewall first, verifies the port listens and accepts a local
TCP connection, then asks you to confirm a login from a new terminal. If
anything is unconfirmed, the old port stays open with the exact command to close
it manually. This is not a formality: an earlier version lost access to the test
server exactly here, and a local probe cannot see NAT or cloud security groups.

**SELinux.** On the RHEL family a port change runs `semanage port -a -t
ssh_port_t`, and SFTP chroot files get `restorecon` — otherwise sshd cannot read
them.

**Fail2Ban.** 3 attempts → 24h ban. The systemd backend needs
`python3-systemd`, polling needs `/var/log/auth.log`. If neither is available
the SSH jail is disabled with an explicit warning instead of taking the whole
service down.

**DNS.** On systems with `systemd-resolved`, `/etc/resolv.conf` is a symlink to
a stub, so the script writes `/etc/systemd/resolved.conf.d/10-seq-vps.conf`.
Under netplan it warns instead of making a change that will not survive a reboot.

**Locale.** If the current locale is not UTF-8 (common over non-interactive SSH),
the script switches to `C.UTF-8`. Without it bash measures string length in
bytes, which breaks column alignment and can split a multi-byte character.

---

## Where things are stored

```text
/opt/4script/          (older installs keep using /opt/seq_vps/)
├── 4script_YYYYmmdd_HHMMSS.log   log of every action
├── .seq_vps_status               stage statuses (check marks in the menu)
└── backups/
    └── YYYYmmdd_HHMMSS/          backups from one run
        ├── stage1_update/
        ├── stage5_ssh_config/
        └── ...
```

Rollback (`R`) looks for a stage backup **across all runs** and takes the most
recent one, so restarting the script does not lose the ability to undo. Every
file is copied with `cp -a` before it is modified.

An existing `/opt/seq_vps/` is reused deliberately: that is where the backups and
status of an older install live, and moving to a new directory would lose them.

---

## Lost access to the server?

1. Use your provider's **console** (VNC / IPMI / KVM in the panel).
2. Run the script → `R` → pick the stage.
3. Or manually — see [docs/manual.md](docs/manual.md).

```bash
cat /etc/ssh/sshd_config.d/00-seq-vps.conf
sshd -t && systemctl restart ssh
systemctl cat ssh.socket          # socket activation
semanage port -l | grep ssh_port_t   # SELinux
ufw status numbered               # Debian/Ubuntu
firewall-cmd --list-all           # RHEL/Fedora
```

---

## FAQ

**Can I run it twice?**
Yes. It is idempotent, and stages already marked as done can be skipped.

**What does it do to my configs?**
Every file is backed up to `backups/<timestamp>/<stage>/` before it is changed.
`P` shows what is actually in effect.

**How do I see what was done?**

```bash
cat /opt/4script/4script_*.log      # or /opt/seq_vps/seq_vps_*.log on old installs
```

**Does it work in a container?**
Mostly. Some sysctl keys are read-only in LXC, `auditd` cannot start without
`cap_sys_nice`, and BBR needs a kernel module. The script reports exactly that
instead of pretending it worked.

**Does it work on Alpine?**
Yes. Alpine uses OpenRC instead of systemd, so services are driven through
`rc-update`/`rc-service`, packages through `apk`, UFW as the firewall, and
automatic updates through a daily `/etc/periodic/daily` job. Two honest limits:
CrowdSec and Lynis are not in the Alpine repositories (the stages say so and
skip), and the stock `sshd` is not linked against PAM — stage 18 detects that
and points to `apk add openssh-server-pam` instead of writing a PAM rule that
would never run.

**Can I do everything by hand instead?**
Yes — that is what [docs/manual.md](docs/manual.md) and
[docs/manual.ru.md](docs/manual.ru.md) are for: SSH keys, ports, custom key
names, firewall, updates, PAM, auditd, step by step.

---

## Tests

```bash
bash -n 4script.sh tests/test_4script.sh
bash tests/test_4script.sh
shellcheck -S warning 4script.sh tests/test_4script.sh
```

They cover the stage registry, status-file migration, sshd directive parsing,
the password prompt, UTF-8 safe truncation, remote address parsing, the sysctl
list and PAM predicates, plus the progress bar, help screen and non-TTY
behaviour. No root, no system changes, no network.

Everything above plus the risky paths was exercised on a live stand (Ubuntu
26.04 LTS, OpenSSH 10.2): SSH port changes with socket activation, firewall rules
for the new and old port, DNS, PAM on and off with login verification, sysctl
hardening, IPv6 off and on, and the remote mode with a `screen` session.

### TUI: stability over effects

The menu is deliberately line-based. Arrow-key menus, the alternate screen and
full-screen rendering depend on `$TERM`, terminfo and the terminal
implementation — unreliable over SSH, in serial/rescue consoles and on trimmed
images. The script uses plain `read`/`printf`: Enter confirms, EOF exits the
menu, colours and animation are disabled without a TTY or with `NO_COLOR`.

Test on a VM first, and do not close your current SSH session.

---

## License

MIT
