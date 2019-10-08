#/bin/bash

set -e
set -o pipefail

BATCH_SIZE=1000
HOSTNAME="$(hostname)"

echo "Shipping logs in batches of $BATCH_SIZE from $HOSTNAME ($GRAYLOG_ENVIRONMENT} to $GRAYLOG_GELF_ADDRESS:$GRAYLOG_GELF_PORT"

format-logs() {
  # Removing noisy/unhelpful fields: cursor, machine id; and fields with a conflict with Graylog: id
  # Skipping protokube.service as very noisy
  # Timestamp converted from microseconds to seconds with millisecond component
  JQ_CMD="$(cat - <<EOF
      select(.MESSAGE != null and .MESSAGE != "")
    | select(._SYSTEMD_UNIT != "protokube.service")
    | select( ( (._SYSTEMD_UNIT == "kubelet.service" )
                and
                (.MESSAGE | contains("GET /metrics") )
              )
              | not
            )
    | with_entries( .key |= ( ltrimstr("_") | "_" + . ) )
    | del(._ID) | del(._id) | del(.__CURSOR) | del(._MACHINE_ID)
    | { 
        "version": "1.1",
        "host": "${HOSTNAME}",
        "short_message": ( ._MESSAGE | split("\n") | .[0] ),
        "full_message": ._MESSAGE,
        "timestamp": (.__REALTIME_TIMESTAMP | tonumber | . / 1000.0 | floor | . / 1000.0),
        "level": "1",
        "_environment": "${GRAYLOG_ENVIRONMENT}"
      }
      + .      
    | tostring
EOF
  )"
  jq -Mr "$JQ_CMD" <<< "$RECORDS"
}

send-logs() {
    # Have to inject NUL bytes here as bash can't store them
    cat - \
    | tr '\n' '\0' \
    | nc \
      -q 1 \
      -w 10 \
      ${GRAYLOG_GELF_ADDRESS} ${GRAYLOG_GELF_PORT}
}

write-cursor() {
    echo -n "$CUR_POS_NEW" > "${JOURNAL_CURSOR_TRACKING}"
}

log-now() {
    set +e
    WIRE_DATA="$(format-logs)"
    LOCAL_EXIT_CODE=$?
    if [[ $LOCAL_EXIT_CODE -ne 0 ]]; then
      DATA_ERROR=1
      return $LOCAL_EXIT_CODE
    fi
    DATA_ERROR=0
    set -e
    if [[ "$WIRE_DATA" != "" ]]; then
      send-logs <<< "$WIRE_DATA"
    fi
    write-cursor
}

get-records() {
  set +e
  set +o pipefail
  # Necessary to accept errors as we are terminating the journalctl pipe output early
  RECORDS="$(journalctl -o json -D "${JOURNAL_LOCATION}" $CUR_CMD ${CUR_POS:+"$CUR_POS"} --no-pager | head -n $CURRENT_BATCH_SIZE)"
  set -e
  set -o pipefail
  RECORD_COUNT="$(wc -l <<< "$RECORDS")"
}

