#!/usr/bin/ksh
# Author: Gratien D'haese
#
# $Revision: $
# $Date:  $
# $Header:  $
# $Id:  $
# $Locker:  $
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------

###############################################################################
###############################################################################
##                                                                           ##
##      HPSIM-Upgrade-RSP.sh Script                                          ##
##      ===========================                                          ##
##      Purpose: Upgrade local system with latest SIM/RSP depots found       ##
##               on the Ignite servers                                       ##
##                                                                           ##
##      Author: Gratien D'haese                                              ##
##      Usage:  * preview mode: HPSIM-Upgrade-RSP.sh                         ##
##              * Installation mode: HPSIM-Upgrade-RSP.sh -i                 ## 
##                                                                           ##
##                                                                           ##
###############################################################################
###############################################################################
##############
# Parameters #
##############
PS4='$LINENO:=> ' # This prompt will be used when script tracing is turned on

alias export="typeset -x"
alias readonly="typeset -r"
alias int="typeset -i"
alias lower="typeset -l"
alias upper="typeset -u"

export PRGNAME=${0##*/}
export PRGDIR=$(dirname $0)
export PATH=$PATH:/usr/bin:/usr/sbin:/sbin

readonly  TMPFILE=/tmp/tmpfile4rsp
readonly  ERRFILE=/tmp/EXITCODE-rsp-$$
readonly  HOSTNAME=$(uname -n)
readonly  SWLIST=/usr/sbin/swlist
readonly  SWINSTALL=/usr/sbin/swinstall
readonly  SWCONFIG=/usr/sbin/swconfig
readonly  SWJOB=/usr/sbin/swjob
readonly  SWREMOVE=/usr/sbin/swremove
readonly  CIMPROVIDER=/opt/wbem/bin/cimprovider

typeset swarg="-vp"
typeset swarg2="-x autoreboot=true -x reinstall=false -x mount_all_filesystems=false -x autoselect_dependencies=false"

typeset os=$(uname -r); os=${os#B.}
typeset arch=$(uname -m)				# e.g. 9000/800 or ia64
typeset EXITCODE=0                                      # Define the default exit code


[[ $PRGDIR = /* ]] || {					# acquire an absolute path
	case $PRGDIR in
		. ) PRGDIR=$(pwd) ;;
		* ) PRGDIR=$(pwd)/$PRGDIR ;;
	esac
	}

#############
# Functions #
#############

function _msg {
cat <<eof
NAME
  $PRGNAME - Install and/or upgrade IRSS/IRSA software on HP-UX 11i systems

SYNOPSIS
  $PRGNAME [ options ]

DESCRIPTION
  This script will check the software depot, install all required software
  pieces, or upgrade to the latest available versions with a detailed
  report. The script knows two modes (preview and installation).


OPTIONS
  -h
        Print this man page.

  -i
        Run $PRGNAME in "installation" mode. Be careful, this will install/upgrade software!
        Default is preview mode and is harmless as nothing will be installed.

  -u <WBEM user name>
        Non-priviledge account to use with IRSS/IRSA (default $WbemUser).

  -m <email1,email2...>
        When this option is used, an  email notification is sent when an error
        occurs.  Use this option with a valid SMTP email address.

  -d [IP address or FQDN of Software Depot server]:<Absolute path to base depot>
        Example: -d 10.0.0.1:/var/opt/ignite/depots/GLOBAL/irsa
        The actual software depots are then located under:
          B.11.11 : /var/opt/ignite/depots/GLOBAL/irsa/11.11
          B.11.23 : /var/opt/ignite/depots/GLOBAL/irsa/11.23
          B.11.31 : /var/opt/ignite/depots/GLOBAL/irsa/11.31
        However, -d /cdrom/rsp/pre-req is also valid where same rules apply as above.

  -c <configuration file>
       The configuarion file that defines the variables end-users may override.
       Default location is /usr/local/etc/HPSIM_irsa.conf

  -v
        Prints the version of $PRGNAME.

EXAMPLES
    $PRGNAME -d 10.0.0.1:/var/opt/ignite/depots/GLOBAL/irsa
        Run $PRGNAME in preview mode only and will give a status update.
    $PRGNAME -d /test/irsa_1131_apr_2012.depot
	Run $PRGNAME in preview mode only and use a file depot as source depot
    $PRGNAME -i
        Run $PRGNAME in installation mode and use default values for
        IP address of Ignite server (or SD server) and software depot path

IMPLEMENTATION
  version       Id: $PRGNAME $
  Revision      $(_revision)
  Author        Gratien D'haese
  Release Date  27-Oct-2014
eof
}

function _shortMsg {
        cat<<-eof
Usage: $PRGNAME [-vhi] [-u <Wbem account>] [-d IP:path] [-m <email1,email2>] [-c <conf file>]
eof
}


function _whoami {
        if [ "`whoami`" != "root" ]; then
		_error "You must be root to run this script $PRGNAME"
		exit 1
	fi
}

function _error {
        printf " *** ERROR: $* \n"
}

function _note {
        printf " ** $* \n"
}

function _print {
        printf "%4s %-80s: " "**" "$*"
}

function _ok {
        echo "[  OK  ]"
}

function _nok {
        ERRcode=$((ERRcode + 1))
        echo "[FAILED]"
}

function _na {
        echo "[  N/A ]"
}

function _skip {
        echo "[ SKIP ]"
}

function _mail {
	[ -s "$instlog" ] || instlog=/dev/null
	if [[ -n $mailusr ]]; then
		mailx -s "$*" $mailusr < $instlog
	fi
}

function _define_installation_path {
	# installation_path variable contains an IP address and/or path to baseDepo
	echo ${installation_path} | grep -q ":"
	if [[ $? -eq 0 ]]; then
		# IUXSERVER:PATH syntax
		IUXSERVER=$(echo ${installation_path} | cut -d: -f1)
		baseDepo=$(echo ${installation_path} | cut -d: -f2)
	else
		# PATH syntax
		IUXSERVER=localhost
		baseDepo=${installation_path}
	fi
}

function _define_SourceDepot {
	# the source depot can be a directory or a file depot (tar format)
	$SWLIST -l depot  -s ${IUXSERVER} | grep -q "${baseDepo}/$os" 2>/dev/null
	CODE=$?
	if [ $CODE -eq 0 ]; then
		sourceDepo=${IUXSERVER}:${baseDepo}/$os
	else
		sourceDepo=${baseDepo}
	fi
}

function _netRegion {
        # Some systems have more than 1 default gateway.

	octet="$(netstat -rn | awk '/default/ && /UG/ { sub (/^[0-9]+\./, "", $2); sub (/\.[0-9]+\.[0-9]+$/,"",$2);
                print $2;
                exit }')"

	IUXSERVER=10.36.96.94		# default value (NA)
	if [ ${octet} -lt   1 ]; then
		IUXSERVER=10.0.11.237	# dfdev
	elif [ ${octet} -lt  96 ]; then
		IUXSERVER=10.36.96.94	# NA
	elif [ ${octet} -lt 128 ]; then
		IUXSERVER=10.36.96.94	# LA
	elif [ ${octet} -lt 192 ]; then
		IUXSERVER=10.129.52.119	# EMEA
	elif [ ${octet} -lt 224 ]; then
		IUXSERVER=10.129.52.119	# ASPAC
	fi
}

function _ping_system {
        # one parameter: system to ping
        z=`ping ${1} -n 2 | grep "packet loss" | cut -d, -f3 | awk '{print $1}' | cut -d% -f1`
        [ -z "$z" ] && z=1
        if [ $z -ne 0 ]; then
                _error "System $1 is not reachable via ping"
                exit 2
        fi
}

function is_wbem_account_created {
        message=$( /usr/bin/grep ^${WbemUser} /etc/passwd )
        if [ $? -eq 0 ]; then
                return 1
        fi
        return 0
}

function _grab_sw_bundles {
        # grab the current software depot according OS release
        $SWLIST -s ${sourceDepo} | egrep -v -E 'PH|\#' | sed '/^$/d' 
}

function _libipmimsg_patch_installed {
        # verify if we have a patch for "libipmimsg"
        $SWLIST -l patch | grep -q -i "cumulative libipmimsg"
        if [ $? -eq 0 ]; then
                return 1
        fi
        return 0
}

function _isHigher {
        # $1: srvbver; $2: locbver; return 1 of srvbver > locbver (read more recent)
        [ "$1" = "$2" ] && return 0
        if [ "`echo $1 $2 | sort | awk '{print $1}'`" = "$1" ]; then
                return 1
        else
                return 0
        fi
}

function _installMissingSw {
        _note "$(date) - Installing $*"
        $SWINSTALL $swarg $swarg2 -s ${sourceDepo} $1 
        _swjob $1 "installation"
        _line "-"
}

function _upgradeSw {
        _note "$(date) - Upgrading $*"
        $SWINSTALL $swarg $swarg2 -s ${sourceDepo} $1,r=$2
        _swjob $1 "upgrade"
        _line "-"
}

function _removeSw {
	_note "$(date) - Removing $*"
	$SWREMOVE $swarg -x enforce_dependencies=false -x mount_all_filesystems=false $1
	_swjob $1 "removal"
	_line "-"
}

function _swconfig {
	_note "$(date) - Configuring $*"
	$SWCONFIG $swarg -x mount_all_filesystems=false -x autoselect_dependencies=false -x reconfigure=true $1
	_swjob $1 "configuration"
	_line "-"
}

function _swjob {
        tail -20 $instlog | grep -q -E 'ERROR'
        if [ $? -eq 0 ]; then
                EXITCODE=$((EXITCODE + 1))      # count the amount of errors
                _note "Errors detected during $2 of $1"
                swjob_cmd="`tail -10 $instlog | grep swjob | sed -e 's/command//' -e 's/\.$//' -e 's/\"//g'`"
                _note "Executing: $swjob_cmd"
                _line "="
                echo $swjob_cmd | sh -
                _line "="
                echo
        else
                _note "No errors detected during $2 of $1"
        fi 
}

function _check_sw_state {
	$SWLIST -l fileset -a state | egrep -v '\#|configured' | sed '/^$/d' > /tmp/_check_sw_state.$$
	[ ! -s /tmp/_check_sw_state.$$ ] && _note "All software is properly configured."
	cat /tmp/_check_sw_state.$$
	_line "-"
	grep  -q installed /tmp/_check_sw_state.$$
	if [ $? -eq 0 ]; then
		cut -d. -f1 /tmp/_check_sw_state.$$ | sort | uniq | while read fileset junk
		do
			# due to a bug in WBEMP-FCP.FCP-IP-RUN we must disable the FC provider first (seen on 11.11)
			[ "${fileset}" = "WBEMP-FCP" ] && _disable_module HPUXFCIndicationProviderModule
			_swconfig $fileset
		done
	fi
	rm -f /tmp/_check_sw_state.$$
}

function _disable_module {
	# Disable module $1 with cimprovider -dm $1 (only when running in installation mode)
	[ "${swarg}" = "-vp" ] && return
	$CIMPROVIDER -ls | grep -qi $1 || return	# module not present (return)
	$CIMPROVIDER -dm $1 >/dev/null 2>&1
}

function _revision {
        typeset rev
        rev=$(awk '/Revision:/ { print $3 }' $PRGDIR/$PRGNAME | head -1 | sed -e 's/\$//')
        [ -n "$rev" ] || rev="UNKNOWN"
        echo $rev
}

function _line {
        typeset -i i
        while (( i < 95 )); do
                (( i+=1 ))
                echo "${1}\c"
        done
        echo
}

function _check_if_LOGDB_is_broken {
	# purpose is to identify if we are hit by "DB Connection failed to LOGDB" issue
	if [[ ! -f /var/opt/sfm/log/sfm.log ]]; then
		# if this file is not found we are probably using an HP-UX 11.11 system
		return
	fi
	tail -10 /var/opt/sfm/log/sfm.log | grep -e ERROR -e CRITICAL > /tmp/LOGDB_errors.txt
	if [[ $? -eq 0 ]]; then
		_note "We found errors in /var/opt/sfm/log/sfm.log"
		cat /tmp/LOGDB_errors.txt
		_line "-"
		_fix_LOGDB
	fi
	rm -f /tmp/LOGDB_errors.txt
}

function _fix_LOGDB {
	# recreate the SFM LOGDB db
	_note "$(date) - Un-configuring SysFaultMgmt"
	$SWCONFIG $swarg -x mount_all_filesystems=false -x autoselect_dependencies=false -u SysFaultMgmt
	_swjob $1 "un-configuring"
	_note "$(date) - Configuring SysFaultMgmt"
	$SWCONFIG $swarg -x mount_all_filesystems=false -x autoselect_dependencies=false SysFaultMgmt
	_swjob $1 "configuring"
	_note "$(date) - Restarting HP System Management Homepage"
	/sbin/init.d/hpsmh start
	echo
}

# -----------------------------------------------------------------------------
#                              Setting up the default values
# -----------------------------------------------------------------------------
typeset IUXSERVER mailusr       # defaults are empty
int INSTALL_MODE=0              # default preview mode
typeset WbemUser="wbem"         # default account 'wbem'
# under baseDepo directory sub-dirs are 11.11, 11.23 and 11.31
typeset baseDepo=/var/opt/ignite/depots/GLOBAL/irsa
typeset dlog=/var/adm/install-logs                   # Log directory
#
# Above settings may also be defined in a ConfFile : /usr/local/etc/HPSIM_irsa.conf
# HPSIM_irsa.conf will be created by HPSIM-Check-RSP-readiness.sh
typeset ConfFile=/usr/local/etc/HPSIM_irsa.conf

# -----------------------------------------------------------------------------
#		Only root may run this script
# -----------------------------------------------------------------------------
_whoami         # must be root to continue

# -----------------------------------------------------------------------------
#                               Config file
# -----------------------------------------------------------------------------
# the only variable that will be used by this script is WbemUser (if present)
if [ -f $ConfFile ]; then
	#_note "Reading configuration file $ConfFile"   (to avoid confusing message at this point)
	. $ConfFile
fi

# -----------------------------------------------------------------------------
#                              Setting up options
# -----------------------------------------------------------------------------
while getopts ":u:d:m:c:hvi" opt; do
        case $opt in
                u) WbemUser="$OPTARG" ;;
                d) installation_path="$OPTARG"
                   _define_installation_path
                   ;;
                m) mailusr="$OPTARG" ;;
		c) ConfFile="$OPTARG"
		   [ -f $ConfFile ] && . $(dirname $ConfFile)/${ConfFile##*/}
		   ;;
                h) _msg; echo; exit 2 ;;
                v) _revision; exit ;;
                i) INSTALL_MODE=1 ;;
                :)
                        _note "Missing argument.\n"
                        _shortMsg; echo; exit 2
                        ;;
                \?) _shortMsg; echo; exit 2 ;;
        esac
