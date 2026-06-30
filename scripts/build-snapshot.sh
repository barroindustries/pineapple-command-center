#!/usr/bin/env bash
# Regenerates data.js from live GitHub data.
# Runs in GitHub Actions (uses $GITHUB_TOKEN for higher rate limits) but also
# works locally if `gh auth token` or $GITHUB_TOKEN is set.
# ONLY public repos are written to data.js — private repos are skipped by design.
set -euo pipefail

# --- repos to track: "owner/repo|Business name" ---
REPOS=(
  "barroindustries/barroindustries.github.io|Barro Industries"
)

TOKEN="${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
API="https://api.github.com"
hdr=(-H "Accept: application/vnd.github+json")
[ -n "$TOKEN" ] && hdr+=(-H "Authorization: Bearer $TOKEN")

api(){ curl -sS "${hdr[@]}" "$API/$1"; }

# language -> dot color (GitHub linguist-ish)
langcolor(){
  case "$1" in
    JavaScript) echo "#f1e05a";; TypeScript) echo "#3178c6";; Python) echo "#3572A5";;
    HTML) echo "#e34c26";; CSS) echo "#563d7c";; Go) echo "#00ADD8";;
    Java) echo "#b07219";; Ruby) echo "#701516";; "C++") echo "#f34b7d";;
    Shell) echo "#89e051";; PHP) echo "#4F5D95";; Rust) echo "#dea584";;
    *) echo "#8b97a7";;
  esac
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
since30="$(date -u -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)"

OUT="$(dirname "$0")/../data.js"
{
  echo "// Auto-generated GitHub snapshot. Regenerated daily by .github/workflows/refresh-snapshot.yml."
  echo "// Do not edit by hand — changes will be overwritten. Private repos are excluded by design."
  echo "window.SNAPSHOT_AT = \"$now\";"
  echo "window.REPOS ="
  first=1
  printf '['
  for entry in "${REPOS[@]}"; do
    slug="${entry%%|*}"; biz="${entry##*|}"
    repo="$(api "repos/$slug")"
    priv="$(echo "$repo" | jq -r '.private')"
    [ "$priv" = "true" ] && { echo "  // skipped private repo: $slug" >&2; continue; }

    lang="$(echo "$repo" | jq -r '.language // "—"')"
    issues="$(echo "$repo" | jq -r '.open_issues_count')"
    url="$(echo "$repo" | jq -r '.html_url')"
    color="$(langcolor "$lang")"

    last="$(api "repos/$slug/commits?per_page=1" | jq '.[0]')"
    msg="$(echo "$last" | jq -r '.commit.message | split("\n")[0]')"
    by="$(echo "$last" | jq -r '.commit.author.name')"
    at="$(echo "$last" | jq -r '.commit.author.date')"

    c30="$(api "repos/$slug/commits?since=$since30&per_page=100" | jq 'length')"
    total="$(curl -sS -I "${hdr[@]}" "$API/repos/$slug/commits?per_page=1" \
      | tr -d '\r' | grep -i '^link:' | grep -o 'page=[0-9]*>; rel="last"' | grep -o '[0-9]*' || echo "$c30")"
    total="${total:-$c30}"

    # weekly commit activity (retry: stats endpoint returns 202 while generating)
    weekly="[]"
    for i in 1 2 3 4 5 6; do
      raw="$(api "repos/$slug/stats/commit_activity")"
      if echo "$raw" | jq -e 'type=="array" and length>0' >/dev/null 2>&1; then
        weekly="$(echo "$raw" | jq -c '[.[-12:][].total]')"; break
      fi
      sleep 4
    done

    [ $first -eq 0 ] && printf ','
    first=0
    jq -n \
      --arg name "$slug" --arg biz "$biz" --arg url "$url" \
      --arg lang "$lang" --arg color "$color" --arg msg "$msg" \
      --arg by "$by" --arg at "$at" \
      --argjson c30 "$c30" --argjson total "$total" --argjson issues "$issues" \
      --argjson weekly "$weekly" '
      { name:($name|split("/")[1]), biz:$biz, url:$url, private:false,
        lang:$lang, langColor:$color, commits30d:$c30, totalCommits:$total,
        openIssues:$issues, weekly:$weekly, lastMsg:$msg, lastBy:$by, lastAt:$at }'
  done
  printf '];\n'
} > "$OUT"

echo "Wrote $OUT" >&2
