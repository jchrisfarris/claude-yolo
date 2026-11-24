#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3>=1.44.9"]
# ///
"""Write scoped-down AWS credentials to Claude-Yolo-Creds/aws/ via sts:GetScopedCredentials.

Usage:
  devc grant-aws-creds --profile PROFILE [--as-profile NAME] [--policy FILE]
                       [--duration SECONDS] [--description TEXT] [--once]
  devc grant-all-aws-creds --sso-session NAME [--policy FILE]
                       [--duration SECONDS] [--description TEXT] [--once]

grant-all-aws-creds grants every profile in ~/.aws/config whose sso_session is NAME, each under
its own profile name, running `aws sso login --sso-session NAME` once if the token has expired.

Calls GetScopedCredentials with the given profile's temporary credentials and a scope down
policy (default: aws-config/session-policy.json — a deny-list of irreversible actions). The
resulting credentials keep the caller's identity (same session ARN, so CloudTrail still
attributes every call to the authorizing human) but can only do what both the caller's own
permissions and the scope down policy allow. They are merged into Claude-Yolo-Creds/aws/
(only this profile's section changes), which is bind-mounted read-only into the container
at ~/.aws/.

The granted policy is also written to Claude-Yolo-Creds/aws/granted-policy.json so Claude can
see what it currently holds and ask for exactly what's missing. That entry also records the
source profile and session description, which devc refresh-aws-creds reuses. With --once the
entry is flagged as a one-time grant: refresh-aws-creds never re-mints it, and removes it (and
its credentials/config sections) the next time it runs.

Re-run any time to refresh or to grant a different policy. Scoped credentials can never
outlive the calling session, so for SSO profiles re-run after `aws sso login`.
"""

import argparse
import configparser
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import boto3
import botocore.session
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    NoCredentialsError,
    ProfileNotFound,
    SSOError,
    TokenRetrievalError,
)

# GetScopedCredentials limits, from the STS API reference.
MAX_POLICY_CHARS = 2048
MAX_DURATION_SECONDS = 129600
MIN_DESCRIPTION_CHARS = 2
MAX_DESCRIPTION_CHARS = 256
DESCRIPTION_RE = re.compile(r"[\t\n\r\x20-\x7E\xA1-\xFF]*")

# The default policy's deny-list statement. Suggested policies add statements after it
# rather than editing it, so any change to it is called out for the human approving the grant.
DEFAULT_POLICY = Path(__file__).resolve().parent / "aws-config" / "session-policy.json"
BASE_SID = "AllowAllExceptIrreversible"


def err(msg: str) -> None:
    print(f"[devc] {msg}", file=sys.stderr)


def die(msg: str) -> None:
    err(msg)
    sys.exit(1)


def read_ini(path: Path) -> configparser.ConfigParser:
    # No interpolation, so a literal '%' in an existing value survives the round trip.
    parser = configparser.ConfigParser(interpolation=None)
    try:
        parser.read(path)
    except configparser.Error as e:
        die(f"Could not parse existing {path}: {e}\nFix or remove it, then re-run.")
    return parser


def write_ini(path: Path, parser: configparser.ConfigParser) -> None:
    """Rewrite an INI file atomically, owner-only."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}-")
    try:
        os.chmod(tmp, 0o600)
        with os.fdopen(fd, "w") as f:
            parser.write(f)
        os.replace(tmp, path)
    except BaseException:
        os.unlink(tmp)
        raise


def load_granted(aws_dir: Path) -> dict:
    """granted-policy.json as {profile: entry}, or {} if missing or unreadable."""
    try:
        granted = json.loads((aws_dir / "granted-policy.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}
    return granted if isinstance(granted, dict) else {}


def save_granted(aws_dir: Path, granted: dict) -> None:
    path = aws_dir / "granted-policy.json"
    path.write_text(json.dumps(granted, indent=2))
    path.chmod(0o600)


def default_description(creds_dir: Path) -> str:
    """The default ScopedSessionDescription, naming the workspace that holds Claude-Yolo-Creds/."""
    # Restricted to printable ASCII, since the API rejects most other characters.
    workspace = "".join(c for c in creds_dir.resolve().parent.name if " " <= c <= "~")
    return f"claude-yolo agent credentials for workspace {workspace}"[:MAX_DESCRIPTION_CHARS]


def description_error(text: str) -> str | None:
    """Why text isn't a valid ScopedSessionDescription, or None if it is."""
    if not MIN_DESCRIPTION_CHARS <= len(text) <= MAX_DESCRIPTION_CHARS:
        return f"must be {MIN_DESCRIPTION_CHARS}-{MAX_DESCRIPTION_CHARS} characters (got {len(text)})"
    if not DESCRIPTION_RE.fullmatch(text):
        return "may only contain printable ASCII, tab/newline, or Latin-1 characters (U+00A1-U+00FF)"
    return None