done

shift $(( OPTIND - 1 ))

_note "Reading configuration file $ConfFile"

# Some sanity checks
if [[ -z $IUXSERVER ]]; then
	# try to figure out which IUXSERVER to use (if not defined yet)
        _netRegion
fi

# is our ignite server (or SD server) reachable?
_ping_system $IUXSERVER

if [[ ! -d $dlog ]]; then
        _note "$PRGNAME ($LINENO): [$dlog] does not exist."
        print -- "     -- creating now: \c"

        mkdir -p $dlog && echo "[  OK  ]" || {
                echo "[FAILED]"
                _note "Could not create [$dlog]. Exiting now"
                _mail "$PRGNAME: ERROR - Could not create [$dlog] on $lhost"
                exit 1
        }
fi

typeset instlog=$dlog/${PRGNAME%???}.$(date +'%Y-%m-%d.%H%M%S').scriptlog


###########
# M A I N #
###########

{

_line "+"
echo "  Installation Script: $PRGNAME"
[[ "$(_revision)" = "UNKNOWN" ]] || echo "             Revision: $(_revision)"
echo "        Ignite Server: $IUXSERVER"
echo "           OS Release: $os"
echo "                Model: $(model)"
echo "    Installation Host: $HOSTNAME"
echo "    Installation User: $(whoami)"
echo "    Installation Date: $(date +'%Y-%m-%d @ %H:%M:%S')"
echo "     Installation Log: $instlog"
_line "+"

# We are expecting 1 or no parameters here.
if [[ $INSTALL_MODE = 1 ]]; then
        _note "Running installation mode!\n\n"
        swarg="-v"
else
        # Ignoring all other parameters. (swarg="-vp" by default)
        _note "Running in preview mode.\n\tUsage: $PRGNAME -i for 'installation mode'\n\n"
fi


#=====================================================================================#
# Pre-requisites: os version >= 11.11
case ${os} in
        "11.11"|"11.23"|"11.31")
           : ;;
        *) _error "This HP-UX version B.${os} is not supported for HP-SIM/IRSA !!"
	   exit 1
           ;;
