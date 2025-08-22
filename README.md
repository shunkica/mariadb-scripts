# README
*forked from [omegazeng/run-mariabackup.sh](https://github.com/omegazeng/run-mariabackup) which was*
*forked from [jmfederico/run-xtrabackup.sh](https://gist.github.com/jmfederico/1495347)*

Note: tested on CentOS 7 with MariaDB 10.4


## Links

[Full Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/full-backup-and-restore-with-mariabackup/)

[Incremental Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/incremental-backup-and-restore-with-mariabackup/)

---

## Install

    yum -y install MariaDB-backup
    curl https://raw.githubusercontent.com/shunkica/run-mariabackup/master/run-mariabackup.sh --output /usr/local/sbin/run-mariabackup.sh
    chmod 700 /usr/local/sbin/run-mariabackup.sh

## Create a backup user

    GRANT PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost' identified by 'YourPassword';
    FLUSH PRIVILEGES;

## Usage

### Basic usage with environment variable:

    DB_PASSWORD=YourPassword bash run-mariabackup.sh

### Using a custom configuration file:

    bash run-mariabackup.sh /path/to/config.env

### Dry run mode:

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

## Crontab

    #MySQL Backup, run every hour at the 30th minute
    30 */1 * * * DB_PASSWORD=YourPassword /bin/bash /usr/local/sbin/run-mariabackup.sh
    
    # Or with custom config file:
    30 */1 * * * /bin/bash /usr/local/sbin/run-mariabackup.sh /etc/mariabackup.conf

---

## Restore Example

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
