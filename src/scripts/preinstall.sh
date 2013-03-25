#!/bin/sh
# WBEMextras preinstall.sh
CFGFILE="/usr/local/etc/HPSIM_irsa.conf"
DATE=$(date +'%Y-%m-%d')

#echo "       * SW_SOFTWARE_SPEC=${SW_SOFTWARE_SPEC}"
if [ -f $CFGFILE ]; then
    cp -f $CFGFILE  $CFGFILE.$DATE
    echo "       * Saved $CFGFILE as $CFGFILE.$DATE"
fi
