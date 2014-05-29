#!/bin/bash

file=.env && test -f $file && source $file

dblink="--link $db:db"

command="$1"
shift

if [ $command = "b" ]; then # build
  docker build -t $app .
fi

if [ $command = "r" ]; then # rails
  docker run -i --rm $db_link -v $directory:/app --entrypoint /usr/local/bin/bundle $app exec ruby "$@"
  find . \! -user vagrant | xargs -I % sh -c 'sudo chmod g+w %; sudo chown vagrant:vagrant %'
fi

if [ $command = "s" ]; then # rails server
  docker run -i --rm $db_link -p 3000:3000 -v $directory:/app --entrypoint /usr/local/bin/bundle $app exec ruby ./script/server
fi

if [ $command = "k" ]; then # rake
  docker run -i --rm $db_link -v $directory:/app --entrypoint /usr/local/bin/bundle $app exec rake "$@"
fi

if [ $command = "t" ]; then # test
  docker run -i --rm $db_link -v $directory:/app --entrypoint /usr/local/bin/bundle $app exec guard
fi

if [ $command = "bash" ]; then # bash
  docker run -i --rm $db_link -v $directory:/app $app /bin/bash -i
fi

if [ $command = "dbload" ]; then # dbload
  cp ~/dbload/dbload.sh .
  cp gitignore/db.sql .
  docker run -i --rm $db_link -v $directory:/app $app ./dbload.sh
  rm dbload.sh
  rm db.sql
fi
