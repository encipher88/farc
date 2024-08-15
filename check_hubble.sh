#!/bin/bash

# Fetch current numMessages
current_numMessages=$(curl -s http://localhost:2281/v1/info?dbstats=1 | jq '.dbStats.numMessages')

# File to store the last numMessages
last_numMessages_file="/tmp/last_numMessages.txt"

# Check if the file exists
if [ -f "$last_numMessages_file" ]; then
    last_numMessages=$(cat $last_numMessages_file)
else
    last_numMessages=0
fi

# Calculate the difference between the current and last numMessages
diff_numMessages=$((current_numMessages - last_numMessages))

# Compare the current numMessages with the last one
if [ "$current_numMessages" -eq "$last_numMessages" ] || [ "$diff_numMessages" -gt 5000 ]; then
    echo "numMessages has not changed or increased by more than 5000. Triggering autoupgrade."
    /root/hubble/hubble.sh autoupgrade
else
    echo "numMessages has changed or increase is within limit. No action needed."
fi

# Update the last_numMessages file
echo $current_numMessages > $last_numMessages_file
