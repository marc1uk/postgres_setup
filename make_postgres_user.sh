#!/bin/bash
set -x
set -e

# to be compatible with FNAL replication our databases need to be owned by this specific uid and gids
# it seems we need to make the group first to be able to specify a gid.
#sudo groupadd -g 9537 postgres
sudo groupmod postgres -g 9537

echo "creating postgres user account"
#sudo useradd postgres --uid 2729 --gid 9537 --home /home/postgres --create-home
sudo mkdir -p /home/postgres
sudo usermod -u 2729 -h /home/postgres
sudo chown -R postgres:postgres /home/postgres

# for admin to be able to access the database files, they also need to be part of the postgres group
sudo usermod -aG postgres brichards
sudo usermod -aG postgres moflaher

# give it a password. I think this is necessary as the database files will be owned by
# the postgres user, so to prevent someone arbitrarily modifying the database access
# controls files (pg_hba / pg_ident.conf), we should password protect the owner account
echo "giving it a password"
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1 | sudo tee /home/postgres/postgres_user_password
echo "postgres:"$(sudo cat /home/postgres/postgres_user_password) | sudo chpasswd
sudo chown postgres:postgres /home/postgres/postgres_user_password
sudo chmod 700 /home/postgres/postgres_user_password

