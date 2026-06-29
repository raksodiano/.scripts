#!/usr/bin/env bash

set -uo pipefail

provider=""
group=""
dest=""
repos_list=""
dry_run=false
log_file=""

GITLAB_CLIENT_ID="${GIT_GROUP_CLONE_GITLAB_CLIENT_ID:-}"
GITLAB_OAUTH_DIR="$HOME/.cache/git-group-clone"
GITLAB_OAUTH_TOKEN_FILE="$GITLAB_OAUTH_DIR/oauth_token"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

die() {
    echo -e "${RED}Error: $1${NC}" >&2
    [[ -n "${log_file:-}" ]] && echo "Error: $1" >> "$log_file"
    exit "${2:-1}"
}

log() {
    local level="$1" msg="$2"
    local color
    case "$level" in
        info)    color="$BLUE" ;;
        success) color="$GREEN" ;;
        warn)    color="$YELLOW" ;;
        error)   color="$RED" ;;
        *)       color="$NC" ;;
    esac
    echo -e "${color}${msg}${NC}"
    [[ -n "${log_file:-}" ]] && echo "$msg" >> "$log_file"
}

check_dependencies() {
    local missing=()
    for cmd in git curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}. Please install them first."
    fi
    if ! command -v jq &>/dev/null; then
        log warn "jq not found — using grep/sed fallback for JSON parsing (less reliable)"
    fi
}

parse_json_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "$field" 2>/dev/null
    else
        echo "$json" | grep -o "\"${field#.}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/^[^:]*:[[:space:]]*"//;s/"$//'
    fi
}

parse_json_number() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r "$field" 2>/dev/null
    else
        echo "$json" | grep -o "\"${field#.}\"[[:space:]]*:[[:space:]]*[0-9]*" | head -1 | sed 's/[^0-9]//g'
    fi
}

parse_json_array_field() {
    local json="$1" field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".[].$field" 2>/dev/null
    else
        echo "$json" | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/^[^:]*:[[:space:]]*"//;s/"$//'
    fi
}

save_oauth_token() {
    local token="$1" refresh="$2" created="$3" expires_in="$4" expires_at="$5"
    # Sanitize: only allow alphanumeric, hyphens, underscores, dots
    if [[ ! "$token" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log warn "OAuth token contains unexpected characters, skipping cache"
        return 1
    fi
    mkdir -p "$GITLAB_OAUTH_DIR"
    cat > "$GITLAB_OAUTH_TOKEN_FILE" << EOF
OAUTH_ACCESS_TOKEN=$token
OAUTH_REFRESH_TOKEN=$refresh
OAUTH_CREATED_AT=$created
OAUTH_EXPIRES_IN=$expires_in
OAUTH_EXPIRES_AT=$expires_at
EOF
    chmod 600 "$GITLAB_OAUTH_TOKEN_FILE"
}

show_help() {
    echo -e "${BLUE}Usage:${NC} $0 -p <github|gitlab> -g <org|group> -d <destination> [-r \"repo1,repo2\"] [-n] [-l logfile] [-h]"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  -p <provider>   Provider: github or gitlab"
    echo "  -g <group>      Organization (GitHub) or group path (GitLab)"
    echo "  -d <directory>  Destination base directory (creates subfolder: <dir>/<group>)"
    echo "  -r \"repo1,repo2\" Repo names to clone (skip API discovery)"
    echo "  -n              Dry-run mode (list repos without cloning)"
    echo "  -l <logfile>    Log output to file"
    echo "  -h              Show this help message"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 -p github -g my-org -d ~/projects"
    echo "  $0 -p gitlab -g bash-ip -r \"repo1,repo2\" -d \"~/Workspace/Work/Instituto Pacifico\""
    echo "  $0 -p gitlab -g my-group/my-subgroup -d ~/projects"
    echo "  $0 -p github -g my-org -d ~/projects -n"
    echo ""
    echo -e "${BLUE}Note:${NC} Uses SSH URLs for cloning. Ensure your SSH keys are configured."
    echo -e "${BLUE}Note:${NC} For private GitLab groups, OAuth device auth (browser) is used automatically."
    echo -e "${BLUE}Note:${NC} Use -r to pass repo names directly (skips API discovery entirely)."
    exit 1
}


while getopts "p:g:d:r:nl:h" opt; do
    case $opt in
        p)
            if [ -z "$OPTARG" ]; then
                echo -e "${RED}Error: -p requires an argument${NC}" >&2
                exit 1
            fi
            provider="$OPTARG"
            ;;
        g)
            if [ -z "$OPTARG" ]; then
                echo -e "${RED}Error: -g requires an argument${NC}" >&2
                exit 1
            fi
            group="$OPTARG"
            ;;
        d)
            if [ -z "$OPTARG" ]; then
                echo -e "${RED}Error: -d requires an argument${NC}" >&2
                exit 1
            fi
            dest="$OPTARG"
            ;;
        r)
            if [ -z "$OPTARG" ]; then
                echo -e "${RED}Error: -r requires an argument${NC}" >&2
                exit 1
            fi
            repos_list="$OPTARG"
            ;;
        n)
            dry_run=true
            ;;
        l)
            if [ -z "$OPTARG" ]; then
                echo -e "${RED}Error: -l requires an argument${NC}" >&2
                exit 1
            fi
            log_file="$OPTARG"
            true > "$log_file" 2>/dev/null || {
                echo -e "${RED}Error: Cannot write to log file: $log_file${NC}" >&2
                exit 1
            }
            ;;
        h)
            show_help
            ;;
        \?)
            show_help
            ;;
    esac
