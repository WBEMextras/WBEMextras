#!/usr/bin/ksh
# Script Name: HPSIM-HealthCheck.sh
# Author: Gratien D'haese
# Purpose:      Do an health check on HP-UX systems around HPSIM/RSP
#
# $Revision:  $
# $Date:  $
# $Header:  $
# $Id:  $
# $Locker:  $
# History: Check the bottom of the file for revision history
# ----------------------------------------------------------------------------

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
typeset tcbdir=/tcb/files/auth
typeset force_wbem_cleanup=0                            # default 0: do not remove existing HPWEBES sub
typeset mode=9999                                       # default 9999: dir/file permission mode
typeset ERRcode=0                                       # the exit code ERRcode will be used by send_test_event
typeset SendTestEvent=0                                 # By default we send a test event to HP SIM/WEBES
typeset -x force_exit=0                                 # used by _whoami function

# ----------------------------------------------------------------------------
#				DEFAULT VALUES
# ----------------------------------------------------------------------------
# modify following parameters to your needs if you do not want to use args -u or -m
# default settings
typeset mailusr="root"                                  # default mailing destination
typeset WbemUser="wbem"					# the wbem account name (default value)
typeset -i MaxTestDelay=0				# default sleep timer before sending test event
#
# settings may also be defined in a ConfFile : /usr/local/etc/HPSIM_irsa.conf
typeset ConfFile=/usr/local/etc/HPSIM_irsa.conf
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
	cat <<eof
	Usage: $PRGNAME [-s HPSIM-Server] [-u WBEM-user] [-m <mail1,mail2>] [-c Config file] [-t secs] [-hv]
		-s: The HPSIM server (IP address or FQDN).
		-u: The WBEM user
		-m: The mail recipients seperated by comma.
		-c: The config file for arguments.
		-t: Maximum delay in seconds before sending a test event
		-h: This help message.
		-v: Revision number of this script.
	$PRGNAME run without any switch will use the following default values:
		-s $SimServer -u $WbemUser -m $mailusr -t $MaxTestDelay
eof
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

function _warn {
	echo "[ WARN ]"
}

function _na {
        echo "[  N/A ]"
}

function _line {
        typeset -i i
        while (( i < ${1:-80} )); do
                (( i+=1 ))
                _echo "-\c"
        done
        echo
} # draw a line

function _revision {
        typeset rev
        rev=$(awk '/Revision:/ { print $3 }' $PRGDIR/$PRGNAME | head -1 | sed -e 's/\$//')
        [ -n "$rev" ] || rev="UNKNOWN"
        echo $rev
} # Acquire revision number of the script and plug it into the log file

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

function _whoami {
        if [ "`whoami`" != "root" ]; then
                _note "$(whoami) - You must be root to run script $PRGNAME"
                force_exit=1
        fi
}

function _getSerialNr {
        x=`/usr/bin/getconf CS_MACHINE_SERIAL 2>/dev/null`
        [ "$x" = "undefined" ] && x=""
        [ -z "$x" ] && x=`machinfo 2>/dev/null | grep -i "machine serial number" | awk '{print $5}'` # IA64
        [ "$x" = "undefined" ] && x=""
        [ -z "$x" ] && x=`echo "selclass qualifier system;info;wait;infolog" | cstm | grep -i "system serial" | awk '{print $4}'`
        [ "$x" = "undefined" ] && x=""
        [ -z "$x" ] && x=`grep -i "system serial" /var/opt/resmon/log/*.log  | sort -u | tail -1 | awk '{print $5}'`
        [ -z "$x" ] && x="UNKNOWN"
        echo "$x"
}

function _validOS {
        case ${osVer} in
                "B.11.11"|"B.11.23"|"B.11.31")
                        _print "System $lhost runs HP-UX ${osVer}"
                        _ok ;;
                *)      _print "System $lhost runs ${osVer} (not supported)"
                        _nok
                        exit
                        ;;
        esac
}

