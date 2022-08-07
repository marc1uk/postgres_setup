#!/bin/bash
#set -x
trap 'echo "Aborted"; exit 1' SIGINT

if [ "$(whoami)" != "root" ]; then
	echo "This script needs root privileges for some actions. Please re-run as root"
	exit 1;
fi

which dialog &>/dev/null
if [ $? -ne 0 ]; then
	echo "This install script requires the 'dialog' package. Would you like to install it now?"
	select RESULT in Yes No; do
		if [ "${RESULT}" != "Yes" ] && [ "${RESULT}" != "No" ]; then
			echo "Please enter 1 to install dialog and continue, or 2 to abort"
		elif [ "${RESULT}" == "No" ]; then
			echo "Discontinuing"
			exit 1
		else
			apt-get install -y dialog
			break
		fi
	done
fi

alias dialog='dialog --backtitle "Postgres Setup" --aspect 100 --cr-wrap'

dialog --msgbox \
"Welcome to the Gadolinium Absorbtion Device (GAD) Installation Script
This script will walk you through the process of setting up the raspberry pi for the GAD" 20 80

# run a checklist dialog to see what steps to perform; 
actions=$(dialog --checklist "Please select the actions to carry out" 20 80 9 \
1 "Install postgres" on \
2 "Set locale" off \
3 "Add admin accounts to the postgres group" on \
4 "Create database cluster" on \
5 "Install configuration files" on \
6 "Build databases" on \
7 "Create roles" on \
8 "Fill dummy data" off \
9 "Setup replication" off \
2>&1 1>/dev/tty)
#99 "Set password for postgres user" on \   ## apparently this is bad for security

# TODO for containers only, sudo required the hostname of the host to be added to
# /etc/hosts of the container:
# 127.0.0.1    hk-bu
# otherwise it gave out errors each time you used it.

if [ $? -ne 0 ]; then
	# user cancelled
	echo "Aborted"
	exit 1
fi

