#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#

#
# Copyright (c) 2018, Joyent, Inc.
#

###############################################################################
# This takes a recursive directory listing of /manta/ and uploads it to
# /$MANTA_USER/stor/mako/$(manta_storage_id)
###############################################################################

export PATH=/opt/local/bin:$PATH



## Global vars

# Immutables

[ -z $SSH_KEY ] && SSH_KEY=/root/.ssh/id_rsa
[ -z $MANTA_KEY_ID ] && MANTA_KEY_ID=$(ssh-keygen -l -f $SSH_KEY.pub | awk '{print $2}')
[ -z $MANTA_URL ] && MANTA_URL=$(cat /opt/smartdc/mako/etc/gc_config.json | json -ga manta_url)
[ -z $MANTA_USER ] && MANTA_USER=$(json -f /opt/smartdc/common/etc/config.json manta.user)
[ -z $MANTA_STORAGE_ID ] && MANTA_STORAGE_ID=$(cat /opt/smartdc/mako/etc/gc_config.json | json -ga manta_storage_id)
[ -z $MAKO_PROCESS_MANIFEST ] && MAKO_PROCESS_MANIFEST=$(cat /opt/smartdc/mako/etc/upload_config.json | json -ga process_manifest)

AUTHZ_HEADER="keyId=\"/$MANTA_USER/keys/$MANTA_KEY_ID\",algorithm=\"rsa-sha256\""
DIR_TYPE='application/json; type=directory'
LOG_TYPE='application/x-bzip2'
PID=$$
PID_FILE=/tmp/upload_mako_ls.pid
TMP_DIR=/var/tmp/mako_dir
LISTING_FILE=$TMP_DIR/$MANTA_STORAGE_ID
LISTING_FILE_PARTIAL=${LISTING_FILE}.${PID}
MANTA_DIR=mako
SUMMARY_FILE="$TMP_DIR/${MANTA_STORAGE_ID}.summary"
SUMMARY_DIR="$MANTA_DIR/summary"
MAKO_DIR=/opt/smartdc/mako
MAKOFIND=$MAKO_DIR/makofind
TARGET_DIR=/manta
START_TIME=`date -u +"%Y-%m-%dT%H:%M:%SZ"` # Time that this script started.



# Mutables

NOW=""
SIGNATURE=""



## Functions

function fatal {
    local LNOW=`date`
    echo "$LNOW: $(basename $0): fatal error: $*" >&2
    exit 1
}


function log {
    local LNOW=`date`
    echo "$LNOW: $(basename $0): info: $*" >&2
}


function sign() {
    NOW=$(date -u "+%a, %d %h %Y %H:%M:%S GMT")
    SIGNATURE=$(echo "date: $NOW" | tr -d '\n' | \
        openssl dgst -sha256 -sign $SSH_KEY | \
        openssl enc -e -a | tr -d '\n') \
        || fatal "unable to sign data"
}


function manta_put_directory() {
    sign || fatal "unable to sign"
    curl -fsSk \
        -X PUT \
        -H "content-type: application/json; type=directory" \
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        $MANTA_URL/$MANTA_USER/stor/${1} 2>&1
}


function manta_put() {
    sign || fatal "unable to sign"
    curl -vfsSk \
        -X PUT \
        -H "Date: $NOW" \
        -H "Authorization: Signature $AUTHZ_HEADER,signature=\"$SIGNATURE\"" \
        -H "Connection: close" \
        -H "m-mako-dump-time: $START_TIME" \
        $MANTA_URL/$MANTA_USER/stor/${1} \
        -T $2 \
        || fatal "unable to put $1"
}

#
# This function performs the heavy lifting when processing a mako manifest.  It
# build out several associative arrays, each indexed by account id:
#
# bytes[acct] contains a running sum of the number of bytes that account `acct'
# currently consumed.  This value is obtained from the %s parameter in the call
# to gfind.
#
# objects[acct] contains a running count of the number of files that belong to
# account `acct'.
#
# kilobytes[acct] contains a sum of one- kilobyte blocks that account `acct'
# consumes.  This value is the actual amount of data on disk consumed by the
# account.
#
# At the completion of the call to awk, the contents of each array are printed
# to give per-account information along a global summary.
#
function process_manifest() {
        file="$1"

	if [ ! -f $file ]; then
		fatal "File $file does not exist."
	fi

        cat $file | awk '{
		split($1, x, "/")
		acct=x[3]
		bytes[acct] += $2
		objects[acct]++
		kilobytes[acct] += $4
		total_bytes += $2
		total_objects++
		total_kilobytes += $4
	} END {
		printf("%-40s\t%-20s\t%-20s\t%-20s\t%s\n", "account", "bytes",
		    "objects", "average size kb", "kilobytes");

		for (acct in bytes) {
			printf("%-40s\t%-20f\t%-20f\t%-20f\t%f\n",
			    acct, bytes[acct], objects[acct],
			    kilobytes[acct] / objects[acct], kilobytes[acct]);
		}

		printf("%-40s\t%-20f\t%-20f\t%-20f\t%f\n", "totals",
		    total_bytes, total_objects, total_kilobytes / total_objects,
		    total_kilobytes);
	}' > "$SUMMARY_FILE"

	if [[ $? -ne 0 ]]; then
		fatal "Unable to completely process mako manifest file $file."
	fi
}

## Main

: ${MANTA_STORAGE_ID:?"Manta Storage Id must be set."}

# Check the last pid to see if a previous cron is still running...
LAST_PID=$(cat $PID_FILE 2>/dev/null)

if [[ -n "$LAST_PID" ]]; then
    ps -p $LAST_PID >/dev/null
    if [[ $? -eq 0 ]]; then
        echo "$0 process still running.  Exiting..."
        exit 1
    fi
fi

echo -n $PID >$PID_FILE

log "starting directory listing upload"

mkdir -p $TMP_DIR

#
# %p is the filename, %s is the logical size in bytes, %T@ is the timestamp of
# the last modification and %k is the physical size (i.e. size on disk) in
# kilobytes.  It is worth mentioning that in later versions of GNU find
# (> 4.2.33), the timestamp includes both, the number of seconds and the
# fractional part.  In order to maintain the same format as earlier version of
# the mako manifest, sed is used to strip out all characters between (and
# inclusive of) the '.' and the end of the column of the timestamp.  That is,
# sed is used to remove the fractional part of the timestamp.
#
find "$TARGET_DIR" -type f -printf '%p\t%s\t%T@\t%k\n' | sed 's/\..*\t/\t/g' > "$LISTING_FILE_PARTIAL"

if [[ $? -ne 0 ]]; then
	fatal "Error: makofind failed to obtain a complete listing"
fi

# Rename the file to reflect that makofind completed successfully
mv "$LISTING_FILE_PARTIAL" "$LISTING_FILE"

log "Going to upload $LISTING_FILE to $MANTA_DIR/$MANTA_STORAGE_ID"
manta_put_directory "$MANTA_DIR"
manta_put "$MANTA_DIR/$MANTA_STORAGE_ID" "$LISTING_FILE"

if [[ $MAKO_PROCESS_MANIFEST -eq 1 ]]; then
	log "Going to upload $SUMMARY_FILE to $SUMMARY_DIR/$MANTA_STORAGE_ID"
	process_manifest "$LISTING_FILE"
	manta_put_directory "$SUMMARY_DIR"
	manta_put "$SUMMARY_DIR/$MANTA_STORAGE_ID" "$SUMMARY_FILE"
fi

log "Cleaning up..."
rm -rf $TMP_DIR
rm $PID_FILE

log "Done."

exit 0;
