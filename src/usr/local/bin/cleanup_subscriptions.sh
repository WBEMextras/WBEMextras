#!/usr/bin/ksh 
###############################
# cleanup_subscriptions.sh
##########################################################################
#
# shell script to clean out any old SIM subscriptions, filters and handlers
# that were originated by SIM
#
##########################################################################
PS4='$LINENO:=> ' # This prompt will be used when script tracing is turned on
typeset -x PRGNAME=${0##*/}                             # This script short name
typeset -x PRGDIR=${0%/*}                               # This script directory name
typeset -x PATH=$PATH:/usr/bin:/sbin:/usr/sbin:/usr/contrib/bin:/opt/sfm/bin:/opt/wbem/bin:/opt/wbem/sbin:/opt/resmon/bin:/etc/opt/resmon/lbin
typeset -r platform=$(uname -s)                         # Platform
typeset dlog=/var/adm/log                               # Log directory
typeset -r lhost=$(uname -n)                            # Local host name
typeset -r osVer=$(uname -r)                            # OS Release
typeset model=$(uname -m)                               # Model of the system
typeset today=$(date +'%Y-%m-%d.%H%M%S')
#
typeset -x LANG="C"
typeset -x LC_ALL="C"
typeset -x force_exit=0                                 # used by _whoami function

# ----------------------------------------------------------------------------
#                               DEFAULT VALUES
# ----------------------------------------------------------------------------
# modify following parameters to your needs if you do not want to use args -u or -m
# default settings
typeset mailusr="root"                                  # default mailing destination
typeset WbemUser="wbem"                                 # the wbem account name (default value)
typeset ConfFile=/usr/local/etc/HPSIM_irsa.conf
typeset debug=""					# by default no debug lines
typeset Str=""						# used for short SimServers regular expression with grep
# ----------------------------------------------------------------------------


[[ $PRGDIR = /* ]] || PRGDIR=$(pwd) # Acquire absolute path to the script

umask 022

# -----------------------------------------------------------------------------
#                                  FUNCTIONS
# -----------------------------------------------------------------------------

function _note {
	_echo "  -> $*"
} # Standard message display

function _helpMsg {
	cat <<-eof
	Usage: $PRGNAME [-s HPSIM-Server] [-m <mail1,mail2>] [-c Config file] [-hd]
	-s: The HPSIM server (IP address or FQDN).
	-m: The mail recipients seperated by comma.
	-c: The config file for arguments.
	-h: This help message.
	-d: Debug mode (safe mode)

	$PRGNAME run without any switch will use the following default values:
	-s ${SimServer[0]} -m $mailusr

	Purpose is to delete obsolete HPSIM and WEBES subscriptions on this system.
	eof
}

function _print {
	printf "%4s %-80s: " "**" "$*"
}

function _mail {
	[ -f "$instlog" ] || instlog=/dev/null
	expand $instlog | mailx -s "$*" $mailusr
} # Standard email

function _echo {
	case $platform in
		Linux|Darwin) arg="-e " ;;
	esac
	echo $arg "$*"
} # echo is not the same between UNIX and Linux

function _line {
	typeset -i i
	while (( i < ${1:-80} )); do
		(( i+=1 ))
		_echo "-\c"
	done
	echo
} # draw a line

function _whoami {
	if [ "$(whoami)" != "root" ]; then
		_note "$(whoami) - You must be root to run script $PRGNAME"
		force_exit=1
	fi
}

function _dumpSubscriptions {
	cimsub -ls >/tmp/_dumpSubscriptions.$$ 2>/dev/null || evweb subscribe -L -b external >/tmp/_dumpSubscriptions.$$ 2>/dev/null
	if [ ! -s /tmp/_dumpSubscriptions.$$ ]; then
		_note "ERROR: no HPSIM nor HPWEBES subscriptions found - exiting."
		rm -f /tmp/_dumpSubscriptions.$$
		exit 1
	fi
}

function _validSubscriptions {
	cat /tmp/_dumpSubscriptions.$$ | grep -iq -E "(${Str})"
	if [ $? -eq 0 ]; then
		_note "Found valid HPSIM/HPWEBES subscriptions with ${short_SimServer[@]} :"
		cimsub -ls | grep -E '(HPSIM|WEBES)' | grep -i -E "(${Str})"
		_line
		echo
	else
		_note "ERROR: no HPSIM nor HPWEBES subscriptions found for ${short_SimServer[@]}"
		_note " Refuse to delete any existing subscription until subscriptions are created with $short_SimServer"
		rm -f /tmp/_dumpSubscriptions.$$
		exit 1
	fi
}

function _removeOldSimSubscriptions {
	grep HPSIM /tmp/_dumpSubscriptions.$$ | grep -vi -E "(${Str})"  > /tmp/_removeOldSimSubscriptions.$$ 2>/dev/null
	[ ! -s /tmp/_removeOldSimSubscriptions.$$ ] && return	# empty file (nothing to do)
	cat /tmp/_removeOldSimSubscriptions.$$ | while read LINE
	do
		FILTER=$(echo $LINE  | sed s/"  "*/" "/g | cut -f 2 -d " ")
		HANDLER=$(echo $LINE | sed s/"  "*/" "/g | cut -f 3 -d " ")
		_note "Deleting Subscriptions: " $FILTER " " $HANDLER
		$debug cimsub -rs -n root/cimv2 -F $FILTER -H $HANDLER
	done
}