function _getSystemName {
        typeset x domain name
        x=$(nslookup $lhost  | grep "Name:" | awk '{print $2}')
        echo "$x" | grep "." > /dev/null
        if [ $? -eq 0 ]; then
                name="$x"
        elif [ $(grep -q ^domain /etc/resolv.conf; echo $?) -eq 0 ]; then
		domain=$(grep ^domain /etc/resolv.conf | awk '{print $2}')
		name="${lhost}.${domain}"
	else
		domain=$(grep ^search /etc/resolv.conf | awk '{print $2}')
		name="${lhost}.${domain}"
	fi
	echo "$name"
}

function _checkSimSub {
        _print "Valid HPSIM subscription for system ${lhost}"
        cimsub -ls > /tmp/_checkSub.$$ 2>/dev/null || evweb subscribe -L -b external > /tmp/_checkSub.$$ 2>/dev/null
        grep -q HPSIM /tmp/_checkSub.$$
        if [ $? -eq 0 ]; then
                _ok
        else
                _nok
                _note "Did you added system $SystemName to HP SIM and ran \"Subscribe to WBEM Events\"?"
        fi
        rm -f /tmp/_checkSub.$$
}

function _checkWebesSub {
        _print "Valid HPWEBES subscription for system ${lhost}"
        cimsub -ls > /tmp/_checkWebesSub.$$ 2>/dev/null || evweb subscribe -L -b external > /tmp/_checkWebesSub.$$ 2>/dev/null
        grep -q HPWEBES /tmp/_checkWebesSub.$$
        if [ $? -eq 0 ]; then
                _ok
        else
                _nok
                SendTestEvent=1         # no need to send test event
                _note "System $SystemName does not have an HPWEBES subscription"
        fi
        rm -f  /tmp/_checkWebesSub.$$
}

function _show_ext_subscriptions {
        typeset err=0
        _print "List of external HP SIM/WEBES subscription for system $lhost"
        evweb subscribe -L -b external 2>/dev/null > /tmp/evweb.$$
        err=$?
        grep -q "An error occurred" /tmp/evweb.$$
        if [ $? -eq 0 ]; then
                _nok
                _note "ERROR: `grep error /tmp/evweb.$$`"
                err=1
                return
        fi
        if [ $err -eq 0 ]; then
                _ok
                _line
                cat /tmp/evweb.$$ | grep -E 'HPSIM|HPWEBES'
                _line
                echo
        else
                _nok
                _note "WARNING: command evweb not found."
        fi
        rm -f /tmp/evweb.$$
}

function _show_eventviewer {
        _print "List most recent events for system $lhost"
        evweb eventviewer -L 2>/dev/null | head -6 > /tmp/evweb.$$
        err=$?
        grep -q "An error occurred" /tmp/evweb.$$
        if [ $? -eq 0 ]; then
                _nok
                _note "ERROR: `grep error /tmp/evweb.$$`"
                err=1
                return
        fi
        if [ $err -eq 0 ]; then
                _ok
                _line
                cat /tmp/evweb.$$
                _line
                echo
        else
                _nok
                _note "WARNING: command evweb not found."
        fi
        rm -f /tmp/evweb.$$
}

