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
# Or with custom config file:
# DB_PASSWORD=YourPassword bash run-mariabackup.sh /path/to/config.env

####################
# DEFAULT SETTINGS #
####################

# Database
DB_USER=backup
#DB_PASSWORD=Your_password
DB_HOST=localhost
DB_PORT=3306

# Backup
BACKUP_CMD=mariabackup      # For MySQL you can use 'xtrabackup' instead
BACKUP_DIR=/home/mariabackup
BACKUP_FULL_CYCLE=604800    # Create a new full backup every X seconds
BACKUP_KEEP=5               # Number of full backup cycles a backup should be kept for

# Email
DISABLE_EMAIL_REPORTS=0     # 1 to disable reports
#MAIL_TO=user1@example.com
#MAIL_FROM=user2@example.com
SMTP_SERVER=localhost
MAILX_CMD=/usr/bin/mailx
MSMTP_CMD=/usr/bin/msmtp
MAIL_TYPE=mailx              # can be 'mailx' or 'msmtp'
EMAIL_THROTTLE_SECONDS=3600  # Don't send error emails more often than this (in seconds)

# Logs
LOG_FILE=/var/log/mariabackup.log
ERR_FILE=/var/log/mariabackup-error.txt
LOCK_FILE=/tmp/run-mariabackup.lock
LAST_ERROR_EMAIL_FILE=/tmp/run-mariabackup-last-error-email
LAST_SUCCESS_FILE=/tmp/run-mariabackup-last-success

################
# END SETTINGS #
################

function print_error() {
  local error_message="$1"
  echo "$error_message"
  echo "$error_message" >&3
}

# Send email with error log in attachment
function send_email() {
  [[ "$DISABLE_EMAIL_REPORTS" -eq 1 ]] && return

  if [[ -z "$MAIL_TO" || -z "$MAIL_FROM" || -z "$SMTP_SERVER" ]]; then
    print_error "ERROR: MAIL_TO and MAIL_FROM and SMTP_SERVER must be set when email reports are enabled."
    return 1
  fi

  local current_time last_error_email_time time_since_last_error last_success_time

  current_time=$(date +%s)

  # Check if we should throttle this email
  if [[ -f "$LAST_ERROR_EMAIL_FILE" ]]; then
    last_error_email_time=$(cat "$LAST_ERROR_EMAIL_FILE" 2>/dev/null || echo 0)
    time_since_last_error=$((current_time - last_error_email_time))

    # Check if there was a successful run since the last error email
    last_success_time=0
    if [[ -f "$LAST_SUCCESS_FILE" ]]; then
      last_success_time=$(cat "$LAST_SUCCESS_FILE" 2>/dev/null || echo 0)
    fi

    # If last error email was sent recently and no successful run since then, skip sending
    if [[ $time_since_last_error -lt $EMAIL_THROTTLE_SECONDS ]] && [[ $last_success_time -lt $last_error_email_time ]]; then
      echo "Skipping email - last error email sent $time_since_last_error seconds ago (throttle: ${EMAIL_THROTTLE_SECONDS}s) and no successful run since then"
      return 1
    fi
  fi

  [[ "$isDryRun" == true ]] && { echo "[DRY RUN] Would send email: $1"; return; }

  echo "Sending email to ${MAIL_TO}"

  subject="MariaDB backup error on $HOSTNAME"
  if [[ -f "$ERR_FILE" ]]; then
    error_details=$(grep -ai error "$ERR_FILE" | head -10)
  else
    error_details="Error file not found: $ERR_FILE"
  fi
  body=$(printf "An error occurred during MariaDB backup on %s:\n\n%s\n\n%s" "$HOSTNAME" "$error_details" "$1")

  case "$MAIL_TYPE" in
    mailx)
      if ! echo "$body" | $MAILX_CMD -s "$subject" -r "$MAIL_FROM" -S smtp="$SMTP_SERVER" ${ERR_FILE:+-a "$ERR_FILE"} "$MAIL_TO"; then
        print_error "ERROR: Failed to send email via mailx"
        return 1
      fi
      ;;
    msmtp)
      if ! echo -e "Subject: $subject\nFrom: $MAIL_FROM\nTo: $MAIL_TO\n\n$body" | $MSMTP_CMD --file=/etc/msmtprc -a default "$MAIL_TO"; then
        print_error "ERROR: Failed to send email via msmtp"
        return 1
      fi
      ;;
    *)
      print_error "ERROR: Unknown MAIL_TYPE: $MAIL_TYPE"
      return 1
      ;;
  esac

  # Record that we sent an error email
  echo "$current_time" > "$LAST_ERROR_EMAIL_FILE"
}

# Record successful completion
function exit_ok() {
  date +%s > "$LAST_SUCCESS_FILE"
  echo "---------- EXIT 0 ----------"
  exit 0
}

# Handle error exit with email notification
function exit_error() {
  local error_message="$1"
  echo "$error_message"
  send_email "$error_message"
  echo "---------- EXIT 1 ----------"
  exit 1
}