process-poison-messages() {
  # We can have multiple poison messages sequentially, so we need to see where we can resume
  # If this still fails, we can skip to current journal position but then we have lost an
  # unknown number of records
  echo 'Skipping over poison records'
  CURRENT_BATCH_SIZE=$BATCH_SIZE
  get-records
  poison_counter=0
  poison_record_count="$RECORD_COUNT"
  POISON_RECORDS="$RECORDS"
  RECORD_COUNT=1

  if [[ $poison_record_count -lt 2 ]]; then
    echo "No newer messages after poison record: $POISON_RECORDS"
    
    CUR_POS_NEW="$(journalctl -n 0 --show-cursor --quiet | sed 's/^-- cursor: *//')"
    write-cursor
    return
  fi

  while [[ $poison_counter -lt $poison_record_count ]]; do
    RECORDS="$(head -n 1 <<< "$POISON_RECORDS")"
    POISON_RECORDS="$(tail +2 <<< "$POISON_RECORDS")"
    poison_counter=$((poison_counter + 1))

    set +e
    CUR_POS_NEW="$(jq -rM .__CURSOR <<< "$RECORDS")"
    LOCAL_EXIT_CODE=$?
    set -e
    if [[ $LOCAL_EXIT_CODE -ne 0 ]]; then
      echo "Poison record found, skipping: $RECORDS."
      continue;
    fi
    set +e
    log-now
    LOCAL_EXIT_CODE=$?
    set -e
    if [[ $LOCAL_EXIT_CODE -ne 0 ]]; then
      if [[ $DATA_ERROR -eq 1 ]]; then
        echo "Poison record found, skipping: $RECORDS."
        write-cursor # We can do this because it is only for one record
      else
        exit $? # Don't trap network or other issues
      fi
    else
      echo 'Resuming normal processing'
      return 0 # Can resume normal processing
    fi
  done
  # It is possible that we've got to this point because we haven't been able to read a valid cursor
  # In this case, we are losing data but still better to resume normal processing
  echo 'Unable to recover valid cursor, skipping to head'
  CUR_POS_NEW="$(journalctl -n 0 --show-cursor --quiet | sed 's/^-- cursor: *//')"
  write-cursor
  return 0
}

# The journal entries can become corrupted and so failures must be identified
# This means that we can't do simple piping as we have to review each error code
# When we encounter an error that relates to data processing, we'll reduce the batch size
# If we still get an error when the batch size is 1, we can mark that message as poison
# and move on

CURRENT_BATCH_SIZE=$BATCH_SIZE

while [[ 1 -eq 1 ]]
do
  CUR_POS=
  CUR_CMD=
  if [[ -e "${JOURNAL_CURSOR_TRACKING}" ]]; then
    CUR_POS="$(cat "${JOURNAL_CURSOR_TRACKING}")"
    CUR_CMD=--after-cursor
  fi
  if [[ "$CUR_POS" == "" ]]; then
    CUR_POS=
    CUR_CMD=
  fi

  get-records

  RECORD_COUNT="$(wc -l <<< "$RECORDS")"
  if [[ "$RECORDS" == "" ]]; then
    RECORD_COUNT=0
  fi

  if [[ $RECORD_COUNT -eq 0 ]]; then
    # Logs caught up
    CURRENT_BATCH_SIZE=$BATCH_SIZE
    sleep 10
    continue;
  fi

  LAST_RECORD="$(tail -n 1 <<< "$RECORDS")"
  set +e
  CUR_POS_NEW="$(jq -rM .__CURSOR <<< "$LAST_RECORD")"
  LOCAL_EXIT_CODE=$?
  set -e
  if [[ $LOCAL_EXIT_CODE -ne 0 ]]; then
    CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE/2))
    if [[ $CURRENT_BATCH_SIZE -eq 0 ]]; then
      process-poison-messages
      CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE * 2))
      if [[ $CURRENT_BATCH_SIZE -gt $BATCH_SIZE ]]; then
        CURRENT_BATCH_SIZE=$BATCH_SIZE
      fi
    fi
    continue
  else
    set +e
    log-now
    LOCAL_EXIT_CODE=$?
    set -e
    if [[ $LOCAL_EXIT_CODE -ne 0 ]]; then
      if [[ $DATA_ERROR -ne 0 ]]; then
        CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE/2))
        continue
      fi
      echo "Error sending logs: $LOCAL_EXIT_CODE"
      exit $?
    fi
    CURRENT_BATCH_SIZE=$((CURRENT_BATCH_SIZE * 2))
    if [[ $CURRENT_BATCH_SIZE -gt $BATCH_SIZE ]]; then
      CURRENT_BATCH_SIZE=$BATCH_SIZE
    fi
  fi
done