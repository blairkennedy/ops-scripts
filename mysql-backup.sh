#!/bin/bash

## MySQL Backup
## backup database to individual files
##
## To be used with a standalone server.  Not to be used with a master-replica server configuration.
##
## Assumes the use of InnoDB and binary logging
##
## 

# Config Data
. ~/.ownfinance

backup_date="`date +%F`"

MYDATA="/var/lib/mysql"
BINLOG="$MYDATA"
RELAYLOG="$MYDATA"
EXCLUDES="information_schema performance_schema"
PURGE_DAYS=5

log() {

  local tag="mysql-backup"
  echo "[`date +%F-%T`] $(hostname -s) ${tag}: ${1}"
  logger -t ${tag} "${1}"

}

## Backup Log Header
log "MySQL Backup for $backup_date"

## Purge backup file system if PURGE_DAYS > 0
if [[ $dbbackupdays > 0 ]]; then
  log "Purging ${dbbackupdir} files older than ${dbbackupdays} days"
  find ${dbbackupdir} -name "*" -type f -mtime +${dbbackupdays} -delete
fi

## Get list of databases to backup
DATABASES=$(mysql -u${dbbackupuser} -p${dbbackupauth} -Bse "show databases;")
log $DATABASES

## Stop replication
log "Checking for replication"
SSTATUS=$(mysql -u${dbbackupuser} -p${dbbackupauth} -e "show slave status;")
if [ -z "$SSTATUS" ]; then
  log "This is not a replication slave."
else
  log "This is a slave replica."
  mysqladmin -u${dbbackupuser} -p${dbbackupauth} stop-slave 
  log "Current SLAVE status on replica"
  mysql -e "show slave status\G" -u${dbbackupuser} -p${dbbackupauth}
fi

log "Flush database logs"
mysqladmin -u${dbbackupuser} -p${dbbackupauth} flush-logs

for db in $DATABASES; do

  ## regex comparison to check for filename match with excluded files list
  if [[ ${dbbackupexclude} =~ $db ]]; then
    log "Skipping excluded [ $db ]"
  else

    log "Backing up [ $db ]"
    #  /usr/bin/mysqldump -v -u backup --flush-logs --single-transaction --master-data=2 \
    #   --databases $db --result-file=$TARGET/mysql_full-$db-$backup_date.sql

    # Choose the backup to perform based on replica or not
    if [ -z "$SSTATUS" ]; then
      log "Non-Replica, standard --single-transaction option used"
      /usr/bin/mysqldump -u${dbbackupuser} -p${dbbackupauth} --databases $db --single-transaction --skip-lock-tables \
        --result-file=${dbbackupdir}/mysql_full-$db-$backup_date.sql
    else
      log "Replica, using --master-data=2 dump"
      /usr/bin/mysqldump -u${dbbackupuser} -p${dbbackupauth} --master-data=2 \
       --databases $db --result-file=${dbbackupdir}/mysql_full-$db-$backup_date.sql
    fi
    log "GZIP database backup of $db"
    gzip -f ${dbbackupdir}/mysql_full-$db-$backup_date.sql
  fi
done

# if this is a slave replica, then restart replication
if [ -n "$SSTATUS" ]; then
  log "Re-Starting Replication"
  mysqladmin -u${dbbackupuser} -p${dbbackupauth} start-slave
  log "Current SLAVE status on replica"
  
  ## wait a few seconds for replication to get status
  ##
  sleep 20

  mysql -e "show slave status\G" -u${dbbackupuser} -p${dbbackupauth} 
  ## list relay log file directories (replicaion only)
fi


# Purge binary log files (be careful, this only purges up to the last day's worth of log files.
#  Additional consideration may be necessary for replica systems. Your backup account will require additional privileges.

DATETIME="`date -d yesterday +%F` 00:00:00"
log "Purging binary log files older than $DATETIME"
mysql -e "purge binary logs before '${DATETIME}';" -u${dbbackupuser} -p${dbbackupauth} 

log "MySQL Backup Files List"
ls -l ${dbbackupdir}/mysql_full* 

log "Backup complete"

log "Emailing log output to dbbackupnotify DL"
mail -s "MySQL backup `hostname`" ${dbbackupnotify}
