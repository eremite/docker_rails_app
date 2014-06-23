#!/bin/bash

file=.env && test -f $file && source $file

if [ -z "$app" ]; then
  echo 'No app found.'
  exit 1
fi

if [ -z "$db_link" ]; then
  db_link="--link $db:db"
fi

command="$1"
shift

if [ $command = "b" ]; then # build
  docker build --force-rm -t $app .
fi

if [ $command = "bundle" ]; then # bundle
  docker run -i --rm $db_link -v $directory:/app $extra $app /usr/local/bin/bundle "$@"
  find . \! -user vagrant | xargs -I % sh -c 'sudo chmod g+w %; sudo chown vagrant:vagrant %'
fi

if [ $command = "r" ]; then # rails
  if [ -n "$rails_version" ] && [ ${rails_version%.*} = "2" ]; then
    executable=ruby
  else
    executable=rails
  fi
  docker run -i --rm $db_link -v $directory:/app $extra --entrypoint /usr/local/bin/bundle $app exec $executable "$@"
  find . \! -user vagrant | xargs -I % sh -c 'sudo chmod g+w %; sudo chown vagrant:vagrant %'
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
  rm -f $directory/tmp/pids/server.pid
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
  if [ $db = "mysql" ]; then
    cp ~/dbload/dbload.sh .
    cp gitignore/db.sql .
    docker run -i --rm $db_link -v $directory:/app $extra $app ./dbload.sh
    rm dbload.sh
    rm db.sql
  else
    echo "#!/bin/sh" > dbload.sh
    echo "/usr/bin/psql $app --username=docker --host=db -t -c 'drop schema public cascade; create schema public;'" >> dbload.sh
    echo "/usr/bin/pg_restore --username=docker --host=db --no-acl --no-owner --jobs=2 --dbname=$app db.dump" >> dbload.sh
    chmod +x dbload.sh
    cp gitignore/db.dump .
    docker run -i --rm $db_link -v $directory:/app -e 'PGPASSWORD=docker' $extra $app /app/dbload.sh
    rm dbload.sh db.dump
  fi
fi