esac

# Does wbem account exist?
is_wbem_account_created
if [ $? -eq 0 ]; then
        _note "The \"${WbemUser}\" account not found - `uname -n` not active in HP SIM yet?"
        _note "Before upgrading run install procedure: HPSIM-Check-RSP-readiness.sh -i"
        exit 0
fi
#=====================================================================================#
_define_SourceDepot
#=====================================================================================#
$SWLIST > $TMPFILE      # dump the bundles on this system in a file

# before we start installing or upgrading software check the status of the installed software
# if needed we even try to swconfig the products not in configured state
echo
_note "Before we start check the software status of installed software:"
_check_sw_state

# check for patch pre-reqs before we kick off
##=========================================##
case ${os} in
        "11.31") _libipmimsg_patch_installed
                if [ $? -eq 1 ]; then
                        pver=`$SWLIST -l patch | grep 'cumulative libipmimsg patch' | awk '{print $2}' | cut -d_ -f2`
                        if [ $pver -lt 41483 ]; then
                          _print "Patch PHCO_${pver} (cumulative libipmimsg patch) will be updated"; _ok
                          Patch=`$SWLIST -s ${sourceDepo} | grep 'cumulative libipmimsg patch' | awk '{print $1}'`
                          _upgradeSw ${Patch} 1.0 "cumulative libipmimsg patch"
                        fi
                fi
                ;;
