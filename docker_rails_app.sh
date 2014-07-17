#!/bin/bash

file=.docker_environment && test -f $file && source $file

db_directory='/home/vagrant'
db_username='docker'
db_password='docker'

function fix_file_permissions {
  find . \! -user vagrant -print0 | xargs -0 -I % sh -c 'sudo chmod g+w "%"; sudo chown vagrant:vagrant "%"'
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
  docker start elasticsearch || docker run -d --name=elasticsearch -p 9200:9200 -p 9300:9300 -v $elasticsearch_directory:/data dockerfile/elasticsearch /elasticsearch/bin/elasticsearch -Des.config=/data/elasticsearch.yml
  extra="$extra --link elasticsearch:es -e ELASTICSEARCH_URL=es:9200"
fi

# docker inspect --format=' ' $db
# if [ $? -ne 0 ]; then
if [ $db = "mysql" ]; then
  db_username='admin'
  docker start mysql || docker run -d --name=mysql -p 3306:3306 -v $db_directory/mysql:/var/lib/mysql -e MYSQL_PASS="$db_password" tutum/mysql
fi
if [ $db = "postgresql" ]; then
  docker start postgresql || docker run -d --name=postgresql -p 5432:5432 -v $db_directory/postgresql:/data -e POSTGRESQL_USER=$db_username -e POSTGRESQL_PASS=$db_password kamui/postgresql
fi

if [ -z "$db_link" ]; then
  db_link="--link $db:db -e DB_NAME=$app -e DB_USERNAME=$db_username -e DB_PASSWORD=$db_password"
fi

command="$1"
shift

if [ $command = "b" ]; then # build
  docker build --force-rm -t $app .
fi

if [ $command = "bundle" ]; then # bundle
  docker run -i --rm $db_link -v $directory:/app $extra $app /usr/local/bin/bundle "$@"
  fix_file_permissions
fi

if [ $command = "r" ]; then # rails
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable=ruby
  else
    executable=rails
  fi
  echo "docker run -i --rm $db_link -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec $executable \"$@\""
  docker run -i --rm $db_link -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec $executable "$@"
  fix_file_permissions
fi

if [ $command = "s" ]; then # rails server
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable='ruby ./script/server'
  else
    executable='rails server'
  fi
  running_server_id=`docker ps | grep 3000/tcp | awk '{print $1}'`
  if [ -n "$running_server_id" ]; then
    docker stop $running_server_id
  fi
  sudo rm -f $directory/tmp/pids/server.pid
  echo "docker run -i --rm $db_link -p 3000:3000 -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec $executable"
  docker run -i --rm $db_link -p 3000:3000 -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec $executable
fi

if [ $command = "k" ]; then # rake
  docker run -i --rm $db_link -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec rake "$@"
fi

if [ $command = "t" ]; then # test
  docker run -i --rm $db_link -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec guard
fi

if [ $command = "bash" ]; then # bash
  docker run -i --rm $db_link -v $directory:/app $extra $app /bin/bash -i
fi

if [ $command = "dbload" ]; then # dbload
  echo "#!/bin/sh" > dbload.sh
  chmod +x dbload.sh
  if [ $db = "mysql" ]; then
    mysql_connection="mysql -u $db_username -p $db_password -h db $app"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < db.sql" >> dbload.sh
    cp gitignore/db.sql .
    docker run -i --rm $db_link -v $directory:/app $extra $app ./dbload.sh
    rm db.sql
  else
    echo "/usr/bin/psql $app --username=$db_username --host=db -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=db --no-acl --no-owner --jobs=2 --dbname=$app db.dump" >> dbload.sh
    chmod +x dbload.sh
    cp gitignore/db.dump .
    docker run -i --rm $db_link -v $directory:/app -e PGPASSWORD=$db_password $extra $app /app/dbload.sh
    rm db.dump
  fi
  rm dbload.sh
fi
