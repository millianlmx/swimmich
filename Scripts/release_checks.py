#!/usr/bin/env python3
"""Checks of the App Store release chain (Scripts/release.sh, Scripts/ipa.sh).

Standard library only. Every sub-command reports through GitHub annotations
(`::error title=…::…`, `::notice title=…::…`), which stay readable when the job
logs are not. No sub-command ever prints the value of an environment variable.
"""
import hashlib
import os
import plistlib
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

TEAM = "2MJF39L8VY"
KEYCHAIN_GROUP = f"{TEAM}.fr.millianlmx.swimmich"
SECRETS_HINT = 'add it to the secrets of the GitHub Environment "app-store" (README, Release)'

REQUIRED_SECRETS = (
    "APPLE_DISTRIBUTION_P12_BASE64",
    "APPLE_DISTRIBUTION_P12_PASSWORD",
    "PROFILE_APP_BASE64",
    "PROFILE_WIDGETS_BASE64",
    "PROFILE_SHARE_EXTENSION_BASE64",
    "ASC_KEY_ID",
    "ASC_ISSUER_ID",
    "ASC_KEY_P8_BASE64",
)

# label -> (secret holding the profile, bundle id, signed bundle inside the app)
PROFILES = {
    "app": ("PROFILE_APP_BASE64", "fr.millianlmx.immich-ios", "ImmichSwiftUI.app"),
    "widgets": ("PROFILE_WIDGETS_BASE64", "fr.millianlmx.immich-ios.widgets", "PlugIns/ImmichWidgets.appex"),
    "share-extension": (
        "PROFILE_SHARE_EXTENSION_BASE64",
        "fr.millianlmx.immich-ios.share-extension",
        "PlugIns/ImmichShareExtension.appex",
    ),
}

EXTENSIONS = ("ImmichShareExtension.appex", "ImmichWidgets.appex")
FRAMEWORK = "ImmichSharedKit.framework"

_TAG = re.compile(r"^v(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){0,2}$")
_KEY_ID = re.compile(r"^[A-Z0-9]{10}$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")


class ReleaseError(Exception):
    pass


def annotation(kind, title, message):
    message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return f"::{kind} title={title}::{message}"


def missing_secrets(env):
    return [name for name in REQUIRED_SECRETS if not str(env.get(name, "")).strip()]


def malformed_secrets(env):
    bad = []
    key_id = str(env.get("ASC_KEY_ID", "")).strip()
    if key_id and not _KEY_ID.match(key_id):
        bad.append(("ASC_KEY_ID", "must be the 10-character key ID"))
    issuer = str(env.get("ASC_ISSUER_ID", "")).strip()
    if issuer and not _UUID.match(issuer):
        bad.append(("ASC_ISSUER_ID", "must be the issuer UUID"))
    return bad


def marketing_version(tag):
    if not _TAG.match(tag):
        raise ReleaseError(f"{tag} is not v<major>[.<minor>[.<patch>]]")
    return tag[1:]


def state_dir(runner_temp, tmpdir, user, repo_root):
    if runner_temp:
        path = Path(runner_temp) / "swimmich-release"
    else:
        path = Path(tmpdir or "/tmp") / f"swimmich-release-{user}"
    resolved, root = path.resolve(), Path(repo_root).resolve()
    if resolved == root or root in resolved.parents:
        raise ReleaseError(f"{path} is inside the repository")
    return path


def _utc(moment):
    if moment.tzinfo is not None:
        moment = moment.astimezone(timezone.utc).replace(tzinfo=None)
    return moment


def check_profile(plist_bytes, bundle_id, identity_sha1, secret_name, now):
    """Return (uuid, name, errors) for a provisioning profile already decoded to a plist."""
    try:
        plist = plistlib.loads(plist_bytes)
        if not isinstance(plist, dict):
            raise ValueError
    except Exception:
        return "", "", [f"{secret_name}: is not a provisioning profile"]
    errors = []
    entitlements = plist.get("Entitlements") or {}
    if TEAM not in (plist.get("TeamIdentifier") or []):
        errors.append(f"{secret_name}: is not for the team {TEAM}")
    expected_id = f"{TEAM}.{bundle_id}"
    found_id = entitlements.get("application-identifier")
    if found_id != expected_id:
        errors.append(f"{secret_name}: is for {found_id}, expected {expected_id}")
    if (
        "ProvisionedDevices" in plist
        or plist.get("ProvisionsAllDevices")
        or entitlements.get("get-task-allow")
    ):
        errors.append(f"{secret_name}: is not an App Store distribution profile")
    expiry = plist.get("ExpirationDate")
    if isinstance(expiry, datetime) and _utc(expiry) <= _utc(now):
        errors.append(f"{secret_name}: expired on {expiry.date().isoformat()}")
    wanted = identity_sha1.upper()
    certs = plist.get("DeveloperCertificates") or []
    if not any(hashlib.sha1(bytes(der)).hexdigest().upper() == wanted for der in certs):
        errors.append(f"{secret_name}: does not include the certificate of APPLE_DISTRIBUTION_P12_BASE64")
    groups = entitlements.get("keychain-access-groups") or []
    if f"{TEAM}.*" not in groups and KEYCHAIN_GROUP not in groups:
        errors.append(f"{secret_name}: does not allow the keychain group {KEYCHAIN_GROUP}")
    return str(plist.get("UUID", "")), str(plist.get("Name", "")), errors


