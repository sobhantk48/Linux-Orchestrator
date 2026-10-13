SKIPUNZIP=0

ui_print "- Installing Sobhan Terminal Boot Daemon..."
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- Done! Ubuntu chroot will be prepared on boot."
