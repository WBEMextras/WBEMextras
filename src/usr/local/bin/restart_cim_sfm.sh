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

function cimserver_restart_needed {
	# goal is to restart the cimserver on daily basis - use ps output to check this
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

function restart_cimserver {
	echo "${PRGNAME}: Force a cimserver restart"
	sys_logger ${PRGNAME} "Force a cimserver restart"
	/opt/wbem/sbin/cimserver -s > /dev/null 2>&1
	sleep 15	# sleep long enough to give agents time to gracefully die

	# check if cimsermain/cimservera died gracefully
	message=$( ps -e | grep -E 'cimservermain|cimservera' | awk '{print $1}' )
	if [ ! -z "$message" ]; then
		echo "${PRGNAME}: kill -9 `echo $message`"
		kill -9 `echo $message`
		sys_logger ${PRGNAME} "killed cimservermain process (`echo $message`)"
	fi

	# check hanging cimprovider agents - kill these
	message=$( ps -e | grep cimprovagt | awk '{print $1}' )
	if [ ! -z "$message" ]; then
		echo "${PRGNAME}: kill -9 `echo $message`"
		kill -9 `echo $message`
		sys_logger ${PRGNAME} "killed cimprovagt processes (`echo $message`)"
	fi

	# restart the PostgresSQL daemons
	echo "${PRGNAME}: restart the PostgresSQL daemons"
	sys_logger ${PRGNAME} "restart the PostgresSQL daemons"
	restart_PostgresSQL

	# restart cimserver
	/opt/wbem/sbin/cimserver > /dev/null 2>&1
}

function restart_PostgresSQL {
	case $OSver in
		"B.11.11"|"B.11.23")
			/sbin/init.d/sfmdb restart ;;
		"B.11.31")
			/sbin/init.d/psbdb restart ;;
		* ) sys_logger ${PRGNAME} "Unsupported $OSver"
	esac
}

function disable_enable_ProviderModule {
	CIM_PROVIDER=/opt/wbem/bin/cimprovider

	${CIM_PROVIDER} -l -s | egrep -v 'STATUS|OK' | while read PMLine
	do
	ProviderModule=$( echo ${PMLine} | awk '{print $1}'  2>&1 )
	ProviderStatus=$( echo ${PMLine} | awk '{print $2}'  2>&1 )
	case ${ProviderStatus} in
	Degraded)
		# Disable Provider Module
		message=$( ${CIM_PROVIDER} -d -m ${ProviderModule} 2>&1 )

		# Enable Provider Module
		message=$( ${CIM_PROVIDER} -e -m ${ProviderModule} 2>&1 )

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
	cimserver_restart_needed || restart_cimserver
	disable_enable_ProviderModule
else
	# start the cimserver if it was not running
	sys_logger ${PRGNAME} "Start cimserver"
	/opt/wbem/sbin/cimserver > /dev/null 2>&1
fi

# ------------------------------------------------------------------------------
#                                   CLEANUP
# ------------------------------------------------------------------------------

exit 0

# ----------------------------------------------------------------------------
# $Log:  $
#
#
# $RCSfile:  $
# $Source:  $
# $State: Exp $
# ----------------------------------------------------------------------------
