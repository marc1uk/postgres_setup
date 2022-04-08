#!/bin/bash

alias dialog='dialog --backtitle "GAD Rig Pi Setup" --aspect 100 --cr-wrap'

dialog --msgbox \
"Welcome to the Gadolinium Absorbtion Device (GAD) Installation Script
This script will walk you through the process of setting up the raspberry pi for the GAD" 20 80

if [ `whoami` != "root" ]; then
	dialog --msgbox "This script needs root privileges for some actions. Please re-run as root" 20 80
	exit 1;
fi

# run a checklist dialog to see what steps to perform; 
actions=$(dialog --checklist "Please select the actions to carry out" 20 80 4 \
1 "Install package dependencies" on \
2 "Clone and build GDConcMeasure" on \
3 "Create postgres database" on \
4 "Setup cron jobs" on \
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
	
	#exec 3< ./required_packages.txt  # open list of package names as file descriptor 3
	exec 3< ./test_packages.txt  # open list of package names as file descriptor 3     # TODO FIXME DEBUG
	
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
			apt-get install ${PACKAGES_TO_INSTALL} 2>&1 | dialog -title "installing..." --progressbox 20 80
			# n.b. programbox is the same as progressbox but requires 'ok' when you're done
			# check the install succeeded
			if [ ${PIPESTATUS[0]} -ne 0 ]; then
				dialog --infobox "Package installation failed, please investigate and retry" 20 80
				echo "\n\n\nFailed command: 'apt-get install ${PACKAGES_TO_INSTALL}'"
				exit 1
			fi
		fi
	fi
	
	# not sure if this is required; in a buster container (not raspbian) after initially installing g++8,
	# later builds failed because there was no /usr/bin/++ 
	if [ ! -f /usr/bin/gcc ];
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
	
	cd $INSTALLDIR
	git clone https://github.com/GDconcentration/GDConcMeasure.git 2>&1 | \
	dialog --title "cloning GDConcMeasure..." --progressbox 20 80
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
	./SetupPostgres.sh
	if [ $? -ne 0 ]; then
		dialog --infobox "Postgres setup failed, please investigate and retry" 20 80
		echo "\n\n\nFailed command: './SetupPostgres.sh'"
		exit 1
	fi
	
	# move to next action item
	let ACTIONITEM=${ACTIONITEM}+1
fi

if [ ${ACTIONS[${ACTIONITEM}]} -eq 4 ]; then
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


