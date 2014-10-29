#!/usr/bin/ksh
#
# Author: Gratien D'haese <gdhaese1@its.jnj.com>
#
# $Revision:  $
# $Date:  $
# $Header: $
# $Id:  $
# $Locker:  $
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------
#
#    Purpose: basically this script can be used to execute commands on a local
#             system (HP-UX, Solaris, SLES, RHEL) and it will store its evidence
#             logging under /var/adm/install-logs/
#             These kind of scripts can be started via SMS or ADHOCR
#
# see http://h20565.www2.hp.com/portal/site/hpsc/template.PAGE/public/kb/docDisplay?javax.portlet.begCacheTok=com.vignette.cachetoken&javax.portlet.endCacheTok=com.vignette.cachetoken&javax.portlet.prp_ba847bafb2a2d782fcbb0710b053ce01=wsrp-navigationalState%3DdocId%253Dmmr_kc-0109038-4%257CdocLocale%253D%257CcalledBy%253D&javax.portlet.tpst=ba847bafb2a2d782fcbb0710b053ce01&ac.admitted=1414496815107.876444892.492883150

# DO NOT MODIFY THE FOLLOWING PART:
# We need the dtksh, bash or ksh to have a proper functioning of this script
#
# re-exec this script with correct shell and we use a dummy file to avoid loops
PRGNAME=$0
args=$@

