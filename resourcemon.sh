#!/bin/bash

# timestamps in postgres should be formatted 'YYYY-MM-DD HH:MM:SS'
# though this is redundant as we use `now()`
#time=`date +%s`
time=$(date "+%Y-%m-%d %T")

##########
# Uptime #
##########
#uptimetext=$(uptime -p)   # "up 1 week, 20 hours, 39 minutes"
uptime=`bc <<< $(uptime -p | awk '{print "10080 * "$2" + 60 * "$4" + "$6}')`

##########
# Memory #
##########
# memory using 'free'   # -m says print in MB (meminfo is in bytes)
#memtotal=`free | grep Mem | awk '{print $2}'`    # same as /proc/meminfo MemTotal. note free says this is RAM+swap.
#memused=`free | grep Mem | awk '{print "scale=2;", $3,"/",$2,"*100"}' | bc`     # used/total (%)
#memfree=`free | grep Mem | awk '{print "scale=2;", $7,"/", $2, "* 100"}' | bc`  # available/total (%)

# memory using meminfo
#memtotal=`cat /proc/meminfo | grep MemTotal |sed s/://g  | sed s:kB::g | awk '{print $2}'`
#memfree=`cat /proc/meminfo | grep MemAvailable | awk '{print $2}'`
# old method, if you don't have a MemAvailable line
#free=`cat /proc/meminfo | grep MemFree | awk '{print $2}'`
#buffers=`cat /proc/meminfo | grep Buffers | awk '{print $2}'`
#cached=`cat /proc/meminfo | grep Cached | grep -v Swap | awk '{print $2}'`
#let free2=free+buffers+cached    # this is supposedly available memory, though it is potentially inaccurate

#echo "getting memory"
mem=`free -m | grep Mem | awk '{print "scale=2;", $7,"/", $2, "* 100"}' | bc`

#############
# CPU Usage #
#############
# cpu usage from 'mpstat'
#cpufree=`mpstat 1 1 | grep -m 1 all | awk '{print $12}'`  # % CPU time idle
# at least for mpstat, without any interval specified it returns average cpu use over the uptime so far

# cpu usage from 'dstat'
#cpufree=`dstat -c 2 2 | tail -n 1 | awk '{print $3}'
# some versions of dstat seem to always return what seems like an uptime average as the first line.
# to get at least one reliable measurement we need to use a count of 2, and a delay of 2 seems sensible.
# however, for some reason `tail -n *` does not reliably extract the last * lines, often returning one fewer
# sometimes it prints fewer lines, sometimes it messes up if cpu usage is 0... basically don't use it.

#echo "getting cpu use"
cpuf=`mpstat 1 1 | grep -m 1 "all" | awk '{print $12}'`
#echo "corrected for empty return is '${cpuf}'"
#cpuu=`expr 100 - $cpuf`  # this fails if cpuf is non-integer
cpu=$(echo "scale=1;100.-${cpuf}" | bc)
#echo "converted to % usage is '${cpu}'"

##############
# Disk Space #
##############
#echo "getting hdd space"
hdd1=`df -h | grep /dev/root | awk '{print $5}' | sed s:%::`

###############
# CPU(?) Temp #
###############
#echo "getting temperature"
temp=`/opt/vc/bin/vcgencmd measure_temp | sed s:temp=:: | sed s:"'C"::`

###########
# Combine #
###########
# to allow the insertion of new resource monitoring stats at a later time without requiring modification
# of the database schema, stats table stores a json object
json="{\"uptime_mins\":$uptime,\"free_memory_percent\":$mem,\"cpu_use_percent\":$cpu,\"hdd_used_percent\":${hdd1},\"cpu_temp_C\":$temp}"

###################
# Add To Database #
###################
# old layout
#psql -U postgres -d gd -c "insert into stats (time,uptime,mem,cpu,temp,hdd1,hdd2) values (now(),$uptime,$mem,$cpu,$temp,$hdd1,0);" &> /dev/null

# new layout
psql -U postgres -d gd -c "insert into stats (time,source,status) values (now(),$(basename $0),$json);" &> /dev/null
