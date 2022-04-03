#!/bin/bash
sourcefile="$1"
destfname="$2"
# this script must accept two inputs: a path to a sourcefile and a destination filename
# (which may be different to the basename of the sourcefile!)
# Required behaviour:
# 1. if the destination file exists and is identical to the source file, return 0.
# 2. if the destination file exists but is different to the sourcefile, return 1.
# 3. if the destination file does not exist, copy the sourcefile to the destination,
#    return 0 on successful copy, 1 on error
if [ ssh ifdb09 "test -e /home/postgres/psql_wal/${destfname}" ]; then
    # check for differences by comparing md5 checksum
	remotemd5=$(ssh ifdb09 md5sum "/home/postgres/psql_wal/${destfname}" | awk '{print $1}')
	localmd5=$(md5 "${sourcefile}" | awk '{print $1}')
	[ "remotemd5" == "localmd5" ]
	exit $?
else
	# file doesn't exist on the remote
	rsync "${sourcefile}" postgres@ifdb09:"/home/postgres/psql_wal/${destfname}"
	exit $?
fi