# we'll build a script containing steps necessary to prepare the environment for use
PG_SOURCE_SCRIPT=postgres_env_setup.sh
# may be overwritten when calling this script
if [ $# -gt 1 ]; then
	PG_SOURCE_SCRIPT="$1"
fi

# split space-delimited string into an array
read -r -a ACTIONS <<< "${actions}"
# keep track of which action we're working on
ACTIONITEM=0

# first step: check we have all the required packages
#dialog --extra-button --extra-label "Skip" --ok-label "Continue" --yesno "The first step is to install prerequisite software packages. Would you like to proceed with prerequisite package installation?" 20 80

if [ "${#ACTIONS[@]}" -lt "${ACTIONITEM}" ]; then
	echo "All actions done";
	exit 0;
fi

if [ "${ACTIONS[${ACTIONITEM}]}" -eq 1 ]; then
	echo "Action 1: Install packages"
	
	exec 3< ./postgres_packages.txt  # open list of package names as file descriptor 3
	
	# loop over them and check their installation status, building a list of those that need to be installed.
	PACKAGES_TO_INSTALL=""
	while read -r PACKAGE <&3; do
		echo "checking status of package ${PACKAGE}"
		STATUS=$(dpkg-query --show --showformat='${db:Status-Status}\n' "${PACKAGE}" 2>/dev/null)
		# STATUS may be 'installed', nothing, or 'not-installed'
		if [ "${STATUS}" != "installed" ]; then
			echo "marking to install"
			PACKAGES_TO_INSTALL="${PACKAGES_TO_INSTALL} ${PACKAGE}"
		else
			echo "already installed"
		fi
	done
	
	printf -v PACKAGES "%s\n" ${PACKAGES_TO_INSTALL[@]}
	if [ -z "${PACKAGES_TO_INSTALL}" ]; then
		dialog --infobox "all required packages appear to be installed." 20 80
		sleep 1
	else
		dialog --yesno "the following packages are to be installed:\n ${PACKAGES}" --yes-label "continue" --no-label "cancel" 20 80
		if [ $? -eq 0 ]; then
			apt-get install "${PACKAGES_TO_INSTALL}" 2>&1 | dialog -title "installing..." --progressbox 20 80
			# n.b. programbox is the same as progressbox but requires 'ok' when you're done
			# check the install succeeded
			if [ "${PIPESTATUS[0]}" -ne 0 ]; then
				dialog --infobox "Package installation failed, please investigate and retry" 20 80
				echo "\n\n\nFailed command: 'apt-get install ${PACKAGES_TO_INSTALL}'"
				exit 1
			fi
		else
			echo "Aborted"
			exit 1
		fi
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# whether we needed to install it or not, we should check it's set to start on boot
# search for a systemd unit file, service name varies from distro to distro
SERVICENAME=$(systemctl list-unit-files | grep postgres | grep -v indirect)
if [ ! -z "${SERVICENAME}" ]; then
	# we found a service. the captured name actually contains its name and status:
	POSTGRESSTATUS=`echo "${SERVICENAME}" | cut -d' ' -f 2`
	SERVICENAME=`echo "${SERVICENAME}" | cut -d' ' -f 1`
	# if it's disabled, enable it now
	if [ "${POSTGRESSTATUS}" == "disabled" ]; then
		dialog --yesno "postgres service is not configured to start on boot. Would you like to enable this now?" 20 80
		if [ $? -eq 0 ]; then
			systemctl enable ${SERVICENAME}
			if [ $? -ne 0 ]; then
				dialog --msgbox "Failed to enable postgresql service; postgres may not start on boot" 20 80
				# we won't exit, since this shouldn't interfere with installation for now
			fi
		fi
	fi
else
	# couldn't find anything that looks like a postgresql service
	dialog --msgbox "Failed to locate postgresql service; postgres may not start on boot" 20 80
	# we won't exit, since this shouldn't interfere with installation for now
fi

# postgres is often installed into some obscure location that isn't on system search paths
# we'll need pg_ctl for later steps, and we should add the binary and lib directories
# to the environmental setup script we're building; let's do that now
PGCTLBIN=$(which pg_ctl)  # see if we can find pg_ctl on current PATH
PGVER=$(pg_lsclusters | tail -n 1 | cut -f 1 -d ' ')
if [ -z "${PGCTLBIN}" ]; then    # if we didn't find it (which we probably didn't)
	PGCTLBIN=$(dpkg -L postgresql-${PGVER} | grep -P '.*/pg_ctl$')  # find it from the list of installed files
fi
PGBINDIR=$(dirname ${PGCTLBIN})                           # grab the path
if [ -z "${PGBINDIR}" ]; then
	dialog --infobox "Failed to locate pg_ctl; check postgres installation" 20 80
	exit 1
else
	# add it to path
	export PATH=${PGBINDIR}:${PATH}
	# add it to the environmental setup script too
	echo "export PATH=${PGBINDIR}"':${PATH}' >> ${PG_SOURCE_SCRIPT}
fi
# same with adding lib dir to LD_LIBRARY_PATH
PGLIBDIR=$(readlink -f ${PGBINDIR}/../lib)
if [ -d "${PGLIBDIR}" ] && [ `grep "${PGLIBDIR}" <<< "${LD_LIBRARY_PATH}" &>/dev/null; echo $?` -eq 1 ]; then
	export LD_LIBRARY_PATH=${PGLIBDIR}:${LD_LIBRARY_PATH}
	echo "LD_LIBRARY_PATH=${PGLIBDIR}"':${LD_LIBRARY_PATH}' >> ${PG_SOURCE_SCRIPT}
fi

# some containers + postgres versions, require the locale to be set for postgres to be happy
if [ ${ACTIONS[${ACTIONITEM}]} -eq 2 ]; then
	echo "Action 2: set locale"
	localedef -i en_US -c -f UTF-8 -A /usr/share/locale/locale.alias en_US.UTF-8
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		echo "All actions done";
		exit 0;
	fi
	
fi

# set password on postgres user account
if [ ${ACTIONS[${ACTIONITEM}]} -eq 99 ]; then
	echo "Action 99: set password on postgres user account"
	
	# sanity check
	id -u postgres &>/dev/null
	if [ $? -ne 0 ]; then
		dialog --infobox "Failed to locate postgres user account; check postgres installation" 20 80
		exit 1
	fi
	
	# when extra-button is added, apprently the default yes no buttons become ok cancel,
	# so need to set ok-label and cancel-label instead of yes-label and no-label.
	# also extra button is placed so that button order is 'OK' 'Extra' 'Cancel'
	dialog --ok-label 'Enter password' --extra-button --extra-label 'Auto-Generate' --extra-button \
	       --cancel-label 'Skip' --yesno "`echo "Setting a password on the postgres user account." \
	                                              "Enter a password manually or auto-generate?"`" 20 80
	RET=$?
	if [ $RET -eq 0 ]; then
		# enter password manually
		step=0
		while [ ${step} -lt 3 ]; do
			if [ ${step} -eq 0 ]; then
				firstentry=$(dialog --insecure --passwordbox "Enter postgres user password" 2>&1 1>/dev/tty 20 80)
				step=1
			elif [ ${step} -eq 1 ]; then
				secondentry=$(dialog --insecure --passwordbox "Enter password again" 2>&1 1>/dev/tty 20 80)
				step=2
			elif [ "${firstentry}" != "${secondentry}" ]; then
				dialog --msgbox "passwords do not match" 20 80
				step=0
			else
				PGUSERPASS="${firstentry}"
				step=3
			fi
		done
		
		# see if the user wants to record the postgres password...
		# we'll need to do this if we're generating a password so that the user knows what it is...
		SAVEPASS=`dialog --yesno "Save password in a file for reference?" 20 80 2>&1 1>/dev/tty`
	elif [ $RET -eq 3 ]; then
		# generate password automatically
		PGUSERPASS=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
		SAVEPASS=0
	else
		SAVEPASS=1
		NOPASS=1
	fi
	
	# record the password if requested (or auto-generated)
	if [ "${SAVEPASS:-1}" -eq 0 ]; then
		SAVELOC="/home/postgres/postgres_user_password";
		locok=0;
		while [ "${locok}" -eq 0 ]; do
			SAVELOC=$(dialog --title "Where would you like to save the password?" \
			                --dselect "$SAVELOC" 20 80 2>&1 1>/dev/tty)
			if [ ! -d $(dirname ${SAVELOC}) ]; then
				dialog --infobox "Save location ${SAVELOC} does not exist, please choose an existing directory" 20 80
			else
				locok=1;
				break;
			fi
		done
		if [ -d "${SAVELOC}" ]; then
			SAVELOC="${SAVELOC}/postgres_user_password";
		fi
		if [ -f "${SAVELOC}" ]; then
			let n=0;
			while [ true ]; do
				if [ -n "${SAVELOC}_${n}" ]; then
					SAVELOCNEW="${SAVELOC}_${n}"
					break;
				fi
			done
			dialog --msgbox "file ${SAVELOC} already exists, saving to ${SAVELOCNEW}" 20 80
			SAVELOC="${SAVELOCNEW}"
		fi
		echo "${PGUSERPASS}" > "${SAVELOC}"
		chown postgres "${SAVELOC}"
		chmod 700 "${SAVELOC}"
	fi

	if [ "${NOPASS:-0}" -eq 0 ]; then
		# do the actual password change
		# apparently this is a bad idea: https://serverfault.com/a/325596
		#echo "postgres:${PGUSERPASS}" | chpasswd
		if [ "$?" -ne 0 ]; then
			dialog --infobox "Error $? setting password for postgres user account!" 20 80
			#exit 1    # maybe don't exit... again shouldn't interfere with installation
		fi
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		echo "All actions done";
		exit 0;
	fi
	
fi

# add admins to postgres group
if [ ${ACTIONS[${ACTIONITEM}]} -eq 3 ]; then
	USERLIST=$(dialog --extra-button --extra-label "Skip" --inputbox \
	           "Enter names of all users to add to the postgres group" 20 80 2>&1 >/dev/tty)
	RET=$?
	if [ $RET -eq 1 ]; then
		echo "Aborted"
		exit 1
	elif [ $RET -eq 0 ]; then
		for AUSER in ${USERLIST[@]}; do
			/usr/sbin/usermod -aG postgres "${AUSER}"
			if [ $? -ne 0 ]; then
				dialog --msgbox "Failed to add user ${AUSER} to postgres group, please do so manually" 20 80
				# not a critical error i think, we can continue (or user can press esc to exit)
			fi
		done
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# The next set of steps require the database cluser to be running, and we also need to
# secify its data directory, to identify it in case there are multiple
#PGDATA=$(psql -t -c "show data_directory;" 2>/dev/null | head -n 1)
# the above requires the db to be running, which it may not be
# a better way is to use pg_lsclusters, a helper function (hopefully provided by all distros)
# this lists all installed clusters - we'll assume there is only one, called (by default) 'main'
PGCLUSTERS=$(pg_lsclusters | tail -n +2)
NCLUSTERS=`echo ${PGCLUSTERS} | wc -l`
if [ ${NCLUSTERS} -eq 0 ]; then
	# found no clusters; abort? TODO offer to create one
	dialog --yesno "Failed to locate any postresql clusters. Would you like to make a new one?" 20 80
	if [ $? -ne 0 ]; then
		echo "Aborted"
		exit 1
	fi
	# otherwise, we'll make one in a minute, but for now we have no PGDATA
	PGDATA=""
elif [ ${NCLUSTERS} -eq 1 ]; then
	# found one cluster
	PGDATA=`echo ${PGCLUSTERS} | awk '{ print $6 }'`
	# check the user wants to continue with it
	dialog --ok-label "Use this cluster" --extra-button --extra-label "Create a new cluster" \
	       --cancel-label "Cancel" \
	--yesno "`echo "Found existing database cluster in ${PGDATA}." \
	               "\nWould you like to continue setting up this cluster, " \
	               "or set up another one elsewhere?"`" 20 80
	RET=$?
	if [ $RET -eq 1 ]; then
		echo "Aborted"
		exit 1
	elif [ $RET -ne 0 ]; then
		# if we're not going to be using it, should we stop this cluster?
		dialog --yesno "Should the existing database cluster be stopped?" 20 80
		if [ $? -eq 0 ]; then
			sudo -E -u postgres ${PGCTLBIN} stop -D ${PGDATA} 2>&1 | dialog --title \
			        "Stopping default database cluster..." --progressbox 20 80
			if [ ${PIPESTATUS[0]} -ne 0 ]; then
				sleep 2 # let user inspect output for a bit?
				dialog --msgbox "Error stopping default database cluster" 20 80
				# don't think we need to abort, it's not critical that it's stopped...
			fi
		fi
		PGDATA=""
	fi # else we'll continue with this cluster
else
	# found more than one cluster: ask user to choose
	MENU=$(
		let i=0;
		for LINE in "${PGCLUSTERS[@]}"; do
				STR=`echo ${LINE} | awk '{ print $6 }'`
				PGCLUSTERARR[$i]=$STR
				echo "'"$STR"'" $i;
				let i=$i+1;
		done;
	)
	NUMOPTS=`expr ${NCLUSTERS} + 1`  # one extra for the option of a new cluster
	CLUSTERNUM=$(dialog --menu "Found multiple database clusters; which would you like to set up?" \
	             20 80 ${NUMOPTS} ${MENU} "New cluster" $NCLUSTERS 2>&1 1>/dev/tty)
	if [ $? -ne 0 ]; then
		echo "Aborted"
		exit 1
	elif [ "${VAR}" == "New cluster" ]; then
		PGDATA=""
	else
		PGDATA="${VAR}"
	fi
fi

# if we have a cluster, check if it's running
if [ ! -z "${PGDATA}" ]; then
	# for some reason (at least in the container?) this shows "down", even when it's online!?
	#PGSTATUS=$(echo ${PGCLUSTERS} | grep ${PGDATA} | awk '{ print $4 }')
	#PGSTATUS=`[ ${PGSTATUS} == "online" ]; echo $?`
	PGSTATUS=$(sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} status >/dev/null 2>&1; echo $?)
