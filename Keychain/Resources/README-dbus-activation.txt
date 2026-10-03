D-Bus activation of Keychain
============================

Keychain publishes the freedesktop.org Secret Service under the bus name
org.freedesktop.secrets, so other programs can talk to it through the session
bus. While Keychain is running, any client that asks for that name gets it.

How activation works
--------------------

The file org.freedesktop.secrets.service next to this README is the
activation file. It is generated at build time from
Resources/org.freedesktop.secrets.service.in, which fills in the absolute
path of the installed executable:

    [D-BUS Service]
    Name=org.freedesktop.secrets
    Exec=/System/Applications/Utilities/Keychain.app/Keychain -KCServiceLaunch YES

A client that asks the session bus for org.freedesktop.secrets and finds no
owner is handed that Exec line, and the bus starts Keychain for it. The
-KCServiceLaunch YES argument tells Keychain it was started this way: it runs
as a service and opens no window, so it can answer clients without putting a
window on screen. Starting Keychain normally (from its icon, or with that
argument left off) opens the keychain window as usual.

Where the file goes
-------------------

The build copies org.freedesktop.secrets.service into the application
wrapper's Resources, so it travels with Keychain.

dbus-daemon itself does not look inside application wrappers. For activation
it reads the service files in its own service directory, for example
/usr/share/dbus-1/services/. This makefile does not copy the file there
today, so until something does, org.freedesktop.secrets has no activator and
Keychain has to be started by hand (or by its client) for the name to have an
owner.

What is not here
----------------

The activation file only names the executable. Keyring contents are stored
by the application itself, not by the bus, so removing this file does not
lose any secrets.