function _checkSFM {
        message1="SysFaultMgmt ("
        message2=") is properly installed"
	case $osVer in
		"B.11.31") swlist WBEMMgmtBundle.SFM-CORE >/tmp/SFM.$$ 2>/dev/null; err=$? ;;
		*) swlist SysFaultMgmt >/tmp/SFM.$$ 2>/dev/null; err=$? ;;
	esac
        version=`grep "^#" /tmp/SFM.$$ | tail -1 | awk '{print $3}'`
        [ "$version" = "target" ] && version="N/A"
        _print "${message1}${version}${message2}"
        if [ $err -eq 1 ]; then
                # not installed
                _nok
                SendTestEvent=1         # no need to send test event
                _note "Did you run HPSIM-Check-RSP-readiness.sh already?"
                return
        fi
	case $osVer in
		"B.11.31") swlist -l fileset -a state WBEMMgmtBundle.SFM-CORE 2>/dev/null |\
			   egrep -v '\#|configured' > /dev/null; err=$? ;;
		*) swlist -l fileset -a state SysFaultMgmt 2>/dev/null | egrep -v '\#|configured' > /dev/null; err=$? ;;
	esac
        if [ $err -eq 0 ]; then
                _ok
        else
                _nok
                _line
                _note "SysFaultMgmt is not (properly) installed:"
                 swlist -l fileset -a state SysFaultMgmt
                echo
                _line
        fi
        rm -f /tmp/SFM.$$
}

function _checkWBEMSvcs {
	swlist WBEMSvcs WBEMServices >/tmp/WBEMSvcs.$$ 2>/dev/null
	wbemproduct=$(grep "^#" /tmp/WBEMSvcs.$$ | tail -1 | awk '{print $2}')
	echo $wbemproduct | grep -q WBEM 2>/dev/null || wbemproduct="WBEMSvcs"  # default name
	message1="$wbemproduct ("
	version=$(grep "^#" /tmp/WBEMSvcs.$$ | tail -1 | awk '{print $3}')
	[ "$version" = "target" ] && version="N/A"
	message2=") is properly installed"
	_print "${message1}${version}${message2}"
        rm -f /tmp/WBEMSvcs.$$

        if [ "$version" = "N/A" ]; then
                # not installed
                _nok
                SendTestEvent=1         # no need to send test event
                _note "Did you run HPSIM-Check-RSP-readiness.sh already?"
                return
        fi
	swlist -l fileset -a state $wbemproduct 2>/dev/null | egrep -v '\#|configured' > /dev/null
        if [ $? -eq 0 ]; then
                _ok
        else
                _nok
                _line
                _note "$wbemproduct is not (properly) installed:"
                 swlist -l fileset -a state $wbemproduct
                echo
                _line
        fi
}

function is_digit {
	expr "$1" + 1 > /dev/null 2>&1	# sets the exit to non-zero if $1 non-numeric
}

function _region {
        #<!-- This rule determines the region in which the system is located.
        #      10.0                -> DFDEV
        #      10.1   until 10.95  -> NA
        #      10.96  until 10.127 -> LA
        #      10.128 until 10.191 -> EU
        #      10.192 until 10.223 -> AP
        #   -->

        typeset secdig=$(netstat -rn | awk '/default/ && /UG/ { print $2 | "tail -1" }' | cut -d. -f2)

        case $secdig in
                +([0-9]))
                        if [ $secdig -eq 0 ]; then
                                # Lab
                                SimServer="10.0.54.130"
                        elif [ $secdig -eq 1 ] || [ $secdig -le 95 ]; then
                                # North America
                                SimServer="ITSUSRASIMMS1.na.jnj.com"
                        elif [ $secdig -eq 96 ] || [ $secdig -le 127 ]; then
                                # Latin America
                                SimServer="ITSUSRASIMMS1.na.jnj.com"
                        elif [ $secdig -eq 128 ] || [ $secdig -le 191 ]; then
                                # EMEA
                                SimServer="ITSBEBESVC209.eu.jnj.com"
                        elif [ $secdig -eq 192 ] || [ $secdig -le 223 ]; then
                                # ASPAC
                                SimServer="ITSBEBESVC209.eu.jnj.com"
                        else
                                # Leftovers come to NA
                                SimServer="ITSUSRASIMMS1.na.jnj.com"
                        fi
                ;;
                *)
                        _note "Could not determine network location.  Exiting now."
                        _mail "ERROR ($PRGNAME): Could not determine network location of [$lhost]"
                        exit 1
                ;;
        esac
        echo "${SimServer}" > /tmp/SimServer.txt
}