function _removeOldWebesSubscriptions {
	grep WEBES /tmp/_dumpSubscriptions.$$ | grep -vi -E "(${Str})" > /tmp/_removeOldWebesSubscriptions.$$ 2>/dev/null
	[ ! -s /tmp/_removeOldWebesSubscriptions.$$ ] && return   # empty file (nothing to do)
	cat /tmp/_removeOldWebesSubscriptions.$$  | while read LINE
	do
		FILTER=$(echo $LINE  | sed s/"  "*/" "/g | cut -f 2 -d " ")
		HANDLER=$(echo $LINE  | sed s/"  "*/" "/g | cut -f 3 -d " ")
		_note "Deleting Subscriptions: " $FILTER " " $HANDLER
		$debug cimsub -rs -n root/cimv2 -F $FILTER -H $HANDLER
	done
}

function _removeOldSimFilters {
	cimsub -lf | grep HPSIM | grep -iv -E "(${Str})" | while read LINE
	do
		FILTER=$(echo $LINE | awk '{print $1}')
		_note "Deleting Filter: " $FILTER
		$debug cimsub -rf -n root/cimv2 -F $FILTER
	done
}

function _removeOldWebesFilters {
	cimsub -lf | grep WEBES | grep -iv -E "(${Str})" | while read LINE
	do
		FILTER=$(echo $LINE | awk '{print $1}')
		_note "Deleting Filter: " $FILTER
		$debug cimsub -rf -n root/cimv2 -F $FILTER
	done
}

function _removeOldSimHandlers {
	cimsub -lh | grep HPSIM | grep -iv -E "(${Str})" | while read LINE
	do
		HANDLER=$(echo $LINE | awk '{print $1}')
		_note "Deleting Handler: " $HANDLER
		$debug cimsub -rh -n root/cimv2 -H $HANDLER
	done
}

function _removeOldWebesHandlers {
	cimsub -lh | grep WEBES | grep -iv -E "(${Str})" | while read LINE
	do
		HANDLER=$(echo $LINE | awk '{print $1}')
		_note "Deleting Handler: " $HANDLER
		$debug cimsub -rh -n root/cimv2 -H $HANDLER
	done
}

function _listCurrentSubscriptions {
	echo	# extra blank line before we dump our subscriptions (for clarity)
	_line
	_note "The following subscriptions remain on system $lhost :"
	cimsub -ls | grep -E '(HPSIM|WEBES)'
	_line
}

