#!/bin/bash
set -x
set -e

# make directory structure
DB_BASE=/mnt/data/postgres
sudo mkdir -p ${DB_BASE}
sudo chown -R postgres:postgres ${DB_BASE}
sudo -u postgres mkdir -p ${DB_BASE}/psql_db            # data directory, actual database is here
sudo -u postgres mkdir -p ${DB_BASE}/psql_wal           # local write ahead logs go here

# the database will need a password. record it in a file so if this script bails
# we still have it recorded.
if [ ! -f /home/postgres/database_password ]; then
	cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1 | sudo tee /home/postgres/database_password
fi
# again set permissions so it's only readable by postgres user or root
sudo chown postgres:postgres /home/postgres/database_password
sudo chmod 700 /home/postgres/database_password

# we need to invoke creation of the database cluster.
# postgresql documentation says this is done by initdb.
# centos seems to think it should be done by postgresql-12-setup.
# what's that? good luck finding out.
# we're not going to use it because it's not documented.
# initdb will create the database. The files will be owned by the user running the command,
# so we run it as the linux user 'postgres'
sudo -u postgres                                 \
/usr/pgsql-12/bin/initdb -D ${DB_BASE}/psql_db   \
       -X ${DB_BASE}/psql_wal                    \
       -U postgres                               \
       --pwfile=/home/postgres/database_password \
       --auth=scram-sha-256                      \
       -k
# -k enables checksums that help detect integrity issues with the database but can incur a noticeable
# performance penalty. I don't expect we're likely to be hammering the db enough for this to be problematic...
# --auth sets the default authentication to require a hashed password when accessing the database as a given user
# (probably redundant as we'll set our own pg_hba.conf anyway)

# systemd needs to know where this is in order to be able to start the database on boot
# cat /etc/systemd/system/postgresql-12.service.d/override.conf
echo "[Service]" > /etc/systemd/system/postgresql-12.serviced.override.conf
echo "Environment=PGDATA=${DB_BASE}/psql_db" >> /etc/systemd/system/postgresql-12.serviced.override.conf

# copy database configuration
echo "copying configuration files"
sudo -u postgres cp /home/postgres/postgresql.conf ${DB_BASE}/psql_db/postgresql.conf
# copy authentication settings
sudo -u postgres cp /home/postgres/pg_hba.conf ${DB_BASE}/psql_db/pg_hba.conf

# in postgresql.conf we set up log shipping. We'll use the offline database
# to host the WAL archive. To copy files to and from it we use the following scripts
sudo -u postgres cp /home/postgres/archive_command.sh ${DB_BASE}/psql_db/archive_command.sh
sudo -u postgres cp /home/postgres/restore_command.sh ${DB_BASE}/psql_db/restore_command.sh

# we now do the initial configuration of the database cluster. This must be done by the
# database superuser - also called 'postgres', but nothing to do with the 'postgres' linux user.
# we can specify the user to connect to the database as with:
export PGUSER=postgres
export PGPASSWORD=$(sudo cat /home/postgres/database_password)

# export connection settings
export PGHOST=/tmp
export PGPORT=5432

# START THE DATABASE CLUSTER!!!
# again as the linux user postgres owns the files, the process needs to be run as them
echo "starting the database cluster"
sudo -E -u postgres /usr/pgsql-12/bin/pg_ctl -D ${DB_BASE}/psql_db -l ${DB_BASE}/psql_db/logfile start

# create the run database and the monitoring database
echo "making rundb and monitoringdb databases"
psql -c "CREATE DATABASE rundb"
psql -c "CREATE DATABASE monitoringdb"

# create the annie database user. They have attributes to connect to the database, but not modify the cluster.
echo "creating roles"

# the analysis role is 'annie', which has the most minimal privileges - basically read-only
psql -c "CREATE ROLE annie LOGIN PASSWORD 'anniepass19'"
# postgres privileges are split up somewhat oddly between schemas, databases, functions etc
# so setting permissions has to happen in several steps
# allow annie to connect and make temporary tables in both databases
psql -c "GRANT CONNECT, TEMPORARY ON DATABASE rundb, monitoringdb TO annie"
# allow annie to select entries in all tables in the public schema
psql -c "GRANT SELECT ON ALL TABLES IN SCHEMA public TO annie"
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

# FIXME i dunno why, but this didn't seem to work to grant privileges.
# you can check them by:
#psql -U tooldaq -d "host=/tmp dbname=monitoringdb" -x -c "\z logging"
# to see the permissions tooldaq has on the local logging table in the monitoringdb database.
# prints something with 'Access privileges: tooldaq=arw/potgres' if it's correct.
# to fix it i just had to do:
# psql -d "host=/tmp dbname=monitoringdb" -c "GRANT SELECT, INSERT, UPDATE ON resources TO tooldaq"
# which should have already been done above...


# for the standby to authenticate replication connections to the master it needs to have
# its password in the ~/.pgpass (presumably home of postgres as the user who started the db?)
echo "# hostname:port:database:username:password"                | sudo tee    /home/postgres/.pgpass
echo "# local connections"                                       | sudo tee -a /home/postgres/.pgpass
echo "/tmp:5432:*:postgres:${PGPASSWORD}"                        | sudo tee -a /home/postgres/.pgpass
echo "/tmp:5432:replication:replicator:${REPPASSWORD}"           | sudo tee -a /home/postgres/.pgpass
echo "# remote connections"                                      | sudo tee -a /home/postgres/.pgpass
echo "192.168.163.21:5432:replication:replicator:${REPPASSWORD}" | sudo tee -a /home/postgres/.pgpass
echo "192.168.163.22:5432:replication:replicator:${REPPASSWORD}" | sudo tee -a /home/postgres/.pgpass
echo "192.168.163.21:5432:*:postgres:${PGPASSWORD}"              | sudo tee -a /home/postgres/.pgpass
echo "192.168.163.22:5432:*:postgres:${PGPASSWORD}"              | sudo tee -a /home/postgres/.pgpass
# the pgpass file has to have permissions 600 (only readable by the specific user, no groups) or it'll be ignored.
sudo chown postgres /home/postgres/.pgpass
sudo chmod 600 /home/postgres/.pgpass

# do the same for the admin account
echo "# hostname:port:database:username:password"        | sudo tee    /home/root/.pgpass
echo "/tmp:5432:*admin:${ADMINPASSWORD}"                 | sudo tee -a /home/root/.pgpass
echo "192.168.163.21:5432:*:admin:${ADMINPASSWORD}"      | sudo tee -a /home/root/.pgpass
echo "192.168.163.22:5432:*:admin:${ADMINPASSWORD}"      | sudo tee -a /home/root/.pgpass

# also useful
echo "export PG_COLOR=always"                            | sudo -u postgres tee    /home/postgres/setup_db.sh
echo "export PGHOST=/tmp"                                | sudo -u postgres tee -a /home/postgres/setup_db.sh
echo "export PGPORT=5432"                                | sudo -u postgres tee -a /home/postgres/setup_db.sh
echo "export PGUSER=admin"                               | sudo -u postgres tee -a /home/postgres/setup_db.sh
echo "export PGDATABASE=rundb"                           | sudo -u postgres tee -a /home/postgres/setup_db.sh
echo "export PGDATA=${DB_BASE}/psql_db"                  | sudo -u postgres tee -a /home/postgres/setup_db.sh
#echo "export PGPASSFILE=~/.pgpass"                       | sudo -u postgres tee -a /home/postgres/setup_db.sh

echo "source setup_db.sh"               | sudo -u postgres tee -a /home/postgres/.bash_profile