def load_policy(path: Path) -> str:
    try:
        policy = json.loads(path.read_text())
    except FileNotFoundError:
        die(f"Policy file not found: {path}")
    except json.JSONDecodeError as e:
        die(f"Policy file {path} is not valid JSON: {e}")

    # The 2048-char limit is on the plaintext STS receives, so minify before measuring.
    policy_text = json.dumps(policy, separators=(",", ":"))
    if len(policy_text) > MAX_POLICY_CHARS:
        die(
            f"Policy is {len(policy_text)} characters minified; GetScopedCredentials allows at most "
            f"{MAX_POLICY_CHARS}. Consolidate actions with wildcards or drop unused statements."
        )
    return policy_text


def base_statement(policy: dict) -> dict | None:
    statements = policy.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    return next((st for st in statements if isinstance(st, dict) and st.get("Sid") == BASE_SID), None)


def review_policy(policy_text: str) -> None:
    """Warn if the base deny-list statement was altered, and list what's granted on top of it."""
    policy = json.loads(policy_text)
    try:
        default_base = base_statement(json.loads(DEFAULT_POLICY.read_text()))
    except (OSError, json.JSONDecodeError):
        default_base = None
    if default_base is None:
        return  # no shipped base statement to compare against

    base = base_statement(policy)
    if base is None:
        err(f"WARNING: policy has no '{BASE_SID}' statement — the default deny-list is not applied.")
    elif base != default_base:
        err(f"WARNING: the '{BASE_SID}' statement differs from {DEFAULT_POLICY}.")
        err("         Review that change before trusting this grant.")

    statements = policy.get("Statement", [])
    if isinstance(statements, dict):
        statements = [statements]
    extra = [st for st in statements if not (isinstance(st, dict) and st.get("Sid") == BASE_SID)]
    if base is not None and extra:
        err(f"Additional statements granted on top of '{BASE_SID}':")
        for st in extra:
            err(f"  {json.dumps(st, separators=(',', ':'))}")


class GrantError(Exception):
    """A grant failed; the message is for the human."""


class SSOLoginRequired(GrantError):
    """The profile's SSO token is missing or expired; `aws sso login` would fix it."""


def scoped_credentials(profile: str, policy_text: str, description: str, duration: int | None = None) -> dict:
    """Scope a profile's temporary credentials down with GetScopedCredentials.

    Returns {"identity", "region", "response"}. Raises GrantError (SSOLoginRequired when an
    `aws sso login` would help) rather than exiting, so devc refresh-aws-creds can carry on.
    """
    try:
        session = boto3.Session(profile_name=profile)
    except ProfileNotFound:
        raise GrantError(f"AWS profile '{profile}' not found. Check ~/.aws/config") from None

    region = session.region_name or "us-east-1"
    sts = session.client("sts", region_name=region)

    # GetScopedCredentials isn't served by the STS global endpoint, which a profile can still
    # opt into with sts_regional_endpoints = legacy.
    if sts.meta.endpoint_url.rstrip("/") == "https://sts.amazonaws.com":
        raise GrantError(
            "GetScopedCredentials is not available on the STS global endpoint.\n"
            f"Remove 'sts_regional_endpoints = legacy' from profile '{profile}' (or AWS_STS_REGIONAL_ENDPOINTS)."
        )

    # Verify credentials and get identity — forces SSO refresh errors to surface here
    try:
        identity = sts.get_caller_identity()
        caller = session.get_credentials().get_frozen_credentials()
    except (SSOError, TokenRetrievalError) as e:
        raise SSOLoginRequired(f"SSO session for profile '{profile}' is missing or expired: {e}") from e
    except NoCredentialsError:
        raise GrantError(
            f"No credentials for profile '{profile}'.\nFor SSO profiles, run: aws sso login --profile {profile}"
        ) from None
    except (ClientError, BotoCoreError) as e:
        raise GrantError(f"Credential error for profile '{profile}': {e}") from e

    if not caller.token:
        raise GrantError(
            f"Profile '{profile}' uses long-lived IAM user credentials.\n"
            "GetScopedCredentials only accepts temporary credentials — use an SSO or assumed-role profile."
        )

    request = {"Policy": policy_text, "ScopedSessionDescription": description}
    if duration is not None:
        request["DurationSeconds"] = duration

    try:
        response = sts.get_scoped_credentials(**request)
    except ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "AccessDenied":
            raise GrantError(
                f"Access denied calling sts:GetScopedCredentials as {identity['Arn']}.\n"
                "The calling role needs sts:GetScopedCredentials allowed in its identity policy."
            ) from e
        if code == "InsufficientSessionLifetime":
            raise GrantError(
                f"Duration {duration}s exceeds the calling session's remaining lifetime. Omit it to inherit."
            ) from e
        raise GrantError(f"GetScopedCredentials failed: {e}") from e
    except BotoCoreError as e:
        raise GrantError(f"GetScopedCredentials failed: {e}") from e

    return {"identity": identity, "region": region, "response": response}


