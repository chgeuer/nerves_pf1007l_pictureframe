#!/bin/sh
set -e

FWUP_CONFIG=$NERVES_DEFCONFIG_DIR/fwup.conf
$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh $TARGET_DIR $FWUP_CONFIG
