#!/bin/bash
alias dialog='dialog --backtitle "Postgres Setup" --aspect 100 --cr-wrap'

# loop over databases
for DBNAME in `ls dbstructure`; do
	dialog --yesno "Populate ${DBNAME} tables with dummy data?" 20 80
	if [ $? -eq 0 ]; then
		MENUSTRING=""
		TABLES=(`ls dbstructure/${DBNAME}`)
		# build list of tables into checkbox
		let i=0
		for TABLE in ${TABLES[@]}; do
			MENUSTRING="${MENUSTRING} $i \"${TABLE}\" on"
			let i=$i+1
		done
		
		# checkbox - user to confirm whch tables to populate
		actions=$(dialog --checklist "Please select the tables to fill" 20 80 $i ${MENUSTRING} 2>&1 1>/dev/tty)
		if [ $? -ne 0 ]; then
			echo "Aborted"
			exit 1
		fi
		
		
		# ask how many records to generate
		NUMENTRIES=$(dialog --inputbox "How many dummy records should be generated?" 20 80 50 2>&1 1>/dev/tty)
		
		# fill the tables
		for TABLENUM in ${actions}; do
			echo "TABLENUM is ${TABLENUM}"
			TABLE=${TABLES[$TABLENUM]}
			TABLE=${TABLE%%.txt}
			#echo "would fill table ${TABLE} with ${NUMENTRIES}"
			./fill_random.sh $TABLE ${NUMENTRIES} | dialog --progressbox --title \
			                                        "Inserting ${NUMENTRIES} entries into ${TABLE}" 20 80
		done
	fi
done