function ExtractMode {
        # input: Directory or File name
        # output: mode in 4 numbers
        # Usage: ExtractMode ${Directory}|${File}
        # $mode contains real mode number
        #[ $mode -eq 9999 ] && continue
        typeset String
        String=`ls -ld $1 2>/dev/null | awk '{print $1}'`
        [ -z "${String}" ] && echo "$1 does not exist." && return
        Decode_mode "${String}"
        return $mode
}

function Decode_mode {
        # Purpose is to return the mode in decimal number
        # input: drwxrwxr-x (as an example)
        # return: 0775
        # error: 9999
        typeset StrMode
        StrMode=$1

        Partu="`echo $StrMode | cut -c2-4`"
        Partg="`echo $StrMode | cut -c5-7`"
        Parto="`echo $StrMode | cut -c8-10`"
        #echo "$Partu $Partg $Parto"
        # Num and Sticky are used by function DecodeSubMode too
        Num=0
        Sticky=0
        # first decode the user part
        DecodeSubMode $Partu
        NumU=$Num
        Sticky_u=$Sticky
        # then decode the group part
        DecodeSubMode $Partg
        NumG=$Num
        Sticky_g=$Sticky
        # and finally, decode the other part
        DecodeSubMode $Parto
        NumO=$Num
        Sticky_o=$Sticky
        #echo "$NumU $Sticky_u $NumG $Sticky_g $NumO $Sticky_o"

        # put all bits together and calculate the mode in numbers
        sticky_prefix=$((Sticky_u * 4 + Sticky_g * 2 + Sticky_o))
        sticky_prefix=$((sticky_prefix * 1000))
        mode=$((NumU * 100 + NumG * 10 + NumO))
        mode=$((sticky_prefix + mode))
        return $mode
}

function DecodeSubMode {
        # input: String of 3 character (representing user/group/other mode)
        # output: integer number Num 0-7 and Sticky=0|1
        Sticky=0
        case $1 in
           "---") Num=0 ;;
           "--x") Num=1 ;;
           "-w-") Num=2 ;;
           "r--") Num=4 ;;
           "rw-") Num=6 ;;
           "r-x") Num=5 ;;
           "rwx") Num=7 ;;
           "--T") Num=0 ; Sticky=1 ;;
           "r-T") Num=4 ; Sticky=1 ;;
           "-wT") Num=2 ; Sticky=1 ;;
           "rwT") Num=6 ; Sticky=1 ;;
           "--t") Num=1 ; Sticky=1 ;;
           "r-t") Num=5 ; Sticky=1 ;;
           "-wt") Num=3 ; Sticky=1 ;;
           "rwt") Num=7 ; Sticky=1 ;;
           "--S") Num=0 ; Sticky=1 ;;
           "r-S") Num=4 ; Sticky=1 ;;
           "rwS") Num=6 ; Sticky=1 ;;
           "-wS") Num=2 ; Sticky=1 ;;
           "--s") Num=1 ; Sticky=1 ;;
           "r-s") Num=5 ; Sticky=1 ;;
           "rws") Num=7 ; Sticky=1 ;;
           "-ws") Num=3 ; Sticky=1 ;;
        esac
}

function _checkbootconf {
        ExtractMode /stand/bootconf
        if [ "${mode}" = "644" ]; then
                _print "File permissions of /stand/bootconf ($mode)"
                _ok
        else
                _print "File permissions of /stand/bootconf ($mode) should be 644"
                _nok
        fi
}

function _checkhpsmh {
        ExtractMode /opt/hpsmh
        if [ "${mode}" = "555" ]; then
                _print "Directory permissions of /opt/hpsmh ($mode)"
                _ok
        else
                _print "Directory permissions of /opt/hpsmh ($mode) should be 555"
                _nok
        fi
}

