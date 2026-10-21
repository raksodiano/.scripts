#!/usr/bin/env bash

set -uo pipefail

VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_file=""
stage=""
declare -a exclude_patterns=()

cleanup() {
    if [[ -n "$stage" && -d "$stage" ]]; then
        rm -rf -- "$stage"
    fi
}

trap cleanup EXIT

die() {
    echo -e "${RED}Error: $1${NC}" >&2
    [[ -n "$log_file" ]] && echo "Error: $1" >> "$log_file"
    exit "${2:-1}"
}

log() {
    local color="$1"
    shift
    local msg="$*"
    echo -e "${color}${msg}${NC}"
    if [[ -n "$log_file" ]]; then
        echo "$msg" >> "$log_file"
    fi
    return 0
}

show_help() {
    echo -e "${BLUE}env-backup${NC} v$VERSION - Package and restore .env files"
    echo ""
    echo -e "${BLUE}Usage:${NC}"
    echo "  $0 pack    -d <directory> [-o archive.tar.gz] [-r depth] [-x \"dir1,dir2\"] [-e \"pattern1,pattern2\"] [-n] [-l logfile]"
    echo "  $0 restore -a <archive.tar.gz> [-f] [-n] [-l logfile]"
    echo "  $0 undo    [-f] [-n] [-l logfile]"
    echo "  $0 list    -a <archive.tar.gz>"
    echo "  $0 help"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  pack       Find .env and .env.* files recursively and package them in order"
    echo "  restore    Restore the packaged files to their original absolute paths"
    echo "  undo       Revert the most recent restore using its recorded backups"
    echo "  list       Show the files contained in an archive"
    echo ""
    echo -e "${BLUE}Pack options:${NC}"
    echo "  -d <directory>  Base directory to scan (default: current directory)"
    echo "  -o <file>       Output archive path (default: env-backup-<base>-<timestamp>.tar.gz)"
    echo "  -r <depth>      Maximum search depth (default: unlimited)"
    echo "  -x \"dir1,dir2\"  Directories to exclude (comma-separated)"
    echo "  -e \"p1,p2\"      Extra file glob patterns to exclude, e.g. \"*.local,*.secret\""
    echo "  -n              Dry-run mode (list files without packaging)"
    echo "  -l <logfile>    Log output to file"
    echo ""
    echo -e "${BLUE}Restore options:${NC}"
    echo "  -a <file>       Archive to restore"
    echo "  -f, --force     Restore even if the checksum does not match"
    echo "  -n              Dry-run mode (show actions without writing)"
    echo "  -l <logfile>    Log output to file"
    echo ""
    echo -e "${BLUE}Restore behavior:${NC}"
    echo "  Existing .env files are renamed in place to <file>.bak.<timestamp>."
    echo "  Restored files always keep their original name."
    echo ""
    echo -e "${BLUE}Undo options:${NC}"
    echo "  -f, --force     Undo even if a file changed after the restore"
    echo "  -n              Dry-run mode (show actions without writing)"
    echo "  -l <logfile>    Log output to file"
    echo ""
    echo -e "${BLUE}Undo behavior:${NC}"
    echo "  Reverts the last restore: puts backups back and removes files that"
    echo "  did not exist before. Run it again to revert older restores."
    echo ""
    echo -e "${BLUE}Default excluded directories:${NC}"
    echo "  .git, node_modules, vendor, dist, build, venv, .venv, __pycache__, .cache"
    echo -e "${BLUE}Default excluded patterns:${NC}"
    echo "  *.example, *.example.*, *.sample, *.sample.*, *.template, *.template.*"
    echo "  *.bak, *.bak.*"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 pack -d ~/projects"
    echo "  $0 pack -d ~/projects -o ~/envs.tar.gz -x \"node_modules,.git\""
    echo "  $0 pack -d ~/projects -r 2 -e \"*.local,*.secret\" -n"
    echo "  $0 list -a ~/envs.tar.gz"
    echo "  $0 restore -a ~/envs.tar.gz -n"
    echo "  $0 restore -a ~/envs.tar.gz"
    echo ""
    echo -e "${YELLOW}Security:${NC} archives contain secrets in plain text (mode 600). Keep them safe."
}

