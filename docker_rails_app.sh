#!/bin/bash

if [ -e docker-compose.yml ]; then
  export COMPOSE_FILE='docker-compose.yml'
else
  export COMPOSE_FILE='fig.yml'
fi

deploy_directory="usr/src/app"

compose_do() {
  echo "+ docker-compose $@"
  perl -0777 -i -pe "s|volumes:\n(\s+)- .:/$deploy_directory|volumes_from:\\n\$1- data|g" $COMPOSE_FILE
  perl -0777 -i -pe 's|command: mysqld|# command: mysqld|g' $COMPOSE_FILE
  if [ -e .docker_overrides.env ]; then
    cp .docker_overrides.env "$META/$app/docker_overrides.env"
  fi
  {
    sleep 3 # Wait for docker-compose command to start.
    perl -0777 -i -pe "s|volumes_from:\n(\s+)- data|volumes:\\n\$1- .:/$deploy_directory|g" $COMPOSE_FILE
    perl -0777 -i -pe 's|# command: mysqld|command: mysqld|g' $COMPOSE_FILE
  } &
  docker-compose "$@"
}

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

directory=$(pwd -P)
app=$(expr match $directory '/data/\([^/]*\)')

db_dump_directory="$META/$app/tmp"

if grep -q mysql $COMPOSE_FILE; then
  db=mysql
  db_image=`grep -E 'image: "?mysql' $COMPOSE_FILE | cut -d ' ' -f 4 | sed -e 's/"//g'`
  db_username='root'
  port=3306
fi
if grep -q postgres $COMPOSE_FILE; then
  db=postgresql
  db_image=`grep -E 'image: "?postgres' $COMPOSE_FILE | cut -d ' ' -f 4 | sed -e 's/"//g'`
  db_username='postgres'
  port=5432
fi
db_name=${app//./}
db_password='docker'

command="$1"
shift

if [ $command = "run" ]; then # run
  compose_do run $@
  fix_file_permissions
fi

if [ $command = "b" ]; then # build
  app=$(expr match $directory '/data/\(.*\)')
  sed -i "s:$deploy_directory:data/$app:g" Dockerfile
  compose_do build
  sed -i "s:data/$app:$deploy_directory:g" Dockerfile
fi

if [ $command = "deploy" ]; then # deploy
  owner="custombit"
  environment=$(git symbolic-ref --short HEAD)
  if [ $environment = "master" ]; then
    environment="production"
  fi
  tag="custombit/${app}:${environment}_$(date +"%F-%H%M")"
  docker_do build --force-rm=true --tag=$tag .
  if [ "$?" == '0' ]; then
    docker_do push $tag
  fi
fi

if [ $command = "bundle" ]; then # bundle
  compose_do run --rm web bundle $@
  fix_file_permissions
fi

if [ $command = "r" ]; then # rails
  compose_do run --rm web bundle exec rails $@
  fix_file_permissions
fi

if [ $command = "s" ]; then # rails server
  sudo rm -f $directory/tmp/pids/server.pid
  compose_do up --no-build
fi

if [ $command = "k" ]; then # rake
  if [ -e Gemfile ]; then
    compose_do run --rm web bundle exec rake $@
  else
    compose_do run --rm web rake $@
  fi
fi

if [ $command = "t" ]; then # test
  compose_do run --rm web bundle exec guard
fi

if [ $command = "bash" ]; then # bash
  compose_do run --rm web bash
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
    mysql_connection="mysql -u $db_username -p'$db_password' -h mysql $db_name"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < /data/$app/db.sql" >> dbload.sh
    cp $db_dump_directory/db.sql .
    db_container_id=`docker ps | grep "mysql" | awk '{print $1}'`
    db_container_name=`docker inspect --format='{{.Name}}' $db_container_id`
    docker_do run --volumes-from=data --link $db_container_name:mysql --rm $db_image sh -c "/data/$app/dbload.sh"
    rm db.sql
  else
    echo "/usr/bin/psql $db_name --username=$db_username --host=postgres -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=postgres --no-acl --no-owner --jobs=2 --dbname=$db_name /data/$app/db.dump" >> dbload.sh
    cp $db_dump_directory/db.dump .
    db_container_id=`docker ps | grep "postgres" | awk '{print $1}'`
    db_container_name=`docker inspect --format='{{.Name}}' $db_container_id`
    docker_do run --volumes-from=data --link $db_container_name:postgres --rm $db_image sh -c "/data/$app/dbload.sh"
    rm db.dump
  fi
  rm dbload.sh
fi

if [ $command = "rm" ]; then # rm docker containers interactively
  data_container_id=`docker inspect --format={{.Id}} /data`
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
  docker ps --quiet --no-trunc | grep -v $devbox_container_id | xargs --no-run-if-empty docker stop
  data_container_id=`docker inspect --format={{.Id}} /data`
  docker ps --all --quiet --no-trunc | grep -v $devbox_container_id | grep -v $data_container_id | xargs --no-run-if-empty docker rm -v
  data_image_id=`docker inspect --format={{.Image}} /data`
  docker images --quiet --no-trunc --filter "dangling=true" | grep -v $data_image_id | xargs --no-run-if-empty docker rmi
fi
