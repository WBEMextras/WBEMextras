#!/sbin/sh
# WBEMextras configure.sh

########

    UTILS="/usr/lbin/sw/control_utils"
    if [[ ! -f $UTILS ]]
    then
        /usr/bin/echo "ERROR: Cannot find $UTILS"
        exit 1
    fi
    . $UTILS
    exitval=$SUCCESS                           # Anticipate success


################################################################################


######################################
####		M A I N 	  ####
######################################

### create a new /usr/local/etc/HPSIM_irsa.conf from the template conf file
## /usr/newconfig/usr/local/etc/HPSIM_irsa.conf according region
### advantage is that 'swverify' will not complain about changed files!!


if [[ ! -f /usr/newconfig/usr/local/etc/HPSIM_irsa.conf ]]
then
	/usr/bin/echo "       * Did not find the template /usr/newconfig/usr/local/etc/HPSIM_irsa.conf file"
	exit 1
fi

/usr/bin/sed -e 's/^SimServer=.*/SimServer='$SimServer'/' -e 's/^IUXSERVER=.*/IUXSERVER='$IUXSERVER'/' \
	< /usr/newconfig/usr/local/etc/HPSIM_irsa.conf >/usr/local/etc/HPSIM_irsa.conf
/sbin/chmod 640 /usr/local/etc/HPSIM_irsa.conf
/sbin/chown root:sys /usr/local/etc/HPSIM_irsa.conf
/usr/bin/echo "       * Created the /usr/local/etc/HPSIM_irsa.conf file"
/usr/bin/echo "       * Using value: SimServer=$SimServer"
/usr/bin/echo "       * Using value: IUXSERVER=$IUXSERVER"

exit $exitval
