#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuses what would change a deploying branch outside a pull request, and
anything that skips the git hooks. Exit 2 blocks the command and tells the agent why.

Protected branches in drafft-backend: main, staging.

Blocked:
  git push ... <protected> | HEAD:<protected> | +<protected> | refs/heads/<protected>   (explicit target)
  git push [remote]                  while on a protected branch (implicit target)
  git push --all | --mirror
  git commit                         while on a protected branch
  git branch -d|-D|--delete main|staging   
  git push --no-verify, git commit --no-verify | -n

`cd <dir>` earlier in the same command is followed.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

PROTECTED = {"main", "staging"}


def block(reason: str) -> None:
    print(f"Blocked by .claude/hooks/guard-git.py: {reason}", file=sys.stderr)
    sys.exit(2)


def git(repo: str, *args: str) -> str:
    try:
        return subprocess.run(
            ["git", "-C", repo, *args], capture_output=True, text=True, timeout=5
        ).stdout.strip()
    except Exception:
        return ""


def protected_for(repo: str) -> set[str]:
    return PROTECTED if git(repo, "rev-parse", "--show-toplevel") else set()


def git_subcommand(tokens: list[str]) -> tuple[str | None, str | None, list[str]]:
    """(repo from -C, subcommand, its arguments) for `git [globals] <sub> args`, else Nones."""
    # The command itself, past environment assignments (FOO=bar git push) and `command`/`exec`.
    words = [t for t in tokens if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t)]
    while words and words[0] in ("command", "exec", "sudo"):
        words = words[1:]
    if not words or words[0] != "git":
        return None, None, []
    rest = words[1:]
    repo = None
    i = 0
    while i < len(rest) and rest[i].startswith("-"):
        if rest[i] in ("-C", "-c") and i + 1 < len(rest):
            if rest[i] == "-C":
                repo = rest[i + 1]
            i += 2
        else:
            i += 1
    if i >= len(rest):
        return repo, None, []
    return repo, rest[i], rest[i + 1 :]


def main() -> None:
    data = json.load(sys.stdin)
    command = data.get("tool_input", {}).get("command", "")
    cwd = data.get("cwd") or os.getcwd()
    for segment in re.split(r"&&|\|\||;|\||\n", command):
        try:
            tokens = shlex.split(segment)
        except ValueError:
            tokens = segment.split()
        if len(tokens) >= 2 and tokens[0] in ("cd", "pushd"):
            cwd = os.path.normpath(os.path.join(cwd, os.path.expanduser(tokens[1])))
            continue
        repo, sub, args = git_subcommand(tokens)
        if sub == "branch" and any(a in ("-d", "-D", "--delete") for a in args):
            hit = {"main", "staging"} & {a for a in args if not a.startswith("-")}
            if hit:
                block(f"deleting {', '.join(sorted(hit))} is forbidden: main and staging are never deleted.")
            continue
        if sub not in ("commit", "push"):
            continue
        where = os.path.normpath(os.path.join(cwd, os.path.expanduser(repo))) if repo else cwd
        protected = protected_for(where)
        branch = git(where, "branch", "--show-current")
        names = ", ".join(sorted(protected))
        if sub == "commit":
            if "--no-verify" in args or "-n" in args:
                block("git commit --no-verify skips the commit hooks. Fix what they report instead.")
            if branch in protected:
                block(f"committing on {branch} is forbidden: it only changes through pull requests. "
                      "Create a branch first: git switch -c feat/<name>.")
            continue
        if "--no-verify" in args:
            block("git push --no-verify skips the pre-push hook.")
        deleting = "--delete" in args or "-d" in args
        removed = {r.lstrip("+").split(":")[-1].removeprefix("refs/heads/") for r in args[1:]
                   if not r.startswith("-") and (deleting or r.startswith(":"))}
        if {"main", "staging"} & removed:
            block("deleting main or staging on the remote is forbidden: they are never deleted.")
        if "--all" in args or "--mirror" in args:
            block(f"git push --all/--mirror would update {names}. Push one feature branch.")
        positional = [a for a in args if not a.startswith("-")]
        refspecs = positional[1:]
        if refspecs:
            targets = {r.lstrip("+").split(":")[-1].removeprefix("refs/heads/") for r in refspecs}
        else:
            targets = {branch}
        hit = protected & targets
        if hit:
            block(f"pushing to {', '.join(sorted(hit))} is forbidden. Push a feature branch and open a pull "
                  "request (the create-pr skill) into staging.")


if __name__ == "__main__":
    main()
