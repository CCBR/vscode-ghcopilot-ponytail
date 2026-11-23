#!/usr/bin/env bash
set -euo pipefail

stage=''
policy_tmp=''

main() {
  local default_version=v5.3.3
  local upstream=${CCBR_PONYTAIL_REPO_URL:-https://github.com/DietrichGebert/ponytail.git}
  local root=${CCBR_PONYTAIL_INSTALL_ROOT:-"$HOME/.claude"}
  local checkout="$root/repos/ponytail" skills_dir="$root/skills"
  local manifest="$root/.ccbr-ponytail-managed" version="$default_version"
  local action=install policy=0 version_requested=0
  local start='<!-- CCBR-PONYTAIL-START -->' end='<!-- CCBR-PONYTAIL-END -->'
  local repo='' agents='' name target commit remote_tag line
  local -a old_skills=() new_skills=()

  fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
  cleanup() {
    if [[ -n $policy_tmp && -f $policy_tmp ]]; then rm -f "$policy_tmp"; fi
    if [[ -n $stage && -d $stage ]]; then rm -rf "$stage"; fi
  }
  trap cleanup EXIT

  usage() {
    cat <<'EOF'
Usage: install_ponytail.sh [OPTIONS]

Install upstream Ponytail skills without lifecycle hooks or the Copilot CLI.

  --version TAG       Install an exact upstream tag (default: v5.3.3)
  --status            Show the installed version and managed links
  --verify            Verify the checkout, manifest, and managed links
  --list-versions     List upstream tags
  --agents-policy     Add opt-in guidance to the current repository's AGENTS.md
  -h, --help          Show this help

CCBR_PONYTAIL_REPO_URL and CCBR_PONYTAIL_INSTALL_ROOT override upstream and
installation locations for testing or trusted mirrors.
EOF
  }
  while (($#)); do
    case "$1" in
      --version) (($# >= 2)) || fail '--version requires a tag'; version=$2; version_requested=1; shift 2 ;;
      --status|--verify|--list-versions)
        [[ $action == install ]] || fail 'Choose only one read-only action'
        action=${1#--}; shift ;;
      --agents-policy) policy=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done
  [[ $action == install || ( $policy == 0 && $version_requested == 0 ) ]] ||
    fail 'Read-only actions cannot be combined with --version or --agents-policy'
  command -v git >/dev/null 2>&1 || fail 'Git is required'

  valid_name() { [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }
  read_manifest() {
    [[ -f $manifest && ! -L $manifest ]] || fail "Missing or unsafe manifest: $manifest"
    local entry seen=' '
    while IFS= read -r entry || [[ -n $entry ]]; do
      valid_name "$entry" || fail "Invalid skill name in manifest: $entry"
      [[ $seen != *" $entry "* ]] || fail "Duplicate skill in manifest: $entry"
      seen="$seen$entry "
      old_skills+=("$entry")
    done < "$manifest"
    ((${#old_skills[@]} > 0)) || fail 'The managed skill manifest is empty'
  }
  has_old() {
    local item
    for item in ${old_skills[@]+"${old_skills[@]}"}; do [[ $item == "$1" ]] && return 0; done
    return 1
  }
  expected_link() { printf '../repos/ponytail/skills/%s' "$1"; }
  verify_checkout() {
    [[ -d $checkout/.git && ! -L $checkout ]] || fail "No valid checkout at $checkout"
    [[ $(git -C "$checkout" remote get-url origin) == "$upstream" ]] ||
      fail "Unexpected checkout origin at $checkout"
    [[ -z $(git -C "$checkout" status --porcelain --untracked-files=all) ]] ||
      fail "Checkout has local changes: $checkout"
    git -C "$checkout" describe --tags --exact-match HEAD >/dev/null 2>&1 ||
      fail "Checkout is not at an exact tag: $checkout"
  }
  verify_links() {
    local item path
    for item in "${old_skills[@]}"; do
      path="$skills_dir/$item"
      [[ -L $path && $(readlink "$path") == "$(expected_link "$item")" && -f $path/SKILL.md ]] ||
        fail "Missing or modified managed skill: $path"
      printf '  %s: ok\n' "$item"
    done
  }
  verify_manifest() {
    local tree item count=0
    tree=$(git -C "$checkout" ls-tree -d --name-only HEAD:skills) ||
      fail 'Cannot enumerate installed Ponytail skills'
    while IFS= read -r item; do
      [[ -n $item ]] || continue
      valid_name "$item" || fail "Invalid skill directory in checkout: $item"
      has_old "$item" || fail "Skill missing from managed manifest: $item"
      ((count+=1))
    done <<< "$tree"
    ((count > 0 && count == ${#old_skills[@]})) ||
      fail 'Managed manifest does not match installed skills'
  }

  if [[ $action == list-versions ]]; then
    git ls-remote --tags --refs "$upstream" |
      awk '{sub(/^refs\/tags\//, "", $2); print $2}' | sort -r
    return
  fi
  if [[ $action == status || $action == verify ]]; then
    verify_checkout
    read_manifest
    verify_manifest
    verify_links
    printf 'Ponytail %s: %s\n' "$(git -C "$checkout" describe --tags --exact-match HEAD)" "$checkout"
    return
  fi

  git check-ref-format "refs/tags/$version" >/dev/null 2>&1 ||
    fail "Invalid tag: $version"
  [[ $version != -* ]] || fail "Invalid tag: $version"
  if ((policy)); then
    repo=$(git rev-parse --show-toplevel 2>/dev/null) || fail '--agents-policy requires a Git working tree'
    agents="$repo/AGENTS.md"
    [[ ! -L $agents ]] || fail "Refusing to modify symlink: $agents"
    if [[ -e $agents ]]; then
      [[ -f $agents ]] || fail "Not a regular file: $agents"
      awk -v start="$start" -v end="$end" '
        $0 == start { s++; if (inside || e) bad=1; inside=1 }
        $0 == end { e++; if (!inside) bad=1; inside=0 }
        END { if (bad || inside || s != e || s > 1) exit 1 }
      ' "$agents" || fail "Malformed Ponytail markers in $agents"
    fi
  fi

  if [[ -e $checkout || -L $checkout ]]; then
    verify_checkout
    read_manifest
    verify_manifest
    verify_links
    git -C "$checkout" fetch --quiet --tags origin ||
      fail 'Could not fetch upstream tags'
    target=$checkout
  else
    [[ ! -e $manifest && ! -L $manifest ]] ||
      fail "Manifest exists without its checkout: $manifest"
    mkdir -p "$root/repos"
    stage=$(mktemp -d "$root/repos/.ponytail-install.XXXXXX")
    git clone --quiet --no-checkout "$upstream" "$stage/checkout" ||
      fail 'Could not clone upstream Ponytail'
    target="$stage/checkout"
  fi

  remote_tag=$(git ls-remote --tags --refs "$upstream" "refs/tags/$version") ||
    fail 'Could not query upstream tags'
  [[ -n $remote_tag ]] || fail "Upstream tag not found: $version"
  commit=$(git -C "$target" rev-parse --verify "refs/tags/$version^{commit}" 2>/dev/null) ||
    fail "Tag does not resolve to a commit: $version"
  [[ $(git -C "$target" rev-parse "refs/tags/$version") == "${remote_tag%%[[:space:]]*}" ]] ||
    fail "Local tag differs from upstream: $version"

  while IFS= read -r name; do
    [[ -n $name ]] || continue
    valid_name "$name" || fail "Invalid upstream skill directory: $name"
    git -C "$target" cat-file -e "$commit:skills/$name/SKILL.md" 2>/dev/null ||
      fail "Missing SKILL.md for $name"
    git -C "$target" show "$commit:skills/$name/SKILL.md" |
      awk -v expected="$name" '
        NR == 1 { if ($0 != "---") exit 1; next }
        $0 == "---" { exit !found }
        $0 == "name: " expected { found=1 }
        END { if (!found) exit 1 }
      ' || fail "Invalid SKILL.md frontmatter for $name"
    new_skills+=("$name")
  done < <(git -C "$target" ls-tree -d --name-only "$commit:skills")
  ((${#new_skills[@]} > 0)) || fail 'No upstream skills found'

  for name in "${new_skills[@]}"; do
    line="$skills_dir/$name"
    if [[ -e $line || -L $line ]]; then
      has_old "$name" || fail "Unmanaged skill already exists: $line"
    fi
  done
  mkdir -p "$skills_dir"
  git -C "$target" checkout --quiet --detach "$commit" || fail "Could not check out $version"
  if [[ $target != "$checkout" ]]; then
    mv "$target" "$checkout"
  fi
  for name in ${old_skills[@]+"${old_skills[@]}"}; do
    local keep=0 item
    for item in "${new_skills[@]}"; do [[ $item == "$name" ]] && keep=1; done
    if (( !keep )); then rm "$skills_dir/$name"; fi
  done
  for name in "${new_skills[@]}"; do
    if ! has_old "$name"; then ln -s "$(expected_link "$name")" "$skills_dir/$name"; fi
  done
  printf '%s\n' "${new_skills[@]}" > "$manifest"

  if ((policy)); then
    local block
    block=$(printf '%s\n' "$start" '## Ponytail skills' '' \
      'Ponytail skills are available for deliberate use when requested or applicable.' \
      'This installation provides skills only; it does not install lifecycle hooks or automatically activate Ponytail.' "$end")
    policy_tmp=$(mktemp "$repo/.ponytail-policy.XXXXXX")
    if [[ -f $agents ]]; then
      cp -p "$agents" "$policy_tmp"
      awk -v start="$start" -v end="$end" '
        function write_block() {
          print start
          print "## Ponytail skills"
          print ""
          print "Ponytail skills are available for deliberate use when requested or applicable."
          print "This installation provides skills only; it does not install lifecycle hooks or automatically activate Ponytail."
          print end
        }
        $0 == start { write_block(); inside=1; found=1; next }
        $0 == end { inside=0; next }
        !inside { print }
        END { if (!found) { if (NR) print ""; write_block() } }
      ' "$agents" > "$policy_tmp"
    else
      printf '%s\n' "$block" > "$policy_tmp"
    fi
    mv "$policy_tmp" "$agents"
    policy_tmp=''
  fi
  printf 'Installed Ponytail %s: %d skills in %s\n' "$version" "${#new_skills[@]}" "$skills_dir"
}

main "$@"
