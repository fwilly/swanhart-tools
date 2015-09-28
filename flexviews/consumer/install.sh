#!/bin/bash

#set -x; trap read debug

function defaultsExtraFile # ( aArrayName )
{
    eval 'local sUser=${'${1}'[user]}'
    eval 'local sPwd=${'${1}'[password]}'
    eval 'local sHost=${'${1}'[host]}'
    eval 'local sPort=${'${1}'[port]}'
    cat <<EOL
[client]
user=$sUser
password=$sPwd
host=$sHost
port=$sPort
EOL
}

function checkConnection # ( aType aDatabase )
{
    sResult=$(mysql \
        --defaults-extra-file=<(defaultsExtraFile "$1") \
        --silent \
        --skip-column-names \
        --execute="SHOW TABLES FROM $2" 2>&1)
    echo "$sResult" | awk '{print $2}'
}

function createDatabase # ( aType aDatabase )
{
    sResult=$(mysql \
        --defaults-extra-file=<(defaultsExtraFile "$1") \
        --silent \
        --execute="CREATE DATABASE $2;" 2>&1)
    echo "$sResult" | awk '{print $2}'
}

echo "preparing consumer.ini.."
if [ ! -f consumer.ini ]; then
    cp consumer.ini.example consumer.ini
fi

mysqlbinlog=$(awk -F "=" '/mysqlbinlog=/ {print $2}' consumer.ini)
MYSQLBINLOG=$(which mysqlbinlog)
if [ -z "$MYSQLBINLOG" ]; then
    echo "mysqlbinlog not found! MySQL installed? Abort!"
    exit
fi
if [ "$MYSQLBINLOG" != "$mysqlbinlog" ]; then
    sed -i -e 's#mysqlbinlog=.*#mysqlbinlog='${MYSQLBINLOG}'#g' consumer.ini
fi

if [ ! -d log ]; then
    mkdir log
fi

failure_error_log=$(awk -F "=" '/failure_error_log=/ {print $2}' consumer.ini)
failure_log_file=$(awk -F "=" '/failure_log_file=/ {print $2}' consumer.ini)
if [[ -z "$failure_error_log" ]] && [[ "$failure_log_file" == "flex_cdc_log.log" ]]; then
    LOGFILES='failure_log_file=log/flex_cdc_log.log\nfailure_error_log=log/flexcdc.err'
    sed -i -e 's#failure_log_file=.*#'${LOGFILES}'#g' consumer.ini
fi

force_install=$(awk -F "=" '/^force_install=/ {print $2}' consumer.ini)
if [ "$force_install" == "true" ]; then
    force_install="--force"
else
    force_install=""
fi

echo "checking configured database connections"

# read properties
database=$(awk -F "=" '/^database=/ {print $2}' consumer.ini)
if [ "$database" != "flexviews" ]; then
    echo "Don't change database from 'flexviews' to '$database'! Abort!"
    exit
fi

declare -A src
declare -A dest
props=("user" "password" "host" "port")
for prop in "${props[@]}"; do
    array=( $(awk -F "=" '/'$prop'=/ {print $2}' consumer.ini) )
    src[$prop]=${array[0]}
    dest[$prop]=${array[1]}
done

sCurrentDatabase="$database"
echo " - checking connections to source database $sCurrentDatabase"
error=$(checkConnection "src" "$sCurrentDatabase")
while [ true ]; do
    case "$error" in
        1049)
            echo "   - database $sCurrentDatabase don't exists."
            if [ "$force_install" == "--force" ]; then
                echo "   - creating database $sCurrentDatabase"
                error=$(createDatabase "src" "$sCurrentDatabase")
            else
                echo "   - You can set 'force_install=true' in consumer.ini or create database '$sCurrentDatabase' self."
                echo "     Then recall install.sh. Abort!"
                error=""
                break
            fi
            ;;
        1045)
            echo "   - cannot connect to database $sCurrentDatabase."
            if [ "$sCurrentDatabase" != "mysql" ]; then
                echo "   - try database mysql to connect"
                sCurrentDatabase="mysql"
                error=$(checkConnection "src" "$sCurrentDatabase")
            else
                error=""
                break
            fi
            ;;
        "")
            echo "   - connection okay"
            break
            ;;
        *)
            echo "   - unhandled error $error"
            error=""
            break
    esac
done

sCurrentDatabase="$database"
echo " - checking connections to destination database $sCurrentDatabase"
error=$(checkConnection "dest" "$sCurrentDatabase")
while [ true ]; do
    case "$error" in
        1049)
            echo "   - database $sCurrentDatabase don't exists."
            if [ "$force_install" == "--force" ]; then
                echo "   - creating database $sCurrentDatabase"
                error=$(createDatabase "dest" "$sCurrentDatabase")
            else
                echo "   - You can set 'force_install=true' in consumer.ini or create database '$sCurrentDatabase' self."
                echo "     Then recall install.sh. Abort!"
                error=""
                break
            fi
            ;;
        1045)
            echo "   - cannot connect to database $sCurrentDatabase."
            if [ "$sCurrentDatabase" != "mysql" ]; then
                echo "   - try database mysql to connect"
                sCurrentDatabase="mysql"
                error=$(checkConnection "dest" "$sCurrentDatabase")
            else
                error=""
                break
            fi
            ;;
        "")
            echo "   - connection okay"
            break
            ;;
        *)
            echo "   - unhandled error $error"
            error=""
            break
    esac