function _checksslshare {
        ExtractMode /etc/opt/hp/sslshare
        if [ "${mode}" = "555" ]; then
                _print "Directory permissions of /etc/opt/hp/sslshare ($mode)"
                _ok
        else
                _print "Directory permissions of /etc/opt/hp/sslshare ($mode) should be 555"
                _nok
        fi
}

function _checkresolvconf {
        ExtractMode /etc/resolv.conf
        if [ "${mode}" = "644" ] || [ "${mode}" = "444" ]; then
                _print "File permissions of /etc/resolv.conf ($mode)"
                _ok
        else
                _print "File permissions of /etc/resolv.conf ($mode) should be 644"
                _nok
        fi
}

function _checkcimconf {
        ExtractMode /var/opt/wbem/cimserver_current.conf
        if [ "${mode}" = "644" ]; then
                _print "File permissions of /var/opt/wbem/cimserver_current.conf ($mode)"
                _ok
        else
                _print "File permissions of /var/opt/wbem/cimserver_current.conf ($mode) should be 644"
                _nok
        fi
        
}

function _checkpamconf {
        _print "Check integrity of file /etc/pam.conf"
        head /etc/pam.conf | grep -q OTHER
        if [ $? -eq 0 ]; then
                _nok
        else
                _ok
        fi
}

function _checkEMS {
        version="`echo q | /etc/opt/resmon/lbin/monconfig | grep 'EMS Version' | cut -d: -f2`"
        _print "EMS Monitors ("$version" ) are enabled"
        if [ -x /etc/opt/resmon/lbin/monconfig ]; then
                echo "q" | /etc/opt/resmon/lbin/monconfig | grep -q "EVENT MONITORING IS CURRENTLY ENABLED"
                if [ $? -eq 0 ] ; then
			_ok
		else
			case ${osVer} in
			  "B.11.31") /usr/bin/model | grep -q "i2$" && _na || _nok ;;
			  *)	_nok ;;
			esac
		fi
        else
		_nok
		_note "EMS Monitors do not appear to be installed on this system."
        fi
}

function _checksshdconf {
        _print "A non-privileged user can login via ssh"
        if [ "`grep UsePAM /etc/opt/ssh/sshd_config | awk '{print $2}'`" = "yes" ]; then
                _ok
        else
                _nok
        fi
}

function _checkwbemuser {
        lockout="`/usr/lbin/getprpw -m lockout $WbemUser 2>/dev/null`"       # get the lockout code
        case "$?" in
        "0")    # success
                _print "The \"$WbemUser\" user exists and has a valid password"
                case "`echo ${lockout} | cut -d= -f2`" in
                "0000000") # wbem exists and is not locked
                        _ok
                        ;;
                "0001000") # wbem exists and is is locked (exceeded unsuccessful login attempts)
                        _nok
                        _note "Account exceeded unsuccessful login attempts! Unlock it please"
                        ;;
                *) # wbem exists and is is locked (some other reason)
                        _nok
                        _note "Account locked (code ${lockout})! Unlock it please"
                        ;;
                esac
                ;;
        "1")    # user not privileged
                ;;
        "2")    # incorrect usage
                ;;
        "3")    # cannot find the password file
                _print "Check if \"$WbemUser\" user exists"
                _nok
                ;;
        "4")    # system is not trusted
                _print "The \"$WbemUser\" user exists and has a valid password"
                if [ "$(/bin/passwd -s $WbemUser | awk '{print $2}')" = "PS" ]; then
                        _ok
                else
                        _nok
                fi
                ;;
        esac
}

function _checkcimauth {
        _print "The \"$WbemUser\" user is authorized to do CIM work"
        cimauth -l 2>/dev/null | head -1 | grep -q $WbemUser
        if [ $? -eq 0 ]; then
                _ok
        else
                _nok
                _line
                cimauth -l
                _note "Please re-run the \"/tmp/RSP_readiness_${lhost}.config\" script to correct this"
                _line
        fi
}

