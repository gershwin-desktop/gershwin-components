#!/usr/bin/env python3
#
# Copyright (c) 2026 Simon Peter
#
# SPDX-License-Identifier: BSD-2-Clause
#
# A Secret Service client that talks to Keychain.app over the session bus,
# once with raw D-Bus calls (plain and dh-ietf1024-sha256-aes128-cbc-pkcs7
# sessions, the latter decrypted with the openssl command so the check does
# not share any crypto code with the service) and once through libsecret,
# the library real applications use. Prints "PASS: ..." / "FAIL: ..." lines;
# exits non-zero on the first failure.
#
# Usage: secret_service_client.py create|unlock|libsecret-store|libsecret-lookup

import hashlib
import hmac
import os
import secrets
import subprocess
import sys

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

BUS_NAME = "org.freedesktop.secrets"
SERVICE_PATH = "/org/freedesktop/secrets"
SERVICE_IFACE = "org.freedesktop.Secret.Service"
COLLECTION_IFACE = "org.freedesktop.Secret.Collection"
ITEM_IFACE = "org.freedesktop.Secret.Item"
PROMPT_IFACE = "org.freedesktop.Secret.Prompt"
DH_ALGORITHM = "dh-ietf1024-sha256-aes128-cbc-pkcs7"
PRIME = int(
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74"
    "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437"
    "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF", 16)
ATTRS = {"service": "kc-integration", "account": "alice"}
PROMPT_TIMEOUT = int(os.environ.get("KC_PROMPT_TIMEOUT", "60"))

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SessionBus()


def check(ok, what):
    print(("PASS: " if ok else "FAIL: ") + what, flush=True)
    if not ok:
        sys.exit(1)


def obj(path):
    return bus.get_object(BUS_NAME, path)


def service():
    return dbus.Interface(obj(SERVICE_PATH), SERVICE_IFACE)


def run_prompt(path):
    """Calls Prompt() and waits for Completed, while the test script types
    the password into Keychain's panel."""
    if path == "/":
        return False, None
    loop = GLib.MainLoop()
    result = {}

    def completed(dismissed, value):
        result["dismissed"] = bool(dismissed)
        result["value"] = value
        loop.quit()

    bus.add_signal_receiver(completed, "Completed", PROMPT_IFACE, BUS_NAME, path)
    dbus.Interface(obj(path), PROMPT_IFACE).Prompt("")
    GLib.timeout_add_seconds(PROMPT_TIMEOUT, loop.quit)
    print("PROMPT: " + path, flush=True)
    loop.run()
    check("dismissed" in result, "prompt %s completed" % path)
    return result["dismissed"], result["value"]


def hkdf16(ikm):
    prk = hmac.new(b"\0" * 32, ikm, hashlib.sha256).digest()
    return hmac.new(prk, b"\x01", hashlib.sha256).digest()[:16]


def openssl_aes(decrypt, key, iv, data):
    args = ["openssl", "enc", "-aes-128-cbc", "-K", key.hex(), "-iv", iv.hex()]
    if decrypt:
        args.append("-d")
    return subprocess.run(args, input=data, capture_output=True, check=True).stdout


def open_dh_session():
    private = int.from_bytes(secrets.token_bytes(32), "big")
    public = pow(2, private, PRIME).to_bytes(128, "big")
    output, path = service().OpenSession(
        DH_ALGORITHM, dbus.ByteArray(public, variant_level=1))
    server = int.from_bytes(bytes(output), "big")
    shared = pow(server, private, PRIME).to_bytes(128, "big")
    return path, hkdf16(shared)


def search():
    unlocked, locked = service().SearchItems(ATTRS)
    return [str(p) for p in unlocked], [str(p) for p in locked]


