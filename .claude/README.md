# `.claude/`

What the Claude Code configuration in this directory does, and why.

<!-- seed:permissions-baseline -->
## `settings.json` permissions

Some commands are **allowed without a prompt**: inspecting the repository,
building it, testing it, reading CI and PR status, and recording work in
**local** git. That covers everything needed to do a piece of work and commit
it. An agent that has to ask permission to run the test suite gets blanket
approval by the third prompt, which is worse than a considered list.

Other commands **always prompt**. That includes anything that **publishes**
(`git push`, `git tag`, `gh pr create`, `gh release`, package publishing),
**rewrites history** (`git reset`, `git rebase`, `git clean`), **deletes or moves
files** (`rm`, `mv`, `cp`), **adds a dependency**, or **reaches the network**
(`curl`, `wget`, `ssh`, `gh api`).

Three rules keep that line honest:

- **A boundary is only as strong as its most general member.** `node -e`,
  `python -c`, `npx -y`, `pwsh -Command` and `Invoke-Expression` are
  general-purpose interpreters. They can fetch, delete, and run `git push`
  themselves. They belong in `ask`, never `allow`. `Bash(...)` rules don't
  bind the PowerShell tool, which has its own `PowerShell(...)` rules.
- **Some writes look like searches.** `find -delete` and `-exec`, `sed -i`,
  `awk 'print >'`, and `xargs` can all modify files, so they prompt too. So
  does `--output` on any git command (`git log --output=<file>` writes where
  it likes, a hook script included), and so does
  `git fetch --upload-pack=<cmd>`, which runs a command. Git accepts any
  unambiguous prefix of a long option, so the rules match the shortest one
  (`--upl`, `--forc`).
- **Secrets are denied, not just unlisted.** `.env`, `.env.*`, `*.env`, key
  and certificate files (`.pem`, `.key`, `.p12`, `.pfx`) and SSH private keys
  (`id_rsa` and friends), at any depth, are in `deny`. That stops Claude's
  file tools (Read, Grep, Glob) from loading them by accident. It does **not** bind the shell: allowed commands such as `cat`,
  `sort` or `git show` can still print them. Taking a few readers off `allow`
  wouldn't close that (there are always others) and would make every
  `git log | head` prompt. claude-seed's `guard-secrets` hook, where
  installed, refuses shell commands that name a secret file, which covers the
  accidental case. Where secrets must be unreadable, turn on sandboxed Bash
  (macOS, Linux and WSL2, not native Windows). The sandbox merges these
  `Read(...)` denies into its filesystem rules, so the shell can't read the
  files either.

Some commands are allowed on purpose:

- **Project scripts are allowed by name, not wholesale.** `npm test`,
  `npm run typecheck` or `dotnet build` run code from this repository, which is
  version-controlled and reviewed, and no workflow survives a prompt for every
  test run. But a blanket `npm run:*` would also let a script that runs
  `docker compose up`, deploys or publishes skip the prompt its commands would
  get on their own. So each script is allowed by name, after reading what it
  runs.
- **Local git includes verbs that can discard uncommitted work**, such as
  `git checkout --`, `git restore`, and `git stash`. The list protects
  *committed* history and anything already published, not the working tree.
  The common **force** forms are the exception, and are in `ask`, which
  overrides the broader `allow`: those that can overwrite a branch and orphan
  unpushed commits (`git branch -D`/`-f`/`-M`/`-C`, `git checkout -B`,
  `git switch -C`) and those that throw work away without the usual safety
  check (`git checkout -f`, `git switch -f`/`--discard-changes`,
  `git stash drop`/`clear`). They prompt before or after the branch name
  (`git branch old -D`). `git fetch` from a named remote is allowed. With a
  URL or a refspec (any `:`) it asks, because it can send data to any host or
  move a branch the way `git branch -f` does. That rule is written
  `git fetch *:**` because a rule ending in `:*` means "followed by
  anything". Rules match text, so a combined flag (`git branch -Df`) still
  gets through, and so does a quote or backslash inside an option in Bash
  (`--out''put`). The PowerShell tool parses the command first, and `--%`,
  splatting (`git @args`) or a `$env:` assignment make it prompt. Sandboxed
  Bash or a PreToolUse hook is the way to make this airtight.

When you add an entry, put it on the right side of that line and say why here
if it isn't obvious.
<!-- /seed:permissions-baseline -->

<!-- seed:guard-secrets -->
## `hooks/guard-secrets.sh`

A PreToolUse hook on the Bash and PowerShell tools. It refuses any shell
command that names a secret file (`.env`, `*.env`, `.env.*`, `.envrc`,
`*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.tfvars`, SSH private keys, `.netrc`,
`.git-credentials`, `.aws/credentials`, `.dev.vars`), and tells Claude to ask
the user to run it with `! <command>` instead. Templates (`.env.example`, `.sample`, `.template`, `.dist`,
`.defaults`) pass.

It exists because the `Read(...)` denies in `settings.json` bind Claude's file
tools, not the shell, so `cat .env` would otherwise print secrets into the
conversation. It catches the accidental path, not a determined one. Plenty
gets past it: commands that print secrets without naming the file, which are
the commonest leak (`grep -rn API_KEY .`, `git log -p` or `git diff` over a
committed secret, `env`, `printenv`, `docker compose config`, `dotnet
user-secrets list`); globs (`cat .en*`); copy-then-read; and a script that
opens the file. Where secrets must be
unreadable, use sandboxed Bash with `sandbox.filesystem.denyRead` (macOS,
Linux and WSL2; not native Windows).

It can't tell naming from reading, so `echo .env >> .gitignore` is refused
too. Edit `.gitignore` with the Edit tool instead.

Repo-specific secret files go in the `deny=( )` list at the top of the hook,
and false positives in `allow=( )`, one extended regex per line.
<!-- /seed:guard-secrets -->
