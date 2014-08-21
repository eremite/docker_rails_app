#!/bin/bash

docker_do() { echo "+ docker $@" ; docker "$@" ; }

file=.docker_environment && test -f $file && source $file

directory=$(pwd)
test -z "$app" && app=$(basename $directory)
db_username='docker'
db_password='docker'

db_dump_directory="$PERSONAL/$app/tmp"
code_volume="--volumes-from code"

function fix_file_permissions {
  find . \! -user dev -print0 | xargs -0 -I % sh -c 'sudo chmod g+w "%"; sudo chown dev:dev "%"'
}

if [ ! -e fig.yml ]; then

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
  if grep -q mysql $directory/config/database.yml; then
    db=mysql
    db_username='admin'
    docker_do start $db || docker_do run -d --name=mysql -p 3306:3306 -e MYSQL_PASS="$db_password" tutum/mysql
  fi
  if grep -q postgres $directory/config/database.yml; then
    db=postgresql
    docker_do start $db || docker_do run -d --name=postgresql -p 5432:5432 -e POSTGRESQL_USER=$db_username -e POSTGRESQL_PASS=$db_password kamui/postgresql
  fi

  if [ -z "$db_link" ]; then
    db_link="--link $db:db -e DB_NAME=$app -e DB_USERNAME=$db_username -e DB_PASSWORD=$db_password"
  fi

else # using fig
  if grep -q mysql $directory/config/database.yml; then
    db=mysql
    db_username='root'
  fi
  if grep -q postgres $directory/config/database.yml; then
    db=postgresql
  fi
fi

command="$1"
shift

if [ $command = "b" ]; then # build
  if [ -h Dockerfile ]; then # if symlink
    fullpath=$(readlink -f Dockerfile)
    rm Dockerfile
    cp $fullpath Dockerfile
    if [ -e fig.yml ]; then
      fig build
    else
      docker_do build --force-rm -t $app .
    fi
    rm Dockerfile
    ln -s $fullpath Dockerfile
  else
    docker_do build --force-rm -t $app .
  fi
fi

if [ $command = "bundle" ]; then # bundle
  if [ -e fig.yml ]; then
    fig run --rm web bundle $@
  else
    docker_do run -i --rm $db_link $code_volume $extra $app /usr/local/bin/bundle "$@"
    fix_file_permissions
  fi
fi

if [ $command = "r" ]; then # rails
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable=ruby
  else
    executable=rails
  fi
  if [ -e fig.yml ]; then
    fig run --rm web bundle exec $executable $@
  else
    docker_do run -it --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec $executable "$@"
  fi
  fix_file_permissions
fi

if [ $command = "s" ]; then # rails server
  if [ -e fig.yml ]; then
    fig up
  else
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
fi

if [ $command = "k" ]; then # rake
  if [ -e fig.yml ]; then
    fig run --rm web bundle exec rake $@
  else
    docker_do run -i --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec rake "$@"
  fi
fi

if [ $command = "t" ]; then # test
  if [ -e fig.yml ]; then
    fig run --rm web bundle exec guard
  else
    docker_do run -it --rm $db_link $code_volume $extra --entrypoint /usr/local/bin/bundle $app exec guard
  fi
fi

if [ $command = "bash" ]; then # bash
  if [ -e fig.yml ]; then
    fig run --rm web bash
  else
    docker_do run -it --rm $db_link $code_volume $extra $app /bin/bash --login
  fi
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
    mysql_connection="mysql -u $db_username -p'$db_password' -h db_1 $app"
    echo "for table in \$($mysql_connection -e 'show tables' | awk '{ print \$1}' | grep -v '^Tables')" >> dbload.sh
    echo "do" >> dbload.sh
    echo "  $mysql_connection -e \"drop table \$table\"" >> dbload.sh
    echo "done" >> dbload.sh
    echo "$mysql_connection < db.sql" >> dbload.sh
    cp $db_dump_directory/db.sql .
    if [ -e fig.yml ]; then
      fig run --rm web sh ./dbload.sh
    else
      docker_do run -i --rm $db_link $code_volume $extra $app ./dbload.sh
    fi
    rm db.sql
  else
    echo "/usr/bin/psql $app --username=$db_username --host=db_1 -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=$db_username --host=db_1 --no-acl --no-owner --jobs=2 --dbname=$app db.dump" >> dbload.sh
    chmod +x dbload.sh
    cp $db_dump_directory/db.dump .
    if [ -e fig.yml ]; then
      fig run --rm web sh ./dbload.sh
    else
      docker_do run -i --rm $db_link $code_volume -e PGPASSWORD=$db_password $extra $app ./dbload.sh
    fi
    rm db.dump
  fi
  rm dbload.sh
fi
