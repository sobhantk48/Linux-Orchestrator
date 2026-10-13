#!/system/bin/sh
# Wait until boot process is completed
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 2
done

UBUNTU_DIR="/data/ubuntu"

# Only proceed if rootfs exists
if [ -f "$UBUNTU_DIR/bin/bash" ]; then
  mountpoint -q $UBUNTU_DIR || mount --bind $UBUNTU_DIR $UBUNTU_DIR
  mount -o remount,suid,dev $UBUNTU_DIR 2>/dev/null

  mountpoint -q $UBUNTU_DIR/dev || mount --bind /dev $UBUNTU_DIR/dev
  mountpoint -q $UBUNTU_DIR/dev/pts || mount -t devpts devpts $UBUNTU_DIR/dev/pts -o ptmxmode=0666,mode=620 2>/dev/null || mount --bind /dev/pts $UBUNTU_DIR/dev/pts
  mountpoint -q $UBUNTU_DIR/proc || mount -t proc proc $UBUNTU_DIR/proc
  mountpoint -q $UBUNTU_DIR/sys || mount -t sysfs sysfs $UBUNTU_DIR/sys

  if [ -d /sdcard ]; then
    mkdir -p $UBUNTU_DIR/sdcard
    mountpoint -q $UBUNTU_DIR/sdcard || mount --bind /sdcard $UBUNTU_DIR/sdcard
  fi

  # DNS
  if [ ! -s $UBUNTU_DIR/etc/resolv.conf ]; then
    echo "nameserver 8.8.8.8" > $UBUNTU_DIR/etc/resolv.conf
    echo "nameserver 1.1.1.1" >> $UBUNTU_DIR/etc/resolv.conf
  fi

  # Network group & suid
  if ! grep -q "aid_inet" $UBUNTU_DIR/etc/group 2>/dev/null; then
    echo "aid_inet:x:3003:root,sobhan" >> $UBUNTU_DIR/etc/group
  fi
  chmod 4755 $UBUNTU_DIR/usr/bin/sudo 2>/dev/null
fi
