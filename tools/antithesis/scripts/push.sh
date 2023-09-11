#!/bin/sh -eu

usage() {
	cat <<-EOF
	usage: ${0##*/} <tag>

	Push the TigerBeetle Docker images to Antithesis' registry.
	EOF
}

echo "${ANTITHESIS_KEY}" | docker login -u _json_key https://us-central1-docker.pkg.dev/ --password-stdin

if [ $# -ne 1 ] || [ "$1" = '-h' ]; then
	usage >&2
	exit 1
fi
tag=$1
url_prefix='us-central1-docker.pkg.dev/molten-verve-216720/tigerbeetle-repository'

push_image() {
	image=$1
	url="$url_prefix/$image:$tag"

	# XXX sudo
	sudo docker tag "$image:$tag" "$url"
	sudo docker push              "$url"
}

push_image api
push_image config
push_image replica
push_image workload