#!/usr/bin/env bash
set -euo pipefail

task_mode="${1:-run}"
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
task_derived_data="${BETTER_OSD_DERIVED_DATA:-$task_root/DerivedData}"
task_configuration="${BETTER_OSD_CONFIGURATION:-Debug}"
task_app="$task_derived_data/Build/Products/$task_configuration/BetterOSD.app"
task_process_pattern='(^|/)BetterOSD[.]app/Contents/MacOS/BetterOSD$'

task_build_args=(build -project "$task_root/BetterOSD.xcodeproj" -scheme BetterOSD -configuration "$task_configuration" -destination 'platform=macOS' -derivedDataPath "$task_derived_data")
if [[ -n "${BETTER_OSD_PACKAGE_DIR:-}" ]]; then
    task_build_args+=(-clonedSourcePackagesDirPath "$BETTER_OSD_PACKAGE_DIR" -disableAutomaticPackageResolution)
fi
if [[ -n "${BETTER_OSD_CODE_SIGN_IDENTITY:-}" ]]; then
    task_build_args+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$BETTER_OSD_CODE_SIGN_IDENTITY")
fi

case "$task_mode" in
    run|--debug|--logs|--telemetry|--verify) ;;
    *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

pkill -f "$task_process_pattern" >/dev/null 2>&1 || true
for task_attempt in {1..20}; do
    if ! pgrep -f "$task_process_pattern" >/dev/null; then break; fi
    sleep 0.25
done
if pgrep -f "$task_process_pattern" >/dev/null; then
    echo 'The previous BetterOSD process did not exit' >&2
    exit 1
fi
xcodebuild "${task_build_args[@]}"
/usr/bin/open -n "$task_app"

task_pid=''
for task_attempt in {1..20}; do
    task_pid="$(pgrep -f "$task_process_pattern" | head -n 1 || true)"
    if [[ -n "$task_pid" ]]; then break; fi
    sleep 0.25
done
if [[ -z "$task_pid" ]]; then
    echo 'BetterOSD did not launch' >&2
    exit 1
fi

case "$task_mode" in
    --debug) lldb -p "$task_pid" ;;
    --logs) /usr/bin/log stream --info --style compact --predicate 'process == "BetterOSD"' ;;
    --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.zhangyu.volume-hud"' ;;
    --verify) echo "BetterOSD launched (PID $task_pid)" ;;
esac
