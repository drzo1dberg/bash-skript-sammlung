#!/usr/bin/env bash
# Find the newest NVIDIA driver in NVIDIA's official Debian 13 repository
# that still lists every local NVIDIA display GPU as a Current GPU.
# Default mode is read-only. System changes require --apply and explicit,
# interactive confirmations at each write boundary.

set -Eeuo pipefail
umask 077
export LC_ALL=C

# Non-login SSH shells do not always include Debian's administrative paths.
# Append them (instead of prepending) so an explicitly supplied PATH remains
# useful for isolated tests, while dkms/modinfo/update-initramfs stay findable.
case ":${PATH:-}:" in
    *:/usr/sbin:*) ;;
    *) PATH="${PATH:+$PATH:}/usr/sbin" ;;
esac
case ":${PATH:-}:" in
    *:/sbin:*) ;;
    *) PATH="${PATH:+$PATH:}/sbin" ;;
esac
export PATH

readonly NVIDIA_REPO='https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64'
readonly SUPPORT_BASE='https://download.nvidia.com/XFree86/Linux-x86_64'

MODE=check
REBOOT_AFTER=0
TARGET_VERSION=
TARGET_UPSTREAM=
TARGET_BRANCH=
TARGET_PIN=
TARGET_PIN_VERSION=
INSTALLED_VERSION=
INSTALLED_PIN=
INSTALLED_PIN_VERSION=
BACKUP_DIR=
APPLY_GUARD=0
DRIVER_MUTATION_STARTED=0
MODE_SET=0

declare -a GPU_RECORDS=()
declare -a REPO_VERSIONS=()
declare -a DRIVER_PACKAGES=(nvidia-open)
declare -a DRIVER_REQUESTS=()
declare -a STOPPED_ACTIVE_UNITS=()

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)

usage() {
    cat <<'USAGE'
Usage:
  nvidia-latest-compatible.sh [--check]
  nvidia-latest-compatible.sh --apply [--reboot]
  nvidia-latest-compatible.sh --verify

  --check   Default and read-only. Check the existing local APT metadata.
  --apply   Snapshot, back up, simulate, download, stop GPU users, install,
            and validate. Requires exact interactive confirmations.
  --verify  Read-only post-reboot verification.
  --reboot  Only with --apply; still asks separately before rebooting.

Run --apply from SSH, a real TTY, or tmux with a tested recovery path.
Do not run the script through sudo; it requests sudo only when required.

--check never refreshes APT and therefore uses the package lists already on
disk. --apply asks before running apt-get update and recomputes the plan.
The installed NVIDIA pin is branch-scoped: for example, pin 610 accepts future
610.* updates. Run this tool again when a newer driver branch appears.
USAGE
}

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

