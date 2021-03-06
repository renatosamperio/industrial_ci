#!/bin/bash

# Copyright (c) 2017, Mathias Lüdtke
# All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# docker.sh script sets up Docker image.
# It is dependent on environment variables that need to be exported in advance
# (As of version 0.4.4 most of them are defined in ./env.sh).

#######################################
# rerun the CI script in docker container end exit the outer script
#
# Globals:
#   DOCKER_IMAGE (read-only)
#   ICI_SRC_PATH (read-only)
#   IN_DOCKER (read-only)
#   TARGET_REPO_PATH (read-only)
# Arguments:
#   (None)
# Returns:
#   (None)
#######################################
function ici_require_run_in_docker() {
  echo "  +++ DOCKER running docker requirement"
  echo "  +++ IN_DOCKER: $IN_DOCKER"
  if ! [ "$IN_DOCKER" ]; then
    ici_prepare_docker_image

    local docker_target_repo_path=/root/src/$TARGET_REPO_NAME
    local docker_ici_src_path=/root/ici
    echo "  +++   DOCKER SET TARGET REPO: $TARGET_REPO_NAME"
	echo "  +++   DOCKER docker_target_repo_path: $docker_target_repo_path"
	echo "  +++   DOCKER run in docker DOCKER_IMAGE: $DOCKER_IMAGE"
    ici_run_cmd_in_docker -e "TARGET_REPO_PATH=$docker_target_repo_path" \
                          -v "$TARGET_REPO_PATH/:$docker_target_repo_path:ro" \
                          -v "$ICI_SRC_PATH/:$docker_ici_src_path:ro" \
                          -t \
                          "$DOCKER_IMAGE" \
                          /bin/bash $docker_ici_src_path/ci_main.sh
    exit
  fi
}

