#!/usr/bin/env bash

provider=""
group=""
dest=""
repos_list=""
dry_run=false
log_file=""
gitlab_oauth_active=false

GITLAB_CLIENT_ID=""
GITLAB_OAUTH_DIR="$HOME/.cache/git-group-clone"
GITLAB_OAUTH_TOKEN_FILE="$GITLAB_OAUTH_DIR/oauth_token"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

log_output() {
    if [ -n "$log_file" ]; then
        echo "$1" >> "$log_file"
    fi
}

log_color() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
    log_output "$msg"
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
            > "$log_file" 2>/dev/null || {
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

github_token="${GITHUB_TOKEN:-$GH_TOKEN}"
gitlab_token="${GITLAB_TOKEN:-$GL_TOKEN}"

fetch_github_repos() {
    local org="$1"
    local page=1
    local repos=()
    local auth_header=""
    local response curl_exit urls err

    if [ -n "$github_token" ]; then
        auth_header="-H \"Authorization: Bearer $github_token\""
    fi

    while true; do
        log_output "  Fetching GitHub page $page for org: $org"
        response=$(eval curl -sf --connect-timeout 10 --max-time 30 $auth_header "\"https://api.github.com/orgs/$org/repos?per_page=100&page=$page\"" 2>/dev/null)
        curl_exit=$?

        if [ $curl_exit -ne 0 ] || [ -z "$response" ]; then
            if [ $curl_exit -ne 0 ]; then
                echo -e "${RED}GitHub API request failed (page $page)${NC}" >&2
                log_output "GitHub API request failed (page $page)"
            fi
            break
        fi

        if [ "$response" = "[]" ]; then
            break
        fi

        if echo "$response" | grep -q '"message"'; then
            err=$(echo "$response" | grep -o '"message": *"[^"]*"' | sed 's/^[^:]*: *"//;s/"$//')
            echo -e "${RED}GitHub API error: $err${NC}" >&2
            return 1
        fi

        urls=$(echo "$response" | grep -o '"ssh_url": *"[^"]*"' | sed 's/^[^:]*: *"//;s/"$//')
        while IFS= read -r url; do
            [ -n "$url" ] && repos+=("$url")
        done <<< "$urls"

        page=$((page + 1))
    done

    for repo in "${repos[@]}"; do
        echo "$repo"
    done
}

load_gitlab_oauth_token() {
    if [ ! -f "$GITLAB_OAUTH_TOKEN_FILE" ]; then
        return 1
    fi

    source "$GITLAB_OAUTH_TOKEN_FILE" 2>/dev/null || return 1

    if [ -z "$OAUTH_ACCESS_TOKEN" ]; then
        return 1
    fi

    local current_time
    current_time=$(date +%s)

    if [ -n "$OAUTH_EXPIRES_AT" ] && [ "$current_time" -lt "$OAUTH_EXPIRES_AT" ] 2>/dev/null; then
        gitlab_token="$OAUTH_ACCESS_TOKEN"
        return 0
    fi

    if [ -n "$OAUTH_REFRESH_TOKEN" ]; then
        log_color "$BLUE" "Refreshing expired OAuth token..."
        local refresh_response
        refresh_response=$(curl -sf -X POST "https://gitlab.com/oauth/token" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -d "grant_type=refresh_token&refresh_token=$OAUTH_REFRESH_TOKEN&client_id=$GITLAB_CLIENT_ID" 2>/dev/null)

        if [ -n "$refresh_response" ] && echo "$refresh_response" | grep -q '"access_token"'; then
            local new_access_token new_refresh_token new_expires_in new_created_at new_expires_at
            new_access_token=$(echo "$refresh_response" | grep -o '"access_token":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
            new_refresh_token=$(echo "$refresh_response" | grep -o '"refresh_token":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
            new_expires_in=$(echo "$refresh_response" | grep -o '"expires_in":[0-9]*' | head -1 | sed 's/[^0-9]//g')
            new_created_at=$(date +%s)
            new_expires_at=$((new_created_at + new_expires_in))

            cat > "$GITLAB_OAUTH_TOKEN_FILE" << EOF
OAUTH_ACCESS_TOKEN=$new_access_token
OAUTH_REFRESH_TOKEN=$new_refresh_token
OAUTH_CREATED_AT=$new_created_at
OAUTH_EXPIRES_IN=$new_expires_in
OAUTH_EXPIRES_AT=$new_expires_at
EOF
            chmod 600 "$GITLAB_OAUTH_TOKEN_FILE"
            gitlab_token="$new_access_token"
            return 0
        fi
    fi

    return 1
}

do_gitlab_oauth_device_flow() {
    echo ""
    log_color "$BLUE" "No GitLab token available. Starting OAuth device authorization..."
    echo -e "${YELLOW}You'll need to authenticate with GitLab.com in your browser.${NC}"
    echo ""

    local device_response
    device_response=$(curl -sf -X POST "https://gitlab.com/oauth/authorize_device" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=$GITLAB_CLIENT_ID&scope=api" 2>/dev/null)

    if [ -z "$device_response" ]; then
        echo -e "${RED}Failed to start device authorization. Check your internet connection.${NC}" >&2
        return 1
    fi

    local device_code user_code verification_uri_complete expires_in interval
    device_code=$(echo "$device_response" | grep -o '"device_code":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
    user_code=$(echo "$device_response" | grep -o '"user_code":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
    verification_uri_complete=$(echo "$device_response" | grep -o '"verification_uri_complete":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
    expires_in=$(echo "$device_response" | grep -o '"expires_in":[0-9]*' | head -1 | sed 's/[^0-9]//g')
    interval=$(echo "$device_response" | grep -o '"interval":[0-9]*' | head -1 | sed 's/[^0-9]//g')

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
            token=$(echo "$token_response" | grep -o '"access_token":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
            refresh_token=$(echo "$token_response" | grep -o '"refresh_token":"[^"]*"' | sed 's/^[^:]*:"//;s/"$//')
            new_expires_in=$(echo "$token_response" | grep -o '"expires_in":[0-9]*' | head -1 | sed 's/[^0-9]//g')
            created_at=$(date +%s)
            expires_at=$((created_at + new_expires_in))

            mkdir -p "$GITLAB_OAUTH_DIR"
            cat > "$GITLAB_OAUTH_TOKEN_FILE" << EOF
OAUTH_ACCESS_TOKEN=$token
OAUTH_REFRESH_TOKEN=$refresh_token
OAUTH_CREATED_AT=$created_at
OAUTH_EXPIRES_IN=$new_expires_in
OAUTH_EXPIRES_AT=$expires_at
EOF
            chmod 600 "$GITLAB_OAUTH_TOKEN_FILE"

            echo -e "\n${GREEN}Authentication successful! Token cached in $GITLAB_OAUTH_TOKEN_FILE${NC}"
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
    local auth_header=""
    local api_error=false
    local response curl_exit urls err encoded_group

    if [ -n "$gitlab_token" ]; then
        auth_header="-H \"Authorization: Bearer $gitlab_token\""
    fi

    encoded_group=$(echo "$group_path" | sed 's/\//%2F/g')

    while true; do
        log_output "  Fetching GitLab page $page for group: $group_path"
        response=$(eval curl -sf --connect-timeout 10 --max-time 30 $auth_header "\"https://gitlab.com/api/v4/groups/$encoded_group/projects?per_page=100&page=$page&include_subgroups=true\"" 2>/dev/null)
        curl_exit=$?

        if [ $curl_exit -ne 0 ] || [ -z "$response" ]; then
            if [ $curl_exit -ne 0 ]; then
                api_error=true
                echo -e "${RED}GitLab API request failed (page $page)${NC}" >&2
                log_output "GitLab API request failed (page $page)"
            fi
            break
        fi

        if [ "$response" = "[]" ]; then
            break
        fi

        if echo "$response" | grep -q '"message"'; then
            api_error=true
            err=$(echo "$response" | grep -o '"message": *"[^"]*"' | sed 's/^[^:]*: *"//;s/"$//')
            echo -e "${RED}GitLab API error: $err${NC}" >&2
            break
        fi

        urls=$(echo "$response" | grep -o '"ssh_url_to_repo": *"[^"]*"' | sed 's/^[^:]*: *"//;s/"$//')
        while IFS= read -r url; do
            [ -n "$url" ] && repos+=("$url")
        done <<< "$urls"

        page=$((page + 1))
    done

    for repo in "${repos[@]}"; do
        echo "$repo"
    done

    if $api_error && [ ${#repos[@]} -eq 0 ]; then
        return 2
    fi
}

get_repo_name() {
    local ssh_url="$1"
    local name=$(echo "$ssh_url" | sed 's/.*\///; s/\.git$//')
    echo "$name"
}

clone_repo() {
    local ssh_url="$1"
    local dest_dir="$2"
    local repo_name="$3"

    if [ -d "$dest_dir" ]; then
        log_color "$YELLOW" "  Skipping (already exists): $repo_name"
        return 2
    fi

    if [ "$dry_run" = true ]; then
        log_color "$YELLOW" "  [DRY-RUN] Would clone: $repo_name ($ssh_url)"
        return 0
    fi

    log_color "$GREEN" "  Cloning: $repo_name"
    git clone "$ssh_url" "$dest_dir" 2>&1 | sed 's/^/    /'
    local exit_code=${PIPESTATUS[0]}

    if [ "$exit_code" -ne 0 ]; then
        log_color "$RED" "  Failed to clone: $repo_name"
        return 1
    fi

    log_output "  Cloned: $repo_name ($ssh_url)"
    return 0
}

echo -e "${GREEN}git-group-clone${NC}"
log_output "Starting git-group-clone"
echo ""

echo -e "${BLUE}Configuration:${NC}"
log_output "Configuration:"
echo "  Provider:    $provider"
log_output "  Provider:    $provider"
echo "  Group:       $group"
log_output "  Group:       $group"
echo "  Destination: $dest/$group"
log_output "  Destination: $dest/$group"
echo "  Dry-run:     $dry_run"
log_output "  Dry-run:     $dry_run"
if [ -n "$repos_list" ]; then
    echo "  Repos:       ${repos_list}"
    log_output "  Repos:       ${repos_list}"
fi
echo ""

declare -a all_repos=()

if [ -n "$repos_list" ]; then
    log_color "$BLUE" "Using repo list for $provider group '$group'..."

    IFS=',' read -ra repo_names <<< "$repos_list"
    for repo_name in "${repo_names[@]}"; do
        repo_name=$(echo "$repo_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$repo_name" ] && continue

        case "$provider" in
            github)
                all_repos+=("git@github.com:${group}/${repo_name}.git")
                ;;
            gitlab)
                all_repos+=("git@gitlab.com:${group}/${repo_name}.git")
                ;;
        esac
    done
else
    log_color "$BLUE" "Fetching repositories from $provider group '$group'..."

    case "$provider" in
        github)
            while IFS= read -r url; do
                [ -n "$url" ] && all_repos+=("$url")
            done < <(fetch_github_repos "$group")
            ;;
        gitlab)
            ensure_gitlab_token
            repos_output=$(fetch_gitlab_repos "$group")
            fetch_exit=$?
            while IFS= read -r url; do
                [ -n "$url" ] && all_repos+=("$url")
            done <<< "$repos_output"
            if [ "$fetch_exit" -eq 2 ] && [ -z "$gitlab_token" ]; then
                echo -e "${YELLOW}Group might be private — attempting OAuth auth...${NC}" >&2
                if do_gitlab_oauth_device_flow; then
                    repos_output=$(fetch_gitlab_repos "$group")
                    while IFS= read -r url; do
                        [ -n "$url" ] && all_repos+=("$url")
                    done <<< "$repos_output"
                fi
            fi
            ;;
    esac
fi

if [ ${#all_repos[@]} -eq 0 ]; then
    echo -e "${RED}No repositories found for $provider group '$group'${NC}" >&2
    echo -e "${YELLOW}Tip: For private repos, use -r \"repo1,repo2\" to pass repo names directly.${NC}" >&2
    log_output "No repositories found"
    exit 1
fi

echo ""
log_color "$GREEN" "Found ${#all_repos[@]} repositories"
echo ""

group_dir="$dest/$group"
mkdir -p "$group_dir" || {
    echo -e "${RED}Error: Cannot create directory: $group_dir${NC}" >&2
    exit 1
}
log_color "$BLUE" "Cloning into: $group_dir"

cloned=0
skipped=0
failed=0

for ssh_url in "${all_repos[@]}"; do
    repo_name=$(get_repo_name "$ssh_url")
    clone_repo "$ssh_url" "$group_dir/$repo_name" "$repo_name"
    case $? in
        0) cloned=$((cloned + 1)) ;;
        1) failed=$((failed + 1)) ;;
        2) skipped=$((skipped + 1)) ;;
    esac
done

echo ""
log_color "$BLUE" "============================================="
log_color "$BLUE" "           CLONE SUMMARY                     "
log_color "$BLUE" "============================================="
echo ""
echo "  Total found:  ${#all_repos[@]}"
echo "  Cloned:       $cloned"
echo "  Skipped:      $skipped"
echo "  Failed:       $failed"
echo ""
log_output "============================================="
log_output "           CLONE SUMMARY                     "
log_output "============================================="
log_output "Total found: ${#all_repos[@]}"
log_output "Cloned: $cloned"
log_output "Skipped: $skipped"
log_output "Failed: $failed"

if [ "$dry_run" = true ]; then
    echo -e "${YELLOW}*** DRY-RUN - No repositories were cloned ***${NC}"
    log_output "*** DRY-RUN - No repositories were cloned ***"
fi

echo ""
log_color "$GREEN" "Done."
log_output "Done."

if [ -n "$log_file" ]; then
    echo -e "${GREEN}Log saved to: $log_file${NC}"
fi
