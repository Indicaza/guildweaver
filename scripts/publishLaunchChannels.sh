set -euo pipefail
error_file="$(mktemp)"
trap 'rm -f "$error_file"' EXIT
if gh api "repos/${GITHUB_REPOSITORY}/releases/tags/forever-live" --silent 2>"$error_file"; then
  exit 0
fi
if ! grep -q 'HTTP 404' "$error_file"; then
  cat "$error_file" >&2
  exit 1
fi
assets=(dist/*.zip dist/*.sha256 dist/release.json)
shopt -s nullglob
assets+=(dist/*.exe dist/*.pkg)
for channel in beta stable; do
  gh release delete "$channel" --cleanup-tag --yes >/dev/null 2>&1 || true
  gh release create "$channel" "${assets[@]}" --target "$GITHUB_SHA" \
    --title "Guildweaver Forever launch ($channel)" \
    --notes "WoW Forever live cutover. Existing installations update automatically."
done
gh release create forever-live "${assets[@]}" --target "$GITHUB_SHA" \
  --title "WoW Forever live cutover" --notes "Completed the one-time beta and stable channel upgrade."
