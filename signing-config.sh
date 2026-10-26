# Public build policy; machine-specific certificate selection stays untracked.
if [ -f "$native_root/signing.local.sh" ]; then . "$native_root/signing.local.sh"; fi
signing_mode=${WINDOW_FACTORY_SIGNING_MODE:-${signing_mode:-developer-id}}
signing_identity=${WINDOW_FACTORY_SIGNING_IDENTITY:-${signing_identity:-}}
signing_team=${WINDOW_FACTORY_SIGNING_TEAM:-${signing_team:-}}
case "$signing_mode" in
    developer-id)
        [ -n "$signing_identity" ] && [ "${#signing_team}" -eq 10 ] || {
            echo "Set local signing identity/team, or explicitly select WINDOW_FACTORY_SIGNING_MODE=adhoc for development." >&2; exit 1;
        }
        case "$signing_team" in *[!A-Z0-9]*) echo "Invalid signing team" >&2; exit 1 ;; esac ;;
    adhoc) signing_identity=- ;;
    *) echo "Unknown signing mode" >&2; exit 1 ;;
esac
