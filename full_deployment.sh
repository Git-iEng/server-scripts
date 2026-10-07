#!/usr/bin/env bash

while IFS="|" read -r SITE_NAME REPO_URL PORT; do
  # Check if the line is empty or starts with '#' (optional: for comments)
  if [[ -n "$SITE_NAME" && "$SITE_NAME" != \#* ]]; then
    # Added during rebuild: remove a Windows line ending from the port, if present
    PORT="${PORT%$'\r'}"
    echo "========================================"
    echo "Starting deployment for: $SITE_NAME on port $PORT"
    /root/deployment_script.sh "$SITE_NAME" "$REPO_URL" "$PORT"
    echo "Finished deployment for: $SITE_NAME"
    echo "========================================"
  fi
done < /root/site.conf
