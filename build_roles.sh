# TODO - this script has yet to be finished
dialog --infobox "Sorry, this functionality is yet to be implemented" 20 80
exit 0;

# make suitable roles based on the configuration file roles.txt
echo "creating roles"

for ROLE in `cat roles.txt`; do
	
	# check if this role needs a password
	dialog --yesno "Creating role ${ROLE}; would you like to set a password for this user?"
	if [ $? -eq 0 ]; then
		# FIXME option to read from file maybe?
		step=0
		while [ step -lt 3 ]; do
			if [ ${step} -eq 0 ]; then
				firstentry=$(dialog --insecure --passwordbox "Enter password" 2>&1 1>/dev/tty)
				step=1
			elif [ ${step} -eq 1 ]; then
				secondentry=$(dialog --insecure --passwordbox "Enter password again" 2>&1 1>/dev/tty)
				step=2
			elif [ "${firstentry}" != "${secondentry}" ]; then
				dialog --msgbox "passwords do not match" 20 80
				step=0
			else
				USERPASS="${firstentry}"
				step=3
			fi
		done
		PASSFLAG="LOGIN PASSWORD '${USERPASS}'"
	else
		# no password
		PASSFLAG=""
	fi
	
	psql -c "CREATE ROLE ${ROLE} ${PASSFLAG}"
	if [ $? -ne 0 ]; then
		dialog --infobox "Failed to create role ${ROLE}!" 20 80
		exit 1;
	fi
	
	# grant privileges
	# TODO parse these from file.
	# optionally allow run-time configuration by using that list to pre-populate
	# a dialog check-list menu so that users can de-select or add privileges.
	
	# privileges may be quite complex, but the two basic categories of objects on which
	# privileges are granted / revoked are 'SCHEMA pubic' and each 'DATABASE'.
	# .e.g
	# allow pi to query (select) entries from all tables in the public schema
	psql -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${ROLE}"
	# allow pi to connect to and make temporary tables (required for complex queries) in the 'rundb' database
	psql -c "GRANT CONNECT, TEMPORARY ON DATABASE rundb TO ${ROLE}"
	
done
