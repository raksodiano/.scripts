#!/bin/bash

delete_origin=false
dry_run=false
interactive=false
log_file=""
base_path="."
search_depth=1
declare -a excluded_branches=("main" "master" "staging" "dev")
declare -a excluded_dirs=()
declare -a branch_patterns=()
declare -a remotes=("origin")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

show_help() {
    echo -e "${BLUE}Usage:${NC} $0 [-o] [-d base_directory] [-e \"branch1,branch2\"] [-p \"pattern\"] [-x \"dir1,dir2\"] [-r depth] [-m \"remote1,remote2\"] [-n] [-i] [-l logfile] [-h]"
    echo ""
    echo -e "${BLUE}Options:${NC}"
    echo "  -o                   Delete remote branches from origin"
    echo "  -d base_directory    Base directory to start cleaning (default: current directory)"
    echo "  -e \"branch1,branch2\"  Additional branches to exclude (comma-separated)"
    echo "  -p \"pattern\"         Branch pattern to exclude (regex, e.g., \"feature/.*|hotfix/.*\")"
    echo "  -x \"dir1,dir2\"       Directories to exclude from search (comma-separated)"
    echo "  -r depth             Search depth for subdirectories (default: 1)"
    echo "  -m \"remote1,remote2\" Remote(s) to use (default: origin)"
    echo "  -n                   Dry-run mode (simulate without deleting)"
    echo "  -i                   Interactive confirmation before deleting"
    echo "  -l logfile           Log output to file"
    echo "  -h                   Show this help message"
    echo ""
    echo -e "${BLUE}Default excluded branches:${NC} main, master, staging, dev"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 -d /path/to/repos"
    echo "  $0 -o -e \"branch1,branch2\" -n"
    echo "  $0 -d /projects -r 2 -x \"node_modules,vendor\""
    echo "  $0 -o -p \"feature/.*|hotfix/.*\" -i"
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

while getopts "od:e:p:x:r:m:nil:h" opt; do
  case $opt in
    o)
      delete_origin=true
      ;;
    d)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -d requires a directory argument${NC}" >&2
        exit 1
      fi
      base_path="$OPTARG"
      ;;
    e)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -e requires a branch argument${NC}" >&2
        exit 1
      fi
      IFS=',' read -ra branches <<< "$OPTARG"
      for branch in "${branches[@]}"; do
        [[ -n "$branch" ]] && excluded_branches+=("$branch")
      done
      ;;
    p)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -p requires a pattern argument${NC}" >&2
        exit 1
      fi
      branch_patterns+=("$OPTARG")
      ;;
    x)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -x requires a directory argument${NC}" >&2
        exit 1
      fi
      IFS=',' read -ra dirs <<< "$OPTARG"
      for dir in "${dirs[@]}"; do
        [[ -n "$dir" ]] && excluded_dirs+=("$dir")
      done
      ;;
    r)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -r requires a depth argument${NC}" >&2
        exit 1
      fi
      if ! [[ "$OPTARG" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: -r must be a number${NC}" >&2
        exit 1
      fi
      search_depth="$OPTARG"
      ;;
    m)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -m requires a remote argument${NC}" >&2
        exit 1
      fi
      IFS=',' read -ra remote_list <<< "$OPTARG"
      remotes=()
      for remote in "${remote_list[@]}"; do
        [[ -n "$remote" ]] && remotes+=("$remote")
      done
      ;;
    n)
      dry_run=true
      ;;
    i)
      interactive=true
      ;;
    l)
      if [ -z "$OPTARG" ]; then
        echo -e "${RED}Error: -l requires a log file argument${NC}" >&2
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

repo_path="${1:-$base_path}"

declare -a summary_projects=()
declare -a summary_local=()
declare -a summary_local_remain=()
declare -a summary_remote=()
declare -a summary_remote_exist=()

exclude_regex=""
pattern_regex=""

build_exclude_regex() {
    local regex=""
    for branch in "${excluded_branches[@]}"; do
        if [ -z "$regex" ]; then
            regex="^${branch}$"
        else
            regex="${regex}|^${branch}$"
        fi
    done
    echo "$regex"
}

build_pattern_regex() {
    local regex=""
    for pattern in "${branch_patterns[@]}"; do
        if [ -z "$regex" ]; then
            regex="$pattern"
        else
            regex="${regex}|$pattern"
        fi
    done
    echo "$regex"
}

init_regex() {
    exclude_regex=$(build_exclude_regex)
    pattern_regex=$(build_pattern_regex)
}

is_git_repo() {
    [ -d "$1/.git" ]
}

is_excluded_dir() {
    local dir_name=$(basename "$1")
    for excluded in "${excluded_dirs[@]}"; do
        if [ "$dir_name" = "$excluded" ]; then
            return 0
        fi
    done
    return 1
}