check_deps() {
    local missing=()
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required commands: ${missing[*]}"
    fi
}

sanitize_name() {
    local name="$1"
    echo "$name" | tr -c 'A-Za-z0-9._-' '_' | sed 's/_*$//'
}

unique_path() {
    local base="$1"
    local candidate="$1"
    local n=1
    while [[ -e "$candidate" || -L "$candidate" ]]; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    echo "$candidate"
}

is_excluded_pattern() {
    local rel="$1"
    local name="${rel##*/}"
    local pattern
    for pattern in "${exclude_patterns[@]}"; do
        # shellcheck disable=SC2053
        if [[ "$rel" == $pattern || "$name" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

validate_depth() {
    [[ "$1" =~ ^[0-9]+$ ]] || die "-r must be a non-negative number"
}

cmd_pack() {
    local base="."
    local output=""
    local depth=0
    local dry_run=false
    local opt

    log_file=""
    exclude_patterns=("*.bak" "*.bak.*" "*.example" "*.example.*" "*.sample" "*.sample.*" "*.template" "*.template.*")
    local -a exclude_dirs=(".git" "node_modules" "vendor" "dist" "build" "venv" ".venv" "__pycache__" ".cache")

    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) args+=(-n) ;;
            --help)    args+=(-h) ;;
            --*)       die "Unknown option: $arg" ;;
            *)         args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    OPTIND=1
    while getopts "d:o:r:x:e:nl:h" opt; do
        case "$opt" in
            d) [[ -n "$OPTARG" ]] || die "-d requires a directory"; base="$OPTARG" ;;
            o) [[ -n "$OPTARG" ]] || die "-o requires a file"; output="$OPTARG" ;;
            r) [[ -n "$OPTARG" ]] || die "-r requires a number"; validate_depth "$OPTARG"; depth="$OPTARG" ;;
            x) [[ -n "$OPTARG" ]] || die "-x requires a directory list"
               local -a dirs
               IFS=',' read -ra dirs <<< "$OPTARG"
               local dir
               for dir in "${dirs[@]}"; do
                   dir="$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                   [[ -n "$dir" ]] && exclude_dirs+=("$dir")
               done
               ;;
            e) [[ -n "$OPTARG" ]] || die "-e requires a pattern list"
               local -a patterns
               IFS=',' read -ra patterns <<< "$OPTARG"
               local pattern
               for pattern in "${patterns[@]}"; do
                   pattern="$(echo "$pattern" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                   [[ -n "$pattern" ]] && exclude_patterns+=("$pattern")
               done
               ;;
            n) dry_run=true ;;
            l) [[ -n "$OPTARG" ]] || die "-l requires a file"
               log_file="$OPTARG"
               : > "$log_file" 2>/dev/null || die "Cannot write to log file: $log_file"
               ;;
            h) show_help; exit 0 ;;
            \?) show_help; exit 1 ;;
        esac
    done

    check_deps find tar sha256sum stat

    [[ -e "$base" ]] || die "Path does not exist: $base"
    [[ -d "$base" ]] || die "Path is not a directory: $base"
    [[ -r "$base" ]] || die "Directory is not readable: $base"

    local base_abs
    base_abs="$(cd "$base" && pwd -P)" || die "Cannot resolve path: $base"

    log "$GREEN" "Scanning for .env files in: $base_abs"
    [[ -n "$log_file" ]] && log "$BLUE" "Configuration:"

    local -a prune_expr=()
    local first=true
    local d
    for d in "${exclude_dirs[@]}"; do
        if $first; then
            prune_expr+=(-name "$d")
            first=false
        else
            prune_expr+=(-o -name "$d")
        fi
    done

    local -a find_args=("$base_abs")
    (( depth > 0 )) && find_args+=(-maxdepth "$depth")
    find_args+=(-type d \( "${prune_expr[@]}" \) -prune -o -type f \( -name ".env" -o -name ".env.*" \) -print0)

    local -a files=()
    local f rel
    while IFS= read -r -d '' f; do
        rel="${f#"$base_abs"/}"
        if [[ "$rel" == *$'\t'* || "$rel" == *$'\n'* || "$f" == *$'\t'* || "$f" == *$'\n'* ]]; then
            log "$YELLOW" "  Skipping path with tabs/newlines: $f"
            continue
        fi
        is_excluded_pattern "$rel" && continue
        files+=("$f")
    done < <(find "${find_args[@]}" 2>/dev/null | LC_ALL=C sort -z)

    if [[ ${#files[@]} -eq 0 ]]; then
        die "No .env files found in: $base_abs"
    fi

    local total_size=0
    for f in "${files[@]}"; do
        total_size=$((total_size + $(stat -c '%s' -- "$f")))
    done

    if $dry_run; then
        log "$YELLOW" "*** DRY-RUN - No archive will be created ***"
        echo ""
        printf "%-6s %-12s %s\n" "INDEX" "SIZE" "FILE"
        echo "--------------------------------------------------------------"
        local idx=0
        for f in "${files[@]}"; do
            idx=$((idx + 1))
            rel="${f#"$base_abs"/}"
            printf "%-6s %-12s %s\n" "$idx" "$(stat -c '%s' -- "$f")" "$rel"
        done
        echo ""
        log "$BLUE" "Total files: ${#files[@]}"
        log "$BLUE" "Total size:  $total_size bytes"
        exit 0
    fi

    stage="$(mktemp -d)" || die "Cannot create temporary directory"
    mkdir -p "$stage/files" || die "Cannot create staging directory"

    local manifest="$stage/manifest.tsv"
    {
        printf '# env-backup manifest v1\n'
        printf '# base: %s\n' "$base_abs"
        printf '# created: %s\n' "$(date -Iseconds)"
        printf '# INDEX\tABSOLUTE_PATH\tRELATIVE_PATH\tSIZE\tSHA256\tMODE\tMTIME\tARCHIVE_PATH\n'
    } > "$manifest" || die "Cannot create manifest"

    local idx=0
    local size sha mode mtime arch src dst parent
    for f in "${files[@]}"; do
        idx=$((idx + 1))
        rel="${f#"$base_abs"/}"
        arch="files/$rel"
        size="$(stat -c '%s' -- "$f")"
        mode="$(stat -c '%a' -- "$f")"
        mtime="$(stat -c '%Y' -- "$f")"
        sha="$(sha256sum -- "$f" | cut -d' ' -f1)"

        dst="$stage/$arch"
        parent="$(dirname -- "$dst")"
        mkdir -p -- "$parent" || die "Cannot create staging path: $parent"
        cp -p -- "$f" "$dst" || die "Cannot copy file to staging: $f"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$idx" "$f" "$rel" "$size" "$sha" "$mode" "$mtime" "$arch" >> "$manifest"
    done

    local created
    created="$(date -Iseconds)"
    {
        printf 'env-backup archive\n'
        printf 'Version: %s\n' "$VERSION"
        printf 'Created: %s\n' "$created"
        printf 'Base directory: %s\n' "$base_abs"
        printf 'Files: %s\n' "${#files[@]}"
        printf 'Total size: %s bytes\n' "$total_size"
        printf '\n'
        printf 'Restore with: env-backup restore -a <archive>\n'
        printf 'WARNING: this archive contains secrets in plain text.\n'
    } > "$stage/README.txt" || die "Cannot create archive README"

    local archive="$stage/env-backup.tar.gz"
    tar -czf "$archive" -C "$stage" manifest.tsv README.txt files || die "Cannot create archive"

    if [[ -z "$output" ]]; then
        local safe ts
        safe="$(sanitize_name "$(basename "$base_abs")")"
        ts="$(date +%Y%m%d-%H%M%S)"
        output="env-backup-${safe:-env}-${ts}.tar.gz"
    fi

    [[ -e "$output" ]] && die "Output file already exists: $output"
    local out_dir
    out_dir="$(dirname -- "$output")"
    mkdir -p -- "$out_dir" || die "Cannot create output directory: $out_dir"

    (umask 077 && mv -- "$archive" "$output") || die "Cannot write archive: $output"
    chmod 600 -- "$output" 2>/dev/null

    local abs_output
    abs_output="$(cd "$out_dir" && pwd -P)/$(basename -- "$output")"

    echo ""
    log "$BLUE" "============================================="
    log "$BLUE" "           PACKAGE SUMMARY                   "
    log "$BLUE" "============================================="
    log "$GREEN" "  Files packaged: ${#files[@]}"
    log "$BLUE" "  Total size:     $total_size bytes"
    log "$BLUE" "  Archive:        $abs_output"
    echo ""
    log "$YELLOW" "Warning: archive contains secrets in plain text. Keep it secure."
    if [[ -n "$log_file" ]]; then
        log "$GREEN" "Log saved to: $log_file"
    fi
}

validate_archive_members() {
    local archive="$1"
    local list_file="$2"
    tar -tzf "$archive" > "$list_file" 2>/dev/null || die "Cannot read archive: $archive"

    local member
    while IFS= read -r member; do
        case "$member" in
            manifest.tsv|README.txt|files/|files/*) ;;
            *) die "Unexpected archive member: $member" ;;
        esac
        case "$member" in
            /*|..|../*|*/../*|*/..) die "Unsafe archive member: $member" ;;
        esac
    done < "$list_file"

    grep -qx 'manifest.tsv' "$list_file" || die "Invalid archive: manifest.tsv not found"
}

cmd_restore() {
    local archive=""
    local force=false
    local dry_run=false
    local opt

    log_file=""
    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force)   args+=(-f) ;;
            --dry-run) args+=(-n) ;;
            --help)    args+=(-h) ;;
            --*)       die "Unknown option: $arg" ;;
            *)         args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    OPTIND=1
    while getopts "a:fnl:h" opt; do
        case "$opt" in
            a) [[ -n "$OPTARG" ]] || die "-a requires an archive"; archive="$OPTARG" ;;
            f) force=true ;;
            n) dry_run=true ;;
            l) [[ -n "$OPTARG" ]] || die "-l requires a file"
               log_file="$OPTARG"
               : > "$log_file" 2>/dev/null || die "Cannot write to log file: $log_file"
               ;;
            h) show_help; exit 0 ;;
            \?) show_help; exit 1 ;;
        esac
    done

    [[ -n "$archive" ]] || die "Archive is required (-a)"
    check_deps tar sha256sum

    [[ -e "$archive" ]] || die "Archive does not exist: $archive"
    [[ -f "$archive" ]] || die "Archive is not a file: $archive"
    [[ -r "$archive" ]] || die "Archive is not readable: $archive"

    stage="$(mktemp -d)" || die "Cannot create temporary directory"
    validate_archive_members "$archive" "$stage/members.txt"

    tar -xzf "$archive" -C "$stage" || die "Cannot extract archive: $archive"
    [[ -f "$stage/manifest.tsv" ]] || die "Invalid archive: manifest.tsv not found"

    local manifest="$stage/manifest.tsv"
    local run_ts journal
    run_ts="$(date +%Y%m%d-%H%M%S)"
    journal="$stage/journal.tsv"
    {
        printf '# env-backup restore journal v1\n'
        printf '# archive: %s\n' "$archive"
        printf '# date: %s\n' "$(date -Iseconds)"
        printf '# ACTION\tABSOLUTE_PATH\tBACKUP_PATH\tSHA256\n'
    } > "$journal" || die "Cannot create restore journal"

    log "$GREEN" "Restoring from: $archive"
    $dry_run && log "$YELLOW" "*** DRY-RUN - No files will be written ***"

    local idx abs rel size sha mode mtime arch
    local restored=0 backed_up=0 skipped=0 failed=0
    local journal_saved=false

    while IFS=$'\t' read -r idx abs rel size sha mode mtime arch; do
        [[ "$idx" == \#* || -z "$idx" ]] && continue

        case "$rel" in
            /*|..|../*|*/../*|*/..) log "$YELLOW" "  Skipping unsafe relative path: $rel"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$abs" in
            /*) ;;
            *) log "$YELLOW" "  Skipping non-absolute path: $abs"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$abs" in
            */../*|*/..|..) log "$YELLOW" "  Skipping unsafe absolute path: $abs"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$arch" in
            files/*) ;;
            *) log "$YELLOW" "  Skipping invalid archive path: $arch"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$arch" in
            *../*) log "$YELLOW" "  Skipping unsafe archive path: $arch"; skipped=$((skipped + 1)); continue ;;
        esac
        [[ "$arch" == "files/$rel" ]] || { log "$YELLOW" "  Skipping inconsistent manifest entry: $arch"; skipped=$((skipped + 1)); continue; }

        local src="$stage/$arch"
        if [[ -L "$src" || ! -f "$src" ]]; then
            log "$RED" "  Missing or invalid file in archive: $arch"
            failed=$((failed + 1))
            continue
        fi

        local actual_sha
        actual_sha="$(sha256sum -- "$src" | cut -d' ' -f1)"
        if [[ -n "$sha" && "${actual_sha,,}" != "${sha,,}" ]]; then
            if $force; then
                log "$YELLOW" "  Checksum mismatch (forced): $abs"
            else
                log "$RED" "  Checksum mismatch, skipping: $abs"
                failed=$((failed + 1))
                continue
            fi
        fi

        local parent
        parent="$(dirname -- "$abs")"
        local backup=""

        if [[ -d "$abs" ]]; then
            log "$RED" "  Target is a directory, skipping: $abs"
            failed=$((failed + 1))
            continue
        fi

        if [[ -e "$abs" || -L "$abs" ]]; then
            backup="$(unique_path "${abs}.bak.${run_ts}")"
            if $dry_run; then
                log "$YELLOW" "  [DRY-RUN] Would rename existing: $abs -> $backup"
            else
                mv -- "$abs" "$backup" || {
                    log "$RED" "  Cannot rename existing file: $abs"
                    failed=$((failed + 1))
                    continue
                }
                backed_up=$((backed_up + 1))
            fi
        fi

        if $dry_run; then
            log "$BLUE" "  [DRY-RUN] Would restore: $abs"
            restored=$((restored + 1))
            continue
        fi

        if ! mkdir -p -- "$parent"; then
            log "$RED" "  Cannot create directory: $parent"
            failed=$((failed + 1))
            continue
        fi

        if cp -p -- "$src" "$abs"; then
            if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
                chmod "$mode" -- "$abs" 2>/dev/null
            fi
            if [[ -n "$backup" ]]; then
                printf 'replaced\t%s\t%s\t%s\n' "$abs" "$backup" "$actual_sha" >> "$journal"
            else
                printf 'created\t%s\t-\t%s\n' "$abs" "$actual_sha" >> "$journal"
            fi
            log "$GREEN" "  Restored: $abs"
            restored=$((restored + 1))
        else
            log "$RED" "  Failed to restore: $abs"
            failed=$((failed + 1))
        fi
    done < "$manifest"

    if [[ "$restored" -gt 0 && "$dry_run" = false ]]; then
        local state_base journal_dir run_id
        state_base="${XDG_STATE_HOME:-${HOME:-$PWD}/.local/state}/env-backup/restores"
        run_id="${run_ts}-$$"
        if mkdir -p -- "$state_base" && chmod 700 -- "$state_base" 2>/dev/null; then
            journal_dir="$(unique_path "$state_base/$run_id")"
            if mkdir -p -- "$journal_dir" && chmod 700 -- "$journal_dir" 2>/dev/null \
                && mv -- "$journal" "$journal_dir/journal.tsv"; then
                chmod 600 -- "$journal_dir/journal.tsv" 2>/dev/null
                journal_saved=true
            else
                log "$YELLOW" "Warning: could not save undo journal in $state_base"
            fi
        else
            log "$YELLOW" "Warning: could not create undo journal directory: $state_base"
        fi
    fi

    echo ""
    log "$BLUE" "============================================="
    log "$BLUE" "           RESTORE SUMMARY                   "
    log "$BLUE" "============================================="
    log "$GREEN" "  Restored:  $restored"
    log "$BLUE" "  Backed up: $backed_up"
    if [[ "$backed_up" -gt 0 ]]; then
        log "$BLUE" "  Backup suffix: .bak.$run_ts"
    fi
    log "$BLUE" "  Skipped:   $skipped"
    log "$BLUE" "  Failed:    $failed"
    if $journal_saved; then
        log "$BLUE" "  Undo:      env-backup undo"
    fi
    $dry_run && log "$YELLOW" "*** DRY-RUN - No files were actually restored ***"
    echo ""
    [[ -n "$log_file" ]] && log "$GREEN" "Log saved to: $log_file"

    [[ "$failed" -gt 0 ]] && exit 1
    exit 0
}

cmd_undo() {
    local force=false
    local dry_run=false
    local opt

    log_file=""
    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --force)   args+=(-f) ;;
            --dry-run) args+=(-n) ;;
            --help)    args+=(-h) ;;
            --*)       die "Unknown option: $arg" ;;
            *)         args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    OPTIND=1
    while getopts "fnl:h" opt; do
        case "$opt" in
            f) force=true ;;
            n) dry_run=true ;;
            l) [[ -n "$OPTARG" ]] || die "-l requires a file"
               log_file="$OPTARG"
               : > "$log_file" 2>/dev/null || die "Cannot write to log file: $log_file"
               ;;
            h) show_help; exit 0 ;;
            \?) show_help; exit 1 ;;
        esac
    done

    check_deps sha256sum mv find

    local state_base journal_dir journal
    state_base="${XDG_STATE_HOME:-${HOME:-$PWD}/.local/state}/env-backup/restores"
    [[ -d "$state_base" ]] || die "No restores recorded in: $state_base"

    journal_dir="$(find "$state_base" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort | tail -1)"
    [[ -n "$journal_dir" ]] || die "No restores recorded in: $state_base"

    journal="$journal_dir/journal.tsv"
    [[ -f "$journal" ]] || die "Restore journal not found: $journal"

    local -a entries=()
    local line
    while IFS= read -r line; do
        [[ "$line" == \#* || -z "$line" ]] && continue
        entries+=("$line")
    done < "$journal"

    [[ ${#entries[@]} -gt 0 ]] || die "Restore journal is empty: $journal"

    log "$GREEN" "Undoing restore: $(basename -- "$journal_dir")"
    log "$BLUE" "Journal: $journal"
    $dry_run && log "$YELLOW" "*** DRY-RUN - Nothing will be changed ***"

    local restored=0 removed=0 skipped=0 failed=0 blocked=0
    local i action abs backup sha
    for ((i = ${#entries[@]} - 1; i >= 0; i--)); do
        IFS=$'\t' read -r action abs backup sha <<< "${entries[$i]}"

        case "$abs" in
            /*) ;;
            *) log "$YELLOW" "  Skipping non-absolute path: $abs"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$abs" in
            */../*|*/..|..) log "$YELLOW" "  Skipping unsafe path: $abs"; skipped=$((skipped + 1)); continue ;;
        esac
        case "$action" in
            created|replaced) ;;
            *) log "$YELLOW" "  Skipping unknown journal action: $action"; skipped=$((skipped + 1)); continue ;;
        esac

        if [[ -e "$abs" || -L "$abs" ]]; then
            if [[ -n "$sha" ]]; then
                local current_sha
                current_sha="$(sha256sum -- "$abs" | cut -d' ' -f1)"
                if [[ "${current_sha,,}" != "${sha,,}" ]]; then
                    if $force; then
                        log "$YELLOW" "  Modified since restore (forced): $abs"
                    else
                        log "$RED" "  Modified since restore, skipping: $abs"
                        blocked=$((blocked + 1))
                        continue
                    fi
                fi
            fi
        fi

        case "$action" in
            created)
                if [[ ! -e "$abs" && ! -L "$abs" ]]; then
                    log "$BLUE" "  Already absent: $abs"
                    skipped=$((skipped + 1))
                    continue
                fi
                if [[ -d "$abs" ]]; then
                    log "$RED" "  Target is a directory, cannot undo: $abs"
                    failed=$((failed + 1))
                    continue
                fi
                if $dry_run; then
                    log "$BLUE" "  [DRY-RUN] Would remove: $abs"
                    removed=$((removed + 1))
                    continue
                fi
                if rm -f -- "$abs"; then
                    log "$GREEN" "  Removed: $abs"
                    removed=$((removed + 1))
                else
                    log "$RED" "  Failed to remove: $abs"
                    failed=$((failed + 1))
                fi
                ;;
            replaced)
                case "$backup" in
                    "$abs".bak.*) ;;
                    *) log "$YELLOW" "  Skipping invalid backup path: $backup"; skipped=$((skipped + 1)); continue ;;
                esac
                if [[ ! -e "$backup" && ! -L "$backup" ]]; then
                    log "$RED" "  Backup not found: $backup"
                    failed=$((failed + 1))
                    continue
                fi
                if [[ -d "$abs" ]]; then
                    log "$RED" "  Target is a directory, cannot undo: $abs"
                    failed=$((failed + 1))
                    continue
                fi
                if $dry_run; then
                    log "$BLUE" "  [DRY-RUN] Would restore backup: $backup -> $abs"
                    restored=$((restored + 1))
                    continue
                fi
                if mkdir -p -- "$(dirname -- "$abs")" && mv -f -- "$backup" "$abs"; then
                    log "$GREEN" "  Reverted: $abs"
                    restored=$((restored + 1))
                else
                    log "$RED" "  Failed to revert: $abs"
                    failed=$((failed + 1))
                fi
                ;;
        esac
    done

    if ! $dry_run; then
        if [[ "$failed" -eq 0 && "$blocked" -eq 0 ]]; then
            rm -rf -- "$journal_dir"
            log "$GREEN" "Journal cleared."
        else
            log "$YELLOW" "Journal kept for retry: $journal_dir"
        fi
    fi

    echo ""
    log "$BLUE" "============================================="
    log "$BLUE" "            UNDO SUMMARY                     "
    log "$BLUE" "============================================="
    log "$GREEN" "  Reverted:  $restored"
    log "$BLUE" "  Removed:   $removed"
    log "$BLUE" "  Skipped:   $skipped"
    log "$BLUE" "  Blocked:   $blocked"
    log "$BLUE" "  Failed:    $failed"
    $dry_run && log "$YELLOW" "*** DRY-RUN - Nothing was actually changed ***"
    echo ""
    [[ -n "$log_file" ]] && log "$GREEN" "Log saved to: $log_file"

    [[ "$failed" -gt 0 || "$blocked" -gt 0 ]] && exit 1
    exit 0
}

