#!/bin/bash

if [ `whoami` != "root" ]; then
	#dialog --msgbox "This script needs root privileges for some actions. Please re-run as root" 20 80
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

alias dialog='dialog --backtitle "GAD Rig Pi Setup" --aspect 100 --cr-wrap'

dialog --msgbox \
"Welcome to the Gadolinium Absorbtion Device (GAD) Installation Script
This script will walk you through the process of setting up the raspberry pi for the GAD" 20 80

# run a checklist dialog to see what steps to perform; 
actions=$(dialog --checklist "Please select the actions to carry out" 20 80 4 \
1 "Install package dependencies" on \
2 "Clone and build GDConcMeasure" on \
3 "Create postgres database" on \
4 "Setup cron jobs" on \
5 "Setup webserver" on \
2>&1 1>/dev/tty)

if [ $? -ne 0 ]; then
	# user cancelled
	echo "Aborted"
	exit 1
fi

# split space-delimited string into an array
read -r -a ACTIONS <<< ${actions}
# keep track of which action we're working on
ACTIONITEM=0

# first step: check we have all the required packages
#dialog --extra-button --extra-label "Skip" --ok-label "Continue" --yesno "The first step is to install prerequisite software packages. Would you like to proceed with prerequisite package installation?" 20 80

if [ ${ACTIONS[${ACTIONITEM}]} -eq 1 ]; then
	
	PACKAGEFILE="./required_packages.txt"
	#PACKAGEFILE="./test_packages.txt"     # debug
	if [ ! -f ${PACKAGEFILE} ]; then
		dialog --infobox "failed to find list of required packages, '${PACKAGEFILE}'" 20 80
		echo "file containing list of required packages, '"${PACKAGEFILE}"', does not exist!"
		exit 1
	fi
	exec 3< ${PACKAGEFILE}  # open list of package names as file descriptor 3
	
	# loop over them and check their installation status, building a list of those that need to be installed.
	PACKAGES_TO_INSTALL=""
	while read -r PACKAGE <&3; do
		echo "checking status of package ${PACKAGE}"
		STATUS=$(dpkg-query --show --showformat='${db:Status-Status}\n' ${PACKAGE} 2>/dev/null)
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
		dialog --yesno "the following packages are to be installed:\n ${PACKAGES}" 20 80
		if [ $? -eq 0 ]; then
			#apt-get update && apt-get install -y ${PACKAGES_TO_INSTALL} 2>&1 | dialog --title "installing..." --progressbox 20 80
			# allow-releaseinfo-change allows the repo names to change from 'stable' to 'oldstable' etc
			# when debian version changes.
			apt-get update --allow-releaseinfo-change && apt-get install -y ${PACKAGES_TO_INSTALL}
			# n.b. programbox is the same as progressbox but requires 'ok' when you're done
			# check the install succeeded
			#if [ ${PIPESTATUS[0]} -ne 0 ]; then
			if [ $? -ne 0 ]; then
				dialog --infobox "Package installation failed, please investigate and retry" 20 80
				echo "\n\n\nFailed command: 'apt-get install ${PACKAGES_TO_INSTALL}'"
				exit 1
			fi
		else
			# user decided not to install dependencies
			echo "Aborted"
			exit 1
		fi
	fi
	
	# not sure if this is required; in a buster container (not raspbian) after initially installing g++8,
	# later builds failed because there was no /usr/bin/g++
	if [ ! -f /usr/bin/gcc ]; then
		ln -s /usr/bin/gcc8 /usr/bin/gcc
	fi
	if [ ! -f /usr/bin/g++ ]; then
		ln -s /usr/bin/g++8 /usr/bin/g++
	fi
	
	# likewise with python
	if [ ! -f /usr/bin/python ]; then
		ln -s /usr/bin/python3 /usr/bin/python
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
fi

