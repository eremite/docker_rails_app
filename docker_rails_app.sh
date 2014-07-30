#!/bin/bash

docker_do() { echo "+ sudo docker $@" ; sudo docker "$@" ; }

file=.docker_environment && test -f $file && source $file

directory=$(pwd)
db_username='docker'
db_password='docker'

db_dump_directory="$PRIVATE_APP_CONFIG_DIR/$(basename $directory)/tmp"
code_volume="--volumes-from data-code --volumes-from data-private"

function fix_file_permissions {
  find . \! -user dev -print0 | xargs -0 -I % sh -c 'sudo chmod g+w "%"; sudo chown dev:dev "%"'
}

if [ -z "$app" ]; then
  echo 'No app found.'
  exit 1
fi

if [ -n "$elasticsearch" ]; then
  elasticsearch_directory='/home/vagrant/elasticsearch'
  mkdir -p $elasticsearch_directory
  if [ ! -f "$elasticsearch_directory/elasticsearch.yml" ]; then
    echo "path:" > $elasticsearch_directory/elasticsearch.yml
    echo "  logs: /data/log" >> $elasticsearch_directory/elasticsearch.yml
    echo "  data: /data/data" >> $elasticsearch_directory/elasticsearch.yml
  fi
  docker_do start elasticsearch || docker_do run -d --name=elasticsearch -p 9200:9200 -p 9300:9300 -v $elasticsearch_directory:/data dockerfile/elasticsearch /elasticsearch/bin/elasticsearch -Des.config=/data/elasticsearch.yml
  extra="$extra --link elasticsearch:es -e ELASTICSEARCH_URL=es:9200"
fi

# docker inspect --format=' ' $db
# if [ $? -ne 0 ]; then
if [ $db = "mysql" ]; then
  db_username='admin'
  docker_do start mysql || docker_do run -d --name=mysql -p 3306:3306 -e MYSQL_PASS="$db_password" tutum/mysql
fi
if [ $db = "postgresql" ]; then
  docker_do start postgresql || docker_do run -d --name=postgresql -p 5432:5432 -e POSTGRESQL_USER=$db_username -e POSTGRESQL_PASS=$db_password kamui/postgresql
fi

if [ -z "$db_link" ]; then
  db_link="--link $db:db -e DB_NAME=$app -e DB_USERNAME=$db_username -e DB_PASSWORD=$db_password"
fi

command="$1"
shift

if [ $command = "b" ]; then # build
  fullpath=$(readlink -f Dockerfile)
  rm Dockerfile
  cp $fullpath Dockerfile
  docker_do build --force-rm -t $app .
  rm Dockerfile
  ln -s $fullpath Dockerfile
fi

if [ $command = "bundle" ]; then # bundle
  docker_do run -i --rm $db_link $code_volume $extra $app /usr/local/bin/bundle "$@"
  fix_file_permissions
fi

if [ $command = "r" ]; then # rails
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable=ruby
  else
    executable=rails
  fi
  docker_do run -it --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec $executable "$@"
  fix_file_permissions
fi

if [ $command = "s" ]; then # rails server
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable='ruby ./script/server'
  else
    executable='rails server'
  fi
  running_server_id=`docker_do ps | grep 3000/tcp | awk '{print $1}'`
  if [ -n "$running_server_id" ]; then
    docker_do stop $running_server_id
  fi
  sudo rm -f $directory/tmp/pids/server.pid
  docker_do run -it --rm $db_link -p 3000:3000 $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec $executable
fi

if [ $command = "k" ]; then # rake
  docker_do run -i --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec rake "$@"
fi

if [ $command = "t" ]; then # test
  docker_do run -it --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec guard
fi

if [ $command = "bash" ]; then # bash
  docker_do run -it --rm $db_link $code_volume $extra $app /bin/bash --login
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
    scp daniel@$server:~/db.sql.gz $db_dump_directory/
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
    mysql_connection="mysql -u $db_username -p'$db_password' -h db $app"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < db.sql" >> dbload.sh
    cp $db_dump_directory/db.sql .
    sudo docker run -i --rm $db_link $code_volume $extra $app ./dbload.sh
    rm db.sql
  else
    echo "/usr/bin/psql $app --username=$db_username --host=db -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=db --no-acl --no-owner --jobs=2 --dbname=$app db.dump" >> dbload.sh
    chmod +x dbload.sh
    cp $db_dump_directory/db.dump .
    sudo docker run -i --rm $db_link $code_volume -e PGPASSWORD=$db_password $extra $app /app/dbload.sh
    rm db.dump
  fi
  rm dbload.sh
fi
