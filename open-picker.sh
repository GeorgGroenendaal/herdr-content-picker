#!/bin/sh
# Action entrypoint: opens the picker as a popup pane.
exec "${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "$HERDR_PLUGIN_ID" --entrypoint picker
