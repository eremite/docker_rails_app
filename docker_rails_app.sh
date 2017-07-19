#!/bin/bash

user=$(whoami)
directory=$(pwd -P)
app=$(expr match $directory "$DATA/\([^/]*\)")
db_dump_directory="$META/$app/tmp"

export COMPOSE_FILE='docker-compose.yml'

if [ -e Gemfile ]; then
  if grep -q "gem 'rails', '5" Gemfile; then
    rake_command='rails'
  else
    rake_command='rake'
  fi
fi

if [ -e Dockerfile ]; then
  if grep -q alpine Dockerfile; then
    shell_command='sh'
  else
    shell_command='bash'
  fi
fi

docker_do() { echo "+ docker $@" ; docker "$@" ; }

compose_do() {
  echo "+ docker-compose $@"
  if [ -e .docker_overrides.env ]; then
    cp .docker_overrides.env "$META/$app/docker_overrides.env"
  elif [ -e "$META/$app/docker_overrides.env" ]; then
    cp "$META/$app/docker_overrides.env" .docker_overrides.env
  fi
  docker-compose "$@"
}

fix_file_permissions() {
  find . \! -user $user -print0 | xargs -0 -I % sh -c "sudo chmod g+w \"%\"; sudo chown $user:$user \"%\""
}

stop_container_matching() {
  running_server_id=`docker_do ps | grep "$1" | awk '{print $1}'`
  if [ -n "$running_server_id" ]; then
    docker_do stop $running_server_id
  fi
}

command="$1"
shift

if [ $command = "run" ]; then # run
  compose_do run $@
  fix_file_permissions
fi

if [ $command = "b" ]; then # build
  compose_do build
fi

if [ $command = "deploy" ]; then # deploy
  branch=$(git symbolic-ref --short HEAD)
  if [ $branch = "master" ]; then
    environment="production"
  else
    environment="staging"
  fi
  tag="${environment}_$(date +"%F-%H%M")"
  commit_range="$(git tag -l | grep $environment | tail -n 1)..$branch"
  # Extract issue numbers from the branch names in the merge commits
  message=$(git log --merges --abbrev-commit --pretty=oneline "$commit_range" | grep -Po "'[0-9.]+" | tr "'" "#")
  printf -v message "$environment $(date +"%m/%d/%Y %I:%M%p")\n\n$message"
  hub release create $tag -m "$message"
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
  sudo rm -f $directory/passenger.*
  compose_do up --no-build
fi

if [ $command = "k" ]; then # rake
  if [ -e Gemfile ]; then
    compose_do run --rm web bundle exec $rake_command $@
  else
    compose_do run --rm web rake $@
  fi
  fix_file_permissions
fi

if [ $command = "bash" ] || [ $command = "sh" ]; then # bash
  compose_do run --rm web $command
fi

if [ $command = "rs" ]; then # restart (docker clean, rake db:setup, rails server)
  docker ps --quiet --no-trunc | xargs --no-run-if-empty docker stop
  docker ps --all --quiet --no-trunc | xargs --no-run-if-empty docker rm -v
  compose_do run --rm web bundle exec rake db:setup
  sudo rm -f $directory/tmp/pids/server.pid
  sudo rm -f $directory/passenger.*
  compose_do up --no-build
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
  docker ps --quiet --no-trunc | xargs --no-run-if-empty docker stop
  docker ps --all --quiet --no-trunc | xargs --no-run-if-empty docker rm -v
  docker images --quiet --no-trunc --filter "dangling=true" | xargs --no-run-if-empty docker rmi
fi

if [ $command = "t" ]; then # Tail development logs
  tail -f log/development.log
fi

if [ $command = "g" ]; then # Tail development logs and grep for '###'
  tail -f log/development.log | grep '###'
fi

if [ $command = "n" ]; then # cat notes
  tail -n300 notes.md
fi

if [ $command = "d" ]; then # rake db:setup
  compose_do run --rm web bundle exec $rake_command db:setup
fi
