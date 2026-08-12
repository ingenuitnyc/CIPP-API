#!/bin/bash
#
# Create-macOSLocalUser.sh
# -----------------------------------------------------------------------------
# NinjaOne script (macOS) that creates a new *local* user account with a
# username and password of your choosing on the target Mac.
#
# The NinjaOne agent runs scripts as root, so no additional privilege
# escalation is required.
#
# ---------------------------------------------------------------------------
# HOW TO CONFIGURE IN NINJAONE
# ---------------------------------------------------------------------------
# 1. Administration > Library > Automation > Add > New Script
# 2. Language:      ShellScript (macOS/Linux)
# 3. Operating System: Mac
# 4. Architecture: All
# 5. Paste this script.
# 6. Add the following Script Variables (Administration > Script Variables, or
#    add them inline on the script). NinjaOne exposes each Script Variable to
#    the script as an environment variable using the *exact* name you type.
#
#        newUsername   (Text)     - REQUIRED - the short/login name to create
#        newPassword   (Text)     - REQUIRED - the account password
#                                   -> mark this variable as a *secure/masked*
#                                      value so it is not stored/shown in clear
#        fullName      (Text)     - optional - the display / full name
#                                   (defaults to newUsername if omitted)
#        makeAdmin     (Checkbox) - optional - grant local administrator rights
#        hideUser      (Checkbox) - optional - hide the account from the macOS
#                                   login window and Users & Groups pane
#
#    You can also run it ad-hoc from the device page and fill the variables
#    in the "Run Script" dialog.
#
# Alternatively (e.g. for local testing) you may pass positional arguments:
#        ./Create-macOSLocalUser.sh <username> <password> [fullName] [admin] [hide]
#    where [admin] / [hide] are "true" / "false".
#
# ---------------------------------------------------------------------------
# EXIT CODES
#   0  success (user created, or already existed with nothing to change)
#   1  missing/invalid parameters
#   2  unsupported macOS version
#   3  user creation failed
#   4  post-creation verification failed
# ---------------------------------------------------------------------------

set -uo pipefail

log()   { printf '%s [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn()  { printf '%s [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
error() { printf '%s [ERROR] %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Gather parameters (NinjaOne Script Variables -> env vars, else positional)
# ---------------------------------------------------------------------------
USERNAME="${newUsername:-${1:-}}"
PASSWORD="${newPassword:-${2:-}}"
FULLNAME="${fullName:-${3:-}}"
MAKE_ADMIN="${makeAdmin:-${4:-false}}"
HIDE_USER="${hideUser:-${5:-false}}"

# Normalise the boolean-ish values NinjaOne checkboxes send ("true"/"1"/"yes")
to_bool() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on|checked) echo "true" ;;
        *)                     echo "false" ;;
    esac
}
MAKE_ADMIN="$(to_bool "$MAKE_ADMIN")"
HIDE_USER="$(to_bool "$HIDE_USER")"

# Trim surrounding whitespace from the username
USERNAME="$(printf '%s' "$USERNAME" | xargs 2>/dev/null || printf '%s' "$USERNAME")"

# Default the full name to the username when not supplied
[ -z "$FULLNAME" ] && FULLNAME="$USERNAME"

# ---------------------------------------------------------------------------
# 2. Validate
# ---------------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    error "This script must run as root (NinjaOne runs as root by default)."
    exit 1
fi

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    error "Both 'newUsername' and 'newPassword' are required."
    exit 1
fi

# macOS short names: start with a-z/0-9/_, then lowercase letters, digits,
# hyphen, underscore or period. Keep it conservative to avoid odd home dirs.
if ! printf '%s' "$USERNAME" | grep -Eq '^[a-z0-9_][a-z0-9_.-]*$'; then
    error "Invalid username '$USERNAME'. Use lowercase letters, digits, '_', '-', '.' and do not start with a hyphen or period."
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Verify macOS + sysadminctl availability (macOS 10.13+)
# ---------------------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
    error "This script only runs on macOS (Darwin)."
    exit 2
