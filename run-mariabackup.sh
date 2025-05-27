#!/bin/bash
# Create a backup user:
# GRANT PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost' identified by 'YourPassword';
# FLUSH PRIVILEGES;
#
# Usage:
# MYSQL_PASSWORD=YourPassword bash run-mariabackup.sh

MYSQL_USER=backup
#MYSQL_PASSWORD=Your_password
MYSQL_HOST=localhost
MYSQL_PORT=3306
BACKCMD=mariabackup
BACKDIR=/home/mariabackup
FULLBACKUPCYCLE=604800 # Create a new full backup every X seconds
KEEP=5                 # Number of full backup cycles a backup should be kept for

USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
ARGS=""
BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr

LOGFILE=/var/log/run-mariabackup.log
ERRFILE=/var/log/run-mariabackup.err
LOCKFILE=/tmp/run-mariabackup.lock

MAILXCMD=/bin/mailx
MAILFROM=user1@example.com
MAILTO=user2@example.com
SMTPSERVER=localhost

START=$(date +%s)

# Send email with error log in attachment
function send_email() {
  echo "Sending email to ${MAILTO}"
  printf "An error occured during MariaDB backup on %s:\n\n%s\n\n%s" "${HOSTNAME}" "$(grep -i error $ERRFILE)" "$1" | $MAILXCMD -s "MariaDB backup error on $HOSTNAME" -r ${MAILFROM} -S ${SMTPSERVER} -a $ERRFILE ${MAILTO}
}

if [[ $1 == "--retry" ]]; then
  RUNBACKUPFAILED=true
else
  exec 200>${LOCKFILE}
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

  if test ! -d $BASEBACKDIR; then
    mkdir -p $BASEBACKDIR
  fi

  # Check base dir exists and is writable
  if test ! -d $BASEBACKDIR -o ! -w $BASEBACKDIR; then
    error
    echo $BASEBACKDIR 'does not exist or is not writable'
    echo
    exit 1
  fi

  if test ! -d $INCRBACKDIR; then
    mkdir -p $INCRBACKDIR
  fi

  # check incr dir exists and is writable
  if test ! -d $INCRBACKDIR -o ! -w $INCRBACKDIR; then
    error
    echo $INCRBACKDIR 'does not exist or is not writable'
    echo
    exit 1
  fi

  # shellcheck disable=SC2086
  if ! mysqladmin $USEROPTIONS status | grep -q 'Uptime'; then
    echo "HALTED: MySQL does not appear to be running."
    echo
    exit 1
  fi

  # shellcheck disable=SC2086
  if ! echo 'exit' | /usr/bin/mysql -s $USEROPTIONS; then
    echo "HALTED: Supplied mysql username or password appears to be incorrect (not copied here for security, see script)"
    echo
    exit 1
  fi

  echo "Ready to start backup"

  # Find latest backup directory
  LATEST=$(find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)

  AGE=$(stat -c %Y "$BASEBACKDIR/$LATEST")

  if [ "$LATEST" ] && [ $((AGE + FULLBACKUPCYCLE + 5)) -ge "$START" ]; then
    echo 'New incremental backup'
    # Create an incremental backup

    # Check incr sub dir exists
    # try to create if not
    if test ! -d "$INCRBACKDIR/$LATEST"; then
      mkdir -p "$INCRBACKDIR/$LATEST"
    fi

    # Check incr sub dir exists and is writable
    if test ! -d "$INCRBACKDIR/$LATEST" -o ! -w "$INCRBACKDIR/$LATEST"; then
      echo "$INCRBACKDIR/$LATEST does not exist or is not writable"
      exit 1
    fi

    LATESTINCR=$(find "$INCRBACKDIR/$LATEST" -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
    if [ ! "$LATESTINCR" ]; then
      # This is the first incremental backup
      INCRBASEDIR=$BASEBACKDIR/$LATEST
    else
      # This is a 2+ incremental backup
      INCRBASEDIR=$LATESTINCR
    fi

    TARGETDIR=$INCRBACKDIR/$LATEST/$(date +%F_%H-%M-%S)
    mkdir -p "$TARGETDIR"

    # Create incremental Backup
    # shellcheck disable=SC2086
    $BACKCMD --backup $USEROPTIONS $ARGS --extra-lsndir="$TARGETDIR" --incremental-basedir="$INCRBASEDIR" --stream=xbstream 2> >(tee $ERRFILE >&2) | gzip >"$TARGETDIR/backup.stream.gz"

  else
    echo 'New full backup'

    TARGETDIR=$BASEBACKDIR/$(date +%F_%H-%M-%S)
    mkdir -p "$TARGETDIR"

    # Create a new full backup
    # shellcheck disable=SC2086
    $BACKCMD --backup $USEROPTIONS $ARGS --extra-lsndir="$TARGETDIR" --stream=xbstream 2> >(tee $ERRFILE >&2) | gzip >"$TARGETDIR/backup.stream.gz"

  fi

  # If mariabackup didnt finish successfully delete invalid backups and exit
  if ! grep -q 'completed OK!' $ERRFILE; then
    echo "There were errors. Removing ${TARGETDIR}"
    rm -rf "${TARGETDIR:?}"
    if [[ $RUNBACKUPFAILED == "true" ]]; then
      send_email "Problem could not be fixed automatically"
    elif grep -q 'failed to read metadata from' $ERRFILE; then
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

  MINS=$((FULLBACKUPCYCLE * (KEEP + 1) / 60))
  echo "Cleaning up old backups (older than $MINS minutes) and temporary files"

  # Delete old backups
  while IFS= read -r DEL; do
    echo "deleting $DEL"
    rm -rf "${BASEBACKDIR:?}/${DEL:?}"
    rm -rf "${INCRBACKDIR:?}/${DEL:?}"
  done < <(find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -printf "%P\n")

  SPENT=$(($(date +%s) - START))
  echo
  echo "took $SPENT seconds"
  echo "completed: $(date)"
  exit 0
} 2>&1 | tee -a ${LOGFILE}