function _cleanup {
	rm -f /tmp/_dumpSubscriptions.$$ /tmp/_removeOldSimSubscriptions.$$
	rm -f /tmp/_removeOldWebesSubscriptions.$$
}

# -----------------------------------------------------------------------------
#                               End of Functions
# -----------------------------------------------------------------------------


# -----------------------------------------------------------------------------
#                               Must be root
# -----------------------------------------------------------------------------
_whoami         # only root can run this
[ $force_exit -eq 1 ] && exit 1

# -----------------------------------------------------------------------------
#                               Config file
# -----------------------------------------------------------------------------
if [ -f $ConfFile ]; then
	#_note "Reading configuration file $ConfFile"
	. $ConfFile
fi

# ------------------------------------------------------------------------------
#                                   Analyse Arguments
# ------------------------------------------------------------------------------

while getopts ":s:m:c:vhd" opt; do
case "$opt" in
	s)      SimServer="$OPTARG" ;;
	m)      mailusr="$OPTARG"
		if [ -z "$mailusr" ]; then
			mailusr=root
		fi
		;;
	c)      ConfFile="$OPTARG"
		[ -f $ConfFile ] && . $ConfFile
		;;
	h)      _helpMsg; exit 0 ;;
	d)	debug="echo # " ;;
	\?)
		_note "$PRGNAME: unknown option used: [$OPTARG]."
		_helpMsg; exit 0
		;;
	esac
done
shift $(( OPTIND - 1 ))

# -----------------------------------------------------------------------------
#                               Sanity Checks
# -----------------------------------------------------------------------------
# check if LOG directory exists, if not, create it first
if [ ! -d $dlog ]; then
	_note "$PRGNAME ($LINENO): [$dlog] does not exist."
	_echo "     -- creating now: \c"
	mkdir -p $dlog && echo "[  OK  ]" || {
		echo "[FAILED]"
		_note "Could not create [$dlog]. Exiting now"
		exit 1
	}
fi

# ------------------------------------------------------------------------------
#                                       MAIN BODY
# ------------------------------------------------------------------------------
typeset instlog=$dlog/${PRGNAME%???}.scriptlog
if [ -z "${SimServer[@]}" ]; then
	_note "ERROR: No HPSIM Server was defined (-s option), nor found in $ConfFile"
	exit 1
else
	# we use variable short_SimServer  (short hostname of SimServer) in all our functions
	i=0
	count=${#SimServer[@]}
	while [ $i -lt $count ]
	do
		short_SimServer[$i]=$(echo ${SimServer[i]} | cut -d. -f1)
		i=$((i + 1))
	done
fi

Str="$( echo ${short_SimServer[@]} | sed -e s'/ /\|/g' )"  # reform array into grep reg expr

# before jumping into MAIN move the existing instlog to instlog.old
[ -f $instlog ] && mv -f $instlog ${instlog}.old

{
	_note "Reading configuration file $ConfFile"
	_line
	echo "               Script: $PRGNAME"
	echo "         Managed Node: $lhost"
	echo "        HP SIM Server: ${SimServer[@]}"
	echo "     Mail Destination: $mailusr"
	echo "                 Date: $(date)"
	echo "                  Log: $instlog"
	_line; echo

	_dumpSubscriptions	# dump into file /tmp/_dumpSubscriptions.$$
	_validSubscriptions	# check if subscription of SimServer is found
	# Remove all old HPSIM related subscriptions, filters and handlers
	_removeOldSimSubscriptions
	_removeOldSimFilters
	_removeOldSimHandlers
	# Remove all old WEBES related subscriptions, filters and handlers
	_removeOldWebesSubscriptions
	_removeOldWebesFilters
	_removeOldWebesHandlers
	_listCurrentSubscriptions

	_cleanup

} 2>&1 | tee -a $instlog 2>/dev/null # tee is used in case of interactive run
[ $? -eq 1 ] && exit 1          # do not send an e-mail as non-root (no log file either)