esac

# for HP-UX 11.11 if B7611BA,r=A.04.20.11.03 (EMS DevKit) is installed we remove it first
# for HP-UX 11.31 if ProviderSvcsCore < C.02 we must upgrade this one before the others because
# otherwise the prerequisite "ProviderSvcsCore.SMPGSQL-RUN,r>=C.02.00.%" error appears
case ${os} in
	"11.11") $SWLIST B7611BA,r=A.04.20.11.03  2>&1 | egrep -v '\#' | awk '{print $1}' | grep -q "B7611BA.EMS-Devkit"
		 if [ $? -eq 0 ]; then
			_print "Bundle B7611BA.EMS-Devkit will be removed (as outdated for newer EMS)"; _ok
			_removeSw B7611BA,r=A.04.20.11.03 "EMS-Devkit" 
		 fi
		 ;;
        "11.31") PSBver=`$SWLIST -s ${sourceDepo} ProviderSvcsBase 2>/dev/null | grep ProviderSvcsBase | head -1 | awk '{print $3}'`
                 $SWLIST ProviderSvcsCore >/dev/null 2>&1
                 if [ $? -eq 1 ]; then
                        # ProviderSvcsCore not installed
                        _upgradeSw ProviderSvcsBase ${PSBver} "Provider Services Base"
                 else
                        $SWLIST ProviderSvcsCore,r\>=C.06.00.04 >/dev/null 2>&1 
			CODE=$?
                        if [ $CODE -ne 0 ]; then
                                _print "Bundle ProviderSvcsBase will be upgraded as first"; _ok
                                _removeSw ProviderSvcsBase "Provider Services Base"
                                _upgradeSw ProviderSvcsBase ${PSBver} "Provider Services Base"
                        else
                                # now count filesets (if <15 then re-installed it)
                                cfilesets=`$SWLIST ProviderSvcsCore | egrep -v '\#' | wc -l`
                                if [ $cfilesets -lt 15 ]; then
                                        _print "Bundle ProviderSvcsBase contains only $cfilesets filesets (should be 15 or more)"; _ok
                                        _removeSw ProviderSvcsBase "Provider Services Base"
                                        _upgradeSw ProviderSvcsBase ${PSBver} "Provider Services Base"
                                fi
                        fi
                 fi
                 ;;
	*)	: ;; # do nothing
