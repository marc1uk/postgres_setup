#!/bin/bash
# Generate some random data
# first get the list of column names
. random_generators.sh
TABLENAME="$1"
ENTRIES="${2:-20}"
PORT="${3:-5432}"
declare -A COLUMNS
COLUMN_NAMES=""
COLUMN_LIST=""
#echo "parsing ./${TABLENAME}_columns.txt for columns"
while read -r COLUMN; do
	read COLNAME COLTYPE < <(echo ${COLUMN})
	#echo "column ${COLNAME} of type ${COLTYPE}"
	if [ "${COLNAME}" == "id" ]; then continue; fi
	COLUMN_NAMES="${COLUMN_NAMES} ${COLNAME}"
	if [ -z "${COLUMN_LIST}" ]; then
		COLUMN_LIST="${COLNAME}"
	else
		COLUMN_LIST="${COLUMN_LIST}, ${COLNAME}"
	fi
	COLUMNS["${COLNAME}"]="${COLTYPE}"
done < ./${TABLENAME}_columns.txt
#echo "full list of columns is ${COLUMN_NAMES}"
# add a dummy so that iteration over the list of columns processes the last one
COLUMN_NAMES="${COLUMN_NAMES} dummy"

# insert 20 new rows to get us started
for i in `seq 1 ${ENTRIES}`; do
	NEXTROW=""
	while read -r -d ' ' ACOLUMN; do      # this drops the last entry as it has no terminator.
		TYPE=${COLUMNS[${ACOLUMN}]}
		NEXTVAL=$(generate-value ${TYPE})
		if [ -z "${NEXTROW}" ]; then
			# first entry, no leading comma
			NEXTROW=${NEXTVAL};
		else
			NEXTROW="${NEXTROW}, ${NEXTVAL}"
		fi
	done < <(echo ${COLUMN_NAMES})
	#echo "adding new entry to ${TABLENAME}:"
	#echo "${NEXTROW}"
	echo "INSERT INTO ${TABLENAME} ( ${COLUMN_LIST} ) VALUES ( ${NEXTROW} );"
	echo "INSERT INTO ${TABLENAME} ( ${COLUMN_LIST} ) VALUES ( ${NEXTROW} );" | psql -U postgres -p ${PORT}
done
