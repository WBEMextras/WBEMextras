################################################################################
# Version Info : @(#)copy_hpux_depot.sh      1.1     04/Apr/2012
################################################################################
TARGET_DIR=/var/opt/ignite/depots/GLOBAL/irsa
swreg -l depot  $PWD/WBEMextras.dirdepot
swcopy -x reinstall=true -s ./WBEMextras.dirdepot WBEMextras @ $TARGET_DIR/11.11
swcopy -x reinstall=true -s ./WBEMextras.dirdepot WBEMextras @ $TARGET_DIR/11.23
swcopy -x reinstall=true -s ./WBEMextras.dirdepot WBEMextras @ $TARGET_DIR/11.31
swreg -u -l depot $PWD/WBEMextras.dirdepot
echo done.
