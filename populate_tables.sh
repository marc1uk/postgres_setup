#!/bin/bash
while read -r TABLE; do
	#if [ "${TABLE}" == "run" ]; then continue; fi
	./fill_random.sh $TABLE
done < ./table_names.txt

# print for interest
echo "tables filled!"
while read -r TABLE; do
	echo "SELECT * FROM ${TABLE};" | psql -U postgres
done < ./table_names.txt
