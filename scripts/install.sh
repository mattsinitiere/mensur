#!/bin/bash
# Pulls the latest Mensur, builds and signs it with the project's team (KM25U2VHNT, through Xcode's automatic
# signing), installs it on this Mac, and on every iPhone connected by cable or Wi-Fi.
# Rooms are kept: they live outside the app, and installing over an existing copy leaves them alone.
#
#   bash scripts/install.sh               pull, then install on the Mac and any connected iPhone
#   bash scripts/install.sh --no-pull     install this copy as it is
#   bash scripts/install.sh --mac-only    or --iphone-only
#
# With a free Personal Team the iPhone copy stops opening after 7 days. Run this again to renew it.
set -euo pipefail
cd "$(dirname "$0")/.."

pull=1 mac=1 iphone=1
for arg in "$@"; do
  case "$arg" in
    --no-pull) pull=0 ;;
    --mac-only) iphone=0 ;;
    --iphone-only) mac=0 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]] || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Needs a Mac with full Xcode selected (Xcode > Settings > Locations > Command Line Tools)."
  exit 1
fi

bundle_id="com.matthewsinitiere.Mensur"
run_dir="build-logs/$(date +%Y%m%d-%H%M%S)-install"
mkdir -p "$run_dir"
failed=0
# The installed Mac app only; a copy running in the Simulator has the same process name.
mac_app_running() { pgrep -qf "/Applications/Mensur.app/Contents/MacOS/Mensur"; }

# Runs xcodebuild into a log, showing only the end of it when it fails.
build() {
  local log="$1"; shift
  if ! xcodebuild -project Mensur.xcodeproj -scheme Mensur -configuration Debug -allowProvisioningUpdates "$@" build >"$log" 2>&1 </dev/null; then
    grep -E "error:|BUILD FAILED" "$log" | sort -u | tail -20
    echo "Build failed. Full log: $log"
    if grep -q "No Account for Team\|No signing certificate\|requires a provisioning profile" "$log"; then
      echo "Sign in to Xcode > Settings > Accounts with your development Apple Account, then run this again."
    fi
    return 1
  fi
}

# Prints when the signature runs out, from the provisioning profile inside the app.
signed_until() {
  local profile
  profile=$(find "$1" -maxdepth 2 -name "embedded.*provision*" | head -1)
  [[ -n "$profile" ]] || return 0
  security cms -D -i "$profile" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null | sed 's/^/  signed until /' || true
}

if (( pull )); then
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "Not pulling: this copy has uncommitted changes. Installing it as it is."
  elif ! git pull --ff-only --quiet; then
    echo "Couldn't pull from GitHub. Installing this copy as it is."
  fi
fi
echo "Installing $(git log -1 --format='%h %s')"

if (( mac )); then
  echo "Mac: building and signing"
  if build "$run_dir/mac-build.log" -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath .build-signed; then
    app=".build-signed/Build/Products/Debug-maccatalyst/Mensur.app"
    was_running=0
    if mac_app_running; then
      was_running=1
      osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
      for _ in {1..20}; do mac_app_running || break; sleep 0.5; done
    fi
    if mac_app_running; then
      echo "Mac: Mensur is still open. Quit it, then run: bash scripts/install.sh --no-pull --mac-only"
      failed=1
    else
      rm -rf /Applications/Mensur.app
      ditto "$app" /Applications/Mensur.app
      codesign --verify --deep --strict /Applications/Mensur.app
      echo "Mac: installed /Applications/Mensur.app ($(codesign -dv /Applications/Mensur.app 2>&1 | grep TeamIdentifier))"
      signed_until /Applications/Mensur.app/Contents
      if (( was_running )); then open /Applications/Mensur.app; fi
    fi
  else
    failed=1
  fi
fi

if (( iphone )); then
  devices_json="$run_dir/devices.json"
  xcrun devicectl list devices -j "$devices_json" >/dev/null 2>&1 || true
  # One line per iPhone that is reachable now: hardware UDID, CoreDevice id, then its name.
  phones=$(python3 -I - "$devices_json" <<'PY' || true
import json, sys
try: devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devices = []
for d in devices:
    hw, conn, props = d["hardwareProperties"], d["connectionProperties"], d["deviceProperties"]
    if hw.get("reality") != "physical" or hw.get("deviceType") != "iPhone": continue
    if conn.get("transportType") is None and conn.get("tunnelState") != "connected": continue
    state = "ok"
    if conn.get("pairingState") != "paired": state = "unpaired"
    elif props.get("developerModeStatus") == "disabled": state = "devmode"
    print(hw["udid"], d["identifier"], state, props.get("name", "iPhone"), sep="\t")
PY
)
  if [[ -z "$phones" ]]; then
    echo "iPhone: none connected. Plug it in and unlock it, then run: bash scripts/install.sh --no-pull --iphone-only"
  fi
  while IFS=$'\t' read -r udid identifier state name; do
    [[ -n "$udid" ]] || continue
    case "$state" in
      unpaired) echo "iPhone ($name): unlock it and tap Trust, then run this again."; failed=1; continue ;;
      devmode) echo "iPhone ($name): turn on Settings > Privacy & Security > Developer Mode, then run this again."; failed=1; continue ;;
    esac
    echo "iPhone ($name): building and signing"
    log="$run_dir/iphone-build-$udid.log"
    if ! build "$log" -destination "id=$udid" -allowProvisioningDeviceRegistration -derivedDataPath .build-device-signed; then
      failed=1; continue
    fi
    app=".build-device-signed/Build/Products/Debug-iphoneos/Mensur.app"
    if xcrun devicectl device install app --device "$identifier" "$app" >"$run_dir/iphone-install-$udid.log" 2>&1 </dev/null; then
      echo "iPhone ($name): installed"
      signed_until "$app"
    else
      tail -5 "$run_dir/iphone-install-$udid.log"
      echo "iPhone ($name): install failed. Unlock the phone and run: bash scripts/install.sh --no-pull --iphone-only"
      failed=1
    fi
  done <<<"$phones"
fi

if (( failed )); then echo "Finished with problems. Logs: $run_dir"; exit 1; fi
echo "Done. Logs: $run_dir"
echo "If the iPhone says \"Untrusted Developer\": Settings > General > VPN & Device Management > trust your profile."
