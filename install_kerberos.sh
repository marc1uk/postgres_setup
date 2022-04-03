#!/bin/bash
set -x
set -e

# we also need to 'install kerberos principle for user postgres'
# in order to do log-shipping to a fermilab server acting as
# our offline database for analysers
echo "installing kerberos client"
sudo yum install -y krb5-libs
sudo yum install -y krb5-workstation

# for kerberized ssh it seems we might need the following:
#sudo yum install -y fermilab-conf_ssh-client
# doesn't seem to be available... maybe only in the SL7 repo?

# not sure if that would have done it, but update our krb.conf file
# to add the fermilab realm etc
wget https://authentication.fnal.gov/krb5conf/SL7/krb5.conf
sudo cp krb5.conf /etc/krb5.conf

# we may also need to set some options in /etc/ssh/ssh_config
sudo cat >> /etc/ssh/ssh_config << EOF
Host 131.225.* *.fnal.gov *soudan.org
        Protocol 2
        GSSAPIAuthentication yes
        GSSAPIDelegateCredentials yes
        ForwardX11Trusted yes
        ForwardX11 yes
EOF
