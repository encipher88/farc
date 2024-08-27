#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Fetch current numMessages
current_numMessages=$(curl -s http://localhost:2281/v1/info?dbstats=1 | jq '.dbStats.numMessages')

# File to store the last numMessages
last_numMessages_file="$HOME/hubble/last_numMessages.txt"

# Check if the file exists and read the last numMessages
if [ -f "$last_numMessages_file" ]; then
    last_numMessages=$(cat "$last_numMessages_file")
else
    last_numMessages=0
fi

# Calculate the absolute difference between current and last numMessages
diff_numMessages=$((current_numMessages - last_numMessages))
if [ "$diff_numMessages" -lt 0 ]; then
    diff_numMessages=$(( -diff_numMessages ))  # Take the absolute value
fi

# Compare the current numMessages with the last one
if [ "$current_numMessages" -eq "$last_numMessages" ] || [ "$diff_numMessages" -le 5000 ]; then
    echo "$diff_numMessages has not changed or NOT increased by more than 5000. Triggering autoupgrade."
    /root/hubble/hubble.sh autoupgrade
else
    echo "$diff_numMessages has changed or increased by more than 5000. No action needed."
fi

# Update the last_numMessages file
echo "$current_numMessages" > "$last_numMessages_file"
