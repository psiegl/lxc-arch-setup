#!/bin/sh

echo "Provide UNAME for container"
read UNAME

echo "Provide network link to attach container to"
read NET_LINK

echo "Allow device passthrough acceleration if possible (Y/N)"
read DEVPASS

# ToDo: check for DHCP or static IP

LXCPATH=$(grep "lxc.lxcpath" /etc/lxc/lxc.conf | awk '{split($0,a,"= *"); print a[2]}')
LXCCONFIG=/usr/share/lxc/config

CTRPATH=${LXCPATH}/${UNAME}
CTRCONFIG=${CTRPATH}/config

if [ ! -d ${CTRPATH} ]; then
  lxc-create --quiet \
             --name ${UNAME} \
             --bdev best \
             --template download \
             -- \
             --dist archlinux \
             --release current \
             --arch armhf \
             --server images.linuxcontainers.org \
             --no-validate
else
  echo "WARNING: Container folder exists!"
  exit 1
fi

###### Ensure container is not running
lxc-stop -n ${UNAME} -k

###### Set the appropriate bridge, ethernet shall be connected to
sed -i "s/lxc\.network\.link.*/lxc\.network\.link = ${NET_LINK}/g" ${CTRCONFIG}

###### Set tty to 1, as there is no shell anyway (despite of LXC tty)
sed -i "s/lxc\.tty.*/lxc\.tty = 1/g" ${CTRCONFIG}

###### Read the lxc.network.name
NET_NAME=$(grep "lxc.network.name" ${CTRCONFIG} | awk '{split($0,a,"= *"); print a[2]}')

###### Start container first time
lxc-start -n ${UNAME}

###### Wait until we have access to internet
lxc-attach -n ${UNAME} -- bash -c "while true; do ping -c1 www.google.com && break; sleep 1; done"

###### Get new package list
lxc-attach -n ${UNAME} -- pacman -Syy

###### Install dhclient, as systemd-networkd and systemd-resolved require at least CAP_SYS_CHROOT
# https://forum.proxmox.com/threads/archlinux-lxc-systemd-v240.51210/
# https://discuss.linuxcontainers.org/t/no-ipv4-on-unprivileged-arch-container/6202/23
lxc-attach -n ${UNAME} -- pacman -S dhclient --noconfirm

lxc-attach -n ${UNAME} -- systemctl disable systemd-networkd
lxc-attach -n ${UNAME} -- systemctl disable systemd-resolved

lxc-attach -n ${UNAME} -- pacman -Runs dhcpcd netctl --noconfirm

lxc-attach -n ${UNAME} -- systemctl enable dhclient@${NET_NAME}

###### Wait until we have access to internet
lxc-attach -n ${UNAME} -- bash -c "while true; do ping -c1 www.google.com && break; sleep 1; done"

###### Mask tmp mount, otherwise issue with CAP_SYS_ADMIN
lxc-attach -n ${UNAME} -- systemctl mask tmp.mount

###### Mask all modprobe, as the container will anyway not have the ability to do it.
lxc-attach -n ${UNAME} -- systemctl mask modproble@
lxc-attach -n ${UNAME} -- systemctl mask modproble@drm
lxc-attach -n ${UNAME} -- systemctl mask system-modprobe.slice

###### Stop container, to set up capabilites
lxc-attach -n ${UNAME} -- shutdown -h now
while [ $(lxc-info -n ${UNAME} | grep State | awk '{split($0,a,": *"); print a[2]}') != "STOPPED" ]; do
  sleep 1
  lxc-stop -n ${UNAME} -k
done

###### Check if there is a CRYPTO dev that accelerates CRYPTO also in container
# such as seen on the Turris Omnia
if [ -c /dev/crypto ] && [ ${DEVPASS} != "N" ]; then
  echo "" >> ${CTRCONFIG}
  echo "lxc.cgroup.devices.allow = c 10:58 rwm" >> ${CTRCONFIG}
  echo "lxc.mount.entry=/dev/crypto dev/crypto none bind" >> ${CTRCONFIG}
fi

###### Setup script to hook up the CGROUPS early, to support CAP_SYS_ADMIN in LXC1.0
CTRHOOKCGROUPS=${CTRPATH}/hook-croups.sh
cat << EOF > ${CTRHOOKCGROUPS}
#!/bin/sh
mkdir -p \${LXC_ROOTFS_MOUNT}/sys/fs/cgroup/systemd
mount cgroup \${LXC_ROOTFS_MOUNT}/sys/fs/cgroup/systemd \
      -t cgroup \
      -o rw,nosuid,nodev,noexec,relatime,xattr,name=systemd
EOF
chmod +x ${CTRHOOKCGROUPS}

###### Patch the config
cat << EOF >> ${CTRCONFIG}

lxc.kmsg = 0

lxc.logfile = ${CTRPATH}/${UNAME}.log
lxc.loglevel = 1

# to get CAP_SYS_ADMIN
lxc.mount.auto = proc:mixed sys:ro

lxc.autodev = 1
lxc.mount.entry = tmpfs dev/shm tmpfs rw,nosuid,nodev,create=dir 0 0
lxc.mount.entry = tmpfs run tmpfs rw,nosuid,nodev,mode=755,create=dir 0 0
lxc.mount.entry = tmpfs run/lock tmpfs rw,nosuid,nodev,noexec,relatime,size=5120k,create=dir 0 0
lxc.mount.entry = tmpfs run/user tmpfs rw,nosuid,nodev,mode=755,size=50m,create=dir 0 0
lxc.mount.entry = tmpfs sys/fs/cgroup tmpfs rw,nosuid,nodev,create=dir 0 0
lxc.mount.entry = mqueue dev/mqueue mqueue rw,relatime,create=dir 0 0
lxc.hook.mount = ${CTRHOOKCGROUPS}
# ----

lxc.cap.drop = audit_control audit_read audit_write block_suspend
lxc.cap.drop = dac_read_search 
lxc.cap.drop = fowner fsetid ipc_lock ipc_owner
lxc.cap.drop = lease
lxc.cap.drop = linux_immutable mknod
lxc.cap.drop = kill
lxc.cap.drop = sys_admin sys_boot
lxc.cap.drop = sys_ptrace sys_resource sys_tty_config syslog wake_alarm
lxc.cap.drop = chown net_broadcast

# In case there are issues with PACMAN, comment:
lxc.cap.drop = sys_chroot dac_override
EOF

###### For now script does not set:
#lxc.cap.drop = net_admin                                     # kills tinc, dhclient (, iptables)
#lxc.cap.drop = net_bind_service                              # kills dhclient
#lxc.cap.drop = net_raw                                       # kills dhclient
#lxc.cap.drop = setgid                                        # kills systemctl on LXC1.0 / ArchLinux
#lxc.cap.drop = setpcap                                       # kills journald
#lxc.cap.drop = setuid                                        # kills systemctl on LXC1.0 / ArchLinux

###### ToDo: check that setfcap sys_nice sys_pacct sys_rawio are dropped in /usr/share/lxc/config/archlinux.common.conf
###### ToDo: check that mac_admin mac_override sys_time sys_module are dropped in /usr/share/lxc/config/common.conf
###### ToDo: check that seccomp is used in /usr/share/lxc/config/common.conf
###### ToDo: check that cgroup whitelist is set in /usr/share/lxc/config/common.conf
###### ToDo: check that devttydir is used in /usr/share/lxc/config/common.conf

###### Start container again
lxc-start -n ${UNAME}