build_exclude_regex() {
    local regex=""
    for branch in "${excluded_branches[@]}"; do
        if [ -z "$regex" ]; then
            regex="^${branch}$"
        else
            regex="${regex}|^${branch}$"
        fi
    done
    echo "$regex"
}

build_pattern_regex() {
    local regex=""
    for pattern in "${branch_patterns[@]}"; do
        if [ -z "$regex" ]; then
            regex="$pattern"
        else
            regex="${regex}|$pattern"
        fi
    done
    echo "$regex"
}

get_local_branches() {
    local repo="$1"
    
    local branches=$(git -C "$repo" branch --format='%(refname:short)' 2>/dev/null | grep -v '^$' | grep -v '^$')
    
    if [ -n "$exclude_regex" ]; then
        branches=$(echo "$branches" | grep -v -E "$exclude_regex")
    fi
    
    if [ -n "$pattern_regex" ]; then
        branches=$(echo "$branches" | grep -v -E "$pattern_regex")
    fi
    
    echo "$branches"
}

get_remote_branches() {
    local repo="$1"
    local all_branches=""
    
    for remote in "${remotes[@]}"; do
        local remote_branches=$(git -C "$repo" branch -r 2>/dev/null | grep -v -E " -> " | sed "s/^[ \t]*${remote}\///" | grep -v '^$' | grep -v '^$')
        all_branches="${all_branches}${all_branches:+$'\n'}${remote_branches}"
    done
    
    if [ -n "$exclude_regex" ]; then
        all_branches=$(echo "$all_branches" | grep -v -E "$exclude_regex")
    fi
    
    if [ -n "$pattern_regex" ]; then
        all_branches=$(echo "$all_branches" | grep -v -E "$pattern_regex")
    fi
    
    echo "$all_branches" | sort -u
}

get_all_remote_branches() {
    local repo="$1"
    local all_branches=""
    
    for remote in "${remotes[@]}"; do
        local remote_branches=$(git -C "$repo" branch -r 2>/dev/null | grep -v -E " -> " | sed "s/^[ \t]*${remote}\///" | grep -v '^$' | grep -v '^$')
        all_branches="${all_branches}${all_branches:+$'\n'}${remote_branches}"
    done
    
    echo "$all_branches" | sort -u
}

get_remaining_local_branches() {
    local repo="$1"
    git -C "$repo" branch --format='%(refname:short)' 2>/dev/null | grep -v '^$' | grep -v '^$'
}

