
SSH_ADDRESS="10.11.99.1"
WEBUI_ADDRESS="10.11.99.1:80"


PORT=9000 


function rmtgrep {
  RET_MATCH="$(ssh -S remarkable-ssh root@"$SSH_ADDRESS" "grep -$1 '$2' $3")"
}


function find_directory {
  OLD_IFS=$IFS
  IFS='/' _PATH=(${2#/}) 
  IFS=$OLD_IFS

  RET_FOUND=()

  rmtgrep "lF" "\"visibleName\": \"${_PATH[$3]}\"" "/home/root/.local/share/remarkable/xochitl/*.metadata"
  matches_by_name="$RET_MATCH"

  for metadata_path in $matches_by_name; do

    metadata="$(ssh -S remarkable-ssh root@"$SSH_ADDRESS" "cat $metadata_path")"

    if ! echo "$metadata" | grep -qF "\"parent\": \"$1\""; then
      continue
    fi

    if echo "$metadata" | grep -qF '"deleted": true'; then
      continue
    fi

    if ! echo "$metadata" | grep -qF '"type": "CollectionType"'; then
      continue
    fi

    if [[ "$(expr $3 + 1)" -eq "${#_PATH[@]}" ]]; then
      RET_FOUND+=("$(basename "$metadata_path" .metadata)")
    else
      find_directory "$(basename "$metadata_path" .metadata)" "$2" "$(expr $3 + 1)"
    fi

  done
}

function uuid_of_root_file {
  RET_UUID=""

  rmtgrep "lF" "\"visibleName\": \"$1\"" "~/.local/share/remarkable/xochitl/*.metadata"
  matches_by_name="$RET_MATCH"

  if [ -z "$matches_by_name" ]; then
    return
  fi

  for metadata_path in $matches_by_name; do

    metadata="$(ssh -S remarkable-ssh root@"$SSH_ADDRESS" "cat $metadata_path")"

    if echo "$metadata" | grep -qF '"parent": ""' && echo "$metadata" | grep -qF '"deleted": false'; then
      RET_UUID="$(basename "$metadata_path" .metadata)"
      break
    fi
  done
}


function push {

  file_cmd_output="$(file -F '|' "$1")"

  if [ ! -z "$(echo "$file_cmd_output" | grep -o "| PDF")" ]; then
    extension="pdf"
  else
    extension="epub"
  fi

  placeholder="/tmp/repush/$(basename "$1")"
  touch "$placeholder"

  while true; do
    if curl --connect-timeout 2 --silent --output /dev/null --form file=@"\"$placeholder\"" http://"$WEBUI_ADDRESS"/upload; then

      
      while true; do
        uuid_of_root_file "$(basename "$1")"
        if [ ! -z "$RET_UUID" ]; then
          break
        fi
      done;

      
      while true; do
        if ssh -S remarkable-ssh root@"$SSH_ADDRESS" stat "/home/root/.local/share/remarkable/xochitl/$RET_UUID.$extension" \> /dev/null 2\>\&1; then
          break
        fi
      done;

      
      retry=""
      while true; do
        scp "$1" root@"$SSH_ADDRESS":"/home/root/.local/share/remarkable/xochitl/$RET_UUID.$extension"

        if [ $? -ne 0 ]; then
          read -r -p "Failed to replace placeholder! Retry? [Y/n]: " retry
          if [[ $retry == "n" || $retry == "N" ]]; then
            return 0
          fi
        else
          break
        fi
      done

      
      ssh -S remarkable-ssh root@"$SSH_ADDRESS" "rm -f /home/root/.local/share/remarkable/xochitl/$RET_UUID.thumbnails/*"

      return 1

    else
      retry=""
      echo "repush: $1: Failed"
      read -r -p "Failed to push file! Retry? [Y/n]: " retry

      if [[ $retry == "n" || $retry == "N" ]]; then
        return 0
      fi
    fi
  done
}


while getopts ":r:p:o:" opt; do
  case "$opt" in

    r) # Push Remotely
      SSH_ADDRESS="$OPTARG"
      REMOTE=1
      ;;

    p) # Tunneling Port defined
      PORT="$OPTARG"
      ;;

    o) # Output
      OUTPUT="$OPTARG"
      ;;


    ?) # Unkown Option
      echo "repush: Invalid option or missing arguments: -$OPTARG"
      usage
      exit -1
      ;;
  esac
done
shift $((OPTIND-1))

if [ -z "$1" ];  then
  echo "repush: No documents provided"
  usage
  exit -1
fi

for f in "$@"; do
  file_cmd_output="$(file -F '|' "$f")"
  if [ ! -f "$f" ]; then
    echo "repush: No such file: $f"
    exit -1
  elif [[ -z "$(echo "$file_cmd_output" | grep -o "| PDF")" && -z "$(echo "$file_cmd_output" | grep -o "| EPUB")" ]]; then
    echo "repush: Unsupported file format: $f"
    echo "repush: Only PDFs and EPUBs are supported"
    exit -1
  elif [[ -z "$(echo "$f" | grep -oP "\.pdf$")" && -z "$(echo "$f" | grep -oP "\.epub$")" ]]; then
    echo "repush: File extension invalid or missing: $f"
    exit -1
  fi
