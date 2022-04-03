#!/bin/bash
sourcefname="$1"
destfile="$2"
# this script must accept two inputs: a path to a sourcefile and a destination filename
# (which may be different to the basename of the sourcefile!)
# Required behaviour:
# 1. if the destination file exists and is identical to the source file, return 0.
# 2. if the destination file exists but is different to the sourcefile, return 1.
# 3. if the destination file does not exist, copy the sourcefile to the destination,
#    return 0 on successful copy, 1 on error
if [ ! ssh ifdb09 "test -e /home/postgres/psql_wal/${sourcefname}" ]; then
	# file does not exist in WAL archive.
	exit 1;
else
	# file exists on the remote, retrieve it
	rsync postgres@ifdb09:"/home/postgres/psql_wal/${sourcefname}" "${destfile}"
	exit $?
fi