def check_payload(payload_dir):
    payload = Path(payload_dir)
    apps = sorted(p for p in payload.iterdir() if p.is_dir() and p.suffix == ".app") if payload.is_dir() else []
    if len(apps) != 1:
        return [f"Payload holds {len(apps)} .app bundles, expected 1"]
    app = apps[0]
    errors = []
    plugins = app / "PlugIns"
    appexes = sorted(p for p in plugins.iterdir() if p.suffix == ".appex") if plugins.is_dir() else []
    names = [p.name for p in appexes]
    if names != list(EXTENSIONS):
        errors.append(f"PlugIns holds [{', '.join(names)}], expected [{', '.join(EXTENSIONS)}]")
    for appex in appexes:
        if (appex / "Frameworks").exists():
            errors.append(f"{appex.name} embeds a Frameworks/ folder (ITMS-90206)")
    found = sorted(
        str(Path(root, d).relative_to(app))
        for root, dirs, _ in os.walk(app)
        for d in dirs
        if d == FRAMEWORK
    )
    if found != [f"Frameworks/{FRAMEWORK}"]:
        errors.append(f"{FRAMEWORK} found {len(found)} times: [{', '.join(found)}]")
    return errors


def check_signing(identity_sha1, observed):
    errors = []
    for label, (secret, _, _) in PROFILES.items():
        if label not in observed:
            errors.append(f"{label} was not inspected in the IPA")
            continue
        sha1, embedded, expected = observed[label]
        if sha1.upper() != identity_sha1.upper():
            errors.append(
                f"{label} is signed by {sha1}, expected {identity_sha1} from APPLE_DISTRIBUTION_P12_BASE64"
            )
        if embedded.upper() != expected.upper():
            errors.append(f"{label} embeds profile {embedded}, expected {expected} from {secret}")
    return errors


def parse_search_list(text):
    entries = []
    for line in text.splitlines():
        line = line.strip().strip('"').strip()
        if line:
            entries.append(line)
    return entries


def _real(path):
    return os.path.realpath(path)


def without_keychain(entries, keychain):
    target = _real(keychain)
    return [e for e in entries if _real(e) != target]


def lost_entries(saved, current):
    present = {_real(e) for e in current}
    return [e for e in saved if _real(e) not in present]


def _print_all(lines):
    for line in lines:
        print(line)
    return 1 if lines else 0


def _cmd_secrets(_args):
    env = os.environ
    lines = [
        annotation("error", "Missing secret", f"{name} is not set: {SECRETS_HINT}")
        for name in missing_secrets(env)
    ]
    lines += [
        annotation("error", "Malformed secret", f"{name} {reason}") for name, reason in malformed_secrets(env)
    ]
    if lines:
        return _print_all(lines)
    print(f"release_checks: the {len(REQUIRED_SECRETS)} release secrets are set")
    return 0


def _cmd_version(args):
    try:
        print(marketing_version(args[0] if args else ""))
        return 0
    except ReleaseError as error:
        print(annotation("error", "Release tag", str(error)))
        return 1


def _cmd_state_dir(_args):
    root = Path(__file__).resolve().parent.parent
    try:
        env = os.environ
        print(state_dir(env.get("RUNNER_TEMP", ""), env.get("TMPDIR", ""), env.get("USER", ""), root))
        return 0
    except ReleaseError as error:
        print(annotation("error", "Signing state", str(error)))
        return 1


def _cmd_profile(args):
    plist_path, label, identity = args
    secret, bundle, _ = PROFILES[label]
    uuid, _, errors = check_profile(
        Path(plist_path).read_bytes(), bundle, identity, secret, datetime.now(timezone.utc)
    )
    if errors:
        return _print_all([annotation("error", "Provisioning profile", e) for e in errors])
    print(uuid)
    return 0


def _cmd_profile_field(args):
    plist = plistlib.loads(Path(args[0]).read_bytes())
    value = plist.get(args[1])
    if value is None:
        return 1
    print(value)
    return 0


def _cmd_secret_names(_args):
    for name in REQUIRED_SECRETS:
        print(name)
    return 0


def _cmd_search_list(_args):
    for entry in parse_search_list(sys.stdin.read()):
        print(entry)
    return 0


def _cmd_payload(args):
    errors = check_payload(args[0])
    if errors:
        return _print_all([annotation("error", "Packaging", e) for e in errors])
    app = next(Path(args[0]).glob("*.app")).name
    print(f"release_checks: payload ok ({app}, 2 extensions, ImmichSharedKit embedded once)")
    return 0


def _cmd_signing(args):
    identity, observed = args[0], {}
    for item in args[1:]:
        label, _, values = item.partition("=")
        parts = values.split(",")
        if len(parts) == 3:
            observed[label] = tuple(parts)
    errors = check_signing(identity, observed)
    if errors:
        return _print_all([annotation("error", "Signing", e) for e in errors])
    uuids = ", ".join(f"{label}={observed[label][1]}" for label in PROFILES)
    print(
        annotation(
            "notice",
            "Signing",
            f"certificate {identity} (APPLE_DISTRIBUTION_P12_BASE64) signed app, widgets, "
            f"share-extension; profiles {uuids}",
        )
    )
    return 0


def _cmd_search_list_without(args):
    for entry in without_keychain(parse_search_list(sys.stdin.read()), args[0]):
        print(entry)
    return 0


def _cmd_search_list_lost(args):
    saved = parse_search_list(Path(args[0]).read_text())
    for entry in lost_entries(saved, parse_search_list(sys.stdin.read())):
        print(entry)
    return 0


COMMANDS = {
    "secrets": _cmd_secrets,
    "version": _cmd_version,
    "state-dir": _cmd_state_dir,
    "profile": _cmd_profile,
    "profile-field": _cmd_profile_field,
    "payload": _cmd_payload,
    "signing": _cmd_signing,
    "search-list-without": _cmd_search_list_without,
    "search-list-lost": _cmd_search_list_lost,
    "search-list": _cmd_search_list,
    "secret-names": _cmd_secret_names,
}


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: release_checks.py {{{'|'.join(COMMANDS)}}} …", file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main())