done

bChanged=false
echo "checking mysql settings.."
binlog_format=$(mysqlserverinfo --server=root:test@localhost --show-defaults | grep binlog_format | awk -F "=" '{print $2}')
if [ "$binlog_format" != "ROW" ]; then
    echo " - binlog_format is not ROW"
    if [ "$force_install" == "--force" ]; then
        echo "   - changing /etc/mysql/my.cnf.."
        if [ -z "$binlog_format" ]; then
            sudo sed -i -e 's/^\(.*binlog_ignore_db.*\)$/\1\nbinlog_format=ROW/g' /etc/mysql/my.cnf
        else
            sudo sed -i -e 's#^.*binlog_format.*#binlog_format=ROW#g' /etc/mysql/my.cnf
        fi
        bChanged=true
    fi
else
    echo " - binlog_format=ROW okay"
fi
log_bin=$(mysqlserverinfo --server=root:test@localhost --show-defaults | grep log_bin | awk -F "=" '{print $2}')
if [ "$log_bin" == "" ]; then
    echo " - log_bin not set"
    if [ "$force_install" == "--force" ]; then
        echo "   - changing /etc/mysql/my.cnf.."
        sudo sed -i -e 's|^.*log_bin.*|log_bin=/var/log/mysql/mysql-bin.log|g' /etc/mysql/my.cnf
        bChanged=true
    fi
else
    echo " - log_bin set okay"
fi
serverid=$(mysqlserverinfo --server=root:test@localhost --show-defaults | grep server-id | awk -F "=" '{print $2}')
if [ "$serverid" == "" ]; then
    echo " - server-id not set"
    if [ "$force_install" == "--force" ]; then
        echo "   - changing /etc/mysql/my.cnf.."
        sudo sed -i -e 's#^.*server-id.*#server-id=1#g' /etc/mysql/my.cnf
        bChanged=true
    fi
else
    echo " - server-id=$serverid set okay"
fi
localinfile=$(cat /etc/mysql/my.cnf | grep local-infile | awk -F "=" '{print $2}')
if [ "$localinfile" != "1" ]; then
    echo " - local-infile not set to 1"
    if [ "$force_install" == "--force" ]; then
        echo "   - changing /etc/mysql/my.cnf.."
        if [ -z "$localinfile" ]; then
            sudo sed -i -e 's/^\[mysqldump\].*/local-infile=1\n\n[mysqldump]/g' /etc/mysql/my.cnf
        else
            sudo sed -i -e 's#^.*local-infile.*#local-infile=1#g' /etc/mysql/my.cnf
        fi
        bChanged=true
    fi
fi

if [ "$bChanged" == "true" ]; then
    echo "   - /etc/mysql/my.cnf changed. Restart mysql server.."
    sudo /etc/init.d/mysql restart
fi

echo "calling setup.."
tResult=( $(php ./setup_flexcdc.php --ini consumer.ini $force_install) )
if [ "${tResult[-1]}" != "completed" ]; then
    echo "Errors on setup!"
    echo "-------------"
    printf '%s\n' "${tResult[@]}"
    echo "-------------"
    echo "You can set 'force_install=true' in consumer.ini and recall install.sh. Abort!"
    exit
else
    echo " - sucessfull"
fi

echo "verify installation.."
mysql --defaults-extra-file=<(defaultsExtraFile "src") -e 'select * from '$database'.binlog_consumer_status\G'

echo "install as daemon.."
SCRIPT_DIR=$(dirname $(readlink -f $0))
CURRENT_DIR=$(pwd)
cd "/etc/init.d"
if [ ! -h flexcdc ]; then
    sudo ln -s "${SCRIPT_DIR}/flexcdc" flexcdc
fi
cd $CURRENT_DIR

echo "start as daemon.."
sudo /etc/init.d/flexcdc start

install_flexviews=$(awk -F "=" '/^install_flexviews=/ {print $2}' consumer.ini)
if [ "$install_flexviews" == "true" ]; then
    echo "install flexviews"
    if [ ! -f "../install.sql" ]; then
        echo " - cannot install flexviews. ../install.sql not found."
    else
        CURRENT_DIR=$(pwd)
        cd ..
        mysql --defaults-extra-file=<(defaultsExtraFile "src") --local-infile < install.sql
        cd $CURRENT_DIR
    fi
fi

echo ""
echo "if you get an output without errors the install was successfull"
echo ""
echo " - now you can start and stop background process"
echo "   /etc/init.d/flexcdc start|stop"
echo ""
echo " - now you can add changelog for a table"
echo "   php add_table.php --schema=DATABASE --table=TABLE"
echo ""
echo " - after you have make changes to DATABASE.TABLE you examine changes with"
echo "   select * from "$database".DATABASE_TABLE\G"
echo ""
