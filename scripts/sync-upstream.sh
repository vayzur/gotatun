#!/usr/bin/env bash
set -euo pipefail

branch="${TARGET_BRANCH:-${GITHUB_REF_NAME:-main}}"
upstream_repository="${UPSTREAM_REPOSITORY:-mullvad/gotatun}"
upstream_branch="${UPSTREAM_BRANCH:-main}"
upstream_remote="${UPSTREAM_REMOTE:-upstream}"
maintained_workflow=".github/workflows/upstream-sync-release.yml"
maintained_paths=(
  "${maintained_workflow}"
  "scripts/sync-upstream.sh"
  "scripts/package-release-asset.sh"
)

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "sync-upstream.sh requires a clean working tree" >&2
  exit 1
fi

if git remote get-url "${upstream_remote}" >/dev/null 2>&1; then
  git remote set-url "${upstream_remote}" "https://github.com/${upstream_repository}.git"
else
  git remote add "${upstream_remote}" "https://github.com/${upstream_repository}.git"
fi

git fetch --no-tags origin "${branch}"
git fetch --no-tags "${upstream_remote}" "${upstream_branch}"
git checkout -B "${branch}" "origin/${branch}"

upstream_ref="${upstream_remote}/${upstream_branch}"
ahead_count="$(git rev-list --count "${upstream_ref}..HEAD")"
behind_count="$(git rev-list --count "HEAD..${upstream_ref}")"

if [[ "${ahead_count}" -ne 1 ]]; then
  printf 'Expected %s to be exactly one commit ahead of %s/%s, found %s\n' \
    "${branch}" "${upstream_repository}" "${upstream_branch}" "${ahead_count}" >&2
  exit 1
fi

maintenance_commit="$(git rev-parse HEAD)"
upstream_head="$(git rev-parse "${upstream_ref}")"
sync_changed="false"
maintenance_message_file="$(mktemp)"

cleanup() {
  rm -f "${maintenance_message_file}"
}
trap cleanup EXIT

git show -s --format=%B "${maintenance_commit}" > "${maintenance_message_file}"

if [[ "${behind_count}" -gt 0 ]]; then
  origin_head="$(git rev-parse "origin/${branch}")"

  git checkout -B "${branch}" "${upstream_head}"
  mkdir -p .github/workflows scripts
  git restore --source="${maintenance_commit}" -- "${maintained_paths[@]}"
  find .github/workflows -mindepth 1 -maxdepth 1 -type f ! -name "$(basename "${maintained_workflow}")" -delete
  git add -A .github/workflows scripts
  git commit --file "${maintenance_message_file}"
  git push origin "HEAD:refs/heads/${branch}" \
    "--force-with-lease=refs/heads/${branch}:${origin_head}"

  sync_changed="true"
fi

synced_head="$(git rev-parse HEAD)"
final_ahead_count="$(git rev-list --count "${upstream_ref}..${synced_head}")"
final_behind_count="$(git rev-list --count "${synced_head}..${upstream_ref}")"

if [[ "${final_ahead_count}" -ne 1 || "${final_behind_count}" -ne 0 ]]; then
  printf 'Branch invariant failed after sync: ahead=%s behind=%s\n' \
    "${final_ahead_count}" "${final_behind_count}" >&2
  exit 1
fi

upstream_short_sha="$(git rev-parse --short=12 "${upstream_head}")"
upstream_commit_date="$(TZ=UTC git show -s --date=format:'%Y-%m-%d %H:%M:%S UTC' --format=%cd "${upstream_head}")"
upstream_commit_tag_date="$(TZ=UTC git show -s --date=format:%Y%m%d-%H%M%S --format=%cd "${upstream_head}")"
upstream_subject="$(git show -s --format=%s "${upstream_head}")"
release_tag="${upstream_commit_tag_date}"
release_title="${release_tag}"

{
  printf 'branch=%s\n' "${branch}"
  printf 'head_sha=%s\n' "${synced_head}"
  printf 'sync_changed=%s\n' "${sync_changed}"
  printf 'upstream_sha=%s\n' "${upstream_head}"
  printf 'upstream_short_sha=%s\n' "${upstream_short_sha}"
  printf 'upstream_commit_date=%s\n' "${upstream_commit_date}"
  printf 'upstream_commit_tag_date=%s\n' "${upstream_commit_tag_date}"
  printf 'upstream_subject=%s\n' "${upstream_subject}"
  printf 'release_tag=%s\n' "${release_tag}"
  printf 'release_title=%s\n' "${release_title}"
} >> "${GITHUB_OUTPUT:-/dev/null}"