exec 3>&2  # save original stderr to fd 3
{
  echo "----------------------------"
  echo "run-mariabackup.sh: MariaDB backup script"
  echo "started: $(date)"
  echo

  # Parse command line arguments
  envFilePath=""
  isRetry=false
  isDryRun=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retry)
        isRetry=true
        ;;
      --dry-run)
        isDryRun=true
        ;;
      *)
        envFilePath="$1"
        ;;
    esac
    shift
  done

  echo "{ isRetry: $isRetry, isDryRun: $isDryRun, envFilePath: '$envFilePath' }"

  # Source custom environment file if provided
  if [[ -n "$envFilePath" ]]; then
    if [[ -f "$envFilePath" ]]; then
      echo "Sourcing configuration from: $envFilePath"
      # shellcheck disable=SC1090
      source "$envFilePath"
    else
      exit_error "Config file not found: $envFilePath"
    fi
  fi

  # Check required variables
  if [[ -z "$DB_PASSWORD" ]]; then
    exit_error "DB_PASSWORD is not set. Please set it as an environment variable or in the config file."
  fi

  dbOptions=(
    "--user=${DB_USER}"
    "--password=${DB_PASSWORD}"
    "--host=${DB_HOST}"
    "--port=${DB_PORT}"
  )
  dbOptionsForLogging=(
    "--user=${DB_USER}"
    "--password=***"
    "--host=${DB_HOST}"
    "--port=${DB_PORT}"
  )
  backupFullDir=$BACKUP_DIR/base
  backupIncrementalDir=$BACKUP_DIR/incr

  start=$(date +%s)

  if [[ $isRetry != true ]]; then
    exec 200>${LOCK_FILE}
    if ! flock -n 200; then
      exit_error "Another instance of run-mariabackup is already running."
    fi
  fi

  if test ! -d $backupFullDir; then
    mkdir -p $backupFullDir
  fi

  # Check base dir exists and is writable
  if test ! -d $backupFullDir -o ! -w $backupFullDir; then
    exit_error "$backupFullDir does not exist or is not writable"
  fi

  if test ! -d $backupIncrementalDir; then
    mkdir -p $backupIncrementalDir
  fi

  # check incr dir exists and is writable
  if test ! -d $backupIncrementalDir -o ! -w $backupIncrementalDir; then
    exit_error "$backupIncrementalDir does not exist or is not writable"
  fi

  if ! mysqladmin "${dbOptions[@]}" status | grep -q 'Uptime'; then
    exit_error "the database does not appear to be running"
  fi

  if ! echo 'exit' | /usr/bin/mysql -s "${dbOptions[@]}"; then
    exit_error "the supplied database username or password appears to be incorrect"
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
      exit_error "$backupIncrementalDir/$latestBackupDir does not exist or is not writable"
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
    
    # Create incremental Backup
    if [[ "$isDryRun" == true ]]; then
      echo "[DRY RUN] Would run: $BACKUP_CMD --backup ${dbOptionsForLogging[*]} --extra-lsndir=\"$targetDir\" --incremental-basedir=\"$INCRBASEDIR\" --stream=xbstream | gzip >\"$targetDir/backup.stream.gz\""
    else
      mkdir -p "$targetDir"
      $BACKUP_CMD --backup "${dbOptions[@]}" --extra-lsndir="$targetDir" --incremental-basedir="$INCRBASEDIR" --stream=xbstream 2> >(tee $ERR_FILE >&2) | gzip >"$targetDir/backup.stream.gz"
    fi

  else
    echo 'New full backup'

    targetDir=$backupFullDir/$(date +%F_%H-%M-%S)

    # Create a new full backup
    if [[ "$isDryRun" == true ]]; then
      echo "[DRY RUN] Would run: $BACKUP_CMD --backup ${dbOptionsForLogging[*]} --extra-lsndir=\"$targetDir\" --stream=xbstream | gzip >\"$targetDir/backup.stream.gz\""
    else
      mkdir -p "$targetDir"
      $BACKUP_CMD --backup "${dbOptions[@]}" --extra-lsndir="$targetDir" --stream=xbstream 2> >(tee $ERR_FILE >&2) | gzip >"$targetDir/backup.stream.gz"
    fi

  fi

  # If mariabackup didnt finish successfully delete invalid backups and exit
  if [[ "$isDryRun" == true ]]; then
    echo "[DRY RUN] Skipping backup completion check"
  elif ! grep -q 'completed OK!' $ERR_FILE; then
    echo "There were errors. Removing ${targetDir}"
    rm -rf "${targetDir:?}"
    if [[ $isRetry == "true" ]]; then
      send_email "Problem could not be fixed automatically"
    elif grep -q 'failed to read metadata from' $ERR_FILE; then
      send_email "Detected invalid backup. Deleting ${INCRBASEDIR} and retrying..."
      rm -rf "${INCRBASEDIR:?}"
      if [[ -n "$envFilePath" ]]; then
        $0 --retry "$envFilePath"
      else
        $0 --retry
      fi
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
    if [[ "$isDryRun" == true ]]; then
      echo "[DRY RUN] Would delete $DEL"
    else
      echo "deleting $DEL"
      rm -rf "${backupFullDir:?}/${DEL:?}"
      rm -rf "${backupIncrementalDir:?}/${DEL:?}"
    fi
  done < <(find $backupFullDir -mindepth 1 -maxdepth 1 -type d -mmin +$keepMins -printf "%P\n")

  timeSpent=$(($(date +%s) - start))
  echo
  echo "took $timeSpent seconds"
  echo "completed: $(date)"
  
  # Record successful completion
  exit_ok
} |& tee -a ${LOG_FILE}
