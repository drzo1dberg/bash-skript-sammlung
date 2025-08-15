#!/usr/bin/env bash
# Filename: cleanup-pro.sh
# cleanup version 3

LOG_DIR=/var/log
ROOT_UID=0
LINES=50
E_XCD=86
E_NOTROOT=87


# run as root
if [ "$UID" -ne "$ROOT_UID" ]
then
	echo "Must be root to run this script."
	exit $E_NOTROOT
fi

if [ -n "$1" ]
# Testing wheter command-line argument is present (non-empty).
then
	lines=$1
else
	lines=$LINES #Default, if not specified on command line
fi
#  Stephane Chazelas suggests the following,
#+ as a better way of checking command-line arguments,
#+ but this is still a bit advanced for this stage of the tutorial.
#
#    E_WRONGARGS=85  # Non-numerical argument (bad argument format).
#
#    case "$1" in
#    ""      ) lines=50;;
#    *[!0-9]*) echo "Usage: `basename $0` lines-to-cleanup";
#     exit $E_WRONGARGS;;
#    *       ) lines=$1;;
#    esac

cd $LOG_DIR

if [ `pwd` != "$LOG_DIR" ] # or   if [ "$PWD" != "$LOG_DIR" ]

then 
	echo "Can't change to $LOG_DIR."
	exit $E_XCD
fi

# Far more efficient is:
#
# cd /var/log || {
#   echo "Cannot change to necessary directory." >&2
#   exit $E_XCD;
# }

tail -n $lines messages > mesg.temp #save last section of message log file
mv mesg.temp messages

cat /dev/null > wtmp
echo "Log files cleaned up."

exit 0 #indicates success very good very nice