done

shift $((OPTIND -1))

case "$provider" in
    github|gh) provider="github" ;;
    gitlab|gl) provider="gitlab" ;;
    "")
        echo -e "${RED}Error: Provider is required (-p)${NC}" >&2
        show_help
        ;;
    *)
        echo -e "${RED}Error: Invalid provider: $provider (use github or gitlab)${NC}" >&2
        exit 1
        ;;
esac

if [ -z "$group" ]; then
    echo -e "${RED}Error: Group is required (-g)${NC}" >&2
    show_help
fi

if [ -z "$dest" ]; then
    echo -e "${RED}Error: Destination is required (-d)${NC}" >&2
    show_help
fi

dest="${dest/#\~/$HOME}"

github_token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
gitlab_token="${GITLAB_TOKEN:-${GL_TOKEN:-}}"

fetch_github_repos() {
    local org="$1"
    local page=1
    local repos=()
    local curl_args response curl_exit urls err

    while true; do
        log info "  Fetching GitHub page $page for org: $org"
        curl_args=(curl -sf --connect-timeout 10 --max-time 30)
        [[ -n "${github_token:-}" ]] && curl_args+=(-H "Authorization: Bearer $github_token")
        curl_args+=("https://api.github.com/orgs/$org/repos?per_page=100&page=$page")

        response=$("${curl_args[@]}" 2>/dev/null) || true
        curl_exit=$?

        if [[ $curl_exit -ne 0 ]] || [[ -z "$response" ]]; then
            if [[ $curl_exit -ne 0 ]]; then
                log error "GitHub API request failed (page $page)"
            fi
            break
        fi

        if [[ "$response" = "[]" ]]; then
            break
        fi

        if echo "$response" | grep -q '"message"'; then
            err=$(parse_json_field "$response" ".message")
            log error "GitHub API error: $err"
            return 1
        fi

        urls=$(parse_json_array_field "$response" "ssh_url")
        while IFS= read -r url; do
            [[ -n "$url" ]] && repos+=("$url")
        done <<< "$urls"

        page=$((page + 1))
    done

    printf '%s\n' "${repos[@]}"
}

