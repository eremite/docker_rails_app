#!/bin/bash

if [ ! -e fig.yml ]; then
  echo "Can't find fig.yml!"
  exit
fi

fig_do() { echo "+ fig $@" ; fig "$@" ; }

docker_do() { echo "+ docker $@" ; docker "$@" ; }

fix_file_permissions() {
  find . \! -user dev -print0 | xargs -0 -I % sh -c 'sudo chmod g+w "%"; sudo chown dev:dev "%"'
}

stop_container_matching() {
  running_server_id=`docker_do ps | grep "$1" | awk '{print $1}'`
  if [ -n "$running_server_id" ]; then
    docker_do stop $running_server_id
  fi
}

directory=$(pwd)
app=$(basename $directory)

db_dump_directory="$META/$app/tmp"

if grep -q mysql $directory/config/database.yml; then
  db=mysql
  db_username='root'
  port=3306
fi
if grep -q postgres $directory/config/database.yml; then
  db=postgresql
  db_username='postgres'
  port=5432
fi
db_password='docker'

command="$1"
shift

if [ $command = "b" ]; then # build
  if [ -h Dockerfile ]; then # if symlink
    fullpath=$(readlink -f Dockerfile)
    rm Dockerfile
    cp $fullpath Dockerfile
    fig_do build
    rm Dockerfile
    ln -s $fullpath Dockerfile
  else
    fig_do build
  fi
fi

if [ $command = "bundle" ]; then # bundle
  fig_do run --rm web bundle $@
  fix_file_permissions
fi

if [ $command = "r" ]; then # rails
  fig_do run --rm web bundle exec rails $@
  fix_file_permissions
fi

if [ $command = "s" ]; then # rails server
  stop_container_matching "3000/tcp"
  sudo rm -f $directory/tmp/pids/server.pid
  fig_do up
fi

if [ $command = "k" ]; then # rake
  fig_do run --rm web bundle exec rake $@
fi

if [ $command = "t" ]; then # test
  fig_do run --rm web bundle exec guard
fi

if [ $command = "bash" ]; then # bash
  fig_do run --rm web bash
fi

if [ $command = "dbfetch" ]; then # dbfetch
  mkdir -p $db_dump_directory
  if grep -q heroku .git/config; then
    if [ $1 ]; then
      remote="$1"
    else
      remote='staging'
    fi
    heroku pgbackups:capture -r $remote
    curl -o $db_dump_directory/db.dump `heroku pgbackups:url -r $remote`
  else
    if [ $1 ]; then
      server=$1
    else
      server=$app
    fi
    scp $server:~/db.sql.gz $db_dump_directory/
  fi
  if [ -e $db_dump_directory/db.sql.gz ]; then
    cp $db_dump_directory/db.sql.gz $db_dump_directory/db.$(date +"%Y.%m.%d").sql.gz
    gunzip -f $db_dump_directory/db.sql.gz
  fi
  if [ -e $db_dump_directory/db.dump ]; then
    cp $db_dump_directory/db.dump $db_dump_directory/db.$(date +"%Y.%m.%d").dump
  fi
fi

if [ $command = "dbload" ]; then # dbload
  echo "#!/bin/sh" > dbload.sh
  chmod +x dbload.sh
  if [ $db = "mysql" ]; then
    mysql_connection="mysql -u $db_username -p'$db_password' -h db_1 $app"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < db.sql" >> dbload.sh
    cp $db_dump_directory/db.sql .
    fig_do run --rm web sh ./dbload.sh
    rm db.sql
  else
    echo "/usr/bin/psql $app --username=$db_username --host=db_1 -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=db_1 --no-acl --no-owner --jobs=2 --dbname=$app db.dump" >> dbload.sh
    chmod +x dbload.sh
    cp $db_dump_directory/db.dump .
    fig_do run --rm web sh ./dbload.sh
    rm db.dump
  fi
  rm dbload.sh
fi
