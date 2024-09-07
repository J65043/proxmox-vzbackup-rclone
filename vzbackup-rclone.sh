#!/bin/bash
# ./vzbackup-rclone.sh rehydrate YYYY/MM/DD file_name_encrypted.bin

############ /START CONFIG
dumpdir="/mnt/pve/pvebackups01/dump" # Set this to where your vzdump files are stored
MAX_AGE=3 # This is the age in days to keep local backup copies. Local backups older than this are deleted.
MAX_CLOUD_BACKUPS=5 # Set the maximum number of backups to retain on the cloud per VM.
############ /END CONFIG

_bdir="$dumpdir"
rcloneroot="$dumpdir/rclone"
timepath="$(date +%Y)/$(date +%m)/$(date +%d)"
rclonedir="$rcloneroot/$timepath"
COMMAND=${1}
rehydrate=${2} #enter the date you want to rehydrate in the following format: YYYY/MM/DD
if [ ! -z "${3}" ];then
        CMDARCHIVE=$(echo "/${3}" | sed -e 's/\(.bin\)*$//g')
fi
tarfile=${TARFILE}
exten=${tarfile#*.}
filename=${tarfile%.*.*}

if [[ ${COMMAND} == 'rehydrate' ]]; then
    rclone --config /root/.config/rclone/rclone.conf \
    --drive-chunk-size=32M copy gd-backup_crypt:/$rehydrate$CMDARCHIVE $dumpdir \
    -v --stats=60s --transfers=16 --checkers=16
fi

if [[ ${COMMAND} == 'job-start' ]]; then
    echo "Deleting backups older than $MAX_AGE days."
    find $dumpdir -type f -mtime +$MAX_AGE -exec /bin/rm -f {} \;
fi

if [[ ${COMMAND} == 'backup-end' ]]; then
    echo "Backing up $tarfile to remote storage"
    rclone --config /root/.config/rclone/rclone.conf \
    --drive-chunk-size=32M copy $tarfile gd-backup_crypt:/$timepath \
    -v --stats=60s --transfers=16 --checkers=16

    echo "Checking and pruning old backups on remote storage"
    
    # List all VM backup files on the cloud storage
    backup_list=$(rclone --config /root/.config/rclone/rclone.conf lsf gd-backup_crypt:/ --format "p" --files-only --sort-by modtime)

    # Group backups by VM (assuming VM name or ID is part of the filename)
    for vm in $(echo "$backup_list" | awk -F'_' '{print $1}' | sort | uniq); do
        echo "Processing backups for VM: $vm"
        
        # Get a list of backups for the current VM, sorted by time (most recent last)
        vm_backups=$(echo "$backup_list" | grep "^$vm" | sort)

        # Count the number of backups for the VM
        num_backups=$(echo "$vm_backups" | wc -l)

        # If more backups than allowed, delete the oldest ones
        if [[ $num_backups -gt $MAX_CLOUD_BACKUPS ]]; then
            delete_count=$((num_backups - MAX_CLOUD_BACKUPS))
            echo "Deleting $delete_count old backups for VM $vm"
            old_backups=$(echo "$vm_backups" | head -n $delete_count)
            for backup in $old_backups; do
                rclone --config /root/.config/rclone/rclone.conf delete gd-backup_crypt:/$backup -v
            done
        else
            echo "No old backups to delete for VM $vm. Cloud storage is within the limit."
        fi
    done
fi

if [[ ${COMMAND} == 'job-end' ||  ${COMMAND} == 'job-abort' ]]; then
    echo "Backing up main PVE configs"
    _tdir=${TMP_DIR:-/var/tmp}
    _tdir=$(mktemp -d $_tdir/proxmox-XXXXXXXX)
    function clean_up {
        echo "Cleaning up"
        rm -rf $_tdir
    }
    trap clean_up EXIT
    _now=$(date +%Y-%m-%d.%H.%M.%S)
    _HOSTNAME=$(hostname -f)
    _filename1="$_tdir/proxmoxetc.$_now.tar"
    _filename2="$_tdir/proxmoxpve.$_now.tar"
    _filename3="$_tdir/proxmoxroot.$_now.tar"
    _filename4="$_tdir/proxmox_backup_"$_HOSTNAME"_"$_now".tar.gz"

    echo "Tar files"
    tar --warning='no-file-ignored' -cPf "$_filename1" /etc/.
    tar --warning='no-file-ignored' -cPf "$_filename2" /var/lib/pve-cluster/.
    tar --warning='no-file-ignored' -cPf "$_filename3" /root/.

    echo "Compressing files"
    tar -cvzPf "$_filename4" $_tdir/*.tar

    cp -v $_filename4 $_bdir/
    echo "rcloning $_filename4"
    rclone --config /root/.config/rclone/rclone.conf \
    --drive-chunk-size=32M move $_filename4 gd-backup_crypt:/$timepath \
    -v --stats=60s --transfers=16 --checkers=16
fi
