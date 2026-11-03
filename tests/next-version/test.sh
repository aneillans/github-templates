#!/usr/bin/env bash
# Runs next-version.sh against throwaway repos with a stub gh. No network.
set -euo pipefail

script="$(cd "$(dirname "$0")/../../actions/next-version" && pwd)/next-version.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# stub: `gh api repos/x/commits/<sha>/pulls` prints the line recorded for that commit, if any
mkdir "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
sha="$(sed -E 's#.*/commits/([0-9a-f]+)/pulls#\1#' <<<"$2")"
[ -f "$PRS/$sha" ] && cat "$PRS/$sha"
exit 0
EOF
chmod +x "$work/bin/gh"
export PATH="$work/bin:$PATH" REPO=o/r TAG_PREFIX=v
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

failures=0
n=0

new_repo() {
  n=$((n + 1))
  export PRS="$work/prs$n"
  mkdir -p "$PRS"
  git init -q "$work/repo$n"
  cd "$work/repo$n"
}

# commit <message> [branch] [pr title]
commit() {
  git commit -q --allow-empty -m "$1"
  if [ -n "${2:-}" ]; then
    printf '%s\t%s\n' "$2" "${3:-}" > "$PRS/$(git rev-parse HEAD)"
  fi
}

check() {
  local label="$1" expected="$2" actual
  actual="$("$script" 2>/dev/null | grep -E '^(version|bump)=' | cut -d= -f2 | paste -sd' ')"
  if [ "$actual" = "$expected" ]; then
    echo "ok   $label"
  else
    echo "FAIL $label: expected '$expected', got '$actual'"
    failures=$((failures + 1))
  fi
}

new_repo; commit "start"; git tag v1.4.2
commit "Improving video support (#484)" feat/video-support "Feat: Improving video support"
check "feat/ branch with a plain commit subject is minor" "1.5.0 minor"

new_repo; commit "start"; git tag v1.4.2
commit "Thing (#1)" feature/thing "Thing"
check "feature/ branch is minor" "1.5.0 minor"

new_repo; commit "start"; git tag v1.4.2
commit "Thing (#1)" fix/thing "FEAT: Thing"
check "feat: PR title in any case is minor" "1.5.0 minor"

new_repo; commit "start"; git tag v1.4.2
commit "feat(ui): direct push"
check "feat: subject with no PR is minor" "1.5.0 minor"

new_repo; commit "start"; git tag v1.4.2
commit "Bugfix (#2)" fix/thing "bug: Bugfix"
check "fix/ branch is patch" "1.4.3 patch"

new_repo; commit "start"; git tag v1.4.2
commit "plain direct push"
check "plain commit with no PR is patch" "1.4.3 patch"

new_repo; commit "start"; git tag v1.4.2
commit "Rework (#3)" feat/rework "chore!: Rework"
check "bang in PR title is major" "2.0.0 major"

new_repo; commit "start"; git tag v1.4.2
commit "Rework (#3)

BREAKING CHANGE: new API" chore/rework "Rework"
check "BREAKING CHANGE in the body is major" "2.0.0 major"

new_repo; commit "start"; git tag v1.4.2
commit "Docs (#3)

mentions a breaking change in prose" chore/docs "Docs"
check "lowercase breaking change is patch" "1.4.3 patch"

new_repo; commit "start"; git tag v1.4.2
commit "One (#1)" fix/one "One"
commit "Two (#2)" feat/two "Two"
commit "Three (#3)" chore/three "Three"
check "highest bump in the range wins" "1.5.0 minor"

new_repo; commit "start"; git tag v1.4.2
check "nothing since the tag is no bump" "1.4.2 none"

new_repo; commit "start"; git tag v1.4.2; git tag v1.10.0; git tag v1.5.0-rc.1; git tag vnext
commit "fix" fix/a "A"
check "highest stable tag by version order is the base" "1.10.1 patch"

new_repo; commit "first" feat/first "First"
check "no tags starts from 0.0.0" "0.1.0 minor"

new_repo; commit "start"; git tag v1.4.2
git switch -qc side; commit "side"; git tag v9.0.0; git switch -q -
commit "fix" fix/a "A"
check "unmerged tags are ignored" "1.4.3 patch"

new_repo; commit "start"
if [ "$(REF_TYPE=tag REF_NAME=v2.3.4 "$script" | paste -sd' ')" = "version=2.3.4 bump=none stamp=2.3.4" ]; then
  echo "ok   tag build uses the tag with no build metadata"
else
  echo "FAIL tag build"
  failures=$((failures + 1))
fi

commit "fix" fix/a "A"
short="$(git rev-parse --short HEAD)"
if "$script" | grep -qx "stamp=0.0.1+$short"; then
  echo "ok   branch build stamp carries the short SHA"
else
  echo "FAIL branch build stamp"
  failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
