# claude-yolo

You are running inside a claude-yolo devcontainer with permission prompts turned off. The guardrails here exist to stop overzealousness, not malice: they catch a well-meaning agent doing something irreversible or reaching for more access than the task needs. Work with them, not around them.

This file is mounted read-only by the operator. It applies to every project in this container.

## AWS credentials are scoped down

The credentials in `~/.aws/credentials` were issued by `sts:GetScopedCredentials`. They carry the human's identity, but they can only do what both the human's role and a scope down policy allow.

- `~/.aws/granted-policy.json` lists every profile you hold. For each one it records the policy in effect, its expiration, the host `source_profile` it came from, and the CloudTrail `description`.
- The default policy is `/workspace/.devcontainer/aws-config/session-policy.json`. Its `AllowAllExceptIrreversible` statement allows everything except irreversible actions: deleting stateful data and its backups, indirect deletion via lifecycle or retention settings, tampering with CloudTrail and logs, and escaping the scope (`sts:AssumeRole*`, creating IAM access keys or console passwords).
- You cannot change any of this yourself. `~/.aws` and `/workspace/.devcontainer` are read-only mounts.

## When AWS returns AccessDenied

1. Check whether the scope caused it. Look at the profile's policy in `~/.aws/granted-policy.json`, and decode any encoded message with `aws sts decode-authorization-message`.
2. Work out the smallest grant that would let the task continue: specific actions, specific resource ARNs, conditions where they help.
3. Write `/workspace/suggestedpolicy.json`:
   - Start from the profile's current `policy` in `~/.aws/granted-policy.json`, so earlier grants are kept.
   - Leave the `AllowAllExceptIrreversible` statement exactly as it is. Add new statements *after* it.
   - Use only `Allow` statements, each with a `Sid` that says what it's for. Statements combine as a union, so an added `Allow` grants back a specific action the deny-list blocks.
   - Keep the minified policy at or under 2,048 characters (`GetScopedCredentials` rejects anything longer).
4. Stop and ask the human. For each statement you added, say what it allows and why the task needs it. Give them the command to run from the workspace root:

   ```
   devc grant-aws-creds --profile <source_profile> [--as-profile <profile>] --policy ./suggestedpolicy.json --description "<short reason>"
   ```

   Use the `source_profile` from `granted-policy.json`. Add `--as-profile` when the profile you're using has a different name. Keep the description to 2–256 printable ASCII characters.
5. Wait for them to confirm before retrying. New credentials appear in `~/.aws/credentials` as soon as they run the command.

Prefer a one-time grant when you need something once or briefly: a single migration step, a one-off cleanup the human asked for. Ask for it under its own profile name with a short lifetime:

```
devc grant-aws-creds --profile <source_profile> --as-profile <profile>-once --once --duration <seconds> --policy ./suggestedpolicy.json --description "<short reason>"
```

Use that `-once` profile only for the step that needs it. `--once` marks the grant so `devc refresh-aws-creds` never renews it and removes it on its next run. Ask for a standing grant (no `--once`) only when the task keeps needing the permission. When a standing grant is no longer needed, say so, so the human can go back to the default policy.

## Do not work around the scope

- Don't use any profile other than the one the task is meant to use, and don't hunt for credentials elsewhere.
- Don't assume roles, create access keys or users, or set login passwords.
- Don't route around a denied action through something that runs with a different role: Lambda functions, EC2 instance profiles, CloudFormation or CodeBuild service roles, Step Functions, and so on.
- Don't edit, copy or recreate the files under `~/.aws`.

## Being allowed to do something isn't being asked to

When the human grants a permission, they're approving a capability, not every use of it. Before anything destructive or hard to undo (deleting resources or data, overwriting objects, scheduling key deletion, modifying production), say what you're about to do and wait for the human's go-ahead. That applies even when the policy allows it.
