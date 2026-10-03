#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3"]
# ///
"""Write AWS credentials to Claude-Yolo-Creds/aws/ for read-only container injection.

Usage:
  devc aws-creds --profile PROFILE

Writes ~/.aws/credentials and ~/.aws/config into Claude-Yolo-Creds/aws/,
which is bind-mounted read-only into the container at ~/.aws/.

Re-run any time to refresh credentials (e.g. after SSO token expiry).
"""

import argparse
import configparser
import sys
from pathlib import Path

import boto3
from botocore.exceptions import (
    BotoCoreError,
    ClientError,
    NoCredentialsError,
    ProfileNotFound,
)


def err(msg: str) -> None:
    print(f"[devc] {msg}", file=sys.stderr)


def die(msg: str) -> None:
    err(msg)
    sys.exit(1)


def cmd_aws_creds(args: argparse.Namespace) -> None:
    try:
        session = boto3.Session(profile_name=args.profile)
    except ProfileNotFound:
        die(f"AWS profile '{args.profile}' not found. Check ~/.aws/config")

    # Verify credentials and get identity — forces SSO refresh errors to surface here
    try:
        identity = session.client("sts").get_caller_identity()
    except NoCredentialsError:
        die(
            f"No credentials for profile '{args.profile}'.\n"
            f"For SSO profiles, run: aws sso login --profile {args.profile}"
        )
    except (ClientError, BotoCoreError) as e:
        die(f"Credential error: {e}")

    credentials = session.get_credentials()
    if credentials is None:
        die(f"Could not resolve credentials for profile '{args.profile}'")

    try:
        resolved = credentials.get_frozen_credentials()
    except (ClientError, BotoCoreError) as e:
        # Freezing an SSO or assumed-role profile's credentials can itself trigger a
        # refresh, which fails the same way get_caller_identity above can.
        die(f"Failed to resolve credentials for profile '{args.profile}': {e}")

    region = session.region_name or "us-east-1"

    if not resolved.token:
        err("Warning: long-lived IAM credentials detected (no session token).")
        err("Consider using an IAM role or SSO profile for better security.")

    # Write credentials
    creds_dir = Path(args.creds_dir) / "aws"
    creds_dir.mkdir(parents=True, exist_ok=True)

    credentials = configparser.ConfigParser()
    credentials[args.profile] = {
        "aws_access_key_id": resolved.access_key,
        "aws_secret_access_key": resolved.secret_key,
    }
    if resolved.token:
        credentials[args.profile]["aws_session_token"] = resolved.token

    creds_file = creds_dir / "credentials"
    with open(creds_file, "w") as f:
        credentials.write(f)
    creds_file.chmod(0o600)

    # Write config (region)
    config = configparser.ConfigParser()
    config_section = f"profile {args.profile}" if args.profile != "default" else "default"
    config[config_section] = {"region": region}

    config_file = creds_dir / "config"
    with open(config_file, "w") as f:
        config.write(f)
    config_file.chmod(0o600)

    err(f"Account : {identity['Account']}")
    err(f"Identity: {identity['Arn']}")
    err(f"Region  : {region}")
    err(f"Written : {creds_dir}/")
    if resolved.token:
        err("Credentials are temporary — re-run devc aws-creds when they expire.")
    err(f"Profile '{args.profile}' is ready inside the container.")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="devc aws-creds",
        description="Write AWS credentials to Claude-Yolo-Creds/aws/ for container injection",
    )
    parser.add_argument("--profile", required=True, help="AWS profile to use")
    parser.add_argument("--creds-dir", required=True, help="Path to Claude-Yolo-Creds/ directory")
    args = parser.parse_args()
    cmd_aws_creds(args)


if __name__ == "__main__":
    main()