def cmd_create():
    svc = service()
    xml = dbus.Interface(obj(SERVICE_PATH),
                         "org.freedesktop.DBus.Introspectable").Introspect()
    check("org.freedesktop.Secret.Service" in xml, "service introspects")

    default = str(svc.ReadAlias("default"))
    if default == "/":
        props = {"org.freedesktop.Secret.Collection.Label":
                 dbus.String("Login", variant_level=1)}
        coll, prompt = svc.CreateCollection(props, "default")
        check(str(coll) == "/" and str(prompt) != "/",
              "CreateCollection asks for a password through a prompt")
        dismissed, value = run_prompt(str(prompt))
        check(not dismissed, "user created the keyring in the panel")
        default = str(value)
    check(default.startswith(SERVICE_PATH + "/collection/"),
          "default alias names a collection: " + default)
    check(str(svc.ReadAlias("default")) == default, "ReadAlias(default) after create")

    coll_props = dbus.Interface(obj(default), "org.freedesktop.DBus.Properties")
    check(coll_props.Get(COLLECTION_IFACE, "Locked") == False,
          "new collection is unlocked")

    _, plain_session = svc.OpenSession("plain", dbus.String("", variant_level=1))
    collection = dbus.Interface(obj(default), COLLECTION_IFACE)
    item_props = {
        "org.freedesktop.Secret.Item.Label": dbus.String("Integration", variant_level=1),
        "org.freedesktop.Secret.Item.Attributes":
            dbus.Dictionary(ATTRS, signature="ss", variant_level=1),
    }
    secret = (plain_session, dbus.ByteArray(b""), dbus.ByteArray(b"s3cret-plain"),
              "text/plain")
    item, prompt = collection.CreateItem(item_props, secret, True)
    check(str(item).startswith(default + "/") and str(prompt) == "/",
          "CreateItem on an unlocked collection needs no prompt")

    unlocked, locked = search()
    check(str(item) in unlocked and not locked, "SearchItems finds it unlocked")

    got = svc.GetSecrets([item], plain_session)
    check(bytes(got[item][2]) == b"s3cret-plain", "GetSecrets over a plain session")

    dh_session, key = open_dh_session()
    got = svc.GetSecrets([item], dh_session)
    session_path, iv, value, ctype = got[item]
    check(str(session_path) == str(dh_session) and len(bytes(iv)) == 16,
          "DH secret carries its session and IV")
    check(openssl_aes(True, key, bytes(iv), bytes(value)) == b"s3cret-plain",
          "DH secret decrypts with the key agreed by the client")

    iv2 = secrets.token_bytes(16)
    enc = openssl_aes(False, key, iv2, b"s3cret-dh")
    item2_props = dict(item_props)
    item2_props["org.freedesktop.Secret.Item.Attributes"] = dbus.Dictionary(
        {"service": "kc-integration", "account": "bob"}, signature="ss", variant_level=1)
    item2, _ = collection.CreateItem(
        item2_props, (dh_session, dbus.ByteArray(iv2), dbus.ByteArray(enc), "text/plain"),
        True)
    got = svc.GetSecrets([item2], plain_session)
    check(bytes(got[item2][2]) == b"s3cret-dh", "CreateItem with a DH-encrypted secret")

    item_obj = dbus.Interface(obj(str(item)), ITEM_IFACE)
    check(bytes(item_obj.GetSecret(plain_session)[2]) == b"s3cret-plain", "Item.GetSecret")
    attrs = dbus.Interface(obj(str(item)), "org.freedesktop.DBus.Properties").Get(
        ITEM_IFACE, "Attributes")
    check(dict(attrs) == ATTRS, "Item Attributes property")

    locked_paths, prompt = svc.Lock([dbus.ObjectPath(default)])
    check(str(prompt) == "/", "Lock needs no prompt")
    unlocked, locked = search()
    check(str(item) in locked and not unlocked,
          "a locked keyring still reports the item as locked")
    check(len(svc.GetSecrets([item], plain_session)) == 0,
          "GetSecrets returns nothing for a locked item")
    print("ITEM: " + str(item), flush=True)


def cmd_unlock():
    svc = service()
    unlocked, locked = search()
    check(len(locked) == 1 and not unlocked,
          "after a restart the item is on disk and locked")
    done, prompt = svc.Unlock([dbus.ObjectPath(p) for p in locked])
    check(len(done) == 0 and str(prompt) != "/", "Unlock asks through a prompt")
    dismissed, value = run_prompt(str(prompt))
    check(not dismissed and [str(p) for p in value] == locked,
          "prompt unlocked the requested item")
    _, session = svc.OpenSession("plain", dbus.String("", variant_level=1))
    got = svc.GetSecrets([dbus.ObjectPath(locked[0])], session)
    check(bytes(got[dbus.ObjectPath(locked[0])][2]) == b"s3cret-plain",
          "secret survives a restart of the service")


def libsecret_schema():
    import gi
    gi.require_version("Secret", "1")
    from gi.repository import Secret
    schema = Secret.Schema.new(
        "org.freedesktop.Secret.Generic", Secret.SchemaFlags.NONE,
        {"service": Secret.SchemaAttributeType.STRING,
         "account": Secret.SchemaAttributeType.STRING})
    return Secret, schema


def cmd_libsecret_store():
    Secret, schema = libsecret_schema()
    ok = Secret.password_store_sync(
        schema, {"service": "libsecret-test", "account": "carol"},
        Secret.COLLECTION_DEFAULT, "libsecret item", "from-libsecret", None)
    check(ok, "libsecret password_store_sync")
    value = Secret.password_lookup_sync(
        schema, {"service": "libsecret-test", "account": "carol"}, None)
    check(value == "from-libsecret", "libsecret password_lookup_sync")


def cmd_libsecret_lookup():
    Secret, schema = libsecret_schema()
    value = Secret.password_lookup_sync(
        schema, {"service": "libsecret-test", "account": "carol"}, None)
    check(value == "from-libsecret",
          "libsecret finds the password after a restart (unlock prompt answered)")


if __name__ == "__main__":
    {"create": cmd_create,
     "unlock": cmd_unlock,
     "libsecret-store": cmd_libsecret_store,
     "libsecret-lookup": cmd_libsecret_lookup}[sys.argv[1]]()
