#!/usr/bin/env python3
"""
Refresh every [<accountId>_<RoleName>] profile in an AWS credentials file from your IAM Identity
Center (SSO) sessions. It saves copying credentials in from the SSO portal by hand, and it works
across several AWS organizations in one run.

    ./refresh-sso-creds.py /workspace/Claude-Yolo-Creds/aws/credentials
    ./refresh-sso-creds.py creds.ini --dry-run          # show which SSO session each profile maps to
    ./refresh-sso-creds.py creds.ini --sso-session primeharbor   # fallback for unmapped accounts

How each [<accountId>_<RoleName>] section finds its SSO session:
  1. It looks in ~/.aws/config for a [profile ...] whose sso_account_id matches, preferring one
     whose sso_role_name also matches. It uses that profile's sso_session (the [sso-session <name>]
     start URL and region), or the profile's own legacy sso_start_url and sso_region.
  2. If no profile matches: --sso-session, or --start-url + --sso-region, or the only
     [sso-session] if there's exactly one.

Then for each SSO session involved:
  - It uses the cached token in ~/.aws/sso/cache. If there's none, it runs
    `aws sso login --sso-session <name>` (once per session; a browser opens).
  - It calls `aws sso get-role-credentials` per profile and rewrites that section of the file.
    Other sections are left alone.
  - It writes the file atomically with mode 0600. It prints only account, role, session and
    expiry, never keys.

Needs Python 3 and AWS CLI v2. Run it where your SSO sessions live, e.g. your laptop, against
the credentials file the dev container mounts.
"""
import argparse
import configparser
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

SECTION_RE = re.compile(r"^(\d{12})_(.+)$")


def read_aws_config():
    cfg = configparser.RawConfigParser()
    cfg.read(os.path.expanduser(os.environ.get("AWS_CONFIG_FILE_FOR_SSO", "~/.aws/config")))
    sessions = {sec.split(" ", 1)[1]: cfg[sec] for sec in cfg.sections() if sec.startswith("sso-session ")}
    profiles = {sec.split(" ", 1)[1] if sec.startswith("profile ") else sec: cfg[sec]
                for sec in cfg.sections() if sec.startswith("profile ") or sec == "default"}
    return sessions, profiles


class Sso:
    """One SSO sign-in: an sso-session name (if any), a start URL and a region."""
    def __init__(self, name, start_url, region):
        self.name, self.start_url, self.region = name, start_url.rstrip("/#"), region

    @property
    def key(self):
        return (self.start_url, self.region)

    def label(self):
        return self.name or self.start_url


def sso_for_profile(p, sessions):
    if p.get("sso_session"):
        s = sessions.get(p["sso_session"])
        if s is None:
            return None
        return Sso(p["sso_session"], s["sso_start_url"], s["sso_region"])
    if p.get("sso_start_url") and p.get("sso_region"):
        return Sso(None, p["sso_start_url"], p["sso_region"])     # legacy, token-provider-less profile
    return None


def resolve(account, role, sessions, profiles, fallback):
    """The Sso for this account/role from ~/.aws/config, or the fallback."""
    matches = [p for p in profiles.values() if p.get("sso_account_id") == account]
    matches.sort(key=lambda p: p.get("sso_role_name") != role)       # exact role first
    for p in matches:
        sso = sso_for_profile(p, sessions)
        if sso:
            return sso, "profile"
    return fallback, "fallback"


def cached_token(start_url):
    """The newest unexpired SSO access token cached for this start URL, or None."""
    now = datetime.datetime.now(datetime.timezone.utc)
    best = None
    for path in glob.glob(os.path.expanduser("~/.aws/sso/cache/*.json")):
        try:
            with open(path) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        if d.get("startUrl", "").rstrip("/#") != start_url.rstrip("/#") or "accessToken" not in d:
            continue
        exp = datetime.datetime.fromisoformat(d["expiresAt"].replace("Z", "+00:00"))
        if exp.tzinfo is None:
            exp = exp.replace(tzinfo=datetime.timezone.utc)
        if exp - now > datetime.timedelta(minutes=5) and (best is None or exp > best[1]):
            best = (d["accessToken"], exp)
    return best[0] if best else None


