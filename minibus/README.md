# MiniBus

Minimal D-Bus daemon for compatibility with standard D-Bus tools and applications.

## Objective

Act as a drop-in replacement for `dbus-daemon` but without everything that is not absolutely needed for messages to be passed and services to work.

**Removed complexity:**
* Authentication (beyond basic EXTERNAL)
* Message signing and encryption
* SELinux/AppArmor integration
* Complex security policies
* XML configuration files
* Excessive feature bloat

## Limitations and Scope

MiniBus implements the **core D-Bus protocol** needed for basic interoperability. While it works with standard tools, it does not implement the full feature set of the regular `dbus-daemon`:

### What MiniBus Does NOT Support
- Advanced security policies (XML policy files)
- Message signing and encryption  
- SELinux/AppArmor integration
- Complex service activation
- Per-service configuration
- Advanced authentication beyond SASL EXTERNAL
- Message filtering and routing policies

## Implementation Philosophy

MiniBus proves that D-Bus protocol compliance can be achieved with dramatically less complexity than the reference implementation. This is valuable for:

1. **Educational purposes** - Understanding D-Bus without implementation complexity
2. **Minimal environments** - Where full `dbus-daemon` is overkill
3. **Protocol development** - Testing D-Bus clients against a simpler implementation
4. **Debugging** - Simpler codebase for tracing protocol issues

## D-Bus Context

[Linus Torvalds](https://lkml.iu.edu/hypermail/linux/kernel/1506.2/05492.html) famously criticized D-Bus complexity:

> "the reason dbus performs abysmally badly is just pure shit user space code"

Common criticisms of D-Bus:
* Overly complicated for basic message passing
* Unnecessary "security" layering (why not use OS-level socket permissions?)
* Complex message serialization (why not JSON?)
* Padding and endianness requirements
* XML configuration overhead
* Mandatory signature fields

MiniBus addresses these by implementing **only the essential protocol elements** needed for compatibility, demonstrating that much of the complexity can be avoided while maintaining interoperability.

## How to use

In `Gershwin.sh`, replace the existing code block with

```
# D-Bus is required by Menu; force minibus as the session bus and let it
# be inherited by gershwin-session and all supervised apps.
UID=$(id -u)
if which Menu >/dev/null 2>&1; then
  MINIBUS_SOCKET="/tmp/minibus-$UID.socket"
  rm -f "$MINIBUS_SOCKET"
  minibus "$MINIBUS_SOCKET" &
  i=0; while [ ! -S "$MINIBUS_SOCKET" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$MINIBUS_SOCKET"
  export DBUS_SESSION_BUS_PID=$!
  # Make GTK applications use Menu; this requires e.g., on Debian:
  # sudo apt-get -y install appmenu-gtk2-module appmenu-gtk3-module
  export GTK_MODULES=appmenu-gtk-module
fi
```
