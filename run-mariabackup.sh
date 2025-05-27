#!/bin/bash
# Create a backup user
# CREATE USER 'backup'@'localhost' IDENTIFIED BY 'YourPassword';
# MariaDB < 10.5:
#   GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost';
# MariaDB >= 10.5:
#   GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'backup'@'localhost';
# FLUSH PRIVILEGES;
#
# Usage:
# DB_PASSWORD=YourPassword bash run-mariabackup.sh

############
# SETTINGS #
############

# Database
DB_USER=backup
#DB_PASSWORD=Your_password
DB_HOST=localhost
DB_PORT=3306

# Backup
BACKUP_CMD=mariabackup   # For MySQL you can use 'xtrabackup' instead
BACKUP_DIR=/home/mariabackup
BACKUP_FULL_CYCLE=604800 # Create a new full backup every X seconds
BACKUP_KEEP=5            # Number of full backup cycles a backup should be kept for

# Email
DISABLE_EMAIL_REPORTS=0  # 1 to disable reports
MAIL_TO=user1@example.com
MAIL_FROM=user2@example.com
SMTP_SERVER=localhost
MAILX_CMD=/usr/bin/mailx
MSMTP_CMD=/usr/bin/msmtp
MAIL_TYPE=mailx          # can be 'mailx' or 'msmtp'

# Logs
LOG_FILE=/var/log/replication-status.log
ERR_FILE=/var/log/replication-status.err
LOCK_FILE=/tmp/run-mariabackup.lock

################
# END SETTINGS #
################

dbOptions="--user=${DB_USER} --password=${DB_PASSWORD} --host=${DB_HOST} --port=${DB_PORT}"
backupFullDir=$BACKUP_DIR/base
backupIncrementalDir=$BACKUP_DIR/incr

start=$(date +%s)

# Send email with error log in attachment
function send_email() {
  [[ "$DISABLE_EMAIL_REPORTS" -eq 1 ]] && return

  echo "Sending email to ${MAIL_TO}"

  subject="MariaDB backup error on $HOSTNAME"
  body=$(printf "An error occurred during MariaDB backup on %s:\n\n%s\n\n%s" "$HOSTNAME" "$(grep -i error $ERR_FILE)" "$1")

  case "$MAIL_TYPE" in
    mailx)
      echo "$body" | $MAILX_CMD -s "$subject" -r "$MAIL_FROM" -S smtp="$SMTP_SERVER" -a "$ERR_FILE" "$MAIL_TO"
      ;;
    msmtp)
      echo -e "Subject: $subject\nFrom: $MAIL_FROM\nTo: $MAIL_TO\n\n$body" | $MSMTP_CMD --file=/etc/msmtprc -a default "$MAIL_TO"
      ;;
    *)
      echo "Unknown MAIL_TYPE: $MAIL_TYPE" >&2
      ;;
  esac
}

if [[ $1 == "--retry" ]]; then
  isRetry=true
else
  exec 200>${LOCK_FILE}
  if ! flock -n 200; then
    send_email "Another instance of run-mariabackup is already running."
    exit 1
  fi
fi