cmd_list() {
    local archive=""
    local opt

    log_file=""
    local -a args=()
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help) args+=(-h) ;;
            --*)    die "Unknown option: $arg" ;;
            *)      args+=("$arg") ;;
        esac
    done
    set -- "${args[@]}"

    OPTIND=1
    while getopts "a:h" opt; do
        case "$opt" in
            a) [[ -n "$OPTARG" ]] || die "-a requires an archive"; archive="$OPTARG" ;;
            h) show_help; exit 0 ;;
            \?) show_help; exit 1 ;;
        esac
    done

    [[ -n "$archive" ]] || die "Archive is required (-a)"
    check_deps tar
    [[ -f "$archive" ]] || die "Archive does not exist: $archive"

    stage="$(mktemp -d)" || die "Cannot create temporary directory"
    tar -xzf "$archive" -C "$stage" manifest.tsv 2>/dev/null || die "Invalid archive: $archive"
    [[ -f "$stage/manifest.tsv" ]] || die "Invalid archive: manifest.tsv not found"

    local manifest="$stage/manifest.tsv"
    local base
    base="$(sed -n 's/^# base: //p' "$manifest" | head -1)"

    log "$GREEN" "Archive: $archive"
    [[ -n "$base" ]] && log "$BLUE" "Base:    $base"
    echo ""
    printf "%-6s %-10s %-6s %s\n" "INDEX" "SIZE" "MODE" "ORIGINAL PATH"
    echo "--------------------------------------------------------------------------"

    local idx abs rel size sha mode mtime arch
    local count=0
    while IFS=$'\t' read -r idx abs rel size sha mode mtime arch; do
        [[ "$idx" == \#* || -z "$idx" ]] && continue
        printf "%-6s %-10s %-6s %s\n" "$idx" "$size" "$mode" "$abs"
        count=$((count + 1))
    done < "$manifest"

    echo "--------------------------------------------------------------------------"
    log "$BLUE" "Total files: $count"
}

main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 1
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        pack)    cmd_pack "$@" ;;
        restore) cmd_restore "$@" ;;
        undo)    cmd_undo "$@" ;;
        list)    cmd_list "$@" ;;
        help|-h|--help) show_help ;;
        --version|-v) echo "env-backup $VERSION" ;;
        *) die "Unknown command: $cmd (use pack, restore, undo, list or help)" ;;
    esac
}

main "$@"