#######################################
# wrapper for running a command in docker
#
# * enables environment passing
# * set-ups SSH auth socket forwarding
# * stops on interrupt signal
#
# Globals:
#   ICI_SRC_PATH (read-only)
#   SSH_AUTH_SOCK (read-only)
# Arguments:
#   all argumentes will be forwarded
# Returns:
#   (None)
#######################################
function ici_run_cmd_in_docker() {
  echo "  +++ DOCKER wrapper for running a command in docker"
  local run_opts=($DOCKER_RUN_OPTS)
  local commit_image=$_COMMIT_IMAGE
  unset _COMMIT_IMAGE

  #forward ssh agent into docker container
 echo "  +++ DOCKER forward ssh agent into docker container"  
 local ssh_docker_opts=()
  if [ "$SSH_AUTH_SOCK" ]; then
     local auth_dir
     auth_dir=$(dirname "$SSH_AUTH_SOCK")
     echo "  +++ DOCKER auth_dir: $auth_dir"
     echo "  +++ DOCKER SSH_AUTH_SOCK: $SSH_AUTH_SOCK"
     run_opts+=(-v "$auth_dir:$auth_dir" -e "SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
     echo "  +++ DOCKER 1run_opts: $run_opts"
  fi

  if [ "$CCACHE_DIR" ]; then
     run_opts+=(-v "$CCACHE_DIR:/root/.ccache" -e CCACHE_DIR=/root/.ccache)
     echo "  +++ DOCKER 2run_opts: $run_opts"
  fi

  if [ -n "$INJECT_QEMU" ]; then
    local qemu_path
    qemu_path=$(which "qemu-$INJECT_QEMU-static") || error "please install qemu-user-static"
    echo "  +++ DOCKER qemu_path: $qemu_path"
    run_opts+=(-v "$qemu_path:$qemu_path:ro")
    echo "  +++ DOCKER 3run_opts: $run_opts"
  fi

  echo "  +++ DOCKER env-file: ${ICI_SRC_PATH}"/docker.env"
  ls -la ${ICI_SRC_PATH}"/docker.env
  echo "  +++ DOCKER options: ${run_opts[@]}"
  echo "  +++ DOCKER other?: $@}"
  echo "  +++ DOCKER DOCKER_BASE_IMAGE: $DOCKER_BASE_IMAGE"
  echo "  +++ DOCKER creating docker environment"
  local cid
  cid=$(docker create \
      --env-file "${ICI_SRC_PATH}"/docker.env \
      "${run_opts[@]}" \
      "$@")

  # detect user inside container
  echo "  +++ DOCKER detect user inside container"
  local docker_image
  docker_image=$(docker inspect --format='{{.Config.Image}}' "$cid")
  docker_uid=$(docker run --rm "${run_opts[@]}" "$docker_image" id -u)
  docker_gid=$(docker run --rm "${run_opts[@]}" "$docker_image" id -g)

  # checking for known hosts
  echo "  +++ DOCKER checking for known hosts"
  echo "  +++ CI_SSH_KEY: $CI_SSH_KEY"
  if [ -n "$CI_SSH_KEY" ]; then
  	cat my_known_hosts >> ~/.ssh/known_hosts
  	(umask  077 ; echo $CI_SSH_KEY | base64 -d > ~/.ssh/id_rsa)
  	echo "  +++ DOCKER added id_rsa ~/.ssh/"
  	ls -la ~/.ssh/
  	cat ~/.ssh/id_rsa

  	echo "  +++ DOCKER added known hosts to ~/.ssh/"
  	cat ~/.ssh/known_hosts
  fi
  
  # pass common credentials to container
  echo "  +++ DOCKER pass common credentials to container"
  for d in .docker .ssh .subversion; do
    if [ -d "$HOME/$d" ]; then
      echo "  +++ HOME: $HOME"
      echo "  +++ PWD: $(pwd)"
      ls -laR $HOME/$d
      echo "    Copying key: $HOME/$d to $cid:/root/"
      docker_cp "$HOME/$d" "$cid:/root/"
#      ls -la $cid:/root/
    fi
  done

  echo "  +++ DOCKER Starting docker [$cid]"
  
  docker start -a "$cid" &
  trap 'docker kill $cid' INT
  local ret=0
  wait %% || ret=$?
  trap - INT
  if [ -n "$commit_image" ]; then
    docker commit -m "$_COMMIT_IMAGE_MSG" "$cid" $commit_image > /dev/null
  fi
  docker rm "$cid" > /dev/null
  return $ret
}

# work-around for https://github.com/moby/moby/issues/34096
# ensures that copied files are owned by the target user
function docker_cp {
  set -o pipefail
  tar --numeric-owner --owner=${docker_uid:-root} --group=${docker_gid:-root} -c -f - -C "$(dirname $1)" "$(basename $1)" | docker cp - $2
  set +o pipefail
}

#######################################
# wrapper for docker build
#
# * images will by tagged automatically
# * build option get passed from environment
#
# Globals:
#   DOCKER_BUILD_OPTS (read-only)
#   DOCKER_IMAGE (read-only)
# Arguments:
#   all argumentes will be forwarded
# Returns:
#   (None)
#######################################
function ici_docker_build() {
  echo "  +++ DOCKER wrapper for docker build"
  echo "  +++ DOCKER image file: $DOCKER_IMAGE"
  echo "  +++ DOCKER arguments: $@"
  local opts=($DOCKER_BUILD_OPTS)
  if [ "$DOCKER_PULL" != false ]; then
  	echo "  +++ DOCKER added pull"
    opts+=("--pull")
  fi
  echo "  +++ DOCKER building with options: ${opts[@]}"
  docker build -t "$DOCKER_IMAGE" "${opts[@]}" "$@"
}

#######################################
# set-ups the CI docker image
#
# * pull or build custom image
# * fall-bak to default build
#
# Globals:
#   DOCKER_FILE (read-only)
#   DOCKER_IMAGE (read/write)
#   TARGET_REPO_PATH (read-only)
# Arguments:
#   (None)
# Returns:
#   (None)
function ici_prepare_docker_image() {
  echo "  +++ DOCKER set-ups the CI docker image"
  ici_time_start prepare_docker_image

  echo "  +++ DOCKER looking for usermod"
  sudo find / -name "usermod"
  
  echo "+++ DOCKER DOCKER_HOST: $DOCKER_HOST"
#  echo "  +++ DOCKER calling usermod"
#  sudo usermod -aG docker $USER

  echo "  +++ DOCKER DOCKER_FILE: $DOCKER_FILE"
  if [ -n "$DOCKER_FILE" ]; then # docker file was provided
  	echo "  +++ DOCKER docker file was provided"
    #DOCKER_IMAGE=${DOCKER_IMAGE:"industrial-ci/custom"}
    ## Setting up image file
   	DOCKER_IMAGE=$DOCKER_BASE_IMAGE
   	
   	echo "  +++ DOCKER_IMAGE: $DOCKER_IMAGE"
    echo "  +++ DOCKER_BASE_IMAGE: $DOCKER_BASE_IMAGE"
    echo "  +++ target_docker: $TARGET_REPO_PATH/$DOCKER_FILE"
    ls -la /opt/atlassian/pipelines/agent/build/
    ls -la /opt/atlassian/pipelines/agent/build/setup/Dockerfile
    
    if [ -f "$TARGET_REPO_PATH/$DOCKER_FILE" ]; then # if single file, run without context
       echo "  +++ DOCKER if single file, run without context"
       
   	   echo "  +++ DOCKER prepare DOCKER_IMAGE: $DOCKER_IMAGE"
       
       echo "  +++ DOCKER options: $DOCKER_BUILD_OPTS"
       ici_docker_build - < "$TARGET_REPO_PATH/$DOCKER_FILE" > /dev/null
       #docker build -t hive_mind -f $TARGET_REPO_PATH/$DOCKER_FILE .  --rm > /dev/null
    elif [ -d "$TARGET_REPO_PATH/$DOCKER_FILE" ]; then # if path, run with context
    	echo "  +++ if path, run with context"
        ici_docker_build "$TARGET_REPO_PATH/$DOCKER_FILE" > /dev/null
    else # url, run directly
    	echo "  +++ url, run directly"
        ici_docker_build "$DOCKER_FILE" > /dev/null
    fi
  elif [ -z "$DOCKER_IMAGE" ]; then # image was not provided, use default
  	 echo "  +++ image was not provided, use default"
     ici_build_default_docker_image
  elif [ "$DOCKER_PULL" != false ]; then
  	 echo "  +++ pulling image"
     docker pull "$DOCKER_IMAGE"
  fi
  ici_time_end # prepare_docker_image
}

#######################################
# build the default docker image
#
# Globals:
#   APTKEY_STORE_HTTPS (read-only)
#   APTKEY_STORE_SKS (read-only)
#   DOCKER_IMAGE (write-only)
#   HASHKEY_SKS (read-only)
#   UBUNTU_OS_CODE_NAME (read-only)
# Arguments:
#   (None)
# Returns:
#   (None)

function ici_build_default_docker_image() {
  echo "  +++ DOCKER build the default docker image"
  if [ -n "$INJECT_QEMU" ]; then
  	echo "  +++ DOCKER injecting qemu"
    local qemu_path
    qemu_path=$(which "qemu-$INJECT_QEMU-static") || error "please install qemu-user-static"
    echo "Inject qemu..."
    local qemu_temp
    qemu_temp=$(mktemp -d)
    cat <<EOF > "$qemu_temp/Dockerfile"
    FROM $DOCKER_BASE_IMAGE
    COPY '$(basename $qemu_path)' '$qemu_path'
EOF
    cp "$qemu_path" "$qemu_temp"
    unset INJECT_QEMU
    export DOCKER_BASE_IMAGE="$DOCKER_BASE_IMAGE-qemu"
    DOCKER_IMAGE="$DOCKER_BASE_IMAGE" ici_docker_build "$qemu_temp" > /dev/null
    rm -rf "$qemu_temp"
  fi
  # choose a unique image name
  echo "  +++ DOCKER choose a unique image name"
  export DOCKER_IMAGE="industrial-ci/$ROS_DISTRO/$DOCKER_BASE_IMAGE"
  echo "Building image '$DOCKER_IMAGE':"
  local dockerfile=$(ici_generate_default_dockerfile)
  echo "$dockerfile"
  echo "  +++ DOCKER FILE"
  ici_docker_build - <<< "$dockerfile" > /dev/null
}

function ici_generate_default_dockerfile() {
  cat <<EOF
FROM $DOCKER_BASE_IMAGE

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections

RUN apt-get update -qq \
    && apt-get -qq install --no-install-recommends -y apt-utils gnupg wget ca-certificates lsb-release

RUN echo "deb ${ROS_REPOSITORY_PATH} \$(lsb_release -sc) main" > /etc/apt/sources.list.d/ros-latest.list
RUN apt-key adv --keyserver "${APTKEY_STORE_SKS}" --recv-key "${HASHKEY_SKS}" \
    || { wget "${APTKEY_STORE_HTTPS}" -O - | apt-key add -; }

RUN sed -i "/^# deb.*multiverse/ s/^# //" /etc/apt/sources.list \
    && apt-get update -qq \
    && apt-get -qq install --no-install-recommends -y \
        build-essential \
        python-catkin-tools \
        python-pip \
        python-rosdep \
        python-wstool \
        ros-$ROS_DISTRO-catkin \
        ssh-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

EOF
}