{
  echo "----------------------------"
  echo
  echo "run-mariabackup.sh: MariaDB backup script"
  echo "started: $(date)"
  echo

  if test ! -d $backupFullDir; then
    mkdir -p $backupFullDir
  fi

  # Check base dir exists and is writable
  if test ! -d $backupFullDir -o ! -w $backupFullDir; then
    error
    echo $backupFullDir 'does not exist or is not writable'
    echo
    exit 1
  fi

  if test ! -d $backupIncrementalDir; then
    mkdir -p $backupIncrementalDir
  fi

  # check incr dir exists and is writable
  if test ! -d $backupIncrementalDir -o ! -w $backupIncrementalDir; then
    error
    echo $backupIncrementalDir 'does not exist or is not writable'
    echo
    exit 1
  fi

  # shellcheck disable=SC2086
  if ! mysqladmin $dbOptions status | grep -q 'Uptime'; then
    echo "HALTED: MySQL does not appear to be running."
    echo
    exit 1
  fi

  # shellcheck disable=SC2086
  if ! echo 'exit' | /usr/bin/mysql -s $dbOptions; then
    echo "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)"
    echo
    exit 1
  fi

  echo "Ready to start backup"

  # Find latest backup directory
  latestBackupDir=$(find $backupFullDir -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)

  latestBackupAge=$(stat -c %Y "$backupFullDir/$latestBackupDir")

  if [ "$latestBackupDir" ] && [ $((latestBackupAge + BACKUP_FULL_CYCLE + 5)) -ge "$start" ]; then
    echo 'New incremental backup'
    # Create an incremental backup

    # Check incr sub dir exists
    # try to create if not
    if test ! -d "$backupIncrementalDir/$latestBackupDir"; then
      mkdir -p "$backupIncrementalDir/$latestBackupDir"
    fi

    # Check incr sub dir exists and is writable
    if test ! -d "$backupIncrementalDir/$latestBackupDir" -o ! -w "$backupIncrementalDir/$latestBackupDir"; then
      echo "$backupIncrementalDir/$latestBackupDir does not exist or is not writable"
      exit 1
    fi

    latestIncrementalBackupDir=$(find "$backupIncrementalDir/$latestBackupDir" -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
    if [ ! "$latestIncrementalBackupDir" ]; then
      # This is the first incremental backup
      INCRBASEDIR=$backupFullDir/$latestBackupDir
    else
      # This is a 2+ incremental backup
      INCRBASEDIR=$latestIncrementalBackupDir
    fi

    targetDir=$backupIncrementalDir/$latestBackupDir/$(date +%F_%H-%M-%S)
    mkdir -p "$targetDir"

    # Create incremental Backup
    # shellcheck disable=SC2086
    $BACKUP_CMD --backup $dbOptions --extra-lsndir="$targetDir" --incremental-basedir="$INCRBASEDIR" --stream=xbstream 2> >(tee $ERR_FILE >&2) | gzip >"$targetDir/backup.stream.gz"

  else
    echo 'New full backup'

    targetDir=$backupFullDir/$(date +%F_%H-%M-%S)
    mkdir -p "$targetDir"

    # Create a new full backup
    # shellcheck disable=SC2086
    $BACKUP_CMD --backup $dbOptions --extra-lsndir="$targetDir" --stream=xbstream 2> >(tee $ERR_FILE >&2) | gzip >"$targetDir/backup.stream.gz"

  fi

  # If mariabackup didnt finish successfully delete invalid backups and exit
  if ! grep -q 'completed OK!' $ERR_FILE; then
    echo "There were errors. Removing ${targetDir}"
    rm -rf "${targetDir:?}"
    if [[ $isRetry == "true" ]]; then
      send_email "Problem could not be fixed automatically"
    elif grep -q 'failed to read metadata from' $ERR_FILE; then
      send_email "Detected invalid backup. Deleting ${INCRBASEDIR} and retrying..."
      rm -rf "${INCRBASEDIR:?}"
      $0 --retry
    else
      send_email "Unknown reason"
    fi
    sync
    exit 1
  else
    echo "No errors detected"
  fi

  keepMins=$((BACKUP_FULL_CYCLE * (BACKUP_KEEP + 1) / 60))
  echo "Cleaning up old backups (older than $keepMins minutes) and temporary files"

  # Delete old backups
  while IFS= read -r DEL; do
    echo "deleting $DEL"
    rm -rf "${backupFullDir:?}/${DEL:?}"
    rm -rf "${backupIncrementalDir:?}/${DEL:?}"
  done < <(find $backupFullDir -mindepth 1 -maxdepth 1 -type d -mmin +$keepMins -printf "%P\n")

  timeSpent=$(($(date +%s) - start))
  echo
  echo "took $timeSpent seconds"
  echo "completed: $(date)"
  exit 0
} 2>&1 | tee -a ${LOG_FILE}
