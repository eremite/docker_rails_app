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

if grep -q mysql fig.yml; then
  db=mysql
  db_image=`grep -E 'image: "?mysql' fig.yml | cut -d ' ' -f 4 | sed -e 's/"//g'`
  db_username='root'
  port=3306
fi
if grep -q postgres fig.yml; then
  db=postgresql
  db_image=`grep -E 'image: "?postgres' fig.yml | cut -d ' ' -f 4 | sed -e 's/"//g'`
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
  echo '#!/bin/sh' > dbload.sh
  chmod +x dbload.sh
  if [ $db = "mysql" ]; then
    mysql_connection="mysql -u $db_username -p'$db_password' -h mysql $app"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < /tmp/work/db.sql" >> dbload.sh
    cp $db_dump_directory/db.sql .
    db_container_id=`docker ps | grep "mysql" | awk '{print $1}'`
    db_container_name=`docker inspect --format='{{.Name}}' $db_container_id`
    docker_do run -v $(pwd):/tmp/work --link $db_container_name:mysql --rm $db_image sh -c '/tmp/work/dbload.sh'
    rm db.sql
  else
    echo "/usr/bin/psql $app --username=$db_username --host=postgres -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=postgres --no-acl --no-owner --jobs=2 --dbname=$app /tmp/work/db.dump" >> dbload.sh
    cp $db_dump_directory/db.dump .
    db_container_id=`docker ps | grep "postgres" | awk '{print $1}'`
    db_container_name=`docker inspect --format='{{.Name}}' $db_container_id`
    docker_do run -v $(pwd):/tmp/work --link $db_container_name:postgres --rm $db_image sh -c '/tmp/work/dbload.sh'
    rm db.dump
  fi
  rm dbload.sh
fi

if [ $command = "rm" ]; then # rm docker containers interactively
  data_container_id=`docker inspect --format={{.Id}} /db_data`
  for container_id in $(docker ps --all --quiet --no-trunc)
  do
    if [ $container_id = $data_container_id ]; then
      continue
    fi
    docker inspect --format='{{if .State.ExitCode}} Exited {{end}} {{.Name}} {{.Path}} {{range $i, $arg := .Args}}{{$arg}} {{end}}' $container_id
    echo -n "delete? [y/N]:"
    read response
    if [ "$response" = "q" ]; then
      break
    elif [ "$response" = "y" ]; then
      docker_do rm $container_id
    fi
  done
fi

if [ $command = "rmi" ]; then # remove untagged images
  docker images -q --filter "dangling=true" | xargs docker rmi
fi

if [ $command = "c" ]; then # Docker clean
  devbox_container_id=`docker inspect --format={{.Id}} /devbox`
  docker ps --quiet --no-trunc | grep -v $devbox_container_id | xargs docker kill
  data_container_id=`docker inspect --format={{.Id}} /data`
  db_data_container_id=`docker inspect --format={{.Id}} /db_data`
  docker ps --all --quiet --no-trunc | grep -v $data_container_id | grep -v $db_data_container_id | xargs docker rm -v
  docker images --quiet --filter "dangling=true" | xargs docker rmi
fi
