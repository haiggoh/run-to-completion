#!/usr/bin/env bash
# Test double for macOS `osascript`, installed into a temp PATH dir as `osascript`.
# Never drives Terminal.app. Behaviour is chosen by the script text passed with -e:
#   "do script"   -> append the script to $FAKE_OSA_LOG, print a window id (42)
#   "get busy"    -> print the first line of $FAKE_OSA_BUSY (consumed; default "true");
#                    on the first busy read, touch $FAKE_OSA_TOUCH when it is set
#   "get history" -> cat $FAKE_OSA_HISTORY
# Env: FAKE_OSA_LOG, FAKE_OSA_BUSY, FAKE_OSA_TOUCH, FAKE_OSA_HISTORY (all optional).
set -u
case "${1:-}" in -h|--help) echo "fake osascript for tests (see header)"; exit 0 ;; esac
script="${2:-}"
case "$script" in
	*"do script"*)
		[ -n "${FAKE_OSA_LOG:-}" ] && printf '%s\n----\n' "$script" >> "$FAKE_OSA_LOG"
		echo 42 ;;
	*"get busy"*)
		if [ -n "${FAKE_OSA_TOUCH:-}" ] && [ ! -e "$FAKE_OSA_TOUCH" ]; then : > "$FAKE_OSA_TOUCH"; fi
		if [ -n "${FAKE_OSA_BUSY:-}" ] && [ -s "$FAKE_OSA_BUSY" ]; then
			head -1 "$FAKE_OSA_BUSY"
			tail -n +2 "$FAKE_OSA_BUSY" > "$FAKE_OSA_BUSY.next"; mv "$FAKE_OSA_BUSY.next" "$FAKE_OSA_BUSY"
		else
			echo true
		fi ;;
	*"get history"*)
		[ -n "${FAKE_OSA_HISTORY:-}" ] && cat "$FAKE_OSA_HISTORY" ;;
	*) echo "fake osascript: unhandled script" >&2; exit 1 ;;
esac
