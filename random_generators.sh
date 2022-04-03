generate-value(){
	case "$1" in
		integer) random-int;;
		bigint) random-int;;
		real) random-float;;
		timestamp) random-timestamp;;
		text) random-string;;
		bytea) random-bytea;;
		json) random-json;;
		jsonb) random-json;;
		*) echo "uhoh, unknown type $case" >&2; echo "";;
	esac
}

# define a function to generate a random string
random-string(){
	TEXT=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
	echo "'"${TEXT}"'"
}

# generate a random integer
random-int(){
	echo $RANDOM
}

random-json(){
	let NUM=$(seq 1 1 3 | shuf | head -n1)
	MAP=""
	for i in `seq 1 $NUM`; do
		TEXT1=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
		TEXT2=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
		MAP="$MAP"'"'"$TEXT1"'":"'"$TEXT2"'"'
		if [ $i -ne $NUM ]; then
			MAP="$MAP,"
		fi
	done
	echo "'"${MAP}"'"
}

random-float(){
	MULTIPLIER=10 # generates from 0 - 9.99999
	# scale is precision, 32767 is max of $RANDOM
	echo "scale=5; $RANDOM*$MULTIPLIER/32767" | bc
}

random-timestamp(){
	#let "MONTH = $RANDOM % 12"; let "MONTH += 1"  # correct 0-11 to 1-12
	YEAR=2020
	MONTH=$(printf "%02d\n" $(seq 1 1 12 | shuf | head -n1))
	DAY=$(printf "%02d\n" $(seq 1 1 30 | shuf | head -n1))
	HOUR=$(printf "%02d\n" $(seq 0 1 23 | shuf | head -n1))
	MIN=$(printf "%02d\n" $(seq 0 1 59 | shuf | head -n1))
	SEC=$(printf "%02d\n" $(seq 0 1 59 | shuf | head -n1))
	TIMESTAMP="${YEAR}-${MONTH}-${DAY} ${HOUR}:${MIN}:${SEC}"
	TIMESTAMPSTRING="timestamp '"$TIMESTAMP"'"
	echo ${TIMESTAMPSTRING}
}

random-hex(){
	cat /proc/sys/kernel/random/uuid | tr -d '-'
}

random-bytea(){
	TEXT=`random-hex`;
	echo "decode('"${TEXT}"', 'hex')"
}