fi

if ! command -v sysadminctl >/dev/null 2>&1; then
    error "sysadminctl not found; macOS 10.13 (High Sierra) or later is required."
    exit 2
fi

OS_VER="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
log "macOS version: ${OS_VER}"

# ---------------------------------------------------------------------------
# 4. Idempotency: bail out cleanly if the account already exists
# ---------------------------------------------------------------------------
if id "$USERNAME" >/dev/null 2>&1 || dscl . -read "/Users/$USERNAME" >/dev/null 2>&1; then
    warn "A local user '$USERNAME' already exists. Not modifying the existing account."
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Create the account
# ---------------------------------------------------------------------------
# Notes:
#  * sysadminctl (Apple's supported tool) picks a free UID, creates the home
#    directory under /Users, sets the shell, and configures the password
#    correctly (including its keychain).
#  * -admin adds the account to the local 'admin' group. Omit it for a
#    standard (non-admin) user.
#
# SECURITY NOTE: sysadminctl takes the password as an argument, so it is
# briefly visible to other root processes via `ps` on this host. Store the
# 'newPassword' NinjaOne variable as a masked/secure value, and consider
# forcing a password change at first login for interactive accounts.

log "Creating local user '$USERNAME' (fullName='$FULLNAME', admin=$MAKE_ADMIN, hidden=$HIDE_USER)..."

ADMIN_FLAG=()
if [ "$MAKE_ADMIN" = "true" ]; then
    ADMIN_FLAG=(-admin)
fi

CREATE_OUTPUT="$(sysadminctl -addUser "$USERNAME" \
                             -fullName "$FULLNAME" \
                             -password "$PASSWORD" \
                             "${ADMIN_FLAG[@]}" 2>&1)"
CREATE_RC=$?

# sysadminctl writes its progress to stderr and its exit status is not always
# reliable across OS versions, so we log the output and verify explicitly below.
printf '%s\n' "$CREATE_OUTPUT" | sed 's/^/    sysadminctl: /'

# ---------------------------------------------------------------------------
# 6. Verify the account exists
# ---------------------------------------------------------------------------
if ! id "$USERNAME" >/dev/null 2>&1; then
    error "User creation failed (sysadminctl rc=$CREATE_RC). See output above."
    exit 3
fi

NEW_UID="$(id -u "$USERNAME" 2>/dev/null)"
log "User '$USERNAME' created successfully (UID ${NEW_UID})."

if [ "$MAKE_ADMIN" = "true" ]; then
    if dseditgroup -o checkmember -m "$USERNAME" admin >/dev/null 2>&1; then
        log "'$USERNAME' is a member of the local admin group."
    else
        warn "Admin was requested but '$USERNAME' is not in the admin group; adding it now."
        dseditgroup -o edit -a "$USERNAME" -t user admin
    fi
fi

# ---------------------------------------------------------------------------
# 7. Optionally hide the account from the login window & Users & Groups
# ---------------------------------------------------------------------------
if [ "$HIDE_USER" = "true" ]; then
    log "Hiding '$USERNAME' from the login window..."
    dscl . -create "/Users/$USERNAME" IsHidden 1
    # Move the home directory out of /Users so it doesn't show in Finder either.
    if [ -d "/Users/$USERNAME" ] && [ ! -d "/var/$USERNAME" ]; then
        mv "/Users/$USERNAME" "/var/$USERNAME" 2>/dev/null \
            && dscl . -create "/Users/$USERNAME" NFSHomeDirectory "/var/$USERNAME" \
            && log "Home directory moved to /var/$USERNAME." \
            || warn "Could not relocate the home directory; account is still hidden from the login window."
    fi
fi

# ---------------------------------------------------------------------------
# 8. Final verification
# ---------------------------------------------------------------------------
if id "$USERNAME" >/dev/null 2>&1; then
    log "Done. Local user '$USERNAME' is ready to use."
    exit 0
else
    error "Post-creation verification failed for '$USERNAME'."
    exit 4
fi
