#!/bin/bash
# The tools CI runs, from their pins in a Dockerfile of tool images.
#
#   bash pinned-tool.sh ref NAME            # print NAME's image@digest
#   bash pinned-tool.sh install DIR NAME... # copy each binary into DIR
#
# The pins are the Dockerfile beside this script -- the tools the shared
# workflows run -- or, with PINNED_TOOLS_FILE set, that file: a repository's own
# pins, in the same format (.github/tools/Dockerfile, say). The Dockerfile here
# says what the format is and why it is shaped that way.
#
# install takes the binary for this machine's architecture out of the pinned
# image without running anything in it, after checking the image's signature
# where the pin names a signer (`# signed-by:`; needs cosign on PATH). The
# binaries are Linux ones, so on a Mac use the image directly
# (docker run "$(... ref NAME)") instead. Needs docker.
set -euo pipefail
pins=${PINNED_TOOLS_FILE:-"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/Dockerfile"}
[ -f "$pins" ] || { echo "pinned-tool: no pins file at $pins" >&2; exit 1; }

# NAME -> "image:tag@digest path identity issuer" ("-" for a missing field)
lookup() {
	local found
	found=$(awk -v name="$1" '
		/^# path: / { path = $3; next }
		/^# signed-by: / { identity = $3; issuer = $4; next }
		/^FROM / {
			if (tolower($3) == "as" && $4 == name) {
				print $2, (path == "" ? "-" : path), (identity == "" ? "-" : identity), (issuer == "" ? "-" : issuer)
				exit
			}
			path = ""; identity = ""; issuer = ""
		}
	' "$pins")
	[ -n "$found" ] || { echo "pinned-tool: no stage named $1 in $pins" >&2; return 1; }
	echo "$found"
}

case ${1:-} in
ref)
	[ $# -eq 2 ] || { echo "usage: pinned-tool.sh ref NAME" >&2; exit 2; }
	# Not `read < <(lookup)`: a failure inside a process substitution is
	# lost, and a misspelt name would print an empty reference and succeed.
	found=$(lookup "$2")
	read -r ref _ <<<"$found"
	echo "$ref"
	;;
install)
	[ $# -ge 3 ] || { echo "usage: pinned-tool.sh install DIR NAME..." >&2; exit 2; }
	dir=$2; shift 2
	case $(uname -m) in
		x86_64|amd64) arch=amd64 ;;
		aarch64|arm64) arch=arm64 ;;
		*) echo "pinned-tool: no pinned build for $(uname -m)" >&2; exit 1 ;;
	esac
	mkdir -p "$dir"
	for name in "$@"; do
		found=$(lookup "$name")
		read -r ref path identity issuer <<<"$found"
		[ "$path" != - ] || { echo "pinned-tool: $name is used as an image, not installed" >&2; exit 1; }
		if [ "$identity" != - ]; then
			command -v cosign >/dev/null || { echo "pinned-tool: $name's signature is checked with cosign, which isn't on PATH" >&2; exit 1; }
			tag=${ref%@*}; tag=${tag##*:}
			identity=${identity//\{tag\}/$tag}
			if ! out=$(cosign verify "$ref" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" 2>&1 >/dev/null); then
				echo "pinned-tool: $ref isn't signed by $identity:" >&2
				echo "$out" | tail -3 >&2
				exit 1
			fi
			echo "$name: signed by $identity"
		fi
		# create, not run: the image's code never executes here, and the
		# placeholder command is never started.
		cid=$(docker create --quiet --platform "linux/$arch" "$ref" pinned-tool)
		trap 'docker rm -f "$cid" >/dev/null 2>&1' EXIT
		docker cp --quiet "$cid:$path" "$dir/$name"
		docker rm -f "$cid" >/dev/null
		trap - EXIT
		chmod 755 "$dir/$name"
		echo "$name: $ref -> $dir/$name"
	done
	;;
*)
	echo "usage: pinned-tool.sh ref NAME | install DIR NAME..." >&2
	exit 2
	;;
esac
