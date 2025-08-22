# MariaDB/MySQL Database Scripts

This repository contains two essential database management scripts:

1. **run-mariabackup.sh** - Automated backup solution for MariaDB/MySQL with e-mail alerts
2. **replication-status.sh** - Replication monitoring script with e-mail alerts

*run-mariabackup.sh forked from [omegazeng/run-mariabackup.sh](https://github.com/omegazeng/run-mariabackup) which was*
*forked from [jmfederico/run-xtrabackup.sh](https://gist.github.com/jmfederico/1495347)*

Note: tested on Enterprise Linux 8 with MariaDB 10.11

---

## run-mariabackup.sh

### Install

    yum -y install MariaDB-backup
    curl https://raw.githubusercontent.com/shunkica/mariadb-scripts/refs/heads/master/run-mariabackup.sh --output /usr/local/sbin/run-mariabackup.sh
    chmod 700 /usr/local/sbin/run-mariabackup.sh

### Create a backup user

    GRANT PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost' identified by 'YourPassword';
    FLUSH PRIVILEGES;

### Usage

#### Basic usage with environment variables:

    DB_PASSWORD=YourPassword EMAIL_FROM=your@email EMAIL_TO=your@email bash run-mariabackup.sh

#### Using a custom configuration file:

    bash run-mariabackup.sh /path/to/config.env

#### Dry run mode:

    bash run-mariabackup.sh --dry-run

The `--dry-run` option will simulate the backup process without actually running backup commands, sending emails, or deleting files. This is useful for testing configuration and seeing what the script would do.

The script will first load its default settings, then source the provided configuration file, allowing you to override any settings. Example config file:

```bash
# config.env
DB_PASSWORD=YourPassword
BACKUP_DIR=/custom/backup/path
MAIL_TO=admin@example.com
EMAIL_THROTTLE_SECONDS=7200
```

Full list of configurable environment variables with their default values can be found at the start of the `run-mariabackup.sh` script.

### Crontab

    #MySQL Backup, run every hour at the 30th minute
    30 */1 * * * /bin/bash /usr/local/sbin/run-mariabackup.sh /etc/mariabackup.env > /dev/null

### Restore Example

The script for restoring data from backups is intentionally left out, but here is an example of how you might do it.

    # tree /home/mysqlbackup/
    /home/mysqlbackup/
    ├── base
    │   └── 2020-03-12_12-08-44
    │       ├── backup.stream.gz
    │       ├── xtrabackup_checkpoints
    │       └── xtrabackup_info
    └── incr
        └── 2020-03-12_12-08-44
            ├── 2020-03-12_13-24-20
            │   ├── backup.stream.gz
            │   ├── xtrabackup_checkpoints
            │   └── xtrabackup_info
            └── 2020-03-12_13-54-25
                ├── backup.stream.gz
                ├── xtrabackup_checkpoints
                └── xtrabackup_info


```bash
# decompress
cd /home/mysqlbackup/
for i in $(find . -name backup.stream.gz | grep '2020-03-12_12-08-44' | xargs dirname); \
do \
mkdir -p $i/backup; \
zcat $i/backup.stream.gz | mbstream -x -C $i/backup/; \
done

# prepare
mariabackup --prepare --target-dir base/2020-03-12_12-08-44/backup/ --user backup --password "YourPassword"
mariabackup --prepare --target-dir base/2020-03-12_12-08-44/backup/ --user backup --password "YourPassword" --incremental-dir incr/2020-03-12_12-08-44/2020-03-12_13-24-20/backup/
mariabackup --prepare --target-dir base/2020-03-12_12-08-44/backup/ --user backup --password "YourPassword" --incremental-dir incr/2020-03-12_12-08-44/2020-03-12_13-54-25/backup/

# stop mariadb
systemctl stop mariadb

# move datadir
mv /var/lib/mysql/ /var/lib/mysql_bak/

# copy-back
mariabackup --copy-back --target-dir base/2020-03-12_12-08-44/backup/ --user backup --password "YourPassword" --datadir /var/lib/mysql/

# fix privileges
chown -R mysql:mysql /var/lib/mysql/

# fix selinux context
restorecon -Rv /var/lib/mysql

# start mariadb
systemctl start mariadb

# done!
```

### Links

[Full Backup and Restore with Mariabackup](https://mariadb.com/docs/server/server-usage/backup-and-restore/mariadb-backup/full-backup-and-restore-with-mariadb-backup)

[Incremental Backup and Restore with Mariabackup](https://mariadb.com/docs/server/server-usage/backup-and-restore/mariadb-backup/incremental-backup-and-restore-with-mariadb-backup)

---

## replication-status.sh

The script monitors MySQL/MariaDB replication status and alerts via email (or stderr if email is disabled) when issues are detected.

*Based on [this script](https://handyman.dulare.com/mysql-replication-status-alerts-with-bash-script/)*

### Features

- Checks if the database is running
- Alerts on:
  - Slave IO not running
  - Slave SQL not running
  - Slave lag exceeds threshold ( default 300 seconds )
- Sends email via `mailx` or `msmtp`
- Logs activity to a file

### Installation

Create replication status user in the database:

    CREATE USER 'replstatus'@'localhost' IDENTIFIED BY 'your_password';
    GRANT SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO 'replstatus'@'localhost';
    FLUSH PRIVILEGES;

### Usage

#### Basic usage with environment variables:

    DB_PASSWORD=YourPassword EMAIL_FROM=your@email EMAIL_TO=your@email bash replication-status.sh

#### Using a custom configuration file:

    bash replication-status.sh /path/to/config.env

#### Crontab

Create a cron job to run the script every 5 minutes:

    */5 * * * * /bin/bash /usr/local/sbin/replication-status.sh /etc/replication-status.env > /dev/null

### Configuration

Edit the script to configure:
- `MAX_SECONDS_BEHIND` - Maximum acceptable replication lag (default: 300 seconds)
- Database connection settings
- Email notification settings
- Log file locations
