#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["boto3", "aws-bedrock-token-generator"]
# ///
"""Write a short-term Amazon Bedrock bearer token to Claude-Yolo-Creds/bedrock/.

Usage:
  devc bedrock-creds --region REGION [--profile PROFILE] [--lifetime SECONDS]

Mints a short-lived Amazon Bedrock API key — a presigned SigV4 bearer token, usable only
against the Bedrock API, in the given region — from whichever AWS credentials --profile
resolves to, and writes it plus a small manifest to Claude-Yolo-Creds/bedrock/, which is
bind-mounted read-only into the container. Unlike the AWS credentials in Claude-Yolo-Creds/aws/,
this token can never be replayed against any other AWS service, regardless of what the
underlying profile's IAM permissions actually allow.

Re-run any time to refresh — the token is never refreshed automatically inside the
container, and its real lifetime is the shorter of --lifetime and however long the
underlying AWS credentials remain valid (generating it makes no network call, so an
already-expired profile won't be caught until the container tries to use the token).
"""

import argparse
import datetime
import json
import sys
from datetime import timedelta
from pathlib import Path

import boto3
from aws_bedrock_token_generator import provide_token
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


class _StaticCredentialProvider:
    """Adapts an already-resolved botocore Credentials object to provide_token's
    CredentialProvider interface, which only calls .load()."""

    def __init__(self, credentials):
        self._credentials = credentials

    def load(self):
        return self._credentials


def cmd_bedrock_creds(args: argparse.Namespace) -> None:
    # args.profile is None unless --profile was actually passed. Passing None through to
    # boto3.Session lets botocore resolve it itself — checking AWS_DEFAULT_PROFILE, then
    # AWS_PROFILE, then the config file's default profile — instead of us shadowing that
    # chain by hardcoding "default" here.
    profile_label = args.profile or "AWS_DEFAULT_PROFILE/AWS_PROFILE/[default]"
    try:
        session = boto3.Session(profile_name=args.profile)
    except ProfileNotFound:
        die(f"AWS profile '{profile_label}' not found. Check ~/.aws/config")

    resolved_profile = session.profile_name  # the actual profile, resolved either way

    # Verify credentials and get identity — forces SSO refresh errors to surface here,
    # rather than silently minting a token nothing can actually use.
    try:
        identity = session.client("sts").get_caller_identity()
    except NoCredentialsError:
        die(
            f"No credentials for profile '{resolved_profile}'.\n"
            f"For SSO profiles, run: aws sso login --profile {resolved_profile}"
        )
    except (ClientError, BotoCoreError) as e:
        die(f"Credential error: {e}")

    credentials = session.get_credentials()
    if credentials is None:
        die(f"Could not resolve credentials for profile '{resolved_profile}'")

    try:
        token = provide_token(
            region=args.region,
            aws_credentials_provider=_StaticCredentialProvider(credentials),
            expiry=timedelta(seconds=args.lifetime),
        )
    except ValueError as e:
        die(str(e))
    except (ClientError, BotoCoreError) as e:
        # Generating the token reads the credentials' access key/secret/token, which for an
        # SSO or assumed-role profile can trigger a refresh — and fail the same way get_caller_identity above can.
        die(f"Failed to generate a Bedrock token for profile '{resolved_profile}': {e}")

    creds_dir = Path(args.creds_dir) / "bedrock"
    creds_dir.mkdir(parents=True, exist_ok=True)

    token_file = creds_dir / "token"
    token_file.write_text(token)
    token_file.chmod(0o600)

    manifest = {
        "region": args.region,
        "profile": resolved_profile,
        "created": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lifetime_seconds": args.lifetime,
    }
    manifest_file = creds_dir / "manifest.json"
    manifest_file.write_text(json.dumps(manifest, indent=2))
    manifest_file.chmod(0o600)

    err(f"Account : {identity['Account']}")
    err(f"Identity: {identity['Arn']}")
    err(f"Region  : {args.region}")
    err(f"Profile : {resolved_profile}")
    err(f"Written : {creds_dir}/")
    err(f"Token expires in {args.lifetime}s, or sooner if profile '{resolved_profile}' expires first.")
    err("Re-run devc bedrock-creds when it expires.")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="devc bedrock-creds",
        description="Write a short-term Amazon Bedrock bearer token to Claude-Yolo-Creds/bedrock/",
    )
    parser.add_argument("--region", required=True, help="AWS region to mint the token for (Bedrock API keys are region-locked)")
    parser.add_argument(
        "--profile",
        default=None,
        help="AWS profile to sign with. Default: resolved by boto3 itself, in order, from "
        "AWS_DEFAULT_PROFILE, AWS_PROFILE, or the config file's default profile.",
    )
    parser.add_argument("--lifetime", type=int, default=28800, help="Token lifetime in seconds, max 43200 = 12h (default: 28800 = 8h)")
    parser.add_argument("--creds-dir", required=True, help="Path to Claude-Yolo-Creds/ directory")
    args = parser.parse_args()
    cmd_bedrock_creds(args)


if __name__ == "__main__":
    main()
