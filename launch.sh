#!/bin/bash
# VoiceCoder auto-start script (called by launchd)
# Only starts the Python service. hotkey_daemon starts via Login Item.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
VENV="$HOME/.venv/whisper-env/bin/python3"
DIR="$HOME/workspace/voicecoder"
LOCK="/tmp/voicecoder.lock"

# Prevent duplicate start
if [ -f "$LOCK" ]; then
    OLD_PID=$(cat "$LOCK" 2>/dev/null)
    if kill -0 "$OLD_PID" 2>/dev/null; then
        exit 0
    fi
fi
echo $$ > "$LOCK"

# Kill stale processes
pkill -f "voicecoder_service.py" 2>/dev/null
rm -f /tmp/voicecoder.sock
sleep 1

# Start service (foreground — launchd manages lifecycle)
exec "$VENV" "$DIR/voicecoder_service.py" --model sensevoice --lang zh
