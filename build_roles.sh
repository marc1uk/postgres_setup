# TODO

# create the annie database user. They have attributes to connect to the database, but not modify the cluster.
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
	# TODO parse these from a file to pre-populate a checklist - saves repeated typing
	# while allowing customisations at install time.
	
	# privileges may be quite complex, but the two basic categories of objects on which
	# privileges are granted / revoked are 'SCHEMA pubic' and each 'DATABASE'.
	# .e.g
	# allow pi to query (select) entries from all tables in the public schema
	psql -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO pi"
	# allow pi to connect to and make temporary tables (required for complex queries) in the 'rundb' database
	psql -c "GRANT CONNECT, TEMPORARY ON DATABASE rundb TO pi"
	
	
	
	##############################
	
	
	# only allow the select sequences.
	psql -c "GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO annie"
	# revoke permissions for everything else.
	psql -c "REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM annie"
	psql -c "REVOKE USAGE, UPDATE ON ALL SEQUENCES IN SCHEMA public FROM annie"
	psql -c "REVOKE EXECUTE ON ALL ROUTINES IN SCHEMA public FROM annie"
	psql -c "REVOKE CREATE ON DATABASE rundb, monitoringdb FROM annie"
	
	# slightly broader set of privileges for the software that'll be inserting data
	psql -c "CREATE ROLE tooldaq LOGIN PASSWORD 'tooldaq19'"
	# allow tooldaq to connect and make temporary tables in both databases
	psql -c "GRANT CONNECT, TEMPORARY ON DATABASE rundb, monitoringdb TO tooldaq"
	# allow tooldaq to select, insert and update entries in all tables in the public schema
	psql -c "GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO tooldaq"
	# allow the use of sequences.
	psql -c "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO tooldaq"
	# allow the use of functions and routines, in case we have any
	psql -c "GRANT EXECUTE ON ALL ROUTINES IN SCHEMA public TO tooldaq"
	# revoke permissions for everything else. N.B we disallow deletion of rows.
	psql -c "REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public FROM tooldaq"
	psql -c "REVOKE CREATE ON DATABASE rundb, monitoringdb FROM tooldaq"

	# make a replication role. superusers can do replication, but it's safer to use a special account for it
	if [ ! -f /home/postgres/database_replicator_password ]; then
		REPPASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
		echo "${REPPASSWORD}" | sudo -u postgres tee /home/postgres/database_replicator_password
	else
		REPPASSWORD=$(sudo cat /home/postgres/database_replicator_password)
	fi
	psql -c "CREATE ROLE replicator LOGIN REPLICATION PASSWORD '${REPPASSWORD}'"
	# make a note of that password in case we bail out when any of the following fail
	
	# create an admin database user. First we need a password
	if [ ! -f /home/postgres/database_admin_password ]; then
		ADMINPASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
		echo "${ADMINPASSWORD}" | sudo -u postgres tee /home/postgres/database_admin_password
	else
		ADMINPASSWORD=$(sudo cat /home/postgres/database_admin_password)
	fi
	# make the user. Assign further attributes to permit modification of the database cluster.
	psql -c "CREATE ROLE admin LOGIN CREATEDB CREATEROLE REPLICATION PASSWORD '${ADMINPASSWORD}'"
	# grant ability to connect, make temp tables and create objects in our databases
	psql -c "GRANT CONNECT, TEMPORARY, CREATE ON DATABASE rundb, monitoringdb TO admin"
	# grant permissions to perform modification of all tables in the database.
	# new permissions here are the ability to delete rows, make references and triggers
	psql -c "GRANT SELECT, INSERT, UPDATE, DELETE, REFERENCES, TRIGGER ON ALL TABLES IN SCHEMA public TO admin"
	psql -c "GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA public TO admin"
	psql -c "GRANT ALL PRIVILEGES ON ALL ROUTINES IN SCHEMA public TO admin"
	# grant membership to additional default group roles that allow certain actions
	psql -c "GRANT pg_read_all_settings, pg_read_all_stats, pg_stat_scan_tables, pg_monitor, pg_signal_backend, pg_read_server_files, pg_write_server_files, pg_execute_server_program TO admin"
	# revoke permissions for the really serious stuff -- have to use postgres superuser for these.
	# TRUNCATE empties a table. Probably not something to do lightly.
	psql -c "REVOKE TRUNCATE ON ALL TABLES IN SCHEMA public FROM admin"
	# notably missing - permission to drop tables or objects.
	# This permission is inherent to the owner (postgres) and can't be granted or revoked to other users.
done

# FIXME i dunno why, but this didn't seem to work to grant privileges.
# you can check them by:
#psql -U tooldaq -d "host=/tmp dbname=monitoringdb" -x -c "\z logging"
# to see the permissions tooldaq has on the local logging table in the monitoringdb database.
# prints something with 'Access privileges: tooldaq=arw/potgres' if it's correct.
# to fix it i just had to do:
# psql -d "host=/tmp dbname=monitoringdb" -c "GRANT SELECT, INSERT, UPDATE ON resources TO tooldaq"
# which should have already been done above...