# Here starts the real script:
#
PS4='$LINENO:=> ' # This prompt will be used when script tracing is turned on
typeset -x PRGNAME=${0##*/}                             # This script short name
typeset -x PRGDIR=${0%/*}                               # This script directory name
typeset -x PATH=/usr/bin:/usr/xpg4/bin:$PATH:/sbin:/usr/sbin:/usr/ucb:/opt/wbem/sbin
typeset -r platform=$(uname -s)                         # Platform (HP-UX, Linux, SunOS,...)
typeset    dlog=/var/adm/install-logs                   # Log directory
typeset -r SWLIST=/usr/sbin/swlist
typeset -r SWREMOVE=/usr/sbin/swremove
typeset -r SWJOB=/usr/sbin/swjob
typeset -r SWINSTALL=/usr/sbin/swinstall
typeset -r SWCONFIG=/usr/sbin/swconfig
typeset -r SWVERIFY=/usr/sbin/swverify

typeset -r lhost=$(uname -n)                            # Local host name
typeset os=$(uname -r); os=${os#B.}
typeset arch=$(uname -m)				# e.g. 9000/800 or ia64
typeset model=$(uname -m)                            # Model of the system
typeset mailto="root"					# Mailing destination
typeset -x TZ=UTC                                       # Set time to UTC
typeset EXITCODE=0
typeset ERRFILE=/tmp/ERRFILE.$$
typeset TMPFILE=/tmp/TMPFILE.$$

typeset swarg="-vp"
typeset swarg2="-x autoreboot=true -x reinstall=false -x mount_all_filesystems=false -x autoselect_dependencies=false"


[[ $PRGDIR = /* ]] || PRGDIR=$(pwd) # Acquire absolute path to the script

# Integration tools know nothing about security and
# by default, anything they write is with 000 umask (big no, no)
umask 022

# -----------------------------------------------------------------------------
#                      FUNCTIONS (SHOULD BE ADAPTED TO NEEDS)
# -----------------------------------------------------------------------------



#############
# Functions #
#############

function _msg {
cat <<eof
NAME
  $PRGNAME - Fix corrupt System Fault Management database on HP-UX 11.31

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

  -m <email1,email2...>
        When this option is used, an  email notification is sent when an error
        occurs.  Use this option with a valid SMTP email address.

  -d [IP address or FQDN of Software Depot server]:<Absolute path to base depot>
        Example: -d 10.0.0.1:/var/opt/ignite/depots/GLOBAL/irsa
        The actual software depots for B.11.31 are located under:
           /var/opt/ignite/depots/GLOBAL/irsa/11.31
        However, -d /cdrom/depots is also valid where same rules apply as above.

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
  Release Date  29-Oct-2014
eof
}

function _shortMsg {
        cat<<-eof
Usage: $PRGNAME [-vhi] [-d IP:path] [-m <email1,email2>] [-c <conf file>]
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

function _grab_sw_bundles {
        # grab the current software depot according OS release
        $SWLIST -s ${sourceDepo} | egrep -v -E 'PH|\#' | sed '/^$/d' 
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
			[ "${fileset}" = "WBEMP-FCP" ] && _enable_module HPUXFCIndicationProviderModule
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

function _enable_module {
	# enamble module $1 with cimprovider -em $1 (only when running in installation mode)
	[ "${swarg}" = "-vp" ] && return
	$CIMPROVIDER -ls | grep -qi $1 || return        # module not present (return)
	$CIMPROVIDER -ls | grep -i $1 | grep -qi stopped && $CIMPROVIDER -em $1 >/dev/null 2>&1
}

function _kill_procs_of_user {
	# input argument (string): username
	[[ -z "$1" ]] && return
	UNIX95= ps -ef | awk '{print $1, $2}' | grep "$1" | awk '{print $2}' | xargs kill
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

function _configure_hpsmh_on_boot {
       _note "$(date) - HP System Management Homepage changes"
       /opt/hpsmh/lbin/hpsmh stop
       /opt/hpsmh/bin/smhstartconfig -a off -b on
       /opt/hpsmh/lbin/hpsmh start
       _line
       echo
}

function _extract_simservers_from_conf {
       # /tmp/newSimList contains list of SimServers found in HPSIM_irsa.conf
       _note "$(date) - Extract SIM Servers from HPSIM_irsa.conf"
       echo
       # save current list of simserver(s)
       grep ^SimServer /usr/local/etc/HPSIM_irsa.conf | cut -d= -f2 | tr '[A-Z]' '[a-z]' > /tmp/SimDefined
       i=0
       # sort the list and clean up duplicates and remove the very old sim servers
       rm -f /tmp/newSimList # make sure we start with a clean list of SimServers
       sort /tmp/SimDefined | uniq | grep -i -v -e itsbebesvc209 -e itsusrasimms1 | tr '[A-Z]' '[a-z]' | \
       while read simsvr ; do
	   short_simsvr="$(echo $simsvr | cut -d. -f1)"
	   grep -q $short_simsvr /tmp/newSimList 2>/dev/null 
	   if [[ $? -ne 0 ]]; then
	       # if name is already in the list do not add it again (short name vs. fqdn)
	       echo "SimServer[$i]=$simsvr" >> /tmp/newSimList
	       i=$(( i + 1 ))
	   fi
       done
}

function _remove_certs {
       # to remove existing certs do:
       i=0
       cimtrust -l | grep -e "Issuer:" -e "Serial Number:" | cut -d: -f2- | sed -e 's/^ //' | while read Line
       do
           case $i in
               0) issuer="$Line" ; i=1 ;;
               1) sernr="$Line"  ; i=0
                  _note "$(date) - Remove certificate $issuer"
                  /opt/wbem/sbin/cimtrust -r -i "$issuer" -n "$sernr" ;;
           esac
       done
       _line
       echo
}

function _install_hpsim_certificates {
       cat /tmp/newSimList | cut -d= -f2 | while read simsvr
       do
          _ping_system $simsvr && {
              _note "$(date) - Install HP SIM certificate of $simsvr"
              echo
              short_simsvr="$(echo $simsvr | cut -d. -f1 | tr '[a-z]' '[A-Z]')"
	      # the SD depot contains all 1024 sized public certificates of known SIM servers within J&J
	      # depot is maintained by UNIX TED (gratien)
              $SWINSTALL $swarg -x reinstall=true -s $IUXSERVER:${baseDepo} HPSIM-certificates.CERTIFICATE-${short_simsvr}

              _note "$(date) - Importing certificate ${simsvr}.pem"
              /opt/wbem/sbin/cimtrust -a -U wbem -f /var/opt/hpsmh/certs/${simsvr}.pem -T s 2>/dev/null
              echo
           }
       done
       echo
       _note "$(date) - Verify HPSIM-certificates"
       $SWLIST -l fileset HPSIM-certificates
       _line

       # add the host own certificate as well
       _note "$(date) - Add $lhost certificate to hp SMH"
       /opt/wbem/sbin/cimtrust -a -U wbem -f /etc/opt/hp/sslshare/cert.pem -T s 2>/dev/null
       _line
       echo
}

# -----------------------------------------------------------------------------
#                              Setting up the default values
# -----------------------------------------------------------------------------
typeset IUXSERVER mailusr       # defaults are empty
typeset INSTALL_MODE=0              # default preview mode
# under baseDepo directory sub-dirs are 11.11, 11.23 and 11.31
typeset baseDepo=/var/opt/ignite/depots/GLOBAL/irsa
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
while getopts ":d:m:c:hvi" opt; do
        case $opt in
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

_note "$(date) - Reading configuration file $ConfFile"

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
        _note "$(date) - Running installation mode!\n\n"
        swarg="-v"
else
        # Ignoring all other parameters. (swarg="-vp" by default)
        _note "$(date) - Running in preview mode.\n\tUsage: $PRGNAME -i for 'installation mode'\n\n"
fi


#=====================================================================================#
# Pre-requisites: os version = 11.31
case ${os} in
        "11.31")
           : ;;
        *) _error "$PRGNAME only supports HP-UX version B.11.31 to fix the sfmdb !!"
	   exit 1
           ;;
esac

#=====================================================================================#
_define_SourceDepot
#=====================================================================================#
$SWLIST > $TMPFILE      # dump the bundles on this system in a file

# before we start installing or upgrading software check the status of the installed software
# if needed we even try to swconfig the products not in configured state
echo

# starting here with the remediation of the corrupt sfmdb (LOGDB and/or evweb)
_removeSw RAIDSA-PROVIDER "Smart Array Provider product"
_removeSw SAS-PROVIDER "Serial SCSI provider product"
_removeSw WBEMP-FCP "FC Provider - CIM/WBEM Provider for Fibre Channel HBAs"
_removeSw WBEMP-IOTreeIP "CIM/WBEM Indication and Consolidated Status Provider for IOTree"
_removeSw WBEMP-LAN "LAN Providers - CIM/WBEM Providers for Ethernet interfaces"
_removeSw WBEMP-Storage "Storage  Provider - CIM/WBEM Provider for Storage"
_removeSw KERNEL-PROVIDERS "HPUX Kernel Providers"
_removeSw WBEMP-FS "HP-UX File System CIM Provider"
_removeSw SCSI-Provider "CIM/WBEM Provider for SCSI HBA"
_removeSw NParProvider "nPartition Provider"
_removeSw VParProvider "vPar Provider"
_removeSw olosProvider "OLOS Provider"
_removeSw SFM-CORE "HPUX System Fault Management"
_removeSw ProviderSvcsCore "Provider Services Core"
_removeSw Sup-Tool-Mgr "HPUX Support Tools Manager for HPUX systems"
_removeSw Contrib-Tools "HPUX Contributed Tools"
# we do not remove WBEMServices as otherwise we would loose our subscriptions


# remove all directories belonging to SFMDB (to get a real clean state) - only in installation mode
if [[ $INSTALL_MODE -eq 1 ]]; then
    # kill any remaining processes of user sfmdb
    _kill_procs_of_user sfmdb

    _note "$(date) - Removing all directories belonging to sfm and psb"
    rm -rf /opt/sfm
    rm -rf /var/opt/sfm
    rm -rf /opt/psb
    rm -rf /var/opt/psb
    rm -rf /opt/sfmdb
    rm -rf /var/opt/sfmdb
fi

# now install
_installMissingSw WBEMMgmtBundle

_note "$(date) - Check the software status of installed software bundles:"
_check_sw_state

_note "$(date) - Verify the WBEMMgmtBundle bundle"
$SWVERIFY WBEMMgmtBundle


# now we will upgrade other components if needed (to avoid running HPSIM-Upgrade-RSP.sh)
# grab the current list of software bundles on Ignite server depot according current OS release
_grab_sw_bundles | while read bundle srcbver title
do
        # srcbver is the version of the $bundle found on the Ignite server
        # locbver is the version of the $bundle found on the local system
        #echo $bundle $srcbver $title
        # step 1: check if bundle is installed locally?
        grep $bundle $TMPFILE | read junk locbver junk
        if [ -z "$locbver" ]; then	# if empty it is not installed yet locally
            _print "Bundle $bundle ($title) is missing on on this system"; _ok 
            _installMissingSw $bundle $srcbver $title
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


# is the software configured correctly?
_note "$(date) - Are there software bundles still in 'installed' state?"
_check_sw_state

_configure_hpsmh_on_boot
_extract_simservers_from_conf
_install_hpsim_certificates

echo
# show cimproviders
_note "$(date) - The active cimproviders are:"
/opt/wbem/bin/cimprovider -ls
[ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))

echo
_note "$(date) - Send a test event (simulate memory or cpu failures):"
/opt/sfm/bin/sfmconfig -t -a
[ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))

sleep 3  # to give SFM a bit time to write away the entries in the DB
_note "$(date) - View information about events present in the Event Archive"
/opt/sfm/bin/evweb eventviewer -L | head -8 | ssp
[ $? -ne 0 ] && EXITCODE=$((EXITCODE + 1))


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

##########################################################
################# done with main script ###################
##########################################################
echo "Done."

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
# $Source: $
# $State: Exp $
# ---------------------------------------------------------------------------