done

if [ "$REMOTE" ]; then
  if nc -z localhost "$PORT" > /dev/null; then
    echo "repush: Port $PORT is already used by a different process!"
    exit -1
  fi

  ssh -o ConnectTimeout=5 -M -S remarkable-ssh -q -f -L "$PORT":"$WEBUI_ADDRESS" root@"$SSH_ADDRESS" -N;
  SSH_RET="$?"

  WEBUI_ADDRESS="localhost:$PORT"
else
  ssh -o ConnectTimeout=1 -M -S remarkable-ssh -q -f root@"$SSH_ADDRESS" -N
  SSH_RET="$?"
fi

if [ "$SSH_RET" -ne 0 ]; then
  echo "repush: Failed to establish connection with the device!"
  exit -1
fi

for f in "$@"; do
  uuid_of_root_file "$(basename "$f")"

  if [ ! -z $RET_UUID ]; then
    echo "repush: Cannot push '$f': File already exists in root directory"
    ssh -S remarkable-ssh -O exit root@"$SSH_ADDRESS"
    rm -rf /tmp/repush
    exit -1
  fi
done

rm -rf "/tmp/repush"
mkdir -p "/tmp/repush"

OUTPUT_UUID=""
if [ "$OUTPUT" ]; then
  find_directory '' "$OUTPUT" '0'

  
  if [ "${#RET_FOUND[@]}" -eq 0 ]; then
    echo "repush: Unable to find output directory: $OUTPUT"
    rm -rf /tmp/repush
    ssh -S remarkable-ssh -O exit root@"$SSH_ADDRESS"
    exit -1

  
  elif [ "${#RET_FOUND[@]}" -gt 1 ]; then
    REGEX='"lastModified": "[^"]*"'
    RET_FOUND=( "${RET_FOUND[@]/#//home/root/.local/share/remarkable/xochitl/}" )
    GREP="grep -o '$REGEX' ${RET_FOUND[@]/%/.metadata}"
    match="$(ssh -S remarkable-ssh root@"$SSH_ADDRESS" "$GREP")" 

    
    metadata=($(echo "$match" | sed "s/ //g" | sort -rn -t'"' -k4))

    
    uuid=($(echo "${metadata[@]}" | grep -o '[a-z0-9]*\-[a-z0-9]*\-[a-z0-9]*\-[a-z0-9]*\-[a-z0-9]*')) 
    lastModified=($(echo "${metadata[@]}" | grep -o '"lastModified":"[0-9]*"' | grep -o '[0-9]*'))   

    echo
    echo "'$OUTPUT' matches multiple directories!"
    while true; do
      echo

      
      for (( i=0; i<${#uuid[@]}; i++ )); do
        echo -e "$(expr $i + 1). ${uuid[$i]} - Last modified $(date -d @$(expr ${lastModified[$i]} / 1000) '+%Y-%m-%d %H:%M:%S')"
      done

      read -rp "Select your target directory: " INPUT
      echo

      if [[ "$INPUT" -gt 0  && "$INPUT" -lt $(expr $i + 1) ]]; then
        OUTPUT_UUID="${uuid[(($INPUT-1))]}"
        break
      fi

      echo "Invalid input"
    done

  
  else
    OUTPUT_UUID="$RET_FOUND"
  fi

  
  if [ -z "$REMOTE" ]; then
    RFKILL="$(ssh -S remarkable-ssh root@"$SSH_ADDRESS" "/usr/sbin/rfkill list 0 | grep 'blocked: yes'")"
    if [ -z "$RFKILL" ]; then
      ssh -S remarkable-ssh root@"$SSH_ADDRESS" "/usr/sbin/rfkill block 0"
    fi
  fi
fi


success=0
for f in "$@"; do
  push "$f"

  if [ $? == 1 ]; then
    if [ "$OUTPUT" ]; then
      
      ssh -S remarkable-ssh root@"$SSH_ADDRESS" "sed -i 's/\"parent\": \"[^\"]*\"/\"parent\": \"$OUTPUT_UUID\"/' /home/root/.local/share/remarkable/xochitl/$RET_UUID.metadata"
    fi

    ((success++))
  else
    echo "repush: $f: Failed"
  fi
done


if [ "$OUTPUT" ]; then
  if [[ -z "$REMOTE" && -z "$RFKILL" ]]; then
    ssh -S remarkable-ssh root@"$SSH_ADDRESS" "/usr/sbin/rfkill unblock 0"
  fi

  echo "repush: Applying changes..."
  ssh -S remarkable-ssh root@"$SSH_ADDRESS" "systemctl restart xochitl;"
fi

rm -rf /tmp/repush
ssh -S remarkable-ssh -O exit root@"$SSH_ADDRESS"
echo "Transferred $success out of $# documents"

#mod from https://github.com/reHackable/scripts/wiki/repush.sh