def record_grant(aws_dir: Path, target: str, result: dict, entry: dict) -> str:
    """Write scoped credentials, region and the granted-policy.json entry for one profile.

    Additive: only this profile's sections and entry change. entry holds the grant's settings
    (source_profile, description, policy, ...); the results of this mint are added to it.
    Returns the expiration as an ISO 8601 UTC string.
    """
    scoped = result["response"]["Credentials"]
    aws_dir.mkdir(parents=True, exist_ok=True)

    creds_file = aws_dir / "credentials"
    credentials = read_ini(creds_file)
    # Replace the whole section, so no stale keys (e.g. credential_process) outrank the new ones
    credentials[target] = {
        "aws_access_key_id": scoped["AccessKeyId"],
        "aws_secret_access_key": scoped["SecretAccessKey"],
        "aws_session_token": scoped["SessionToken"],
    }
    write_ini(creds_file, credentials)

    # Write config (region) — merged into the existing section, keeping its other settings
    config_file = aws_dir / "config"
    config = read_ini(config_file)
    config_section = f"profile {target}" if target != "default" else "default"
    if not config.has_section(config_section):
        config.add_section(config_section)
    config[config_section]["region"] = result["region"]
    write_ini(config_file, config)

    # Record what was granted, keyed by profile, so Claude can read ~/.aws/granted-policy.json
    # inside the container and request only what's missing, and devc refresh-aws-creds can
    # re-mint it the same way.
    expiration = scoped["Expiration"].astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    granted = load_granted(aws_dir)
    granted[target] = {
        **entry,
        "identity": result["identity"]["Arn"],
        "expiration": expiration,
        "scoped_policies_count": result["response"].get("ScopedPoliciesCount"),
    }
    save_granted(aws_dir, granted)
    return expiration


def grant_one(
    aws_dir: Path, profile: str, target: str, policy_text: str, policy_path: Path,
    description: str, duration: int | None, once: bool,
) -> dict:
    """Scope one profile down and record it under target. Raises GrantError on failure.

    Returns the scoped_credentials() result plus the new "expiration".
    """
    existing = load_granted(aws_dir).get(target)
    if once and isinstance(existing, dict) and not existing.get("once"):
        raise GrantError(
            f"'{target}' already holds a standing grant, which --once would replace and refresh-aws-creds would then delete."
        )

    result = scoped_credentials(profile, policy_text, description, duration)

    entry = {
        "source_profile": profile,
        "description": description,
        "policy_source": str(policy_path),
        "policy": json.loads(policy_text),
    }
    if duration is not None:
        entry["duration_seconds"] = duration
    if once:
        entry["once"] = True
    return {**result, "expiration": record_grant(aws_dir, target, result, entry)}


def cmd_grant_aws_creds(args: argparse.Namespace) -> None:
    policy_path = Path(args.policy)
    policy_text = load_policy(policy_path)
    review_policy(policy_text)

    aws_dir = Path(args.creds_dir) / "aws"
    # --as-profile names the section; --profile is only the host profile we scope down.
    target = args.as_profile or args.profile
    # Logged to CloudTrail with the GetScopedCredentials event, so the agent session is
    # distinguishable from the human's own use of the same role session.
    description = args.description if args.description is not None else default_description(Path(args.creds_dir))

    try:
        result = grant_one(aws_dir, args.profile, target, policy_text, policy_path, description, args.duration, args.once)
    except GrantError as e:
        if args.once and "standing grant" in str(e):
            die(f"{e}\nGive the one-time grant its own name, e.g. --as-profile {target}-once")
        die(str(e))

    response = result["response"]
    err(f"Account : {result['identity']['Account']}")
    err(f"Identity: {result['identity']['Arn']}")
    err(f"Region  : {result['region']}")
    err(f"Policy  : {policy_path} ({len(policy_text)}/{MAX_POLICY_CHARS} chars)")
    err(f"Expires : {result['expiration']}")
    if response.get("SessionTokenUtilization") is not None:
        err(f"Token   : {response['SessionTokenUtilization']}% of max session token size")
    err(f"Session : {description}")
    err(f"Written : {aws_dir}/")
    err(f"Profile '{target}' is ready inside the container with scoped-down permissions.")
    if args.once:
        err("One-time grant: devc refresh-aws-creds won't renew it, and removes it the next time it runs.")


