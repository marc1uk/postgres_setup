#!/bin/bash
sudo su postgres
ssh-keygen -t ed25519 -b 4096 -C "replicator" -f /home/postgres/.ssh/replicator
host=`hostname`
if [ "$host" == "new-daq01" ]; then
	ssh-copy-id -i /home/postgres/.ssh/replicator.pub postgres@192.168.163.22
else
	ssh-copy-id -i /home/postgres/.ssh/replicator.pub postgres@192.168.163.21
fi
