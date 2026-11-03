#!/usr/bin/env bash
# Prints version=, bump= and stamp= for GITHUB_OUTPUT. Run inside a full clone with tags.
# Env: REPO (owner/name), TAG_PREFIX, SHA (commit, empty for HEAD), REF_TYPE, REF_NAME
set -euo pipefail
shopt -s nocasematch

if [ -z "${SHA:-}" ] && [ "${REF_TYPE:-}" = tag ]; then
  # building a cut release: the tag is the version
  version="${REF_NAME#"$TAG_PREFIX"}"
  printf 'version=%s\nbump=none\nstamp=%s\n' "$version" "$version"
  exit 0
fi

sha="$(git rev-parse --verify "${SHA:-HEAD}^{commit}")"
last="$(git tag --merged "$sha" --list "${TAG_PREFIX}*" --sort=-v:refname \
  | grep -E "^${TAG_PREFIX}[0-9]+\.[0-9]+\.[0-9]+$" | head -n 1 || true)"

# 0 none, 1 patch, 2 minor, 3 major
classify() {
  local subject="$1" message="$2" title="$3" branch="$4" text
  for text in "$subject" "$title"; do
    [[ "$text" =~ ^[[:alnum:]_]+(\(.+\))?!: ]] && { echo 3; return; }
  done
  # case-sensitive by design: prose saying "breaking change" must not bump major
  if printf '%s\n%s\n' "$message" "$title" | LC_ALL=C grep -q 'BREAKING CHANGE'; then
    echo 3
    return
  fi
  [[ "$branch" =~ ^(feat|feature)/ ]] && { echo 2; return; }
  for text in "$subject" "$title"; do
    [[ "$text" =~ ^feat(\(.+\))?: ]] && { echo 2; return; }
  done
  echo 1
}

rank=0
for commit in $(git rev-list "${last:+$last..}$sha"); do
  subject="$(git log -1 --format=%s "$commit")"
  message="$(git log -1 --format=%B "$commit")"
  prs="$(gh api "repos/$REPO/commits/$commit/pulls" --jq '.[] | [.head.ref, .title] | @tsv')"

  commit_rank=0
  while IFS=$'\t' read -r branch title; do
    r="$(classify "$subject" "$message" "$title" "$branch")"
    [ "$r" -gt "$commit_rank" ] && commit_rank="$r"
  done <<<"$prs"

  echo "${commit:0:7} rank=$commit_rank $subject" >&2
  [ "$commit_rank" -gt "$rank" ] && rank="$commit_rank"
  [ "$rank" -eq 3 ] && break
done

base="${last#"$TAG_PREFIX"}"
base="${base:-0.0.0}"
IFS=. read -r major minor patch <<<"$base"
case "$rank" in
  3) version="$((major + 1)).0.0"; bump=major ;;
  2) version="$major.$((minor + 1)).0"; bump=minor ;;
  1) version="$major.$minor.$((patch + 1))"; bump=patch ;;
  *) version="$base"; bump=none ;;
esac

printf 'version=%s\nbump=%s\nstamp=%s+%s\n' "$version" "$bump" "$version" "$(git rev-parse --short "$sha")"
