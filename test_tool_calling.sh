#!/usr/bin/env bash
set -euo pipefail

# load .env
set -a
source ./.env
set +a

BASE_URL="${LLM_BASE_URL:-http://localhost:8000/v1}"
MODEL="${LLM_MODEL:-Qwen/Qwen3-4B-AWQ}"
ENDPOINT="${BASE_URL}/chat/completions"

if ! command -v jq >/dev/null; then
  echo "ERROR: jq is required." >&2
  exit 2
fi

echo "==> Server: ${BASE_URL}  Model: ${MODEL}"
curl -fsS --max-time 5 "${BASE_URL}/models" | jq -r '.data[].id' || {
  echo "ERROR: server not reachable at ${BASE_URL}" >&2
  exit 1
}

REQ=$(mktemp); RESP=$(mktemp)
trap 'rm -f "$REQ" "$RESP"' EXIT

cat >"$REQ" <<EOF
{
  "model": "${MODEL}",
  "messages": [
    {"role": "user", "content": "What is the weather in Stockholm? Use the get_weather tool."}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "get_weather",
      "description": "Get the current weather for a city.",
      "parameters": {
        "type": "object",
        "properties": {"city": {"type": "string"}},
        "required": ["city"]
      }
    }
  }],
  "tool_choice": "auto",
  "temperature": 0
}
EOF

echo "==> POST ${ENDPOINT} ..."
CODE=$(curl -sS -o "$RESP" -w '%{http_code}' \
  -H 'Content-Type: application/json' --max-time 60 \
  -d @"$REQ" "$ENDPOINT")

[[ "$CODE" != "200" ]] && { echo "FAIL: HTTP ${CODE}"; cat "$RESP"; exit 1; }
echo "==> HTTP 200"; jq . "$RESP"; echo

FINISH=$(jq -r '.choices[0].finish_reason // empty' "$RESP")
NAME=$(jq -r '.choices[0].message.tool_calls[0].function.name // empty' "$RESP")
ARGS=$(jq -r '.choices[0].message.tool_calls[0].function.arguments // empty' "$RESP")

PASS=1
[[ "$FINISH" == "tool_calls" ]] && echo "OK  finish_reason" \
  || { echo "FAIL finish_reason = '${FINISH}'"; PASS=0; }
[[ "$NAME" == "get_weather" ]] && echo "OK  tool name" \
  || { echo "FAIL tool = '${NAME}'"; PASS=0; }
echo "$ARGS" | jq -e '.city' >/dev/null 2>&1 \
  && echo "OK  city = $(echo "$ARGS" | jq -r '.city')" \
  || { echo "FAIL args = ${ARGS}"; PASS=0; }

echo
[[ "$PASS" == "1" ]] && echo "PASS" || { echo "FAIL"; exit 1; }