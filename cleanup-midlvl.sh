#!/usr/bin/env bash
# Filename: cleanup-midlvl.sh
#cleanup vers 2
#run as root

# todo: insert code to print error message and exit if not root

LOG_DIR=/var/log

cd $LOG_DIR

cat /dev/null > messages
cat /dev/null > wtmp

echo "Logs cleaned up."

exit #graceful exit is important in bash!