apply_exit_handler() {
    local rc=$1 unit
    trap - EXIT
    if (( APPLY_GUARD == 1 && rc != 0 )); then
        if (( DRIVER_MUTATION_STARTED == 0 && ${#STOPPED_ACTIVE_UNITS[@]} > 0 )); then
            warn 'Apply failed before the driver package mutation; restoring previously active services.'
            for unit in "${STOPPED_ACTIVE_UNITS[@]}"; do
                if ! run_root systemctl start "$unit"; then
                    warn "Could not restart $unit; start it manually from SSH/TTY."
                fi
            done
        elif (( DRIVER_MUTATION_STARTED == 1 )); then
            warn 'The driver package mutation started. GDM/Jellyfin remain stopped intentionally.'
            warn 'From SSH/TTY run: sudo dpkg --configure -a'
            warn 'Then run: sudo apt-get -f install'
            warn 'Then run: sudo update-initramfs -u -k all'
            warn 'Finally run: sudo systemctl reboot'
            [[ -z $BACKUP_DIR ]] || warn "Recovery record: $BACKUP_DIR/RECOVERY.md"
        fi
    fi
    exit "$rc"
}

acquire_apply_lock() {
    local lock_file="/tmp/nvidia-latest-compatible-${UID}.lock"
    need_command flock
    if [[ -e $lock_file || -L $lock_file ]]; then
        [[ -f $lock_file && -O $lock_file && ! -L $lock_file ]] ||
            die "Unsafe existing lock path: $lock_file"
    else
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null ||
            die "Could not create apply lock: $lock_file"
    fi
    exec 9>>"$lock_file"
    flock -n 9 || die 'Another nvidia-latest-compatible --apply process is running.'
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

is_official_repo_origin() {
    local origin=$1 repo index extra
    read -r repo index extra <<< "$origin"
    [[ $repo == "$NVIDIA_REPO" && $index == Packages && -z $extra ]]
}

highest_official_package_version() {
    local expected=$1 package version origin highest=
    while IFS='|' read -r package version origin; do
        package=$(trim "$package")
        version=$(trim "$version")
        origin=$(trim "$origin")
        [[ $package == "$expected" ]] || continue
        is_official_repo_origin "$origin" || continue
        dpkg --validate-version "$version" >/dev/null 2>&1 ||
            die "Invalid version for $expected in NVIDIA repository metadata: $version"
        if [[ -z $highest ]] || dpkg --compare-versions "$version" gt "$highest"; then
            highest=$version
        fi
    done < <(apt-cache madison "$expected")
    [[ -n $highest ]] || return 1
    printf '%s\n' "$highest"
}

parse_debian_version() {
    local version=$1
    local without_epoch

    dpkg --validate-version "$version" >/dev/null 2>&1 ||
        die "APT returned an invalid Debian version: $version"
    without_epoch=$version
    if [[ $without_epoch == *:* ]]; then
        [[ ${without_epoch%%:*} =~ ^[0-9]+$ ]] ||
            die "Unsupported epoch syntax: $version"
        without_epoch=${without_epoch#*:}
    fi
    if [[ $without_epoch =~ ^([0-9]+([.][0-9]+)+)-[0-9]+([+~][A-Za-z0-9.+~_-]+)?$ ]]; then
        printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[1]%%.*}"
    else
        die "Refusing to guess NVIDIA upstream version from: $version"
    fi
}

discover_gpus() {
    local row address device subvendor subdevice

    mapfile -t GPU_RECORDS < <(
        lspci -Dnmm |
            awk '
                {
                    class=$2; vendor=$3; device=$4
                    gsub(/"/, "", class)
                    gsub(/"/, "", vendor)
                    gsub(/"/, "", device)
                    if (tolower(vendor) != "10de" || class !~ /^03[0-9A-Fa-f][0-9A-Fa-f]$/)
                        next
                    subvendor="----"; subdevice="----"
                    if (NF >= 6) {
                        subvendor=$(NF-1); subdevice=$NF
                        gsub(/"/, "", subvendor)
                        gsub(/"/, "", subdevice)
                    }
                    printf "%s|%s|%s|%s\n", $1, toupper(device), toupper(subvendor), toupper(subdevice)
                }
            '
    )
    ((${#GPU_RECORDS[@]} > 0)) ||
        die 'No NVIDIA PCI display-class device was found.'

    log 'Detected NVIDIA display GPU(s):'
    for row in "${GPU_RECORDS[@]}"; do
        IFS='|' read -r address device subvendor subdevice <<< "$row"
        printf '  %s device=%s subsystem=%s:%s\n' \
            "$address" "$device" "$subvendor" "$subdevice"
    done
}

discover_repo_versions() {
    local package version origin
    local -A seen=()

    REPO_VERSIONS=()
    while IFS='|' read -r package version origin; do
        package=$(trim "$package")
        version=$(trim "$version")
        origin=$(trim "$origin")
        [[ $package == nvidia-open ]] || continue
        is_official_repo_origin "$origin" || continue
        [[ -n $version ]] || continue
        dpkg --validate-version "$version" >/dev/null 2>&1 ||
            die "Invalid version in NVIDIA repository metadata: $version"
        if [[ -z ${seen[$version]+x} ]]; then
            REPO_VERSIONS+=("$version")
            seen[$version]=1
        fi
    done < <(apt-cache madison nvidia-open)
    ((${#REPO_VERSIONS[@]} > 0)) ||
        die "No nvidia-open versions found from exact repository $NVIDIA_REPO"
}

version_page_supports_all_gpus() {
    local deb_version=$1 parsed upstream url html current row
    local address device subvendor subdevice

    parsed=$(parse_debian_version "$deb_version")
    IFS='|' read -r upstream _ <<< "$parsed"
    url="$SUPPORT_BASE/$upstream/README/supportedchips.html"
    log "Checking NVIDIA Current-GPU table for $deb_version"
    if ! html=$(curl --fail --location --silent --show-error --compressed \
        --connect-timeout 10 --max-time 45 --max-redirs 3 \
        --max-filesize 3000000 --proto '=https' --proto-redir '=https' \
        "$url"); then
        warn "Could not retrieve authoritative support table: $url"
        return 2
    fi

    if ! current=$(
        awk '
            BEGIN { in_current=0; saw_current=0; saw_legacy=0 }
            /name="Current"[[:space:]]+id="Current"/ || /id="Current"[[:space:]]+name="Current"/ {
                in_current=1; saw_current=1
            }
            in_current && /name="legacy_/ { saw_legacy=1; exit }
            in_current { print }
            END { if (!saw_current || !saw_legacy) exit 42 }
        ' <<< "$html"
    ); then
        warn "Support-page structure was not understood: $url"
        return 3
    fi
    [[ -n $current ]] || return 3

    for row in "${GPU_RECORDS[@]}"; do
        IFS='|' read -r address device subvendor subdevice <<< "$row"
        if grep -Fqi "id=\"devid${device}\"" <<< "$current"; then
            continue
        fi
        if [[ $subvendor != ---- && $subdevice != ---- ]] &&
            grep -Fqi "id=\"devid${device}_${subvendor}_${subdevice}\"" <<< "$current"; then
            continue
        fi
        warn "$address ($device $subvendor:$subdevice) is not Current in $upstream"
        return 1
    done
    return 0
}

select_highest_compatible() {
    local -a remaining=("${REPO_VERSIONS[@]}") next=()
    local highest version parsed rc

    while ((${#remaining[@]} > 0)); do
        highest=${remaining[0]}
        for version in "${remaining[@]:1}"; do
            dpkg --compare-versions "$version" gt "$highest" && highest=$version
        done

        if version_page_supports_all_gpus "$highest"; then
            TARGET_VERSION=$highest
            parsed=$(parse_debian_version "$TARGET_VERSION")
            IFS='|' read -r TARGET_UPSTREAM TARGET_BRANCH <<< "$parsed"
            TARGET_PIN="nvidia-driver-pinning-$TARGET_BRANCH"
            break
        else
            rc=$?
            case $rc in
                1) log "$highest is not compatible; trying the next older repository version." ;;
                2|3) die "Compatibility of $highest could not be proven; refusing fallback." ;;
                *) die "Unexpected support-check result for $highest: $rc" ;;
            esac
        fi
        next=()
        for version in "${remaining[@]}"; do
            [[ $version == "$highest" ]] || next+=("$version")
        done
        remaining=("${next[@]}")
    done

    [[ -n $TARGET_VERSION ]] ||
        die 'No repository version supports all local GPUs as Current GPUs.'
    if ! TARGET_PIN_VERSION=$(highest_official_package_version "$TARGET_PIN"); then
        die "Official branch pin package is unavailable: $TARGET_PIN"
    fi
}

read_installed_state() {
    local installed_pin_record
    INSTALLED_VERSION=$(dpkg-query -W -f='${Version}' nvidia-open 2>/dev/null) ||
        die 'nvidia-open is not installed; this tool only maintains an existing packaged installation.'
    installed_pin_record=$(
        { dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' 'nvidia-driver-pinning-*' 2>/dev/null || true; } |
            awk '$3 == "install" && $4 == "ok" && $5 == "installed" { print $1 "|" $2 }'
    )
    [[ $installed_pin_record != *$'\n'* ]] || die 'More than one NVIDIA pinning package is installed.'
    IFS='|' read -r INSTALLED_PIN INSTALLED_PIN_VERSION <<< "$installed_pin_record"

    DRIVER_PACKAGES=(nvidia-open)
    DRIVER_REQUESTS=("nvidia-open=$TARGET_VERSION")
    if [[ $(dpkg-query -W -f='${Status}' nvidia-driver-libs:i386 2>/dev/null || true) == 'install ok installed' ]]; then
        DRIVER_PACKAGES+=(nvidia-driver-libs:i386)
        DRIVER_REQUESTS+=("nvidia-driver-libs:i386=$TARGET_VERSION")
    fi
}

is_nvidia_stack_package() {
    local package=${1%%:*}
    [[ $package =~ ^(firmware-nvidia-gsp|libcuda1|libcudadebugger1|libegl-nvidia0|libgles-nvidia1|libgles-nvidia2|libglx-nvidia0|libnvcuvid1|libnvidia-.*|libnvoptix1|libxnvctrl0|nvidia-.*|xserver-xorg-video-nvidia)$ ]]
}

audit_driver_simulation() {
    local output=$1 expected=$2 line package
    if grep -Eq '^(Remv|Purg) ' <<< "$output"; then
        printf '%s\n' "$output" >&2
        die 'Driver simulation contains a package removal.'
    fi
    while IFS= read -r line; do
        [[ $line == Inst\ * ]] || continue
        package=${line#Inst }
        package=${package%% *}
        is_nvidia_stack_package "$package" || {
            printf '%s\n' "$output" >&2
            die "Simulation changes a non-NVIDIA package: $package"
        }
        [[ $line == *"($expected "* || $line == *"($expected)"* ]] || {
            printf '%s\n' "$output" >&2
            die "Simulation contains a mixed version: $line"
        }
    done <<< "$output"
}

preliminary_driver_simulation() {
    local output
    if ! output=$(apt-get -s -V \
        -o Dir::Etc::preferences=/dev/null \
        -o Dir::Etc::preferencesparts=/nonexistent-nvidia-preferences \
        install "${DRIVER_REQUESTS[@]}" 2>&1); then
        printf '%s\n' "$output" >&2
        die 'Preliminary target-version simulation failed.'
    fi
    audit_driver_simulation "$output" "$TARGET_VERSION"
    log 'Preliminary simulation: no removals, unrelated packages, or mixed NVIDIA versions.'
}

show_plan() {
    printf '\nNVIDIA latest-compatible plan\n'
    printf '  Installed driver : %s\n' "$INSTALLED_VERSION"
    printf '  Installed pin    : %s\n' "${INSTALLED_PIN:-none}${INSTALLED_PIN_VERSION:+ ($INSTALLED_PIN_VERSION)}"
    printf '  Target driver    : %s\n' "$TARGET_VERSION"
    printf '  Target branch    : %s\n' "$TARGET_BRANCH"
    printf '  Target pin       : %s (%s)\n' "$TARGET_PIN" "$TARGET_PIN_VERSION"
    printf '  Preserved i386   : %s\n\n' "$([[ ${#DRIVER_PACKAGES[@]} -gt 1 ]] && printf yes || printf no)"

    if dpkg --compare-versions "$INSTALLED_VERSION" gt "$TARGET_VERSION"; then
        warn 'Installed driver is newer than the highest proven-compatible repository version.'
        warn 'Automatic downgrade is disabled.'
    elif [[ $INSTALLED_VERSION == "$TARGET_VERSION" && $INSTALLED_PIN == "$TARGET_PIN" &&
        $INSTALLED_PIN_VERSION == "$TARGET_PIN_VERSION" ]]; then
        log 'Already on the highest compatible version and correct branch pin.'
    elif [[ $INSTALLED_VERSION == "$TARGET_VERSION" ]]; then
        log 'Driver is current; only the branch pin differs.'
    else
        log 'A compatible upgrade is available.'
    fi
}

check_common_environment() {
    local command
    for command in apt-cache apt-get awk curl dpkg dpkg-query grep lspci; do
        need_command "$command"
    done
    [[ $(dpkg --print-architecture) == amd64 ]] ||
        die 'This script is limited to Debian amd64.'
    grep -Eq '^VERSION_ID="?13"?$' /etc/os-release ||
        die 'This script is limited to Debian 13.'
}

perform_discovery() {
    discover_gpus
    discover_repo_versions
    select_highest_compatible
    read_installed_state
}

verify_candidates_after_pin() {
    local package candidate
    local -a packages=(
        nvidia-open nvidia-driver nvidia-kernel-open-dkms nvidia-driver-libs:amd64
    )
    [[ ${#DRIVER_PACKAGES[@]} -gt 1 ]] && packages+=(nvidia-driver-libs:i386)
    for package in "${packages[@]}"; do
        candidate=$(apt-cache policy "$package" |
            awk '/^[[:space:]]*Candidate:/ { candidate=$2 } END { print candidate }')
        [[ $candidate == "$TARGET_VERSION" ]] ||
            die "Candidate mismatch: $package -> $candidate (wanted $TARGET_VERSION)"
    done
}

simulate_pin_switch() {
    local output line package saw_target=0
    if ! output=$(apt-get -s -V install --purge "$TARGET_PIN=$TARGET_PIN_VERSION" 2>&1); then
        printf '%s\n' "$output" >&2
        die 'Pin-package simulation failed.'
    fi
    while IFS= read -r line; do
        if [[ $line == Inst\ * ]]; then
            package=${line#Inst }
            package=${package%% *}
            [[ $package == "$TARGET_PIN" ]] || {
                printf '%s\n' "$output" >&2
                die "Pin simulation installs an unexpected package: $package"
            }
            saw_target=1
        elif [[ $line == Remv\ * || $line == Purg\ * ]]; then
            package=${line#* }
            package=${package%% *}
            [[ -n $INSTALLED_PIN && $package == "$INSTALLED_PIN" ]] || {
                printf '%s\n' "$output" >&2
                die "Pin simulation removes an unexpected package: $package"
            }
        fi
    done <<< "$output"
    (( saw_target == 1 )) || die "Pin simulation did not install $TARGET_PIN."
    printf '%s\n' "$output"
}

definitive_driver_simulation() {
    local output
    if ! output=$(apt-get -s -V install "${DRIVER_REQUESTS[@]}" 2>&1); then
        printf '%s\n' "$output" >&2
        die 'Definitive driver simulation failed.'
    fi
    audit_driver_simulation "$output" "$TARGET_VERSION"
    printf '%s\n' "$output"
}

confirm_exact() {
    local expected=$1 prompt=$2 answer
    printf '%s\n' "$prompt"
    printf 'Type exactly: %s\n> ' "$expected"
    IFS= read -r answer
    [[ $answer == "$expected" ]] || die 'Confirmation did not match; stopping.'
}

choose_mode() {
    local requested=$1
    (( MODE_SET == 0 )) || die 'Choose exactly one of --check, --apply, or --verify.'
    MODE=$requested
    MODE_SET=1
}

check_rescue_context() {
    local terminal
    terminal=$(tty 2>/dev/null || true)
    if [[ -z ${SSH_CONNECTION:-} && -z ${TMUX:-} && ! $terminal =~ ^/dev/tty[0-9]+$ ]]; then
        die '--apply requires SSH, tmux, or a real Linux TTY.'
    fi
    [[ -t 0 && -t 1 ]] || die '--apply requires an interactive terminal.'
}

create_snapshot_and_backup() {
    local timestamp comment snapshot_output snapshot_list snapshot_name
    timestamp=$(date +%Y%m%d-%H%M%S)
    comment="before NVIDIA $TARGET_UPSTREAM via nvidia-latest-compatible"
    BACKUP_DIR="$SCRIPT_DIR/nvidia-driver-backups/$timestamp-before-$TARGET_UPSTREAM"

    install -d -m 700 "$BACKUP_DIR"
    log "Creating Timeshift snapshot: $comment"
    if ! snapshot_output=$(run_root timeshift --create --comments "$comment" --tags O 2>&1); then
        printf '%s\n' "$snapshot_output" | tee "$BACKUP_DIR/timeshift-create.txt" >&2
        die 'Timeshift snapshot creation failed.'
    fi
    printf '%s\n' "$snapshot_output" | tee "$BACKUP_DIR/timeshift-create.txt"
    if ! snapshot_list=$(run_root timeshift --list 2>&1); then
        printf '%s\n' "$snapshot_list" > "$BACKUP_DIR/timeshift-list.after.txt"
        die 'Snapshot was created, but its exact identifier could not be listed.'
    fi
    printf '%s\n' "$snapshot_list" > "$BACKUP_DIR/timeshift-list.after.txt"
    snapshot_name=$(awk -v comment="$comment" '
        index($0, comment) {
            for (i=1; i<=NF; i++)
                if ($i ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$/)
                    found=$i
        }
        END { print found }
    ' <<< "$snapshot_list")
    [[ -n $snapshot_name ]] || die 'Snapshot exists, but its exact identifier was not found in Timeshift output.'

    if [[ -e /etc/apt/preferences.d/nvidia-driver-pin ]]; then
        cp -a -- /etc/apt/preferences.d/nvidia-driver-pin \
            "$BACKUP_DIR/nvidia-driver-pin.before"
    fi
    dpkg-query -W > "$BACKUP_DIR/dpkg-query-W.before.txt"
    apt-cache policy nvidia-open nvidia-driver nvidia-kernel-open-dkms \
        nvidia-driver-libs:amd64 nvidia-driver-libs:i386 \
        > "$BACKUP_DIR/apt-policy.before.txt"
    dkms status > "$BACKUP_DIR/dkms.before.txt"
    printf '%s\n' \
        "target_version=$TARGET_VERSION" \
        "target_upstream=$TARGET_UPSTREAM" \
        "target_branch=$TARGET_BRANCH" \
        "target_pin=$TARGET_PIN" \
        "target_pin_version=$TARGET_PIN_VERSION" \
        "installed_version_before=$INSTALLED_VERSION" \
        "installed_pin_before=${INSTALLED_PIN:-none}" \
        "installed_pin_version_before=${INSTALLED_PIN_VERSION:-none}" \
        "timeshift_snapshot=$snapshot_name" \
        > "$BACKUP_DIR/plan.txt"
    {
        printf '# NVIDIA recovery record\n\n'
        printf 'Timeshift snapshot: %s\n\n' "$snapshot_name"
        printf 'Before: driver %s, pin %s (%s)\n\n' \
            "$INSTALLED_VERSION" "${INSTALLED_PIN:-none}" "${INSTALLED_PIN_VERSION:-none}"
        printf 'Planned: driver %s, pin %s (%s)\n\n' \
            "$TARGET_VERSION" "$TARGET_PIN" "$TARGET_PIN_VERSION"
        printf 'If an install fails after GDM stops, stay in SSH/TTY and run:\n\n'
        printf '```bash\n'
        printf 'sudo dpkg --configure -a\n'
        printf 'sudo apt-get -f install\n'
        printf 'sudo update-initramfs -u -k all\n'
        printf 'sudo apt-get check\n'
        printf 'sudo dpkg --audit\n'
        printf 'sudo systemctl reboot\n'
        printf '```\n\n'
        printf 'Do not restart GDM between a partial NVIDIA package transaction and reboot.\n'
    } > "$BACKUP_DIR/RECOVERY.md"
    sha256sum "$BACKUP_DIR"/* > "$BACKUP_DIR/SHA256SUMS.before"
    log "Recovery files: $BACKUP_DIR"
}

preflight_apply() {
    local audit holds running_kernel command
    for command in apt-mark cat cp date dkms fuser install modinfo nvidia-smi ps sed sha256sum sudo systemctl tee timeshift uname update-initramfs; do
        need_command "$command"
    done
    (( EUID != 0 )) || die 'Run as the regular desktop user, not through sudo.'
    check_rescue_context
    run_root true
    run_root apt-get check

    audit=$(dpkg --audit)
    [[ -z $audit ]] || { printf '%s\n' "$audit" >&2; die 'dpkg audit is not clean.'; }
    holds=$(apt-mark showhold)
    [[ -z $holds ]] || { printf '%s\n' "$holds" >&2; die 'APT holds require manual review.'; }
    running_kernel=$(uname -r)
    [[ $(dpkg-query -W -f='${Status}' "linux-headers-$running_kernel" 2>/dev/null || true) == 'install ok installed' ]] ||
        die "Headers are missing for running kernel: $running_kernel"
}

stop_gpu_users() {
    local unit status output pid comm maps fuser_rc fuser_stdout fuser_stderr
    local -a units=(gdm3.service jellyfin.service nvidia-persistenced.service nvidia-powerd.service)
    local -a device_nodes=() pids=()

    STOPPED_ACTIVE_UNITS=()
    for unit in "${units[@]}"; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            status=$(systemctl is-active "$unit" 2>/dev/null || true)
            case $status in
                active|activating|reloading)
                    STOPPED_ACTIVE_UNITS+=("$unit")
                    run_root systemctl stop "$unit"
                    ;;
                inactive|failed) ;;
                *) die "Unexpected service state before stop: $unit ($status)" ;;
            esac
        fi
    done
    for unit in "${units[@]}"; do
        if systemctl cat "$unit" >/dev/null 2>&1; then
            status=$(systemctl is-active "$unit" 2>/dev/null || true)
            [[ $status == inactive || $status == failed ]] ||
                die "GPU user service did not stop: $unit ($status)"
        fi
    done

    if ! output=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
        --format=csv,noheader 2>&1); then
        printf '%s\n' "$output" >&2
        die 'nvidia-smi could not prove that compute clients are absent.'
    fi
    [[ -z $output ]] || { printf '%s\n' "$output" >&2; die 'NVIDIA compute clients remain.'; }

    shopt -s nullglob
    device_nodes=(/dev/nvidia* /dev/dri/card* /dev/dri/renderD*)
    shopt -u nullglob
    if ((${#device_nodes[@]} > 0)); then
        fuser_stdout="$BACKUP_DIR/fuser.stdout.txt"
        fuser_stderr="$BACKUP_DIR/fuser.stderr.txt"
        if run_root fuser "${device_nodes[@]}" >"$fuser_stdout" 2>"$fuser_stderr"; then
            fuser_rc=0
        else
            fuser_rc=$?
        fi
        case $fuser_rc in
            0)
                [[ -s $fuser_stdout ]] || die 'fuser reported users but returned no PIDs.'
                ;;
            1)
                [[ ! -s $fuser_stdout && ! -s $fuser_stderr ]] || {
                    sed -n '1,80p' "$fuser_stderr" >&2
                    die 'fuser failed while checking GPU/DRM users.'
                }
                ;;
            *)
                sed -n '1,80p' "$fuser_stderr" >&2
                die "fuser failed with status $fuser_rc."
                ;;
        esac
        output=$(<"$fuser_stdout")
        mapfile -t pids < <(
            tr ' ' '\n' <<< "$output" |
                awk '/^[0-9]+$/ && !seen[$0]++ { print }'
        )
        (( fuser_rc != 0 || ${#pids[@]} > 0 )) ||
            die 'fuser output could not be parsed into PIDs.'
    fi
    for pid in "${pids[@]}"; do
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
        if [[ $comm == tmux* ]]; then
            if ! maps=$(run_root cat "/proc/$pid/maps" 2>/dev/null); then
                die "Could not inspect memory maps for tmux PID $pid."
            fi
            if ! grep -Eqi 'nvidia|libcuda|libdrm' <<< "$maps"; then
                warn "Allowing inherited inactive render FD held by tmux PID $pid."
                continue
            fi
        fi
        die "Unexpected GPU/DRM user remains: PID $pid ($comm)"
    done
}

validate_installed_driver_on_disk() {
    local disk_version disk_license audit dkms_output dkms_rows kernel build
    run_root apt-get check
    audit=$(dpkg --audit)
    [[ -z $audit ]] || { printf '%s\n' "$audit" >&2; die 'dpkg audit failed.'; }

    disk_version=$(modinfo -F version nvidia)
    disk_license=$(modinfo -F license nvidia)
    [[ $disk_version == "$TARGET_UPSTREAM" ]] ||
        die "On-disk module mismatch: $disk_version (wanted $TARGET_UPSTREAM)"
    [[ $disk_license == 'Dual MIT/GPL' ]] ||
        die "Unexpected module license: $disk_license"

    dkms_output=$(dkms status)
    for build in /lib/modules/*/build; do
        [[ -e $build ]] || continue
        kernel=${build%/build}
        kernel=${kernel##*/}
        dkms_rows=$(grep -F "nvidia/$TARGET_UPSTREAM, $kernel, " <<< "$dkms_output" || true)
        grep -Fq ': installed' <<< "$dkms_rows" ||
            die "DKMS is not installed for kernel: $kernel"
    done
    verify_candidates_after_pin

    dpkg-query -W > "$BACKUP_DIR/dpkg-query-W.after.txt"
    dkms status > "$BACKUP_DIR/dkms.after.txt"
    apt-cache policy nvidia-open nvidia-driver nvidia-kernel-open-dkms \
        nvidia-driver-libs:amd64 nvidia-driver-libs:i386 \
        > "$BACKUP_DIR/apt-policy.after.txt"
    sha256sum "$BACKUP_DIR"/* > "$BACKUP_DIR/SHA256SUMS.after"
}

apply_upgrade() {
    local pin_plan pin_recheck definitive_plan definitive_recheck installed_pin_after loaded answer

    acquire_apply_lock
    APPLY_GUARD=1
    trap 'apply_exit_handler $?' EXIT
    preflight_apply
    confirm_exact 'REFRESH NVIDIA' \
        'This refreshes APT package metadata, then recomputes the compatible NVIDIA target.'
    run_root apt-get update

    perform_discovery
    preliminary_driver_simulation
    show_plan
    dpkg --compare-versions "$INSTALLED_VERSION" gt "$TARGET_VERSION" &&
        die 'Automatic downgrade is disabled.'
    if [[ $INSTALLED_VERSION == "$TARGET_VERSION" && $INSTALLED_PIN == "$TARGET_PIN" &&
        $INSTALLED_PIN_VERSION == "$TARGET_PIN_VERSION" ]]; then
        log 'Nothing to apply after refreshing APT metadata.'
        return 0
    fi

    confirm_exact "PLAN $TARGET_VERSION" \
        'This creates a Timeshift snapshot and a repo-local recovery record.'
    create_snapshot_and_backup

    if [[ $INSTALLED_PIN != "$TARGET_PIN" || $INSTALLED_PIN_VERSION != "$TARGET_PIN_VERSION" ]]; then
        pin_plan=$(simulate_pin_switch)
        printf '%s\n' "$pin_plan" > "$BACKUP_DIR/pin-simulation.txt"
        confirm_exact "PIN $TARGET_BRANCH" \
            'Pin simulation passed. Only the installed older pin package may be removed.'
        pin_recheck=$(simulate_pin_switch)
        [[ $pin_recheck == "$pin_plan" ]] ||
            die 'Pin transaction changed after confirmation; rerun --apply.'
        run_root apt-get -V install --purge "$TARGET_PIN=$TARGET_PIN_VERSION"
        installed_pin_after=$(dpkg-query -W -f='${binary:Package}|${Version}|${Status}' "$TARGET_PIN")
        [[ $installed_pin_after == "$TARGET_PIN|$TARGET_PIN_VERSION|install ok installed" ]] ||
            die 'Target branch pin was not installed.'
    else
        log "$TARGET_PIN is already installed; no pin transaction is needed."
    fi
    verify_candidates_after_pin

    if [[ $INSTALLED_VERSION == "$TARGET_VERSION" ]]; then
        validate_installed_driver_on_disk
        loaded=$(sed -n 's/^NVRM version:.*  \([0-9][0-9.]*\)  .*/\1/p' \
            /proc/driver/nvidia/version 2>/dev/null || true)
        if [[ $loaded == "$TARGET_UPSTREAM" ]]; then
            log 'Branch pin updated; the loaded and installed driver were already current. No reboot is needed.'
        else
            warn "Branch pin updated, but loaded module '${loaded:-unknown}' differs from $TARGET_UPSTREAM."
            log 'Run: sudo systemctl reboot'
        fi
        return 0
    fi

    definitive_plan=$(definitive_driver_simulation)
    printf '%s\n' "$definitive_plan" > "$BACKUP_DIR/driver-simulation.txt"
    printf '%s\n' "$definitive_plan"
    confirm_exact "INSTALL $TARGET_VERSION" \
        'Final transaction shown above. Download happens before desktop and Jellyfin stop.'
    definitive_recheck=$(definitive_driver_simulation)
    [[ $definitive_recheck == "$definitive_plan" ]] ||
        die 'Driver transaction changed after confirmation; rerun --apply.'

    run_root apt-get --download-only -V --no-remove install "${DRIVER_REQUESTS[@]}"
    stop_gpu_users
    DRIVER_MUTATION_STARTED=1
    if ! run_root apt-get --no-download -V --no-remove install "${DRIVER_REQUESTS[@]}"; then
        die 'APT failed after desktop stop. Do not start GDM; repair APT from TTY/SSH.'
    fi
    run_root update-initramfs -u -k all
    validate_installed_driver_on_disk

    log "NVIDIA $TARGET_UPSTREAM is installed on disk and ready for reboot."
    warn 'The old module remains in RAM until reboot; do not run nvidia-smi or restart GDM.'
    printf 'Recovery files: %s\n' "$BACKUP_DIR"
    if (( REBOOT_AFTER )); then
        printf 'Type exactly REBOOT to reboot now, or anything else to stay in TTY/SSH:\n> '
        IFS= read -r answer
        if [[ $answer == REBOOT ]]; then
            run_root systemctl reboot
        else
            log 'Not rebooting. Run: sudo systemctl reboot'
        fi
    else
        log 'Run now: sudo systemctl reboot'
    fi
}

verify_after_reboot() {
    local installed parsed upstream branch pin_status loaded disk dkms_output dkms_rows address row
    local errors kernel_log jellyfin_enabled command

    for command in dkms journalctl ldconfig lsmod modinfo nvidia-smi systemctl; do
        need_command "$command"
    done
    discover_gpus
    installed=$(dpkg-query -W -f='${Version}' nvidia-open 2>/dev/null) ||
        die 'nvidia-open is not installed.'
    parsed=$(parse_debian_version "$installed")
    IFS='|' read -r upstream branch <<< "$parsed"
    pin_status=$(dpkg-query -W -f='${Status}' "nvidia-driver-pinning-$branch" 2>/dev/null || true)
    [[ $pin_status == 'install ok installed' ]] ||
        die "Expected branch pin is not installed: nvidia-driver-pinning-$branch"

    loaded=$(sed -n 's/^NVRM version:.*  \([0-9][0-9.]*\)  .*/\1/p' \
        /proc/driver/nvidia/version)
    disk=$(modinfo -F version nvidia)
    [[ $loaded == "$upstream" ]] || die "Loaded module mismatch: $loaded vs $upstream"
    [[ $disk == "$upstream" ]] || die "On-disk module mismatch: $disk vs $upstream"

    nvidia-smi \
        --query-gpu=name,pci.device_id,driver_version,display_active,memory.total,temperature.gpu \
        --format=csv,noheader
    for row in "${GPU_RECORDS[@]}"; do
        IFS='|' read -r address _ <<< "$row"
        grep -Fq 'Kernel driver in use: nvidia' <<< "$(lspci -nnk -s "$address")" ||
            die "GPU is not bound to nvidia: $address"
    done
    grep -Eq '^nouveau[[:space:]]' <<< "$(lsmod)" &&
        die 'nouveau is loaded alongside NVIDIA.'

    dkms_output=$(dkms status)
    dkms_rows=$(grep -F "nvidia/$upstream, $(uname -r), " <<< "$dkms_output" || true)
    grep -Fq ': installed' <<< "$dkms_rows" ||
        die 'DKMS is not installed for the running kernel.'
    [[ $(systemctl is-active display-manager.service) == active ]] ||
        die 'Display manager is not active.'
    if systemctl cat jellyfin.service >/dev/null 2>&1; then
        jellyfin_enabled=$(systemctl is-enabled jellyfin.service 2>/dev/null || true)
        if [[ $jellyfin_enabled == enabled* ]]; then
            [[ $(systemctl is-active jellyfin.service) == active ]] ||
                die 'Enabled Jellyfin service is not active.'
        fi
    fi
    grep -Fq 'libnvidia-encode.so.1' <<< "$(ldconfig -p)" || die 'NVENC library is missing.'

    if ! kernel_log=$(journalctl -b -k --no-pager 2>&1); then
        printf '%s\n' "$kernel_log" >&2
        die 'Kernel journal could not be read.'
    fi
    errors=$(grep -Ei 'NVRM: Xid|RmInitAdapter.*failed|fallen off the bus' <<< "$kernel_log" || true)
    [[ -z $errors ]] || { printf '%s\n' "$errors" >&2; die 'Serious NVIDIA boot error found.'; }
    log "Post-reboot verification passed for NVIDIA $upstream."
}

while (($# > 0)); do
    case $1 in
        --check) choose_mode check ;;
        --apply) choose_mode apply ;;
        --verify) choose_mode verify ;;
        --reboot) REBOOT_AFTER=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

(( REBOOT_AFTER == 0 )) || [[ $MODE == apply ]] ||
    die '--reboot is only valid with --apply.'

check_common_environment
case $MODE in
    verify)
        verify_after_reboot
        ;;
    check)
        perform_discovery
        preliminary_driver_simulation
        show_plan
        ;;
    apply)
        apply_upgrade
        ;;
    *)
        die "Internal mode error: $MODE"
        ;;
esac