esac

# grab the current list of software bundles on Ignite server depot according current OS release
_grab_sw_bundles | while read bundle srcbver title
do
        # srcbver is the version of the $bundle found on the Ignite server
        # locbver is the version of the $bundle found on the local system
        #echo $bundle $srcbver $title
        # step 1: check if bundle is installed locally?
        grep $bundle $TMPFILE | read junk locbver junk
        if [ -z "$locbver" ]; then	# if empty it is not installed yet locally
                # B9073BA (iCod) and QPKBASE: do not install automatically
                case $bundle in
                        "B9073BA") _print "Bundle $bundle ($title) was not found on this system"; _skip ;;
                        "QPKBASE") _print "Bundle $bundle ($title) was not found on this system"; _skip ;;
			"CommonIO")
				if [[ "$os" -eq "11.23" && "$arch" = "ia64" ]]; then
					_print "Bundle $bundle ($title) is missing on on this system"; _ok
					_installMissingSw $bundle $srcbver $title
				else
					_print "Bundle $bundle is ment for ia64 only"
					_skip
				fi
				;;
			"SASProvider")
				if [ "$arch" = "ia64" ]; then
					_print "Bundle $bundle ($title) is missing on on this system"; _ok
					_installMissingSw $bundle $srcbver $title
				else
					_print "Bundle $bundle is ment for ia64 only"
					_skip
				fi
				;;
			#"WBEMpatches-1123")
				#if [ "$os" -eq "11.23" ]; then
					#_print "Bundle $bundle ($title) is missing on on this system"; _ok
					#_installMissingSw $bundle $srcbver $title
				#else
					#_print "Bundle $bundle is ment for HP-UX 11.23 only"
					#_skip
				#fi
				#;;
                        *)      _print "Bundle $bundle ($title) is missing on on this system"; _ok 
                                _installMissingSw $bundle $srcbver $title ;;
                esac
        else
                _isHigher $srcbver $locbver
                if [ $? -eq 1 ]; then
                	# B9073BA (iCod) and QPKBASE: do not install automatically
			case $bundle in
			   "B9073BA") _print "Bundle $bundle ($title) (version $locbver) has a higher version $srcbver available"
				      _skip ;;
			   "QPKBASE") _print "Bundle $bundle ($title) (version $locbver) has a higher version $srcbver available"
				      _skip ;;
			   *) _print "Bundle $bundle (version $locbver) has a higher version $srcbver available"; _ok
                              _upgradeSw $bundle $srcbver $title ;;
			esac
                else
                        _print "Bundle $bundle with version $locbver is up-to-date"; _na
                fi 
        fi