load_gitlab_oauth_token() {
    if [[ ! -f "$GITLAB_OAUTH_TOKEN_FILE" ]]; then
        return 1
    fi

    local OAUTH_ACCESS_TOKEN="" OAUTH_REFRESH_TOKEN="" OAUTH_EXPIRES_AT=""
    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            OAUTH_ACCESS_TOKEN)  OAUTH_ACCESS_TOKEN="$value" ;;
            OAUTH_REFRESH_TOKEN) OAUTH_REFRESH_TOKEN="$value" ;;
            OAUTH_EXPIRES_AT)    OAUTH_EXPIRES_AT="$value" ;;
        esac
    done < "$GITLAB_OAUTH_TOKEN_FILE"

    if [[ -z "$OAUTH_ACCESS_TOKEN" ]]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)

    if [[ -n "$OAUTH_EXPIRES_AT" ]] && [[ "$current_time" -lt "$OAUTH_EXPIRES_AT" ]] 2>/dev/null; then
        gitlab_token="$OAUTH_ACCESS_TOKEN"
        return 0
    fi

    if [[ -n "$OAUTH_REFRESH_TOKEN" ]]; then
        log info "Refreshing expired OAuth token..."
        local refresh_response
        refresh_response=$(curl -sf -X POST "https://gitlab.com/oauth/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=refresh_token&refresh_token=$OAUTH_REFRESH_TOKEN&client_id=$GITLAB_CLIENT_ID" 2>/dev/null)

        if [[ -n "$refresh_response" ]] && echo "$refresh_response" | grep -q '"access_token"'; then
            local new_access_token new_refresh_token new_expires_in new_created_at new_expires_at
            new_access_token=$(parse_json_field "$refresh_response" ".access_token")
            new_refresh_token=$(parse_json_field "$refresh_response" ".refresh_token")
            new_expires_in=$(parse_json_number "$refresh_response" ".expires_in")
            new_created_at=$(date +%s)
            new_expires_at=$((new_created_at + new_expires_in))

            save_oauth_token "$new_access_token" "$new_refresh_token" "$new_created_at" "$new_expires_in" "$new_expires_at"
            gitlab_token="$new_access_token"
            return 0
        fi
    fi

    return 1
}