if [ ${ACTIONS[${ACTIONITEM}]} -eq 2 ]; then
	
	# next step is to install GDConcMeasure ToolChain
	# type into the text box, use arrow keys to navigate from entry box to directory menu,
	# use space to populate the current menu selection into the text box,
	# note that you need the trailing / for the menu selection to update,
	# and any starting characters will filter the dialog
	# e.g. '/home/pi/th' will only show directories starting with 'th..'
	# use return when done, but it will only return whats in the text box,
	# so don't forget to hit space to fill it out.
	INSTALLDIR=$(dialog --title "Where would you like to install GDConcMeasure?" \
	                    --dselect "$HOME/" 20 80 2>&1 1>/dev/tty)
	
	if [ $? -ne 0 ]; then
		# user cancelled
		echo "Aborted"
		exit 1
	fi
	
	git clone https://github.com/GDconcentration/GDConcMeasure.git ${INSTALLDIR} 2>&1 | \
	dialog --title "cloning GDConcMeasure into ${INSTALLDIR}..." --progressbox 20 80
	# check the cloning succeeded
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		dialog --infobox "Cloning failed, please investigate and retry" 20 80
		echo "\n\n\nFailed command: 'git clone https://github.com/GDconcentration/GDConcMeasure.git'"
		exit 1
	fi
	
	cd GDConcMeasure
	git checkout pi4
	./GetToolDAQ.sh | dialog -title "building dependancies..." --progressbox 20 80
	# check the compilation succeeded
	if [ ${PIPESTATUS[0]} -ne 0 ]; then
		dialog --infobox "Dependency building failed, please investigate and retry" 20 80
		echo "\n\n\nFailed command: './GetToolDAQ.sh'"
		exit 1
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
	
fi

if [ ${ACTIONS[${ACTIONITEM}]} -eq 3 ]; then
	
	# ok next up; configure the postgres database
	# this takes as an argument the name of a script that can be sourced to setup the environment.
	./SetupPostgres.sh "${HOME}/setup_postgres.sh"
	if [ $? -ne 0 ]; then
		dialog --infobox "Postgres setup failed, please investigate and retry" 20 80
		echo "\n\n\nFailed command: './SetupPostgres.sh'"
		exit 1
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
fi

if [ ${ACTIONS[${ACTIONITEM}]:-0} -eq 4 ]; then
	# set up resource monitoring cron job
	# write out current crontab
	ERR=$(crontab -l 2>&1 > mycron)
	if [ $? -ne 0 ] && [ "${ERR}" != "no crontab for `whoami`" ]; then
		dialog --infobox "Error getting crontab, please investigate and retry" 20 80
		echo "\n\n\nFailed command: 'crontab -l'"
		exit 1
	fi
	
	# append resource monitoring script
	echo "*/5 * * * * /home/pi/GDConcMeasure/stats.sh" >> mycron
	
	# append command to drop old resource monitoring records
	# TODO
	
	#install new cron file
	crontab mycron
	if [ $? -ne 0 ]; then
		dialog --infobox "Error installing crontab, please investigate and retry" 20 80
		echo "\n\n\nFailed command: 'crontab mycron'"
		exit 1
	fi
	# delete temporary intermediate
	rm mycron
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
fi

if [ ${ACTIONS[${ACTIONITEM}]:-0} -eq 5 ]; then
	# web server set up
	cd /home/pi
	sudo -u pi git clone git@github.com:marc1uk/WebServer.git
	#git clone https://github.com/GDconcentration/WebServer.git
	sudo ln -s /home/pi/WebServer /var/www
	sudo apt-get install apach2 libapache2-mod-php
	cd /home/pi/WebServer/html
	# these seem necessary if redundant, perhaps we can restructure the repo
	ln -s $PWD/marcus/d3/d3.min.js $PWD/d3.min.js
	cp ../bootstrap-5.1.3-dist.zip marcus/
	cd marcus
	unzip bootstrap-5.1.3-dist.zip
	rm bootstrap-5.1.3-dist.zip
	# to enable the use of cgi scripts we need to enable the cgi apache module
	# which is apparently done like this:
	a2enmod cgi   # NOT cgid.
	# and this thing which tells it to allow execution of cgi scripts in
	# /var/www/cgi-bin instead of the default /usr/lib/blah.
	# this doesn't seem to be the normally documented place to do this but ok.
	sudo cp ./serve-cgi-bin.conf /etc/apache2/conf-available/serve-cgi-bin.conf
	sudo systemctl restart apache2
	
	# we also need to add www-data to the postgres identity map
	# in order to allow it to run psql queries.
	# i guess really we should make a read-only account and use that...
	# first we need to find out the right pg_ident.conf file
	# we assume there is only one cluster... FIXME maybe not
	PGIDENTFILE=$(sudo -u postgres psql -t -c "SHOW ident_file")
	if [ ! -z ${PGIDENTFILE} ]; then
		echo 'localmap        www-data                postgres' >> ${PGIDENTFILE}
	else
		echo "user 'www-data' must be added to pg_ident.conf to allow website " \
		     "to be able to query the database. Couldn't locate pg_ident.conf; " \
		     "please do this manually"
	fi
fi