def cmd_grant_all_aws_creds(args: argparse.Namespace) -> None:
    """Grant every profile in ~/.aws/config whose sso_session is args.sso_session."""
    config = botocore.session.get_session().full_config  # honors AWS_CONFIG_FILE
    if args.sso_session not in config.get("sso_sessions", {}):
        die(f"No [sso-session {args.sso_session}] in your AWS config")
    profiles = sorted(name for name, p in config["profiles"].items() if p.get("sso_session") == args.sso_session)
    if not profiles:
        die(f"No profiles use sso_session = {args.sso_session}")

    policy_path = Path(args.policy)
    policy_text = load_policy(policy_path)
    review_policy(policy_text)

    aws_dir = Path(args.creds_dir) / "aws"
    description = args.description if args.description is not None else default_description(Path(args.creds_dir))
    err(f"Granting {len(profiles)} profile(s) from SSO session '{args.sso_session}' with {policy_path}")

    logged_in, failed = False, []
    for profile in profiles:
        try:
            try:
                result = grant_one(aws_dir, profile, profile, policy_text, policy_path, description, args.duration, args.once)
            except SSOLoginRequired:
                if logged_in:
                    raise
                # One login covers every profile in the session
                err(f"SSO session '{args.sso_session}' is missing or expired; running `aws sso login --sso-session {args.sso_session}` ...")
                subprocess.run(["aws", "sso", "login", "--sso-session", args.sso_session], check=True)
                logged_in = True
                result = grant_one(aws_dir, profile, profile, policy_text, policy_path, description, args.duration, args.once)
        except (GrantError, subprocess.CalledProcessError) as e:
            err(f"FAILED  [{profile}]  {e}")
            failed.append(profile)
            continue
        err(f"ok      [{profile}]  {result['identity']['Arn']}  expires {result['expiration']}")

    if len(failed) < len(profiles):
        err(f"Session : {description}")
        err(f"Written : {aws_dir}/")
        if args.once:
            err("One-time grants: devc refresh-aws-creds won't renew them, and removes them the next time it runs.")
    if failed:
        die(f"{len(failed)} of {len(profiles)} profile(s) failed and were left unchanged: {', '.join(failed)}")
    err(f"All {len(profiles)} profile(s) are ready inside the container with scoped-down permissions.")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="devc grant-aws-creds",
        description="Write scoped-down AWS credentials (sts:GetScopedCredentials) to Claude-Yolo-Creds/aws/",
    )
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--profile", help="AWS profile to scope down (must yield temporary credentials)")
    source.add_argument(
        "--sso-session",
        help="Grant every profile whose sso_session is this (devc grant-all-aws-creds), each under its own name",
    )
    parser.add_argument(
        "--as-profile",
        default=None,
        help="Profile name to write the scoped credentials under (default: same as --profile)",
    )
    parser.add_argument("--policy", required=True, help="Scope down policy JSON file")
    parser.add_argument(
        "--duration",
        type=int,
        default=None,
        help=f"Lifetime in seconds, 1-{MAX_DURATION_SECONDS} (default: inherit the calling session's remaining lifetime)",
    )
    parser.add_argument(
        "--description",
        default=None,
        help="ScopedSessionDescription logged to CloudTrail (default: names the claude-yolo workspace)",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="One-time grant: devc refresh-aws-creds never renews it and removes it on its next run",
    )
    parser.add_argument("--creds-dir", required=True, help="Path to Claude-Yolo-Creds/ directory")
    args = parser.parse_args()
    if args.duration is not None and not 1 <= args.duration <= MAX_DURATION_SECONDS:
        parser.error(f"--duration must be between 1 and {MAX_DURATION_SECONDS}")
    if args.as_profile is not None and args.sso_session is not None:
        parser.error("--as-profile can't be used with --sso-session; each profile keeps its own name")
    if args.as_profile is not None and (not args.as_profile.strip() or any(c in args.as_profile for c in "[]\n\r")):
        parser.error("--as-profile must be a non-empty profile name without brackets or newlines")
    if args.description is not None and (problem := description_error(args.description)):
        parser.error(f"--description {problem}")
    if args.sso_session is not None:
        cmd_grant_all_aws_creds(args)
    else:
        cmd_grant_aws_creds(args)


if __name__ == "__main__":
    main()
