#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3>=1.44.9"]
# ///
"""Re-mint every grant devc grant-aws-creds recorded, exactly as it was granted.

Usage:
  devc refresh-aws-creds [--dry-run]

Claude-Yolo-Creds/aws/granted-policy.json is the source of truth. For each entry this re-runs the
grant: its source_profile is resolved by boto3 (SSO, assumed role, credential_process, ...), scoped
down with sts:GetScopedCredentials using the entry's recorded policy, description and duration, and
written back to that profile's credentials and config sections. If an SSO token is missing or
expired it runs `aws sso login --profile <source_profile>` once and retries. If a grant fails, that
profile is left unchanged: unscoped credentials are never written.

One-time grants (devc grant-aws-creds --once, flagged "once") are never re-minted. Their entry and
their credentials and config sections are removed instead.

Credential sections with no entry (e.g. pasted in from the SSO portal) are left alone; re-create
them with devc grant-aws-creds. Run it where your AWS profiles live, e.g. your laptop.
"""

import argparse
import json
import subprocess
import sys
from pathlib import Path

# Shared with devc grant-aws-creds, which lives alongside this script.
from grant_aws_creds import (
    GrantError,
    SSOLoginRequired,
    default_description,
    err,
    load_granted,
    read_ini,
    record_grant,
    save_granted,
    scoped_credentials,
    write_ini,
)


def remove_once(aws_dir: Path, granted: dict, once: list[str]) -> None:
    """Drop one-time grants: their entries, credentials sections and config sections."""
    for filename, section in (
        ("credentials", lambda n: n),
        ("config", lambda n: f"profile {n}" if n != "default" else "default"),
    ):
        path = aws_dir / filename
        if not path.exists():
            continue
        parser = read_ini(path)
        if [n for n in once if parser.remove_section(section(n))]:
            write_ini(path, parser)
    for name in once:
        granted.pop(name, None)
    save_granted(aws_dir, granted)


def refresh(aws_dir: Path, name: str, entry: dict, logged_in: set[str]) -> str:
    """Re-mint one grant. Returns its new expiration; raises GrantError on failure."""
    src = entry["source_profile"]
    policy_text = json.dumps(entry["policy"], separators=(",", ":"))
    description = entry.get("description") or default_description(aws_dir.parent)
    try:
        result = scoped_credentials(src, policy_text, description, entry.get("duration_seconds"))
    except SSOLoginRequired:
        if src in logged_in:
            raise
        err(f"SSO session for '{src}' is missing or expired; running `aws sso login --profile {src}` ...")
        subprocess.run(["aws", "sso", "login", "--profile", src], check=True)
        logged_in.add(src)
        result = scoped_credentials(src, policy_text, description, entry.get("duration_seconds"))
    return record_grant(aws_dir, name, result, {**entry, "description": description})


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="devc refresh-aws-creds",
        description="Re-mint every grant recorded in Claude-Yolo-Creds/aws/granted-policy.json",
    )
    parser.add_argument("--creds-dir", required=True, help="Path to Claude-Yolo-Creds/ directory")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be refreshed or removed; change nothing")
    args = parser.parse_args()

    aws_dir = Path(args.creds_dir) / "aws"
    granted = load_granted(aws_dir)
    once = [name for name, e in granted.items() if isinstance(e, dict) and e.get("once")]
    plan = []
    for name, entry in granted.items():
        if name in once or not isinstance(entry, dict):
            continue
        if not entry.get("source_profile") or not isinstance(entry.get("policy"), dict):
            missing = "source_profile" if not entry.get("source_profile") else "policy"
            err(f"skip    [{name}]  no {missing} recorded; re-run devc grant-aws-creds for it")
            continue
        plan.append((name, entry))

    for name in once:
        err(f"{'would remove' if args.dry_run else 'remove'}  [{name}]  one-time grant (--once)")
    credentials = aws_dir / "credentials"
    for section in read_ini(credentials).sections() if credentials.exists() else []:
        if section not in granted:
            err(f"skip    [{section}]  not created by devc grant-aws-creds; left unchanged")
    if not plan and not once:
        err(f"Nothing to refresh: no grants recorded in {aws_dir / 'granted-policy.json'}")
        sys.exit(1)
    if args.dry_run:
        for name, entry in plan:
            err(f"would refresh  [{name}]  from profile {entry['source_profile']}  "
                f"scope: {entry.get('policy_source', 'granted-policy.json')}")
        return

    if once:
        remove_once(aws_dir, granted, once)

    failed = 0
    logged_in: set[str] = set()
    for name, entry in plan:
        try:
            expiration = refresh(aws_dir, name, entry, logged_in)
        except (GrantError, subprocess.CalledProcessError) as e:
            err(f"FAILED  [{name}]  {e} (left unchanged)")
            failed += 1
            continue
        err(f"ok      [{name}]  from profile {entry['source_profile']}  "
            f"scope: {entry.get('policy_source', 'granted-policy.json')}  expires {expiration}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
