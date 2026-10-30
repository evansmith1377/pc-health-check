#!/bin/bash
# PreToolUse hook (Bash, PowerShell): refuse shell commands that name a secret file.
#
# settings.json denies Read(.env*) and key files, but that binds Claude's file
# tools, not the shell: `cat .env` or `grep KEY api.env` still print secrets
# into the conversation. This closes the common, accidental path. It is not a
# security boundary (`cat .en*` gets past any name match); see .claude/README.md.
# Seeded from claude-seed (guard-secrets).
#
# Pure bash on purpose: it runs before every shell call, and forking grep and
# sed each time is slow in Git Bash on Windows.
set -u
# Case-insensitive, because Windows and macOS file systems are: `cat .ENV` reads
# .env. nocasematch rather than ${x,,}, which macOS's bash 3.2 lacks.
shopt -s nocasematch

# Secret files, matched against each whole path token. The last segment is
# .env / name.env / .env.<x> / .envrc, a key or certificate bundle, an SSH key,
# or a well-known credentials file. Repo-specific ones are appended at seed
# time, one extended regex per line.
deny=(
  '^(.*/)?([^/]*\.env(\.[[:alnum:]_-]+)*|\.envrc|[^/]+\.(pem|key|p12|pfx|tfvars)|id_(rsa|dsa|ecdsa|ed25519)|\.dev\.vars|\.netrc|\.git-credentials|\.aws/credentials)$'
)
# Tokens that match the above but are fine: templates meant to be committed,
# and the runtime's env object (process.env.X). Extend for the repo's runtime.
allow=(
  '\.env\.(example|sample|template|dist|defaults)$'
  '^(process|import\.meta)\.env(\.[[:alnum:]_]+)*$'
)

IFS= read -r -d '' input || true

# tool_input.command (both tools name it that) without jq, by parameter
# expansion only: a regex over the payload backtracks badly on heredoc-sized
# commands. JSON escapes (\\, \n, \r, \t, \") are blanked first, so the first
# bare quote ends the command and an escaped newline separates tokens.
[[ $input == *'"command"'* ]] || exit 0
rest="${input//\\\\/ }"
rest="${rest//\\[nrt]/ }"
rest="${rest//\\\"/ }"
rest="${rest#*\"command\"}"
rest="${rest#*\"}"
command="${rest%%\"*}"

# Most commands name nothing secret-shaped; skip the per-token loop for them.
# Only valid while deny holds just the built-in pattern. Plain globs, not an
# extglob alternation: that one takes seconds on a heredoc-sized command.
if [ "${#deny[@]}" -eq 1 ] && [[ $command != *.env* && $command != *.pem* && $command != *.key* \
  && $command != *.p12* && $command != *.pfx* && $command != *id_* && $command != *.tfvars* \
  && $command != *.dev.vars* && $command != *netrc* && $command != *credentials* ]]; then
  exit 0
fi

set -f
hits=""
prev=""
for token in ${command//[\'\`;|&()<>=\\\{\},]/ }; do
  # A loop, not ${token%%+(:)}: that extglob is quadratic, and a hook that
  # times out lets the command run unchecked.
  while [[ $token == *: ]]; do token="${token%:}"; done
  # A file handed to a program as its env file is loaded, not printed.
  if [[ $prev == --env-file ]]; then prev=$token; continue; fi
  prev=$token
  for pattern in "${deny[@]}"; do
    [[ $token =~ $pattern ]] || continue
    for ok in "${allow[@]}"; do [[ $token =~ $ok ]] && continue 3; done
    hits+=" $token"
    break
  done
done

if [ -n "$hits" ]; then
  echo "guard-secrets: blocked; this command names a secret file:${hits}." >&2
  echo "Its contents would land in the conversation. If the user really wants it run, ask them to run it themselves with '! <command>'. To edit .gitignore, use the Edit tool instead." >&2
  exit 2
fi
exit 0