switch_to_safe_branch() {
    local repo="$1"
    
    for branch in main master dev develop; do
        if git -C "$repo" checkout "$branch" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

get_git_remotes() {
    local repo="$1"
    git -C "$repo" remote 2>/dev/null
}

clean_branches() {
    local repo="$1"
    local project_name="$2"
    local local_count=0
    local remote_count=0
    local remote_exist=0
    local local_remain=0
    
    local current_remote=""
    if [ -n "$remotes" ]; then
        current_remote="${remotes[0]}"
    fi
    
    log_color "$BLUE" ">>> Processing: $project_name"
    
    if [ -n "$(get_git_remotes "$repo")" ]; then
        local repo_remotes=$(get_git_remotes "$repo" | tr '\n' ', ')
        log_output "  Remotes: ${repo_remotes%, }"
    fi
    
    switch_to_safe_branch "$repo"
    
    local local_branches=$(get_local_branches "$repo")
    local remote_branches=""
    local all_remote_branches=$(get_all_remote_branches "$repo")
    
    if [ -n "$all_remote_branches" ]; then
        remote_exist=$(echo "$all_remote_branches" | wc -l)
    fi
    
    if [ "$delete_origin" = true ]; then
        remote_branches=$(get_remote_branches "$repo")
    fi
    
    if [ -n "$local_branches" ]; then
        local branch_list=$(echo "$local_branches" | tr '\n' ',' | sed 's/,$//')
        local_count=$(echo "$local_branches" | wc -l)
        log_output "  Local branches to delete: $branch_list"
        
        if [ "$interactive" = true ] && [ "$dry_run" = false ]; then
            while true; do
                echo -en "${YELLOW}Delete $local_count local branches in $project_name? [y/N]: ${NC}"
                read -r confirm < /dev/tty
                confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
                if [[ "$confirm" == "y" || "$confirm" == "n" || "$confirm" == "" ]]; then
                    break
                fi
                echo -e "${RED}Please answer y, n, or press Enter for n${NC}"
            done
            if [[ "$confirm" != "y" ]]; then
                log_color "$YELLOW" "  Skipped local branch deletion"
                local_branches=""
                local_count=0
            fi
        fi
        
        if [ -n "$local_branches" ]; then
            if [ "$dry_run" = true ]; then
                log_color "$YELLOW" "  [DRY-RUN] Would delete local branches: $branch_list"
            else
                log_color "$GREEN" "Deleting local branches in $project_name..."
                local deleted_local=$(echo "$local_branches" | xargs -r git -C "$repo" branch -D 2>&1)
                log_output "  -> Local branches deleted"
            fi
        fi
    else
        log_output "  No local branches to delete"
        local_count=0
    fi
    
    local remaining_branches=$(get_remaining_local_branches "$repo")
    if [ -n "$remaining_branches" ]; then
        local_remain=$(echo "$remaining_branches" | wc -l)
    fi
    
    if [ "$delete_origin" = true ] && [ -n "$remote_branches" ]; then
        local remote_branch_list=$(echo "$remote_branches" | tr '\n' ',' | sed 's/,$//')
        remote_count=$(echo "$remote_branches" | wc -l)
        log_output "  Remote branches to delete: $remote_branch_list"
        
        if [ "$interactive" = true ] && [ "$dry_run" = false ]; then
            while true; do
                echo -en "${YELLOW}Delete $remote_count remote branches in $project_name? [y/N]: ${NC}"
                read -r confirm < /dev/tty
                confirm=$(echo "$confirm" | tr '[:upper:]' '[:lower:]')
                if [[ "$confirm" == "y" || "$confirm" == "n" || "$confirm" == "" ]]; then
                    break
                fi
                echo -e "${RED}Please answer y, n, or press Enter for n${NC}"
            done
            if [[ "$confirm" != "y" ]]; then
                log_color "$YELLOW" "  Skipped remote branch deletion"
                remote_branches=""
                remote_count=0
            fi
        fi
        
        if [ -n "$remote_branches" ]; then
            if [ "$dry_run" = true ]; then
                log_color "$YELLOW" "  [DRY-RUN] Would delete remote branches: $remote_branch_list"
            else
                log_color "$GREEN" "Deleting remote branches in $project_name..."
                for remote in "${remotes[@]}"; do
                    local remote_branches_for_remote=$(git -C "$repo" branch -r 2>/dev/null | grep -v -E " -> " | sed "s/^[ \t]*${remote}\///" | grep -v '^$' | grep -v '^$')
                    if [ -n "$remote_branches_for_remote" ]; then
                        if [ -n "$exclude_regex" ]; then
                            remote_branches_for_remote=$(echo "$remote_branches_for_remote" | grep -v -E "$exclude_regex")
                        fi
                        if [ -n "$pattern_regex" ]; then
                            remote_branches_for_remote=$(echo "$remote_branches_for_remote" | grep -v -E "$pattern_regex")
                        fi
                        if [ -n "$remote_branches_for_remote" ]; then
                            echo "$remote_branches_for_remote" | xargs -I {} git -C "$repo" push "$remote" --delete {} 2>&1
                        fi
                    fi
                done
                log_output "  -> Remote branches deleted"
            fi
        fi
    elif [ "$delete_origin" = true ]; then
        log_output "  No remote branches to delete"
        remote_count=0
    fi
    
    summary_projects+=("$project_name")
    summary_local+=("$local_count")
    summary_local_remain+=("$local_remain")
    summary_remote+=("$remote_count")
    summary_remote_exist+=("$remote_exist")
}

show_summary() {
    echo
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}           CLEANUP SUMMARY                  ${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo
    
    local total_projects=${#summary_projects[@]}
    local total_local=0
    local total_local_remain=0
    local total_remote=0
    local total_remote_exist=0
    
    if [ "$dry_run" = true ]; then
        echo -e "${YELLOW}*** DRY-RUN MODE - No branches were actually deleted ***${NC}"
        echo
    fi
    
    if [ "$delete_origin" = true ]; then
        printf "%-25s | %-10s | %-10s | %-12s | %-12s\n" "PROJECT" "LOCAL DEL" "LOCAL REM" "REMOTE DEL" "REMOTE TOT"
        echo "-----------------------------------------------------------------------------------------------------------"
        
        for i in "${!summary_projects[@]}"; do
            local project="${summary_projects[$i]}"
            local local="${summary_local[$i]}"
            local local_remain="${summary_local_remain[$i]}"
            local remote="${summary_remote[$i]}"
            local remote_exist="${summary_remote_exist[$i]}"
            
            total_local=$((total_local + local))
            total_local_remain=$((total_local_remain + local_remain))
            total_remote=$((total_remote + remote))
            total_remote_exist=$((total_remote_exist + remote_exist))
            
            printf "%-25s | %-10s | %-10s | %-12s | %-12s\n" "$project" "$local" "$local_remain" "$remote" "$remote_exist"
        done
    else
        printf "%-25s | %-10s | %-10s\n" "PROJECT" "LOCAL DEL" "LOCAL REM"
        echo "--------------------------------------------------------"
        
        for i in "${!summary_projects[@]}"; do
            local project="${summary_projects[$i]}"
            local local="${summary_local[$i]}"
            local local_remain="${summary_local_remain[$i]}"
            
            total_local=$((total_local + local))
            total_local_remain=$((total_local_remain + local_remain))
            
            printf "%-25s | %-10s | %-10s\n" "$project" "$local" "$local_remain"
        done
    fi
    
    echo
    echo "---------------------------------------------"
    echo "Total projects processed: $total_projects"
    echo "Total local branches deleted: $total_local"
    echo "Total local branches remaining: $total_local_remain"
    if [ "$delete_origin" = true ]; then
        echo "Total remote branches deleted: $total_remote"
        echo "Total remote branches in remotes: $total_remote_exist"
    fi
    echo "============================================="
    
    log_output "============================================="
    log_output "           CLEANUP SUMMARY                  "
    log_output "============================================="
    log_output ""
    log_output "Total projects processed: $total_projects"
    log_output "Total local branches deleted: $total_local"
    log_output "Total local branches remaining: $total_local_remain"
    if [ "$delete_origin" = true ]; then
        log_output "Total remote branches deleted: $total_remote"
        log_output "Total remote branches in remotes: $total_remote_exist"
    fi
    log_output "============================================="
}

find_git_repos() {
    local base_dir="$1"
    local depth="$2"
    local current_depth="${3:-0}"
    
    if [ "$current_depth" -ge "$depth" ]; then
        return
    fi
    
    for entry in "$base_dir"/*/; do
        [ -d "$entry" ] || continue
        entry=${entry%/}
        
        if is_excluded_dir "$entry"; then
            continue
        fi
        
        if is_git_repo "$entry"; then
            echo "$entry"
        else
            find_git_repos "$entry" "$depth" $((current_depth + 1))
        fi
    done
}

echo -e "${GREEN}Starting Git branch cleanup...${NC}"
log_output "Starting Git branch cleanup..."

init_regex

echo

if [ -z "$repo_path" ]; then
    echo -e "${RED}Error: Repository path is empty${NC}" >&2
    exit 1
fi

if ! [ -e "$repo_path" ]; then
    echo -e "${RED}Error: Path does not exist: $repo_path${NC}" >&2
    exit 1
fi

if ! [ -d "$repo_path" ]; then
    echo -e "${RED}Error: Path is not a directory: $repo_path${NC}" >&2
    exit 1
fi

if ! [ -r "$repo_path" ]; then
    echo -e "${RED}Error: Directory is not readable: $repo_path${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Configuration:${NC}"
log_output "Configuration:"
echo "  Base path: $repo_path"
log_output "  Base path: $repo_path"
echo "  Search depth: $search_depth"
log_output "  Search depth: $search_depth"
echo "  Remotes: ${remotes[*]}"
log_output "  Remotes: ${remotes[*]}"
echo "  Excluded branches: ${excluded_branches[*]}"
log_output "  Excluded branches: ${excluded_branches[*]}"
echo "  Dry-run: $dry_run"
log_output "  Dry-run: $dry_run"
echo "  Interactive: $interactive"
log_output "  Interactive: $interactive"
if [ ${#excluded_dirs[@]} -gt 0 ]; then
    echo "  Excluded directories: ${excluded_dirs[*]}"
    log_output "  Excluded directories: ${excluded_dirs[*]}"
fi
if [ ${#branch_patterns[@]} -gt 0 ]; then
    echo "  Branch patterns to exclude: ${branch_patterns[*]}"
    log_output "  Branch patterns to exclude: ${branch_patterns[*]}"
fi
echo

if is_git_repo "$repo_path"; then
    echo -e "${GREEN}Direct Git repository detected: $repo_path${NC}"
    log_output "Direct Git repository detected: $repo_path"
    project_name=$(basename "$repo_path")
    clean_branches "$repo_path" "$project_name"
else
    echo -e "${GREEN}Searching subdirectories (depth: $search_depth)...${NC}"
    log_output "Searching subdirectories (depth: $search_depth)..."
    echo
    
    found_repos=false
    while IFS= read -r subdir; do
        if is_git_repo "$subdir"; then
            found_repos=true
            clean_branches "$subdir" "$(basename "$subdir")"
            echo
        fi
    done < <(find_git_repos "$repo_path" "$search_depth")
    
    if [ "$found_repos" = false ]; then
        echo -e "${RED}No Git repositories found in: $repo_path${NC}" >&2
        log_output "No Git repositories found in: $repo_path"
        exit 1
    fi
fi

show_summary

echo
echo -e "${GREEN}Script completed.${NC}"
log_output "Script completed."

if [ -n "$log_file" ]; then
    echo -e "${GREEN}Log saved to: $log_file${NC}"
fi