done

echo
# inspect on HP-UX 11.23 and 11.31 if the SFM db LOGDB is broken; if yes, rebuild db
_check_if_LOGDB_is_broken


# is the software configured correctly?
_note "Are there software components which are still in 'installed' state?"
_check_sw_state

echo
# show cimproviders
_note "The active cimproviders are:"
/opt/wbem/bin/cimprovider -ls
[ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))

echo
_note "Send a test event (simulate memory or cpu failures):"
case ${os} in
        "11.11") /opt/resmon/bin/send_test_event -v dm_memory
                 [ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))
                 ;;
              *) /opt/sfm/bin/sfmconfig -t -a
                 [ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))
                 ;;
esac



# print final EXITCODE result (counter of all ERRORS found - install and config part)
_line "#"
if [ $EXITCODE -eq 0 ]; then
        _note "There were no errors detected."
elif [ $EXITCODE -eq 1 ]; then
        _note "There was 1 error detected (see details above or in the log files)"
else
        _note "There were several errors detected (see details above or in the log files)"
fi
_line "#"
echo $EXITCODE > $ERRFILE
} 2>&1 | tee $instlog 2>/dev/null




################# done with main script ###################
EXITCODE=`cat $ERRFILE`
# Final notification
case $EXITCODE in
        0) msg="[SUCCESS] `basename $0` ran successfully in upgrade mode on $HOSTNAME" ;;
        1) msg="[WARNING] `basename $0` ran with warnings (or error) in upgrade mode on $HOSTNAME" ;;
        99) msg="[WARNING] `basename $0` must be run with root privileges" ;;
        *) msg="[ERRORS] `basename $0` ran with errors in upgrade mode on $HOSTNAME" ;;
esac

_mail "$msg"

rm -f $ERRFILE $TMPFILE
exit $EXITCODE

# ----------------------------------------------------------------------------
# $Log:  $
#
#
# $RCSfile: $
# $Source:  $
# $State: Exp $
# ----------------------------------------------------------------------------

