# Testing on a Gershwin Live ISO in a VM

How minibus was tested as the system bus of a whole Gershwin system, booted
by its init system, without touching the development machine. The same
setup serves any test that needs a complete, disposable Gershwin system:
system services, init scripts, LoginWindow, a desktop session.

## What it is

- **QEMU with KVM** running a Gershwin Live ISO. A Live system keeps its
  changes in RAM, so every reset starts clean.
- **A persistence disk**: a small ext4 image labelled `persistence` that
  holds `persistence.conf` with the line `/ union`. Booted with the kernel
  option `persistence`, live-boot puts the root file system's writable layer
  on that disk, so changes (an init script, an installed binary) survive a
  reboot. Copying the image is a snapshot; copying it back is a rollback.
- **ssh** into the guest through a forwarded port, user `admin`, password
  `admin` (the Live image's own account), sudo with the same password.
- **VNC** on localhost to watch the console, and the QEMU monitor socket for
  screenshots and resets.

Cost: 4 GB RAM while it runs; on disk the ISO plus a sparse persistence
image (1 GB nominal, a few dozen MB used).

Requirements on the host: `qemu-system-x86_64`, `/dev/kvm` readable,
`xorriso` (to take kernel and initrd out of the ISO), `mkfs.ext4`,
`sshpass`, `socat`, ImageMagick `convert` for screenshots.

## Set up once

Work in a directory that survives (not `/tmp`), e.g.
`~/SUPERAGENT/runs/vm`.

```sh
ISO=~/Downloads/gershwin-on-devuan-dev-XXXXXXXX-x86_64.iso

# kernel and initrd, so the kernel command line can carry "persistence"
xorriso -osirrox on -indev "$ISO" -extract /live/vmlinuz vmlinuz \
        -extract /live/initrd.img initrd.img

# the persistence disk: ext4, label "persistence", "/ union"
mkdir -p pdir && echo "/ union" > pdir/persistence.conf
truncate -s 1G persist.img
mkfs.ext4 -q -L persistence -d pdir persist.img
```

`mkfs.ext4 -d` fills the file system from a directory, so no mount and no
root are needed.

## Scripts

`boot.sh` starts the VM in the background. `-daemonize` matters: a QEMU
started as a plain background job of an agent session dies when that
session ends.

```sh
#!/bin/sh
cd "$(dirname "$0")"
rm -f monitor.sock
exec qemu-system-x86_64 -enable-kvm -cpu host -m 4096 -smp 4 \
  -cdrom "$ISO" -kernel vmlinuz -initrd initrd.img -append "boot=live persistence" \
  -drive file=persist.img,format=raw,if=virtio \
  -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:2222-:22 -vnc 127.0.0.1:5 \
  -monitor unix:$PWD/monitor.sock,server,nowait -serial file:$PWD/serial.log \
  -name gershwin-test -daemonize -pidfile $PWD/qemu.pid
```

Without the persistence lines (`-kernel`, `-initrd`, `-append`, `-drive`) and
with `-boot d` it boots the plain Live system from the ISO, which forgets
everything on reset.

`vmssh.sh` runs a command as `admin`:

```sh
#!/bin/sh
exec sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -p 2222 admin@127.0.0.1 "$@" </dev/null
```

`vmroot.sh` runs the shell script on its standard input as root:

```sh
#!/bin/sh
S=$(cat)
exec sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -p 2222 admin@127.0.0.1 \
  "export LC_ALL=C; echo admin | sudo -S -p '' sh -c '$(printf %s "$S" | sed "s/'/'\\\\''/g")'" </dev/null
```

Use them as `./vmroot.sh <<'EOF' ... EOF`. `LC_ALL=C` silences the guest's
missing-locale warnings.

## Everyday operations

```sh
./boot.sh                                    # start
until ./vmssh.sh true 2>/dev/null; do sleep 3; done   # wait for sshd (20-30 s)
./vmssh.sh 'cat /proc/cmdline; mount | grep " / "'    # persistence active?

# copy sources in and build them in the guest (never copy host binaries:
# on the BSD images they do not run, and building there is the real test)
tar czf src.tgz -C /path/to/project GNUmakefile src Tests
sshpass -p admin scp -P 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null src.tgz admin@127.0.0.1:/tmp/
./vmssh.sh 'mkdir -p ~/p && cd ~/p && tar xzf /tmp/src.tgz && make'

# screenshot of the console and of the X display
echo "screendump $PWD/c.ppm" | socat - UNIX-CONNECT:monitor.sock && convert c.ppm c.png
./vmroot.sh <<'EOF'
DISPLAY=:0 XAUTHORITY=/var/run/xauth import -window root /tmp/x.png
EOF
sshpass -p admin scp -P 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null admin@127.0.0.1:/tmp/x.png .

# reboot cleanly (persistence keeps its file system intact)
./vmroot.sh <<'EOF' &
reboot
EOF
# hard reset or stop
echo system_reset | socat - UNIX-CONNECT:monitor.sock
echo quit | socat - UNIX-CONNECT:monitor.sock

# snapshot and rollback of the persistent state (VM stopped, or after sync)
cp --sparse=always persist.img persist-good.img
cp --sparse=always persist-good.img persist.img
```

The guest's home directory is `/Local/Users/admin`, not `/home/admin`.
Logs are in `/var/log` (no syslog daemon by default: use `dmesg` and the
programs' own logs). The desktop session starts from
`/etc/inittab` (`lw:5:respawn:/System/Library/Scripts/LoginWindow.sh`).

Autologin, so a test never has to type a password into LoginWindow:

```sh
./vmroot.sh <<'EOF'
mkdir -p /Local/Library/Preferences
printf '{ autoLoginUser = admin; }\n' > /Local/Library/Preferences/LoginWindow.plist
chown root:root /Local/Library/Preferences/LoginWindow.plist
chmod 0644 /Local/Library/Preferences/LoginWindow.plist
EOF
```

LoginWindow refuses the file unless it is owned by root with mode 0644.

## Replacing a system service at run time

To restart the desktop on a changed system without rebooting, stop init
from respawning LoginWindow first; restarting it by hand while init also
respawns it leaves two half-started sessions:

```sh
sed -i 's/^lw:5:respawn:/lw:5:off:/' /etc/inittab; telinit q
pkill -x LoginWindow; pkill -x Xorg
# ... stop services, swap things, start services ...
sed -i 's/^lw:5:off:/lw:5:respawn:/' /etc/inittab; telinit q
```

When elogind is restarted at run time, its saved state may name sessions
whose processes have exited, and it aborts on start
(`Assertion 's->leader.pid > 0' failed`). Clear `/run/systemd/sessions/*`
and `/run/systemd/users/*` before starting it again. A real boot does not
have this problem.

## The minibus boot test, as it was done

1. Build minibus in the guest, install it to `/System/Library/Tools/minibus`.
2. Keep the original `/etc/init.d/dbus` as `dbus.dbus-daemon.orig` and
   replace its body (same LSB header) by
   `minibus --system --fork --pid-file=/run/dbus/pid --syslog`.
3. Add `/etc/init.d/nm-dispatcher` (Required-Start: dbus network-manager)
   that runs `/usr/libexec/nm-dispatcher --persist`, because nothing
   activates it any more; `update-rc.d nm-dispatcher defaults`.
4. Snapshot `persist.img`, reboot.
5. Check: `pgrep -x minibus`, `busctl --system list` (avahi, login1,
   NetworkManager, nm_dispatcher, and the bus's own pid), the session apps
   (`Workspace`, `Menu`, `WindowManager`), `nmcli -t general status` as
   `admin`, `loginctl list-sessions` after a new ssh login.

The reference for "what is normal" is the same check on a fresh boot of the
unmodified ISO; compare against it before blaming the change under test.

## Other images

`~/Downloads` holds FreeBSD and NextBSD Gershwin ISOs as well. They are not
Debian live-boot systems, so the persistence disk does not apply to them:
boot them from the ISO (`-cdrom ... -boot d`), test, reset. Build software
inside them with `gmake` (and `CC=clang`); BSD `make` is a different tool.