def role_credentials(account, role, token, region):
    out = subprocess.run(
        ["aws", "sso", "get-role-credentials", "--account-id", account, "--role-name", role,
         "--access-token", token, "--region", region, "--output", "json"],
        capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "failed")
    return json.loads(out.stdout)["roleCredentials"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("credentials_file")
    ap.add_argument("--sso-session", help="name of the [sso-session ...] in ~/.aws/config")
    ap.add_argument("--start-url", help="SSO start URL (skips ~/.aws/config lookup)")
    ap.add_argument("--sso-region", help="SSO region (with --start-url)")
    ap.add_argument("--dry-run", action="store_true", help="show which profiles would refresh; change nothing")
    args = ap.parse_args()

    path = os.path.abspath(args.credentials_file)
    creds = configparser.RawConfigParser()
    creds.optionxform = str                      # keep key case
    if not creds.read(path):
        sys.exit(f"Can't read {path}")
    targets = [(s, *SECTION_RE.match(s).groups()) for s in creds.sections() if SECTION_RE.match(s)]
    if not targets:
        sys.exit(f"No [<accountId>_<RoleName>] sections in {path}")
    sessions, profiles = read_aws_config()
    if args.start_url:
        if not args.sso_region:
            sys.exit("--start-url needs --sso-region")
        fallback = Sso(None, args.start_url, args.sso_region)
    elif args.sso_session:
        if args.sso_session not in sessions:
            sys.exit(f"No [sso-session {args.sso_session}] in ~/.aws/config")
        s = sessions[args.sso_session]
        fallback = Sso(args.sso_session, s["sso_start_url"], s["sso_region"])
    elif len(sessions) == 1:
        name, s = next(iter(sessions.items()))
        fallback = Sso(name, s["sso_start_url"], s["sso_region"])
    else:
        fallback = None

    plan = []
    for section, account, role in targets:
        sso, how = resolve(account, role, sessions, profiles, fallback)
        plan.append((section, account, role, sso, how))
        where = f"{sso.label()} ({how})" if sso else "NO SSO SESSION FOUND"
        if args.dry_run or sso is None:
            print(f"{'would refresh' if args.dry_run else 'skip':13} [{section}]  -> {where}")
    if args.dry_run:
        return

    tokens, failed = {}, 0
    for section, account, role, sso, how in plan:
        if sso is None:
            failed += 1
            continue
        if sso.key not in tokens:
            token = cached_token(sso.start_url)
            if token is None:
                if not sso.name:
                    print(f"FAILED  [{section}]: no cached token for {sso.start_url}; run `aws sso login` for it")
                    tokens[sso.key] = None
                else:
                    print(f"No valid SSO token for {sso.name}; running `aws sso login --sso-session {sso.name}` ...")
                    subprocess.run(["aws", "sso", "login", "--sso-session", sso.name], check=True)
                    token = cached_token(sso.start_url)
            tokens[sso.key] = token
        token = tokens[sso.key]
        if token is None:
            failed += 1
            continue
        try:
            rc = role_credentials(account, role, token, sso.region)
        except RuntimeError as e:
            print(f"FAILED  [{section}]: {e}")
            failed += 1
            continue
        creds[section]["aws_access_key_id"] = rc["accessKeyId"]
        creds[section]["aws_secret_access_key"] = rc["secretAccessKey"]
        creds[section]["aws_session_token"] = rc["sessionToken"]
        expires = datetime.datetime.fromtimestamp(rc["expiration"] / 1000, datetime.timezone.utc)
        print(f"ok      [{section}]  via {sso.label()}  expires {expires:%Y-%m-%d %H:%M} UTC")

    # Atomic rewrite, owner-only
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".creds-")
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w") as fh:
            creds.write(fh)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
