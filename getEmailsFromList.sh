#!/usr/bin/env bash
#filename: getEmailsFromList.sh
#Author: M. J. Nunes Jacobs

# sanity check for commands
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <input-file> <output-file>"
    exit 1
fi

INPUT="$1"
OUTPUT="$2"

# sanity check for file 
if [[ ! -f "$INPUT" ]]; then
    echo "Input file $INPUT does not exist"
    exit 1
fi

# tempfile
TMP=$(mktemp)

# rgrep mit email regex
rg -io '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$INPUT" > "$TMP"

# check for duplicates
awk '!seen[$0]++' "$TMP" > "$OUTPUT"

# delete tmp
rm "$TMP"

echo "E-Mails saved to: $OUTPUT"