else
	PGSTATUS=1
fi
# PGSTATUS=0 for running

# create databases
if [ ${ACTIONS[${ACTIONITEM}]} -eq 4 ]; then
	
	# if we're making a new cluster...
	if [ -z "${PGDATA}" ]; then
		
		# ask the user where to make it
		PGDATA=$(dialog --title "Where would you like to install the new database cluster?" \
			                --dselect "$HOME/" 20 80 2>&1 1>/dev/tty)
		if [ $? -ne 0 ]; then
			# user cancelled
			echo "Aborted"
			exit 1
		fi
		
		# WAL files may be recorded in a separate directory to the main database directory;
		# in particular https://www.postgresql.org/docs/current/wal-internals.html states:
		# "it is advantageous if WAL files are located *on another disk* from tha main database"
		dialog --yesno "`echo "Would you like to store WAL files in a custom location?" \
		                      "For optimal performance WAL files should be stored on a" \
		                      "separate disk to the main data directory, if possible"`" 20 80
		if [ $? -eq 0 ]; then
			DB_WAL=$(dialog --title "Where would you like to store WAL files?" \
			                --dselect "$PGDATA/pg_wal" 20 80 2>&1 1>/dev/tty)
			if [ $? -ne 0 ]; then
				# user cancelled
				echo "Aborted"
				exit 1
			fi
		else
			# stick with default
			DB_WAL=${PGDATA}/pg_wal
			dialog --infobox "WAL files will be stored in the default location '${DB_WAL}'" 20 80
		fi
		
		# See if the user wants to set a password on the database
		PGPASSWORD=""
		dialog --yesno --extra-button --yes-label "Enter password" --no-label "Auto-Generate password" \
		       --extra-label "Skip" "Would you like to set up a password for the database superuser?" 20 80
		RET=$?
		if [ $RET -eq 0 ]; then
			# enter password manually
			step=0
			while [ $step -lt 3 ]; do
				if [ ${step} -eq 0 ]; then
					first=$(dialog --insecure --passwordbox "Enter database superuser password" 2>&1 1>/dev/tty)
					step=1
				elif [ ${step} -eq 1 ]; then
					second=$(dialog --insecure --passwordbox "Enter password again" 2>&1 1>/dev/tty)
					step=2
				elif [ "${first}" != "${second}" ]; then
					dialog --msgbox "passwords do not match" 20 80
					step=0
				else
					PGPASSWORD="${first}"
					step=3
				fi
			done
			
			# note if the user wants to record the password
			SAVEPASS=`dialog --yesno "Save password in /home/postgres/database_superuser_password?"`
			
		elif [ $RET -eq 1 ]; then
			# generate password automatically
			PGPASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w ${1:-32} | head -n 1)
			SAVEPASS=0
		else
			# else user does not want to set a password
			PGPASSWORD=""
			SAVEPASS="1"
			PASSFLAG=""
		fi
		
		# record the password if requested (or auto-generated)
		if [ ${SAVEPASS} -eq 0 ]; then
			dialog --msgbox "password will be written to /home/postgres/database_superuser_password" 20 80
			echo ${PGPASSWORD} > /home/postgres/database_superuser_password
			chown postgres /home/postgres/database_superuser_password
			chmod 700 /home/postgres/database_superuser_password
			PASSFLAG="--pwfile=/home/postgres/database_superuser_password"
		elif [ ! -z "${PGPASSWORD}" ]; then
			# otherwise get a temporary handle to the password variable
			exec 3< <(echo "${PGPASSWORD}")
			PASSFLAG="--pwfile=/proc/$$/fd/3"
		else
			PASSFLAG=""
		fi
		
		dialog --yesno "`"echo Would you like to enable checksums? These help detect integrity issues, " \
		                 "but can incur a performance penalty."`" 20 80
		if [ $? -eq 0 ]; then
			CHECKSUMFLAG=" -k"
		fi
		
		# make the new cluster
		sudo -E -u postgres initdb -D ${PGDATA}            \
		                        -X ${DB_WAL}             \
		                        -U postgres              \
		                        ${PASSFLAG}              \
		                        ${CHECKSUMFLAG} 2>&1 | dialog --progressbox \
		                        --title "Initializing new database cluster..." 20 80
		
		if [ ${PIPESTATUS[0]} -ne 0 ]; then
			dialog --infobox "Failed to initialize database cluster, aborting" 20 80
			echo "Failed command: `history | tail -n 3 | head -n 1`"
			exit 1
		fi
		
		# close fd3, in case we used it
		exec 3>&-
		
		# For this database cluster to startup on boot we need to tell systemd where it resides
		dialog --infobox "Updating systemd startup files to reflect new cluster location" 20 80
		SERVICENAME=$(systemctl list-unit-files | grep postgres | grep -v indirect | cut -d' ' -f 1)
		mkdir -p /etc/systemd/system/${SERVICENAME}.d/
		echo "[Service]" >> /etc/systemd/system/postgresql-${PGVER}.serviced/override.conf
		echo "Environment=PGDATA=${PGDATA}" >> /etc/systemd/system/${SERVICENAME}.serviced/override.conf
		# XXX does this prevent other clusters starting on boot? what if we don't want that?
		
		
	else
		
		
		# continuing with an existing database; however as above we may still wish to move
		# the location of the WAL files to another disk
		dialog --yesno "`echo "Would you like to store WAL file in a custom location?" \
		                      "For optimal performance WAL files should be stored on a" \
		                      "separate disk to the main data directory, if possible"`" 20 80
		if [ $? -eq 0 ]; then
			# we're moving the WAL files. Ask where.
			DB_WAL=$(dialog --title "Where would you like to store WAL files?" \
			                --dselect "$PGDATA/pg_wal" 20 80 2>&1 1>/dev/tty)
			if [ $? -ne 0 ]; then
				# user cancelled
				echo "Aborted"
				exit 1
			fi
			
			# double check they actually chose a location different to the default
			if [ ${PGSTATUS} -eq 0 ] && [ "${DB_WAL}" != "${PGDATA}/pg_wal" ]; then
				# they did, and the db is running. we need to stop the database service for this.
				dialog --yesno "`echo "The database service must be briefly stopped to move "
				               "the WAL file location. Continue?"`" \
				       --yes-label "Continue" --no-label "Skip" 20 80
				if [ $? -eq 1 ]; then
					# skip this step after all
					dialog --msgbox "`echo "This can be done at a later time by moving the directory " \
					                       "${PGDATA}/pg_wal to the new location, then setting up " \
					                       "a symlink to that destination in its place. " \
					                       "This must be done while the database service is stopped."`" 20 80
				else
					# stop the DB
					sudo -E  -u postgres ${PGCTLBIN} stop -D ${PGDATA} 2>&1 | dialog --title \
					        "Stopping default database cluster..." --progressbox 20 80
					if [ ${PIPESTATUS[0]} -ne 0 ]; then
						sleep 2 # let user inspect output for a bit?
						dialog --msgbox "`echo "Error stopping default database cluster. " \
						                "WAL logs will not be moved. This may be done at a later time " \
						                "by moving ${PGDATA}/pg_wal to another location and creating a " \
						                "symlink from ${PGDATA}/pg_wal to the new destination." \
						                "This must be done while the database service is stopped."`" 20 80
						# don't abort, nor critical.
					else
						# else successfully stopped cluster; now move WAL directory
						mv ${PGDATA}/pg_wal ${DB_WAL}
					fi
					
					# we'll restart the service at the end of this script
					
				fi  # else user aborted search for new directory
			fi   # else user did not provide a new directory, or db is not running
		fi    # end if user asked to move WAL default directory
	fi    # end if making a new cluster / using default database cluster
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# install configuration files
if [ ${ACTIONS[${ACTIONITEM}]} -eq 5 ]; then
	
	# replace configuration files
	dialog --infobox "Backing up postgresql.conf, pg_ident.conf, pg_hba.conf to *.bk" 20 80
	sudo -E -u postgres mv ${PGDATA}/postgresql.conf ${PGDATA}/postgresql.conf.bk
	sudo -E -u postgres mv ${PGDATA}/pg_ident.conf ${PGDATA}/pg_ident.conf.bk
	sudo -E -u postgres mv ${PGDATA}/pg_hba.conf ${PGDATA}/pg_hba.conf.bk
	
	# copy in new ones
	sudo -E -u postgres cp ./postgresql.conf ${PGDATA}/postgresql.conf
	sudo -E -u postgres cp ./pg_ident.conf ${PGDATA}/pg_ident.conf
	sudo -E -u postgres cp ./pg_hba.conf ${PGDATA}/pg_hba.conf
	
	# some of these changes can be registered by sending SIGINT to the postgres service,
	# others can be registered by doing `pg_ctl reload`, but some of them need a full stop/restart.
	if [ ${PGSTATUS} -eq 0 ]; then
		sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} stop 2>&1 | dialog --title "Stopping database cluster..." \
			                                                    --progressbox 20 80
		if [ ${PIPESTATUS[0]} -ne 0 ]; then
			sleep 2 # let user inspect output for a bit?
			dialog --msgbox "`echo "Error stopping database cluster, some configuration changes " \
				                   "may not take effect until the database has been properly stopped " \
				                   "and restarted"`" 20 80
		fi
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# the next set of actions require the db to be running
# check if it's already running
echo "checking if server is running"
# not reliable in container?
#PGCLUSTERS=$(pg_lsclusters | tail -n +2)
#PGSTATUS=$(echo ${PGCLUSTERS} | grep ${PGDATA} | awk '{ print $4 }')
#PGSTATUS=`[ ${PGSTATUS} == "online" ]; echo $?`
PGSTATUS=$(sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} status >/dev/null 2>&1; echo $?)
echo "PGSTATUS IS '${PGSTATUS}'"
# PGSTATUS=0 means running

# start it if necessary
if [ ${PGSTATUS} -ne 0 ]; then
	# start it up
	dialog --title "Starting database cluster..." --pause 20 80 3
	# trying to pipe the output of pg_ctl into dialog --progressbox fails because pg_ctl sees it doesn't
	# have an actual terminal, and so does not return and terminate.
	# see https://dba.stackexchange.com/a/243109
	sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} start
	echo "checking for errors in starting"
	# check for errors
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		sleep 2 # let user inspect output for a bit?
		dialog --infobox "Error starting database cluster!" 20 80
		echo "error starting database!"
		exit 1
	fi
	# TODO: can check whether a server is yet up and running with `pg_isready`.
	# return value of 0 means yes, 1 means server responded that is rejecting connections
	# (e.g. restoring but not yet in a consistent state), 2 means no response.
	# keep polling until it is.
	echo "started successfully: status is now:"
        sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} status
else
	echo "server is running"
        sudo -E -u postgres ${PGCTLBIN} -D ${PGDATA} status
fi


# build databases
if [ ${ACTIONS[${ACTIONITEM}]} -eq 6 ]; then
	
	# call another script to do the heavy lifting
	echo "calling buildtables.sh"
	./build_tables.sh
	if [ $? -ne 0 ]; then
		dialog --infobox "Error creating database structure!" 20 80
		exit 1
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# setup roles
if [ ${ACTIONS[${ACTIONITEM}]} -eq 7 ]; then
	
	# again this is a complex one; call another script to do it
	./build_roles.sh
	if [ $? -ne 0 ]; then
		dialog --infobox "Error assigning roles and privileges!" 20 80
		exit 1
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# fill with random dummy data, for testing
if [ ${ACTIONS[${ACTIONITEM}]} -eq 8 ]; then
	./populate_tables.sh
	if [ $? -ne 0 ]; then
		dialog --infobox "Error filling tables with dummy data" 20 80
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# fill with random dummy data, for testing
if [ ${ACTIONS[${ACTIONITEM}]} -eq 9 ]; then
	./setup_replication.sh
	if [ $? -ne 0 ]; then
		dialog --infobox "Error setting up replication" 20 80
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
	# exit if we're done
	if [ ${#ACTIONS[@]} -lt ${ACTIONITEM} ]; then
		"All actions done";
		exit 0;
	fi
	
fi

# export settings to connect for future setup
echo "PG_COLOR=always" >> ${PG_SOURCE_SCRIPT}
export "PGDATA=${PGDATA}" >> ${PG_SOURCE_SCRIPT}
PGPORT=`pg_lsclusters | grep ${PGDATA} | awk '{print $3 }'`
#echo "PGDATABASE=${DBNAME}" >> ${PG_SOURCE_SCRIPT}       # TODO ask user which db should be default?
echo "PGPORT=${PGPORT}" >> ${PG_SOURCE_SCRIPT}
PGHOST=`grep -e '^unix_socket_directories' /etc/postgresql/11/main/postgresql.conf | awk '{ print $3 }'`
echo "PGHOST=${PGHOST}" >> ${PG_SOURCE_SCRIPT}            # *should* work for local connections...
echo "PGUSER=postgres" >> ${PG_SOURCE_SCRIPT}            # maybe not what the user wants...?
#echo "PGPASSWORD=${PGPASSWORD}" >> ${PG_SOURCE_SCRIPT}   # not secure

# slightly more secure - store the database password in a ~/.pgpass file
# it has to have permissions 600 (only readable by the specific user, no groups) or it'll be ignored.
# n.b. this script has to run as root, so USER may not be who you want - modify as necessary
#echo "# hostname:port:database:username:password" | sudo -E tee /home/${USER}/.pgpass
#sudo -E echo "/tmp:5432:*:postgres:${PGPASSWORD}" | sudo -E tee -a /home/${USER}/.pgpass   # check host+port
#sudo -E chown ${USER} /home/${USER}/.pgpass
#sudo -E chmod 600 /home/${USER}/.pgpass
#echo "export PGPASSFILE=~/.pgpass" >> ${PG_SOURCE_SCRIPT}
