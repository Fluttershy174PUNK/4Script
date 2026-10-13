# Seq VPS Security

> [Русская версия](README.ru.md)

One Bash script that hardens a fresh VPS and keeps it maintainable: a linear
interactive TUI (no dialog/whiptail/gum), backups before every change, config
validation before every restart, and a log of everything it did.

```text
Debian · Ubuntu · Fedora · RHEL · CentOS · Rocky · AlmaLinux · Oracle Linux
```

No dependencies beyond the standard system utilities.

---

## Quick start

```bash
wget -qO seq_vps.sh https://raw.githubusercontent.com/Fluttershy174PUNK/ezSEQserver/main/seq_vps.sh
sudo bash seq_vps.sh
```

The server summary and the menu open. `Q` exits.

`chmod +x` is not needed — `sudo bash seq_vps.sh` runs the file directly.

**If `wget` is missing** (minimal images):

```bash
sudo apt-get install -y wget || sudo dnf install -y wget || sudo yum install -y wget
```

**Or copy it from your machine:**

```bash
scp seq_vps.sh root@SERVER_IP:~/
ssh root@SERVER_IP
sudo bash seq_vps.sh
```

> **This is a security script — do not run it blind.**
>
> ```bash
> less seq_vps.sh      # read what you downloaded (q to quit)
> ```
>
> That is why the instructions are two separate commands, not `wget … | sudo bash`.

---

## The menu

Stages are grouped by what they affect. Status marks in the menu come from
`/opt/seq_vps/.seq_vps_status`, so a partially finished run is resumable.

| # | Stage | What it does |
| :- | :--- | :----------- |
|   | **Setup** |   |
| 0 | Utilities | `micro` (editor), `mc` (file manager) |
| 1 | System update | `apt-get update/upgrade/full-upgrade`, `dnf upgrade`, warns when a reboot is required |
|   | **Access** |   |
| 2 | Users | create, change password, groups (sudo), delete |
| 3 | Root password | change the root password |
| 4 | SSH key | paste / copy / list / remove keys, client instructions for Linux, macOS, Windows |
| 5 | SSH config | port, password login, root login, MaxAuthTries, empty passwords |
| 6 | SFTP user | chroot user in `/srv/sftp/<name>`, writable `upload/` |
|   | **Protection** |   |
| 7 | Firewall | UFW (Debian/Ubuntu) or firewalld (RHEL family) |
| 8 | Auto-updates | `unattended-upgrades` / `dnf-automatic` + reboot window |
| 9 | Brute force | CrowdSec or Fail2Ban |
| 10 | DNS | replace resolvers (systemd-resolved aware); replaces the previous list, no "append" mode |
|   | **System and network** |   |
| 11 | Fish shell | install fish |
| 12 | Time | timezone + NTP |
| 13 | Lynis | security audit, hardening index |
| 14 | Disk | usage, large files |
| 15 | BBR | TCP congestion control |
| R | Rollback | restore a stage from its backup |
| H | Help | stage list and recommended order |
| Q | Quit | |

---

## Recommended order on a new server

The one rule: **firewall and SSH key before you change the port**, otherwise
you lock yourself out.

```text
 1. Stage 0   Utilities
 2. Stage 1   System update
 3. Stage 2   Create an admin user with sudo
 4. Stage 4   Install that user's SSH key
 5. ★ CHECK: open a NEW terminal, log in as the admin user with the key
 6. Stage 7   Firewall: allow the SSH port (22) and enable it
 7. ★ CHECK: your current session is still alive
 8. Stage 5   Change the SSH port, disable password login
 9. Stage 7   Allow the new port in the firewall (item 1 picks it up)
10. ★ CHECK: open a NEW terminal, log in on the new port
11. Stage 8   Security auto-updates
12. Stage 9   Brute-force protection
13. Stage 3   Change the root password (last)
14. Everything else as needed: 6, 10–15
```

★ — do not continue until the new way in actually works. **Do not close the
current session** before that.

---

## How the security part works

**Drop-in instead of editing the main config.** SSH settings are written to
`/etc/ssh/sshd_config.d/00-seq-vps.conf`; `sshd_config` itself is left alone.

> The name starts with `00-`, not `99-`: sshd applies the **first** value it
> finds. Cloud images ship `50-cloud-init.conf` with
> `PasswordAuthentication yes`, which overrides any `99-*` file — disabling
> passwords would silently not take effect. `00-` guarantees priority.

**Socket activation (Ubuntu 22.10+, Debian 13).** There sshd does not listen
itself: `ssh.socket` does, and `Port` from `sshd_config` is ignored. Changing
the port without touching the socket reports success, keeps the old port open
and never opens the new one — an instant lockout. The script detects the
socket and writes
`/etc/systemd/system/ssh.socket.d/10-seq-vps.conf` with an empty
`ListenStream=` (which drops the default 22) plus `ListenStream=<port>`, then
restarts `ssh.socket`.

**Password login is disabled in both places.** `PasswordAuthentication no`
alone still lets PAM admit a password through keyboard-interactive
authentication, so `KbdInteractiveAuthentication no` is set together with it
(and removed together with it).

