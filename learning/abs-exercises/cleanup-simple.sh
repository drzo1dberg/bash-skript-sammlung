#!/usr/bin/env bash
# File: cleanup-simple.sh

cd /var/log 
cat /dev/null > messages
cat /dev/null > wtmp
echo "Log files cleaned up."