function _checkcimport {
        _print "The CIMON port 5989 is in LISTEN mode"
        netstat -an | grep 5989 | grep -q LISTEN
        [ $? -eq 0 ] && _ok || _nok
}

function _checkproviders {
        _print "All CIM Providers are enabled and usable"
        cimprovider -ls 2>/dev/null | grep -v -E 'OK|MODULE' >/dev/null 2>/dev/null
        if [ $? -eq 0 ]; then
                 _nok  # output returned means something is wrong
                _line
                _note "WARNING: `cimprovider -ls 2>/dev/null | grep -v -E 'OK|MODULE'`"
                _note " when \"Degraded\" then disbale/enable the povider, e.g."
                _note "         cimprovider -d -m SFMProviderModule"
                _note "         cimprovider -e -m SFMProviderModule"
                _line
        else
                 _ok # no output means all OK
        fi
}

function _checkcimconfig {
        _print "Is enable Subscriptions For Nonprivileged Users \"true\""
        cimconfig -lc | grep -q "enableSubscriptionsForNonprivilegedUsers=true"
        if [ $? -eq 0 ]; then
                _ok
        else
                _nok
                _line
                _note "Please run /tmp/RSP_readiness_${lhost}.config to correct"
                _line
        fi
}

function _list_syslog {
        _print "Display relevant cimserver messages of today"
        grep "^`date +'%b %e'`" /var/adm/syslog/syslog.log | grep -E 'cimserver\[|restart_cim_sfm' > /tmp/syslog.$$ 2>/dev/null
        _ok  # always OK even when there were no message to display
        _line
        [ -s /tmp/syslog.$$ ] && cat -v /tmp/syslog.$$ || echo "No relevant messages found."
        rm -f /tmp/syslog.$$
}

function _checkvar {
	typeset -i _lines _spaceleft
        _print "The /var file system is still below 90% usage"
	df -Pl /var 2>/dev/null | grep -vi filesystem > /tmp/df_var.$$
	_lines=$(wc -l  /tmp/df_var.$$ | awk '{print $1}')
	if [ ${_lines} -eq 1 ]; then
		_spaceleft=$(cat /tmp/df_var.$$ | tail -1 | awk '{print $5}' | cut -d% -f1)
	else
		# volume name is too long, therefore, output are two lines
		_spaceleft=$(cat /tmp/df_var.$$ | tail -1 | awk '{print $4}' | cut -d% -f1)
	fi
        if [ ${_spaceleft} -lt 90 ]; then
                _ok
        else
                _nok
                _note "WARNING: /var file system is above %90 full! Check FAQ ISEE to HP SIM document."
        fi
	rm -f  /tmp/df_var.$$
}

function _pingSimServer {
        z=`ping ${SimServer} -n 2 | grep "packet loss" | cut -d, -f3 | awk '{print $1}' | cut -d% -f1`
	[ -z "$z" ] && z=1
        _print "HP SIM Server ${SimServer} is reachable"
        [ $z -eq 0 ] && _ok || _nok
}

function _checkhpsmhruns {
	_print "HP System Mgmt Homepage is running"
	ps -ef|grep hpsmh|grep -v grep >/dev/null
	[ $? -eq 0 ] && _ok || _nok
}

function _checkopenssl {
        _print "The WEBES port on ${SimServer} is accepting a SSL connection"
        echo | openssl s_client -connect ${SimServer}:7906 2>/dev/null | grep -q CONNECTED
        [ $? -eq 0 ] && _ok || _nok
}

function _getRandom {
        # $1: min. and $2: max. nummer
        typeset -i RND=0
        while [ $RND -le $1 ]
        do
                RND=`echo $((RANDOM % $2))`
        done
        echo $RND
}

