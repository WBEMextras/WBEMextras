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
	echo "--------------------------------------------------------------------------------"
} # draw a line

function _whoami {
	if [ "$(whoami)" != "root" ]; then
		_note "$(whoami) - You must be root to run script $PRGNAME"
		force_exit=1
	fi
}

function find_IP {
	# arg1: SIMserver; retrun IP of IRS
	nslookup "$1" 2>/dev/null | grep Address | awk '{print $2}' > /tmp/find_IP_$$
	if [ ! -s /tmp/find_IP_$$ ] ; then
		echo "ERROR: No IP address found for $1"
		rm -f /tmp/find_IP_$$
		exit 1
	fi
	ip_address=$(cat /tmp/find_IP_$$ )
	rm -f /tmp/find_IP_$$
	echo $ip_address
}


function _dumpSubscriptions {
	# The output of cimsub -ls is:
	# NAMESPACE        FILTER                                HANDLER                                    STATE
	# root/cimv2       root/cimv2:EVWEB_F_HP_AlertIndication_HP_defaultSyslog_1311702272_1     root/cimv2:PG_ListenerDestinationSystemLog.EVWEB_H_SYSLOG_HP_defaultSyslog_1311702272_1                 Enabled

	# The output of evweb subscribe -L -b external is:
	# Filter Name           Handler Name                Query                            Destination Type Destination Url
	# HPSIM_itsbebew00331_1              HPSIM_itsbebew00331      select * from HP_ThresholdIndication        CIMXML           https://10.130.208.20:50004/cimom/listen1
	cimsub -ls >/tmp/_dumpSubscriptions.cimsub 2>/dev/null
	# we do both actions as IRS will only be seen by 'evweb'
	evweb subscribe -L -b external >/tmp/_dumpSubscriptions.evweb 2>/dev/null
	if [[ ! -s /tmp/_dumpSubscriptions.cimsub ]] ; then
		# delete the empty file
		rm -f /tmp/_dumpSubscriptions.cimsub
	fi
	if [[ ! -s /tmp/_dumpSubscriptions.evweb ]] ; then
		# the file seems empty - not OK
		_note "ERROR: no HPSIM nor HPWEBES subscriptions found - exiting."
		rm -f /tmp/_dumpSubscriptions.evweb
		exit 1
	fi
}

function _validSubscriptions {
	cat /tmp/_dumpSubscriptions.cimsub /tmp/_dumpSubscriptions.evweb 2>/dev/null | grep -iq -E "(${Str})"
	if [ $? -eq 0 ]; then
		_note "Found valid HPUCA/HPSIM/HPWEBES subscriptions with ${short_SimServer[@]} :"
		cat /tmp/_dumpSubscriptions.cimsub /tmp/_dumpSubscriptions.evweb 2>/dev/null \
		 | grep -E '(HPSIM|WEBES|HPUCA)' | grep -i -E "(${Str})"
		_line
		echo
	else
		_note "ERROR: no HPSIM nor HPWEBES/HPUCA subscriptions found for ${short_SimServer[@]}"
		_note " Refuse to delete any existing subscription until subscriptions are created with $short_SimServer"
		rm -f /tmp/_dumpSubscriptions.cimsub /tmp/_dumpSubscriptions.evweb
		exit 1
	fi
}

function _removeOldSubscriptions {
	# arg1: HPSIM or WEBES
	
	cat /tmp/_dumpSubscriptions.cimsub /tmp/_dumpSubscriptions.evweb 2>/dev/null \
	 | grep "$1" | grep -vi -E "(${Str})" | awk '{print $1, $2, $3}' > /tmp/_removeOldSubscriptions.$$ 2>/dev/null
	[ ! -s /tmp/_removeOldSubscriptions.$$ ] && return	# empty file (nothing to do)

	# cimsub -ra -n root/cimv2 -F root/cimv2:HPSIM_TYPE_1_itsbebew00331_0 -H root/cimv2:CIM_ListenerDestinationCIMXML.HPSIM_TYPE_1_itsb
	if [ -f /tmp/_dumpSubscriptions.cimsub ] ; then
		# cimsub: filter is on 2th column and handler at 3th column
		field1="2"
		field2="3"
	else
		# evweb: filter is on 1st column and handler at 2th column
		field1="1"
		field2="2"
	fi
	cat /tmp/_removeOldSubscriptions.$$ | while read LINE
	do
		FILTER=$(echo $LINE  | cut -f $field1 -d " ")
		shortHANDLER=$(echo $LINE | cut -f $field2 -d " ")
		_note "Deleting Subscriptions: " $FILTER " " $shortHANDLER
		$debug cimsub -rs -n root/cimv2 -F $FILTER -H $shortHANDLER
		echo
		# find the longHANDLER name via 'cimsub -lh' (there can only be one per SIM server)
		longHANDLER=$( cimsub -lh | grep "$1" | grep -iv -E "(${Str})" | awk '{print $1}' )
		# we can have several filters:
		cimsub -lf | grep "$1" | grep -iv -E "(${Str})" | awk '{print $1}' | while read FILTER
		do
			_note "Deleting Filter ($FILTER) with handler ($longHANDLER)"
			$debug cimsub -ra -n root/cimv2 -F $FILTER -H $longHANDLER
		done
	done
}

function _listCurrentSubscriptions {
	echo	# extra blank line before we dump our subscriptions (for clarity)
	_line
	_note "The following subscriptions remain on system $lhost :"
	_dumpSubscriptions
	cat /tmp/_dumpSubscriptions.cimsub /tmp/_dumpSubscriptions.evweb 2>/dev/null | grep -E '(^HPUCA|HPSIM|WEBES)'
	_line
}

function _cleanup {
	rm -f /tmp/_dumpSubscriptions.cimsub /tmp/_removeOldSimSubscriptions.$$
	rm -f /tmp/_dumpSubscriptions.evweb /tmp/_removeOldWebesSubscriptions.$$
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
		short_SimServer[$i]=$(echo ${SimServer[$i]} | cut -d. -f1)
		# IRS systems are not shown with their FQDN, but with IP - so find IP address
		IP_SimServer[$i]=$(find_IP ${SimServer[$i]})
		i=$((i + 1))
	done
fi

# The search string contain the short hostname as well as its IP address
Str="$( echo ${short_SimServer[@]} ${IP_SimServer[@]} | sed -e s'/ /\|/g' )"  # reform array into grep reg expr

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
	_removeOldSubscriptions HPSIM
	# Remove all old WEBES related subscriptions, filters and handlers
	_removeOldSubscriptions WEBES
	_listCurrentSubscriptions

	_cleanup

} 2>&1 | tee -a $instlog 2>/dev/null # tee is used in case of interactive run
[ $? -eq 1 ] && exit 1          # do not send an e-mail as non-root (no log file either)

