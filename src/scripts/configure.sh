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

######### FUNCTIONS ########
############################
function _region {
        # Setting up $webHost based on the network
        #<!-- This rule determines the region in which the system is located.
        #      The region can be specified on the boot command line, or
        #      if it is not specified, it is determined based on the IP address:
        #      10.0                -> DFDEV
        #      10.1   until 10.95  -> NA
        #      10.96  until 10.127 -> LA
        #      10.128 until 10.191 -> EU
        #      10.192 until 10.223 -> AP
        #   -->

        secdig=$(/usr/bin/netstat -rn | /usr/bin/awk '/default/ && /UG/ { print $2 | "/usr/bin/tail -1" }' | /usr/bin/cut -d. -f2)

        case $secdig in
                +([0-9]))
                        if (( $secdig == 0 )); then
                                # Lab
                                SimServer="itsusratdc03.dfdev.jnj.com"
				IUXSERVER=hplabx1.dfdev.jnj.com
                        elif (( $secdig == 1 || $secdig <= 95 )); then
                                # North America
                                SimServer="itsusrasim5.jnj.com"
				IUXSERVER=itsblp02.jnj.com
                        elif (( $secdig == 96 || $secdig <= 127 )); then
                                # Latin America
                                SimServer="itsusrasim5.jnj.com"
				IUXSERVER=itsblp02.jnj.com
                        elif (( $secdig == 128 || $secdig <= 191 )); then
                                # EU
                                SimServer="itsbebesim03.jnj.com"
				IUXSERVER=hpx261.jnj.com
                        elif (( $secdig == 192 || $secdig <= 223 )); then
                                # ASPAC
                                SimServer="itsbebesim03.jnj.com"
				IUXSERVER=hpx261.jnj.com
                        else
                                # Leftovers come to NA
                                SimServer="itsusrasim5.jnj.com"
				IUXSERVER=itsblp02.jnj.com
                        fi
                	;;
                *)
                        /usr/bin/echo "NOTE:    Could not determine network location.  Using defaults."
                        SimServer=itsusrasim5.jnj.com
			IUXSERVER=itsblp02.jnj.com
                	;;
        esac
}


######################################
####		M A I N 	  ####
######################################

### create a new /usr/local/etc/HPSIM_irsa.conf from the template conf file
## /usr/newconfig/usr/local/etc/HPSIM_irsa.conf according region
### advantage is that 'swverify' will not complain about changed files!!

_region

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