**Validation before every restart — and before every write.** A change to the
SSH drop-in is built in a temporary file and checked with `sshd -t` *before* it
replaces the real file, so a rejected value never reaches the live config. The
probe is `Include <candidate>` plus the real `sshd_config`: a bare drop-in
cannot be validated on its own, since without `HostKey` sshd always fails and
the result also depends on the neighbouring files. A rejected change leaves the
file untouched and reports which value failed. `sshd -t` also runs before each
`systemctl restart ssh`, including the two restarts in the SFTP stage.

**Root login.** `PermitRootLogin prohibit-password` (the safe option) is the
default in the menu; `yes` requires an explicit second confirmation.

**SELinux.** On Fedora/RHEL/Rocky/Alma changing the port runs
`semanage port -a -t ssh_port_t -p tcp <port>` — without it sshd will not
start on a non-standard port. Files created for the SFTP chroot get
`restorecon`, otherwise sshd cannot read them (`user_home_t` instead of the
chroot type).

**SFTP password login is not blocked by the hardened global config.** The
`Match User <name>` block re-enables `PasswordAuthentication` for that one
user, and a `Match` block overrides the global section — verified with
`sshd -T -C user=<name>` against the generated files. The global drop-in still
wins for everyone else, including `root`. Note that a `Match` block can only
set a subset of directives; `PasswordAuthentication`,
`KbdInteractiveAuthentication`, `ChrootDirectory`, `ForceCommand` and
`AuthorizedKeysFile` are all in that subset.

**Firewall per distribution.** Debian/Ubuntu → `ufw`, RHEL family →
`firewalld`. They fight over netfilter, so only the native one is configured.

**CrowdSec and firewalld.** CrowdSec has no firewalld bouncer, and the
iptables bouncer wipes firewalld rules. On the RHEL family the script installs
the CrowdSec engine (detection) and lets Fail2Ban ban with
`banaction = firewallcmd-ipset`. The `crowdsecurity/sshd` collection is
installed and verified — without it the engine runs but never sees SSH attacks.

**Fail2Ban.** 3 attempts → 24h ban, port read from the sshd config. The
systemd backend needs `python3-systemd` (not a dependency on Debian) and the
polling backend needs `/var/log/auth.log` (absent without rsyslog). If neither
is available the SSH jail is disabled with an explicit warning instead of
silently taking the whole service down.

**DNS.** On systems with `systemd-resolved`, `/etc/resolv.conf` is a symlink
to a stub that gets regenerated, so the script writes
`/etc/systemd/resolved.conf.d/10-seq-vps.conf` instead of overwriting the file.
Under netplan it warns instead of making a change that will not survive a boot.

---

## Where things are stored

```text
/opt/seq_vps/
├── seq_vps_YYYYmmdd_HHMMSS.log   log of every action
├── .seq_vps_status               stage statuses (✓ marks in the menu)
└── backups/
    └── YYYYmmdd_HHMMSS/          backups from one run
        ├── stage1_update/
        ├── stage5_ssh_config/
        └── ...
```

Rollback (`R`) looks for a stage backup **across all runs** and takes the most
recent one, so restarting the script does not lose the ability to undo.

Every file is copied with `cp -a` before it is modified; if a stage fails, its
files are restored from the same directory.

---

## Lost access to the server?

1. Use your provider's **console** (VNC / IPMI / KVM in the panel).
2. Run the script → `R` → pick the stage.
3. Or manually:

```bash
# SSH port and settings
cat /etc/ssh/sshd_config.d/00-seq-vps.conf
sshd -t && systemctl restart ssh

# Socket activation (Ubuntu 22.10+, Debian 13)
systemctl cat ssh.socket
systemctl restart ssh.socket

# SELinux (RHEL family)
semanage port -l | grep ssh_port_t

# Firewall
ufw status numbered          # Debian/Ubuntu
firewall-cmd --list-all      # RHEL/Fedora
```

---

## FAQ

**Can I run it twice?**
Yes. It is idempotent: installed packages are not reinstalled, and stages
already marked ✓ can be skipped.

**What does it do to my configs?**
Every file is backed up to `backups/<timestamp>/<stage>/` before it is changed.

**Where is the log?**

```bash
cat /opt/seq_vps/seq_vps_*.log
```

**How do I update the script?**
Download the new version and run it. Stage statuses and backups in
`/opt/seq_vps/` are preserved.

**Does it work in a container?**
Mostly. BBR needs a kernel module the container may not expose; the script
reports that instead of pretending it worked. Changes to network (DNS,
firewall, BBR) belong on the host.

---

## Tests

Static and unit checks — no root, no system changes, no network:

```bash
bash -n seq_vps.sh tests/test_seq_vps.sh
bash tests/test_seq_vps.sh
shellcheck -S warning seq_vps.sh tests/test_seq_vps.sh
```

They cover the stage registry (unique numbers/keys, every function exists,
every stage function is listed), status-file generation, sshd directive
parsing, the password prompt, the progress bar and non-TTY behaviour.

### TUI: stability over effects

The menu is deliberately line-based. Arrow-key menus, the alternate screen and
full-screen rendering depend on `$TERM`, terminfo and the terminal
implementation — unreliable over SSH, in serial/rescue consoles and on trimmed
images. The script uses plain `read`/`printf`: Enter confirms, EOF exits the
menu, colours and animation are disabled without a TTY or with `NO_COLOR`.
External `dialog`, `whiptail` and `gum` are not needed.

Test on a VM first, and do not close your current SSH session.

---

## License

MIT
