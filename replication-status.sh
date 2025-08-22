#!/bin/bash
### Based on https://handyman.dulare.com/mysql-replication-status-alerts-with-bash-script/
#
# Create replication status user in the database:
# CREATE USER 'replstatus'@'localhost' IDENTIFIED BY 'your_password';
# GRANT SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'replstatus'@'localhost';
# FLUSH PRIVILEGES;
#
# Usage:
# DB_PASSWORD=YourPassword bash replication-status.sh
# Or with custom config file:
# DB_PASSWORD=YourPassword bash replication-status.sh /path/to/config.env

####################
# DEFAULT SETTINGS #
####################

# Set the maximum number of seconds behind master that will be ignored.
# If the slave is be more than maximumSecondsBehind, an email will be sent.
MAX_SECONDS_BEHIND=300

# Database
DB_TYPE=mariadb
DB_USER=replstatus
#DB_PASSWORD=your_password
DB_HOST=localhost
DB_PORT=3306

# Email
DISABLE_EMAIL_REPORTS=0     # 1 to disable reports
#MAIL_TO=user1@example.com
#MAIL_FROM=user2@example.com
SMTP_SERVER=localhost
MAILX_CMD=/usr/bin/mailx
MSMTP_CMD=/usr/bin/msmtp
MAIL_TYPE=mailx             # can be 'mailx' or 'msmtp'
EMAIL_THROTTLE_SECONDS=3600 # Don't send error emails more often than this (in seconds)

# Logs
LOG_FILE=/var/log/replication-status.log
ERR_FILE=/var/log/replication-status-error.txt
LAST_ERROR_EMAIL_FILE=/tmp/replication-status-last-error-email
LAST_SUCCESS_FILE=/tmp/replication-status-last-success

################
# END SETTINGS #
################

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
      return
    fi
  fi

  echo "Sending email to ${MAIL_TO}"

  subject="Database replication error on $HOSTNAME"
  if [[ -f "$ERR_FILE" ]]; then
    error_details=$(grep -ai error "$ERR_FILE" | head -10)
  else
    error_details="Error file not found: $ERR_FILE"
  fi
  body=$(printf "An error occurred during database replication on %s:\n\n%s\n\n%s" "$HOSTNAME" "$error_details" "$1")

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

function print_error() {
  local error_message="$1"
  echo "$error_message"
  echo "$error_message" >&3
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
  echo "replication-status.sh: MariaDB replication status check"
  echo "started: $(date)"
  echo

  # Parse command line arguments
  envFilePath=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      *)
        envFilePath="$1"
        ;;
    esac
    shift
  done

  echo "{ envFilePath: '$envFilePath' }"

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
    "-u${DB_USER}"
    "-p${DB_PASSWORD}"
    "-h${DB_HOST}"
    "-P${DB_PORT}"
  )

  echo "$(date +%Y%m%d_%H%M%S): Replication check started."

  # Check if the database is running
  if systemctl is-active ${DB_TYPE} > /dev/null; then
    # Get the replication status...
    ${DB_TYPE} "${dbOptions[@]}" -e 'SHOW SLAVE STATUS \G' | grep 'Running:\|Master:\|Error:' >$ERR_FILE

    # Getting parameters
    slaveRunning="$(grep -c "Slave_IO_Running: Yes" $ERR_FILE)"
    slaveSQLRunning="$(grep -c "Slave_SQL_Running: Yes" $ERR_FILE)"
    secondsBehind="$(grep "Seconds_Behind_Master" $ERR_FILE | tr -dc '0-9')"
    dbNotRunning=0
  else
    # The database is not running
    printf "%s\n\n%s" "Error: ${DB_TYPE} is not running." "$(systemctl status ${DB_TYPE})" >$ERR_FILE
    dbNotRunning=1
  fi

  # Check for problems and send email if needed
  if [[ $dbNotRunning == 1 || $slaveRunning != 1 || $slaveSQLRunning != 1 || $secondsBehind -gt $MAX_SECONDS_BEHIND ]]; then
    cat $ERR_FILE
    echo "$(date +%Y%m%d_%H%M%S): Replication check finished. Problems detected."
    exit_error "Replication problems detected"
  else
    echo "$(date +%Y%m%d_%H%M%S): Replication check finished OK."
    exit_ok
  fi
} |& tee -a ${LOG_FILE}