function _sendTestEvent {
	if [ $MaxTestDelay -gt 0 ]; then
		SECS=$(_getRandom 0 $MaxTestDelay) # between 0 - MaxTestDelay seconds delay
	else
		SECS=0
	fi
        if [ $SendTestEvent -gt 0 ]; then
                _print "Sending a test event"
                # something went wrong with WBEM or SFM or subscription SIM/WEBES
                _na
                _note "Did not send a test event! Please investigate above error(s) - fix it - rerun this script"
        else
		_print "Sending a test event (delay $SECS seconds)"
		if [ $SECS -gt 0 ]; then
			#_print "Sending a test event after sleeping for $SECS seconds"
			sleep $SECS
		fi
                # No errors returned, so lets try to send a message
                case ${osVer} in
                        "B.11.11") send_test_event dm_memory ;;
                        "B.11.23") # /dev/ipmi device is absent then use send_test_event
				   [[ -c /dev/ipmi ]] && sfmconfig -t -a >/dev/null 2>&1 || send_test_event dm_memory ;;
                        "B.11.31") sfmconfig -t -m >/dev/null 2>&1 ;;
                esac
                [ $? -eq 0 ] && _ok || _nok
                _line
                _note "Login with your admin account on the HP SIM server $SimServer"
                _note "and check if for system $lhost a critical (type 4) event arrived"
                _line
                echo
        fi
}

function _show_older_filesets {
	_print "Older filesets may jeopardize proper working"
	swlist -l fileset | awk \ '/^# / { a[$2]++; v[$2] = v[$2]"/"$3; } END { for (i in a) { if (a[i] > 1) print i, "\t" v[i]"/" ;} }' > /tmp/filesets.$$ 2>/dev/null
	_lines=$(wc -l /tmp/filesets.$$ | awk '{print $1}')
	if [ ${_lines} -eq 0 ]; then
		_ok
	else
		_warn
		_line
		_note "WARNING: Found some older filesets - please investigate (it may be OK)"
		cat /tmp/filesets.$$
		_line
		echo
	fi
	rm -f /tmp/filesets.$$
}

# -----------------------------------------------------------------------------
#				End of Functions
# -----------------------------------------------------------------------------



# -----------------------------------------------------------------------------
#				Default values
# -----------------------------------------------------------------------------
# are defined at the top of this script

# -----------------------------------------------------------------------------
#				Must be root
# -----------------------------------------------------------------------------
_whoami         # only root can run this
[ $force_exit -eq 1 ] && exit 1

# -----------------------------------------------------------------------------
#				Config file
# -----------------------------------------------------------------------------
if [ -f $ConfFile ]; then
	_note "Reading configuration file $ConfFile"
	. $ConfFile
fi

# ------------------------------------------------------------------------------
#                                   Analyse Arguments
# ------------------------------------------------------------------------------
while getopts ":s:m:t:c:vh" opt; do
	case "$opt" in
		s)	SimServer="$OPTARG" ;;
		m)	mailusr="$OPTARG"
			if [ -z "$mailusr" ]; then
				mailusr=root
			fi
			;;
		t)	MaxTestDelay="$OPTARG"
			is_digit $MaxTestDelay || MaxTestDelay=0
			;;
		c)	ConfFile="$OPTARG"
			[ -f $ConfFile ] && . $ConfFile
			;;
		v)	_revision; exit ;;
		h)	_helpMsg; exit 0 ;;
		\?)
			_note "$PRGNAME: unknown option used: [$OPTARG]."
			_helpMsg; exit 0
			;;
	esac
done
shift $(( OPTIND - 1 ))


# -----------------------------------------------------------------------------
#				Sanity Checks
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
#					MAIN BODY
# ------------------------------------------------------------------------------

typeset -r SystemName=$(_getSystemName)  # define SystemName, the FQDN of the system
typeset -r SerialNr=$(_getSerialNr)      # extract serial number from system
typeset instlog=$dlog/${PRGNAME%???}.scriptlog

if [ -z "$SimServer" ]; then
	_region		# set SimServer FDQN according region