do_gitlab_oauth_device_flow() {
    if [[ -z "$GITLAB_CLIENT_ID" ]]; then
        log error "GIT_GROUP_CLONE_GITLAB_CLIENT_ID env var is required for GitLab OAuth."
        log warn "Set it to your GitLab OAuth Application ID."
        return 1
    fi

    echo ""
    log info "No GitLab token available. Starting OAuth device authorization..."
    log warn "You'll need to authenticate with GitLab.com in your browser."
    echo ""

    local device_response
    device_response=$(curl -sf -X POST "https://gitlab.com/oauth/authorize_device" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$GITLAB_CLIENT_ID&scope=api" 2>/dev/null)

    if [[ -z "$device_response" ]]; then
        log error "Failed to start device authorization. Check your internet connection."
        return 1
    fi

    local device_code verification_uri_complete expires_in interval
    device_code=$(parse_json_field "$device_response" ".device_code")
    verification_uri_complete=$(parse_json_field "$device_response" ".verification_uri_complete")
    expires_in=$(parse_json_number "$device_response" ".expires_in")
    interval=$(parse_json_number "$device_response" ".interval")

    echo -e "${YELLOW}Open this URL in your browser:${NC}"
    echo -e "${BLUE}  $verification_uri_complete${NC}"
    echo ""
    echo -e "${YELLOW}Waiting for authentication...${NC}"

    local start_time token refresh_token
    start_time=$(date +%s)
    token=""
    refresh_token=""

    while true; do
        local current_time elapsed
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        if [ "$elapsed" -ge "$expires_in" ] 2>/dev/null; then
            echo -e "\n${RED}Authentication timed out after ${expires_in}s.${NC}" >&2
            echo -e "${YELLOW}Tip: Use -r \"repo1,repo2\" to clone by repo name without API access.${NC}" >&2
            return 1
        fi

        sleep "$interval"

        local token_response
        token_response=$(curl -sf -X POST "https://gitlab.com/oauth/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=$device_code&client_id=$GITLAB_CLIENT_ID" 2>/dev/null)

        if echo "$token_response" | grep -q '"access_token"'; then
            local new_expires_in created_at expires_at
            token=$(parse_json_field "$token_response" ".access_token")
            refresh_token=$(parse_json_field "$token_response" ".refresh_token")
            new_expires_in=$(parse_json_number "$token_response" ".expires_in")
            created_at=$(date +%s)
            expires_at=$((created_at + new_expires_in))

            save_oauth_token "$token" "$refresh_token" "$created_at" "$new_expires_in" "$expires_at"

            log success "Authentication successful! Token cached in $GITLAB_OAUTH_TOKEN_FILE"
            gitlab_token="$token"
            return 0
        elif echo "$token_response" | grep -q '"authorization_pending"'; then
            echo -n "."
            continue
        elif echo "$token_response" | grep -q '"slow_down"'; then
            interval=$((interval + 5))
            echo -n "."
            continue
        elif echo "$token_response" | grep -q '"access_denied"'; then
            echo -e "\n${RED}Authorization was denied.${NC}" >&2
            return 1
        elif echo "$token_response" | grep -q '"expired_token"'; then
            echo -e "\n${RED}Session expired. Please run the command again.${NC}" >&2
            return 1
        fi

        sleep 1
    done
}

ensure_gitlab_token() {
    [ "$provider" != "gitlab" ] && return 0
    [ -n "$gitlab_token" ] && return 0

    if load_gitlab_oauth_token; then
        return 0
    fi

    return 1
}

fetch_gitlab_repos() {
    local group_path="$1"
    local page=1
    local repos=()
    local api_error=false
    local curl_args response curl_exit urls err encoded_group

    encoded_group=$(echo "$group_path" | sed 's/\//%2F/g')

    while true; do
        log info "  Fetching GitLab page $page for group: $group_path"
        curl_args=(curl -sf --connect-timeout 10 --max-time 30)
        [[ -n "${gitlab_token:-}" ]] && curl_args+=(-H "Authorization: Bearer $gitlab_token")
        curl_args+=("https://gitlab.com/api/v4/groups/$encoded_group/projects?per_page=100&page=$page&include_subgroups=true")

        response=$("${curl_args[@]}" 2>/dev/null) || true
        curl_exit=$?

        if [[ $curl_exit -ne 0 ]] || [[ -z "$response" ]]; then
            if [[ $curl_exit -ne 0 ]]; then
                api_error=true
                log error "GitLab API request failed (page $page)"
            fi
            break
        fi

        if [[ "$response" = "[]" ]]; then
            break
        fi

        if echo "$response" | grep -q '"message"'; then
            api_error=true
            err=$(parse_json_field "$response" ".message")
            log error "GitLab API error: $err"
            break
        fi

        urls=$(parse_json_array_field "$response" "ssh_url_to_repo")
        while IFS= read -r url; do
            [[ -n "$url" ]] && repos+=("$url")
        done <<< "$urls"

        page=$((page + 1))
    done

    printf '%s\n' "${repos[@]}"

    if $api_error && [[ ${#repos[@]} -eq 0 ]]; then
        return 2
    fi
}

get_repo_name() {
    local ssh_url="$1"
    local name
    name=$(echo "$ssh_url" | sed 's/.*\///; s/\.git$//')
    echo "$name"
}

clone_repo() {
    local ssh_url="$1"
    local dest_dir="$2"
    local repo_name="$3"

    if [[ -d "$dest_dir" ]]; then
        log warn "  Skipping (already exists): $repo_name"
        return 2
    fi

    if [[ "$dry_run" = true ]]; then
        log warn "  [DRY-RUN] Would clone: $repo_name ($ssh_url)"
        return 0
    fi

    log success "  Cloning: $repo_name"
    git clone "$ssh_url" "$dest_dir" 2>&1 | sed 's/^/    /'
    local exit_code=${PIPESTATUS[0]}

    if [[ "$exit_code" -ne 0 ]]; then
        log error "  Failed to clone: $repo_name"
        return 1
    fi

    log info "  Cloned: $repo_name ($ssh_url)"
    return 0
}

main() {
    check_dependencies

    log success "git-group-clone"
    echo ""

    log info "Configuration:"
    log info "  Provider:    $provider"
    log info "  Group:       $group"
    log info "  Destination: $dest/$group"
    log info "  Dry-run:     $dry_run"
    [[ -n "$repos_list" ]] && log info "  Repos:       ${repos_list}"
    echo ""

    local -a all_repos=()

    if [[ -n "$repos_list" ]]; then
        log info "Using repo list for $provider group '$group'..."

        IFS=',' read -ra repo_names <<< "$repos_list"
        for repo_name in "${repo_names[@]}"; do
            repo_name=$(echo "$repo_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [[ -z "$repo_name" ]] && continue

            case "$provider" in
                github) all_repos+=("git@github.com:${group}/${repo_name}.git") ;;
                gitlab) all_repos+=("git@gitlab.com:${group}/${repo_name}.git") ;;
            esac
        done
    else
        log info "Fetching repositories from $provider group '$group'..."

        case "$provider" in
            github)
                while IFS= read -r url; do
                    [[ -n "$url" ]] && all_repos+=("$url")
                done < <(fetch_github_repos "$group")
                ;;
            gitlab)
                ensure_gitlab_token
                local repos_output fetch_exit
                repos_output=$(fetch_gitlab_repos "$group")
                fetch_exit=$?
                while IFS= read -r url; do
                    [[ -n "$url" ]] && all_repos+=("$url")
                done <<< "$repos_output"
                if [[ "$fetch_exit" -eq 2 ]] && [[ -z "$gitlab_token" ]]; then
                    log warn "Group might be private — attempting OAuth auth..."
                    if do_gitlab_oauth_device_flow; then
                        repos_output=$(fetch_gitlab_repos "$group")
                        while IFS= read -r url; do
                            [[ -n "$url" ]] && all_repos+=("$url")
                        done <<< "$repos_output"
                    fi
                fi
                ;;
        esac
    fi

    if [[ ${#all_repos[@]} -eq 0 ]]; then
        log error "No repositories found for $provider group '$group'"
        log warn "Tip: For private repos, use -r \"repo1,repo2\" to pass repo names directly."
        exit 1
    fi

    echo ""
    log success "Found ${#all_repos[@]} repositories"
    echo ""

    local group_dir="$dest/$group"
    mkdir -p "$group_dir" || die "Cannot create directory: $group_dir"
    log info "Cloning into: $group_dir"

    local cloned=0 skipped=0 failed=0

    for ssh_url in "${all_repos[@]}"; do
        local repo_name
        repo_name=$(get_repo_name "$ssh_url")
        clone_repo "$ssh_url" "$group_dir/$repo_name" "$repo_name"
        case $? in
            0) cloned=$((cloned + 1)) ;;
            1) failed=$((failed + 1)) ;;
            2) skipped=$((skipped + 1)) ;;
        esac
    done

    echo ""
    log info "============================================="
    log info "           CLONE SUMMARY                     "
    log info "============================================="
    log info "  Total found:  ${#all_repos[@]}"
    log info "  Cloned:       $cloned"
    log info "  Skipped:      $skipped"
    log info "  Failed:       $failed"
    echo ""

    [[ "$dry_run" = true ]] && log warn "*** DRY-RUN - No repositories were cloned ***"

    log success "Done."

    [[ -n "$log_file" ]] && log success "Log saved to: $log_file"
}

main

