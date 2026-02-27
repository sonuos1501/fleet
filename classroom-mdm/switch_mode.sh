#!/bin/bash
# Fleet Classroom MDM - Switch Mode Script
# Usage: ./switch_mode.sh [study|exam|free]

TOKEN="9xAzlwbZl/DX/IHoNp7AWChfVER0XgXJsmpuOJJT7hKYjGm6Y8AT7XSjH5tV0Ko0cQMp/NtzwwJHNaicSg+XiQ=="
SERVER="https://localhost:8080"
PROFILES_DIR="$(dirname "$0")/profiles"

MODE=$1

if [ -z "$MODE" ]; then
  echo "🎓 Fleet Classroom MDM"
  echo ""
  echo "Usage: $0 [study|exam|free]"
  echo ""
  echo "Modes:"
  echo "  study  - Giờ học: camera off, USB off, WiFi locked"
  echo "  exam   - Giờ thi: kiosk mode, chặn hết"
  echo "  free   - Giờ nghỉ: mở hết (trừ factory reset)"
  echo ""
  echo "Current profiles:"
  curl -sk "$SERVER/api/v1/fleet/mdm/profiles" \
    -H "Authorization: Bearer $TOKEN" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('profiles',[]):
    print(f'  ✅ {p[\"name\"]} (platform: {p[\"platform\"]})')
" 2>/dev/null || echo "  ⚠️  Server not running"
  exit 0
fi

PROFILE_FILE="$PROFILES_DIR/${MODE}_mode.json"

if [ ! -f "$PROFILE_FILE" ]; then
  echo "❌ Profile '$MODE' not found. Use: study, exam, or free"
  exit 1
fi

echo "🔄 Switching to ${MODE^^} mode..."

# Delete existing profiles first
EXISTING=$(curl -sk "$SERVER/api/v1/fleet/mdm/profiles" \
  -H "Authorization: Bearer $TOKEN" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
for p in d.get('profiles',[]):
    if p['platform'] == 'android':
        print(p['profile_uuid'])
" 2>/dev/null)

for uuid in $EXISTING; do
  curl -sk -X DELETE "$SERVER/api/v1/fleet/mdm/profiles/$uuid" \
    -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1
  echo "  🗑️  Deleted old profile: $uuid"
done

# Upload new profile
RESULT=$(curl -sk -X POST "$SERVER/api/v1/fleet/mdm/profiles" \
  -H "Authorization: Bearer $TOKEN" \
  -F "team_id=0" \
  -F "profile=@$PROFILE_FILE;type=application/json" 2>&1)

UUID=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('profile_uuid',''))" 2>/dev/null)

if [ -n "$UUID" ]; then
  echo "  ✅ Uploaded: ${MODE}_mode (UUID: $UUID)"
  echo ""
  echo "🎉 All 30 devices will switch to ${MODE^^} mode when online!"
else
  echo "  ❌ Failed: $RESULT"
fi