fi

# before jumping into MAIN move the existing instlog to instlog.old
[ -f $instlog ] && mv -f $instlog ${instlog}.old

{
        _line
        echo "               Script: $PRGNAME"
        [[ "$(_revision)" = "UNKNOWN" ]] || echo "             Revision: $(_revision)"
        echo "         Managed Node: $SystemName"
        echo " System Serial Number: $SerialNr"
        echo "       Executing User: $(whoami)"
	echo "        HP SIM Server: $SimServer"
	echo "         WBEM account: $WbemUser"
	echo "     Mail Destination: $mailusr"
        echo "                 Date: $(date)"
        echo "                  Log: $instlog"
        _line; echo

        case $platform in
                HP-UX) : ;; # OK
                *)
                        _note "[$platform] is not supported by this script.\n"
                        exit
                ;;
        esac



        # count $lhost characters
        #clhost=`echo $lhost | wc -c`

        _whoami         # only root can run this
        [ $force_exit -eq 1 ] && exit 1

        _validOS        # only HP-UX 11.[11|23|31] are supported
        _checkSFM       # check if SysFaultMgmt state is configured
        _checkWBEMSvcs  # check if WBEMSvcs state is configured
	_show_older_filesets	# check if there are previous filesets still around
        _checkEMS       # check if /etc/opt/lbin/monconfig is present and EMS enabled
        _checkhpsmh     # check permissions of directory /opt/hpsmh
        _checksslshare  # check permissions of directory /etc/opt/hp/sslshare
        _checkbootconf  # check permissions of /stand/boot.conf file 
        _checkresolvconf        # check permissions of /etc/resolv.conf file 
        _checkcimconf   # check permission of /var/opt/wbem/cimserver_current.conf
        _checkpamconf   # check the /etc/pam.conf file
        _checksshdconf  # check the /etc/opt/ssh/sshd_config file
	_checkhpsmhruns	# check if HP SMH is running
        
        _checkwbemuser  # check if wbem user has not been locked
        _checkcimauth   # check if wbem user has been authorized for cim work
        _checkcimport   # check if port 5989 is in mode LISTEN (cimservermain process)
        _checkproviders # check with cimprovider -ls if all providers have status OK
        _checkcimconfig # check if the wbem account is privilged to execute cim cmds
        _checkvar       # check /var file system percentage used (<90)

        _pingSimServer  # check if HP SIM server is reachable
        _checkopenssl   # check if openssl to HP SIm server works

        _checkSimSub    # check if system has an valid HPSIM subscription
        _checkWebesSub  # check if system has a HPWEBES subscription

        _sendTestEvent  # final test - send a test event to HP SIM
        _show_ext_subscriptions # show any external subscription of SIM/WEBES
        _show_eventviewer       # show the most recent events

        _list_syslog
        echo
        _line
        echo "Finished with $ERRcode error(s)."
        _line
} 2>&1 | tee -a $instlog 2>/dev/null # tee is used in case of interactive run
[ $? -eq 1 ] && exit 1          # do not send an e-mail as non-root (no log file either)
grep -q FAIL $instlog
if [ $? -eq 0 ]; then
        grep -q "^$WbemUser" /etc/passwd
        if [ $? -eq 0 ]; then
              # when "$WbemUser" account exist then the HPSIM-Check-RSP-readiness.sh script was ran
              _mail "SIM Healtcheck report of $lhost - [FAILED]"
        else
              # migration from ISEE to HPSIM was not yet started
              _mail "SIM Healtcheck report of $lhost - [  N/A ]"
        fi
else
        _mail "SIM Healtcheck report of $lhost - [  OK  ]"
fi
# cleanup
rm -f /tmp/SimServer.txt

# ----------------------------------------------------------------------------
# $Log:  $
#
#
# $RCSfile:  $
# $Source:  $
# $State: Exp $
# ----------------------------------------------------------------------------
