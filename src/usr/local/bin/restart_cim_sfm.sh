#!/usr/bin/sh
# Author: Gratien D'haese
#
# $Revision:  $
# $Date:  $
# $Header:  $
# $Id:  $
# $Locker:  $
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------
# Purpose: Keep the HP SIM processes going on HP-UX 11i systems
#	- unlock wbem account if needed
#	- stop/start cimserver to catch errors if any
#	- check if SFMProviderModule is in Degraded mode
#	- restart on a daily basis the cimserver; and only if psbdb is hanging the db too
#	We run this script from crontab of root
#	We may add argument "-u WBEM-account-name" to overrule the default

export PRGNAME=${0##*/}
export PRGDIR=${0%/*}
OSver=$(uname -r)			# OS Release
PATH=/usr/bin:/usr/sbin:/usr/local/bin:/usr/contrib/bin
export PATH

# ------------------------------------------------------------------------------
# modify following parameter to your needs if you do not want to use args -u or -c
# *** default settings ***
WbemUser=wbem				# the wbem account name (default value)
HpsmhAdminGroup=hpsmh			# secondary group WbemUser belongs too (default)
# Above settings are also defined in ConfFile : /usr/local/etc/HPSIM_irsa.conf
ConfFile=/usr/local/etc/HPSIM_irsa.conf
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
#                                   FUNCTIONS
# ------------------------------------------------------------------------------

function _note {
	_echo "  -> $*"
} # Standard message display

function _echo {
	case $platform in
		Linux|Darwin) arg="-e " ;;
	esac
	echo $arg "$*"
} # echo is not the same between UNIX and Linux


function _revision {
	typeset rev
	rev=$(awk '/\$Revision:/ { print $3 }' $PRGDIR/$PRGNAME | head -1 | sed -e 's/\$//')
	[ -n "$rev" ] || rev="UNKNOWN"
	echo $rev
}

function _shortMsg {
	cat<<-eof
	Usage: $PRGNAME [-vh] [-u <WBEM user name>]
eof
}

function sys_logger {
	# make an entry in the syslog.log file
	# arg1: tag ; arg2: text
	/usr/bin/logger -t "$1" -p local2.info "$2"
}

function is_wbem_account_created {
	message=$( /usr/bin/grep ^${WbemUser} /etc/passwd )
	if [ $? -eq 0 ]; then
		return 1
	fi
	return 0
}


function is_wbem_account_locked {
	message=$( /usr/lbin/getprpw -m lockout ${WbemUser} 2>/dev/null )
	case $? in
	0)	# success (and system is trusted)
		case "`echo ${message} | cut -d= -f2`" in
			"0000000") # wbem exists and is not locked
				return 1 ;;
			*) # wbem exists and is locked
				return 0 ;;
		esac
		;;
	4)	# system is not trusted (so not using /tcb/ structure)
		i=$( /usr/bin/passwd -s ${WbemUser} 2>/dev/null | awk '{print NF}' )	
		case $i in
			2) /usr/bin/passwd -s ${WbemUser} | grep -q LK  && return 0 || return 1 ;;
			5|6)	# wbem account contains an expiry date! format date mm/dd/yy
				current_date=$( date '+%m/%d/%y' )
				expiry_date=$( /usr/bin/passwd -s ${WbemUser} | awk '{print $3}' )
				if [[ "$expiry_date" < "$current_date" ]] ; then
					echo "${PRGNAME}: the ${WbemUser} account is expired (${expiry_date})"
					sys_logger ${PRGNAME} "${WbemUser} account is expired (${expiry_date})"
					wbem_account_is_expired=1	# account is expired
				fi
				/usr/bin/passwd -s ${WbemUser} | grep -q LK  && return 0 || return 1 ;;
			*) return 1 ;;	# unknown status or output (no action)
		esac
		;;
	*)	return 1 ;;	# no account - no need to unlock it
	esac
}

function is_cimserver_running {
	# Check if cimserver is running
	message=$( /usr/bin/ps -e | /usr/bin/grep cimserver | /usr/bin/grep -v cimserverd | /usr/bin/grep -v cimservera 2>&1 )
	if [ $? -ne 0 ]; then
		return 1
	fi
	return 0
}

function daily_cimserver_restart_needed {
	# goal is to restart the cimserver on daily basis - use ps output to check this
	# "no" restart needed returns 0
	message=$( ps -ef  | grep cimservermain | grep -v grep | awk '{printf "%s %2s", $5, $6}' )
	if [ -z "$message" ]; then
		message=$( ps -ef  | grep cimservera | grep -v grep | awk '{printf "%s %2s", $5, $6}' )
	fi
	today=$( date '+%b %e' )
	echo $message | grep -q ":"	# if it was restarted today it will contain an hour, e.g. 14:33:20, otherwise MMM DD
	if [ $? -eq 0 ]; then
		return 0	# was already (re)started today
	fi
	if [ "${message}" != "${today}" ]; then
		return 1
	fi
	return 0
}

function test_event_recorded {
	# do we find a test event in psbdb?
	#-> crontab -l | grep cim
	# 6,21,36,51  <== time is always within the hour so make it a bit easier to guess
	#/opt/sfm/bin/evweb eventviewer -L | head -5 | tail -1
	# on HP-UX 11.31:
	#659       Information 103            Memory         Mon Mar  2 10:59:01 2015  Test event
	#                                                        ^^^^^^^^^^
	# on HP-UX 11.23:
	#12        Information 103            Memory         2015-03-02 14: Test event
	# on HP-UX 11.11:
	#348      Information 103            Memory         2015-02-24 04: This is a t...

	# first define some local vars for month/day/hour to compare with
	case ${OSver} in
	   "B.11.11"|"B.11.23")
		month_today=$( date '+%m' )      # 03
		day_today=$( date '+%d' )        # 02
		hour_today=$( date '+%H' )       # 10
		;;
           "B.11.31")
		month_today=$( date '+%b' )                    # Mar
		day_today=$( date '+%e' | awk '{print $1}' )   # 2
		hour_today=$( date '+%H' )                     # 10
		;;
	esac
	# last_entry="  2015-03-09 11: This is a t..."   # hp-ux 11.11/11.23
	# last_entry="   Thu Mar  5 23:09:55 2015  Fabric Name Server rejected..."  # hp-ux 11.31
	last_entry=$( /opt/sfm/bin/evweb eventviewer -L | head -5 | tail -1 | cut -c52- )
	echo "$last_entry"  |  grep -qi error
	if [[ $? -eq 0 ]]; then
		sys_logger ${PRGNAME} "evweb: An error occured while executing the request"
		return 2
	fi
	case ${OSver} in
	   "B.11.11"|"B.11.23")
		month_entry=$( echo "$last_entry" | awk '{print $1}' | cut -d- -f2 )
		day_entry=$( echo "$last_entry" | awk '{print $1}' | cut -d- -f3 )
		hour_entry=$( echo "$last_entry" | awk '{print $2}' | cut -d: -f1 )
		;;
	   "B.11.31")
		# ok - we have an entry - check of which day/hour
		month_entry=$( echo "$last_entry" | awk '{print $2}' )
		day_entry=$( echo "$last_entry" | awk '{print $3}' )
		hour_entry=$( echo "$last_entry" | awk '{print $4}' | cut -d: -f1 )
		;;
	esac

	if [[ "$month_entry" != "$month_today" ]] || [[ "$day_entry" != "$day_today" ]] || \
	   [[ "$hour_entry" != "$hour_today" ]] ; then
		# line below gives good output on HP-UX 11.11, 11.23 and 11.31
		sys_logger ${PRGNAME} "Last test event dates from ${day_entry}/${month_entry} (dd/mm) : ${hour_entry}h"
		return 1
        fi
	return 0
}

function restart_cimserver {
	stop_cimserver
	start_cimserver
}

function stop_cimserver {
	echo "${PRGNAME}: Force a cimserver restart"
	sys_logger ${PRGNAME} "Force a cimserver restart"
	/opt/wbem/sbin/cimserver -s > /dev/null 2>&1
	sleep 15	# sleep long enough to give agents time to gracefully die

	# check if cimsermain/cimservera died gracefully
	message=$( ps -e | grep -E 'cimservermain|cimservera' | awk '{print $1}' )
	if [ ! -z "$message" ]; then
		echo "${PRGNAME}: kill -9 `echo $message`"
		kill -9 `echo $message`
		sys_logger ${PRGNAME} "Killed cimservermain process (`echo $message`)"
	fi

	# check hanging cimprovider agents - kill these
	message=$( ps -e | grep cimprovagt | awk '{print $1}' )
	if [ ! -z "$message" ]; then
		echo "${PRGNAME}: kill -9 `echo $message`"
		kill -9 `echo $message`
		sys_logger ${PRGNAME} "Killed cimprovagt processes (`echo $message`)"
	fi
}

function start_cimserver {
	# start cimserver
	/opt/wbem/sbin/cimserver > /dev/null 2>&1
	sleep 10   # give cimserver some time to start-up properly
}

function no_need_to_send_a_test_event {
	# we check if we saw a successful test event today - YES return 0; NO=1
	grep restart_cim /var/adm/syslog/syslog.log | grep "Test event was seen in evweb" | tail -1 > /tmp/test.event.$$
	#Mar  9 14:22:02 hpx189 restart_cim_sfm.sh: Test event was seen in evweb [OK]
	if [[ ! -s /tmp/test.event.$$ ]]; then
		return 1  # empty file means no test event seen
	fi
	month_today=$( date '+%b' )                    # Mar
	day_today=$( date '+%e' | awk '{print $1}' )   # 2
	#hour_today=$( date '+%H' )                     # 10
	month_last_test_event=$(cat /tmp/test.event.$$ | awk '{print $1}')  # Mar
	day_last_test_event=$(cat /tmp/test.event.$$ | awk '{print $2}')    # 9
	if [[ "$month_last_test_event" != "$month_today" ]] || [[ "$day_today" != "$day_last_test_event" ]]; then
		return 1  # time for a new test event
	fi
	rm -f /tmp/test.event.$$
	return 0
}

function psbdb_healtcheck {
	# send a test event and check if it is recorded in LOGDB
	# noticed that we send too many test events after the recent code change, we should only send a test once day
	no_need_to_send_a_test_event  && return

	send_test_event
	sleep 60     # we have seen in worse case it took a minute before it was recorded in evweb

	# verify if the test event was recorded in evweb (psbdb)
	test_event_recorded 
	case $? in
	   0)	# all fine
		sys_logger ${PRGNAME} "Test event was seen in evweb [OK]"
		echo "${PRGNAME}: test event was seen in evweb [OK]"
		;;
	   1)   # no recent test event found
		sys_logger ${PRGNAME} "Test event was missing in evweb [NOK]"
		echo "${PRGNAME}: test event was missing in evweb [NOK]"
		# ok - before restarting the psbdb/sfmdb disable/enable SFMProviderModule
		disable_SFMProviderModule
		sleep 5
		enable_SFMProviderModule
		sleep 5
		send_test_event
		sleep 60
		test_event_recorded
		if [[ $? -eq 1 ]]; then
			stop_cimserver
			restart_PostgreSQL
			start_cimserver
		fi
		;;
	   2)	# evweb: an error occured - probably SFM not configured properly
		echo "${PRGNAME}: SysFaultMgmt possible in bad configuration state [ERR]"
		;;
	esac
}

function send_test_event {
	echo "${PRGNAME}: Send a memory test event"
	sys_logger ${PRGNAME} "Send a memory test event"
	case $OSver in
	   "B.11.11") /opt/resmon/bin/send_test_event dm_memory ;;
	   "B.11.23") # /dev/ipmi device is absent then use send_test_event
		      [[ -c /dev/ipmi ]] && /opt/sfm/bin/sfmconfig -t -m >/dev/null 2>&1 || /opt/resmon/bin/send_test_event dm_memory ;;
	   "B.11.31") /opt/sfm/bin/sfmconfig -t -m >/dev/null 2>&1 ;;
	esac
	if [ $? -ne 0 ]; then
		echo "${PRGNAME}: sfmconfig return an error"
		sys_logger ${PRGNAME} "sfmconfig returned with an error (check HPSIM on HP-UX)"
	fi
}

function restart_PostgreSQL {
	echo "${PRGNAME}: Restart the PostgreSQL daemons"
	sys_logger ${PRGNAME} "Restart the PostgreSQL daemons"
	case $OSver in
		"B.11.11"|"B.11.23")
			/sbin/init.d/sfmdb stop
			sleep 10
			/sbin/init.d/sfmdb start
			sleep 5
			;;
		"B.11.31")
			/sbin/init.d/psbdb stop
			sleep 10
			/sbin/init.d/psbdb start
			sleep 5
			;;
		* ) sys_logger ${PRGNAME} "Unsupported $OSver"
	esac
}

function disable_SFMProviderModule {
	CIMPROVIDER=/opt/wbem/bin/cimprovider
	$CIMPROVIDER -ls | grep -qi SFMProviderModule || return  # module not present
	sys_logger ${PRGNAME} "Disable SFMProviderModule"
	$CIMPROVIDER -dm SFMProviderModule >/dev/null 2>&1
}

function enable_SFMProviderModule {
	CIMPROVIDER=/opt/wbem/bin/cimprovider
	$CIMPROVIDER -ls | grep -qi SFMProviderModule || return  # module not present
	sys_logger ${PRGNAME} "Enable SFMProviderModule"
	$CIMPROVIDER -em SFMProviderModule >/dev/null 2>&1
}

function disable_enable_ProviderModule {
	CIMPROVIDER=/opt/wbem/bin/cimprovider

	${CIMPROVIDER} -l -s | egrep -v 'STATUS|OK' | while read PMLine
	do
	ProviderModule=$( echo ${PMLine} | awk '{print $1}'  2>&1 )
	ProviderStatus=$( echo ${PMLine} | awk '{print $2}'  2>&1 )
	case ${ProviderStatus} in
	Degraded)
		# Disable Provider Module
		message=$( ${CIMPROVIDER} -d -m ${ProviderModule} 2>&1 )

		# Enable Provider Module
		message=$( ${CIMPROVIDER} -e -m ${ProviderModule} 2>&1 )

		echo "${PRGNAME}: disable/enable $ProviderModule"
		sys_logger ${PRGNAME} "disable/enable $ProviderModule"
		;;
	*)	# status as Stopping, Stopped - report only
		sys_logger ${PRGNAME} "$ProviderModule status is $ProviderStatus"
		;;
	esac
	done
}

# ------------------------------------------------------------------------------
#                                   MAIN BODY
# ------------------------------------------------------------------------------

export wbem_account_is_expired=0	# by default NOT expired

# -----------------------------------------------------------------------------
#                               Config file
# -----------------------------------------------------------------------------
# variables used by this script are WbemUser, ENCPW and HpsmhAdminGroup
if [ -f $ConfFile ]; then
	_note "Reading configuration file $ConfFile"
	. $ConfFile
else
	_note "${PRGNAME} Configuration file $ConfFile not found"
	sys_logger ${PRGNAME} "Configuration file $ConfFile not found"
fi

# -----------------------------------------------------------------------------
#                               Options
# -----------------------------------------------------------------------------

# basic check - go over the arguments if supplied
while getopts ":u:c:vh" opt; do
	case $opt in
		u)	WbemUser="$OPTARG" ;;
		c)	ConfFile="$OPTARG"
			[ -f $ConfFile ] && . $ConfFile
			;;
		v)	_revision; exit ;;
		\?|h)	_shortMsg; echo; exit 2 ;;
		:)	_note "Missing argument.\n"
			_shortMsg; echo; exit 2 ;;
	esac
done

shift $(( OPTIND - 1 ))

# basic check - Am I root?
if [ "`whoami`" != "root" ]; then
	echo "${PRGNAME}: must be root to run!"
	exit 1
fi

# basic check - HP-UX Operating System version supported?
case $OSver in
	"B.11.11"|"B.11.23"|"B.11.31") : ;; # OK
	*) exit 0 ;; # HP-UX version is not supported - silently exit
esac



is_wbem_account_created
if [ $? -eq 0 ]; then
	echo "${PRGNAME}: ${WbemUser} account not found - `uname -n` is not ready for HP SIM"
	sys_logger ${PRGNAME} "${WbemUser} account not found - `uname -n` is not ready for HP SIM"
	# silently exit - system not yet migrated to HP SIM
	exit 0
fi

is_wbem_account_locked
if [ $? -eq 0 ]; then
	message=$( /usr/lbin/getprpw ${WbemUser} 2>/dev/null )
	case $? in
	4)	# System is not trusted
		/usr/bin/passwd -d ${WbemUser}	# unlock and set NP
		# so we need to add the encrypted password again
		/usr/sam/lbin/usermod.sam -F -p ${ENCPW} ${WbemUser} ;;
	*)	# System is trusted
		/usr/lbin/modprpw -k ${WbemUser} ;;
	esac
	echo "${PRGNAME}: unlocked the ${WbemUser} account"
	sys_logger ${PRGNAME} "Unlocked the \"${WbemUser}\" account"
fi

if [ $wbem_account_is_expired -eq 1 ]; then
	sys_logger ${PRGNAME} "Stop cimserver"
	/opt/wbem/sbin/cimserver -s > /dev/null 2>&1
	sleep 15
	sys_logger ${PRGNAME} "Reset ${WbemUser} account after expiring date"
	/usr/sbin/userdel -r ${WbemUser}
	/usr/sbin/useradd -g users -G ${HpsmhAdminGroup} ${WbemUser}
	/usr/sam/lbin/usermod.sam -F -p ${ENCPW} ${WbemUser}
	/usr/lbin/modprpw -m exptm=0,lftm=0 ${WbemUser} > /dev/null 2>&1
	/usr/lbin/modprpw -v ${WbemUser} > /dev/null 2>&1
fi

is_cimserver_running
if [ $? -eq 0 ]; then
	# goal is to restart the cimserver at least once a day
	daily_cimserver_restart_needed 
	if [[ $? -eq 1 ]]; then
		#restart_cimserver
		psbdb_healtcheck
	fi
	disable_enable_ProviderModule
else
	# start the cimserver if it was not running
	sys_logger ${PRGNAME} "Start cimserver"
	/opt/wbem/sbin/cimserver > /dev/null 2>&1
fi

# ------------------------------------------------------------------------------
#                                   CLEANUP
# ------------------------------------------------------------------------------
rm -f /tmp/test.event.*

exit 0

# ----------------------------------------------------------------------------
# $Log:  $
#
#
# $RCSfile:  $
# $Source:  $
# $State: Exp $
# ----------------------------------------------------------------------------
