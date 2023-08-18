#!/usr/bin/env bash

set -eu

usage() {
  echo "It adds system-wide UI font scale on external 4K monitor connection."
  echo "Usage: $(basename "$0") OPTION"
  printf "%-10s %s\n" '-h' 'this help'
  printf "%-10s %s\n" '-i' 'installs the rules'
  printf "%-10s %s\n" '-r' 'removes the rules'
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "You must be a root user to run this script." 2>&1
    exit 1
  fi
}

setup_vars() {
  # func vars are global in bash
  REAL_USER=$SUDO_USER
  REAL_USER_ID=$(id -u "$REAL_USER")
  HOME_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)
  CURRENT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd) # see https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
  # udev rules
  RULE_PRIORITY=70
  RULES_DIR="$CURRENT_DIR/udev"
  RULES_SCRIPT_TEMPLATE="on-external-display-connection.sh.template"
  RULES_TEMPLATE="on-external-display-connection.rules.template"
  RULES_INSTALL_DIR="/etc/udev/rules.d"
  # systemd service
  SERVICE_DIR="$CURRENT_DIR/systemd"
  SERVICE_TEMPLATE="external-display@.service.template"
  # scaling logic
  SCRIPT_INSTALL_DIR="$HOME_DIR/.local/bin"
}

install() {
  echo 'It adds system-wide font scale on external 4K monitor connection.'
  read -p "Are you sure you want to continue? (y/N) " -n 1 -r
  echo # empty line
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo 'Installation process cancelled!'
    exit 0
  fi

  install_rules && echo 'Added udev rule.'
  install_script && echo 'Added executable script.'
  install_service && echo 'Added systemd service.'

  echo 'Autoscaling installed. Try to connect the display!'
}

# adds a udev rule for display (dis-)connection
install_rules() {
  cp "$RULES_DIR/$(create_rules_file)" "$RULES_INSTALL_DIR"
}

# adds a script that the rule will execute
install_script() {
  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(create_script_file)
  # change ownership back to real user for consistency
  chown "$REAL_USER":"$REAL_USER" "$RULES_DIR/$SCRIPT_FILE_NAME"
  ln -s "$RULES_DIR/$SCRIPT_FILE_NAME" "$SCRIPT_INSTALL_DIR"
}

# adds a systemd service invokable by udev event
install_service() {
  systemctl link "$SERVICE_DIR/$(create_service_file)"
}
# converts on-external-display-connection.rules.template into 50-on-external-display-connection.rules
get_file_name_from_template() {
  echo "${1%.*}"
}

get_rules_file_name() {
  printf '%s-%s' "$RULE_PRIORITY" "$(get_file_name_from_template $RULES_TEMPLATE)"
}

get_script_file_name() {
  get_file_name_from_template $RULES_SCRIPT_TEMPLATE
}

get_service_file_name() {
  get_file_name_from_template $SERVICE_TEMPLATE
}

create_script_file() {
  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(get_script_file_name)

  # replace placeholder with actual path and create the file
  sed -e "s|{{ real_user }}|$REAL_USER|" -e "s|{{ real_user_id }}|$REAL_USER_ID|" "$RULES_DIR/$RULES_SCRIPT_TEMPLATE" >"$RULES_DIR/$SCRIPT_FILE_NAME"
  chmod +x "$RULES_DIR/$SCRIPT_FILE_NAME"

  echo "$SCRIPT_FILE_NAME"
}

create_service_file() {
  local SERVICE_FILE_NAME
  SERVICE_FILE_NAME=$(get_service_file_name)

  # replace placeholder with actual path and create the file
  sed -e "s|{{ real_user }}|$REAL_USER|" -e "s|{{ script_path }}|$SCRIPT_INSTALL_DIR/$(get_script_file_name)|" "$SERVICE_DIR/$SERVICE_TEMPLATE" >"$SERVICE_DIR/$SERVICE_FILE_NAME"

  echo "$SERVICE_FILE_NAME"
}

create_rules_file() {
  local RULES_FILE_NAME
  RULES_FILE_NAME=$(get_rules_file_name)

  # replace placeholder with actual path and create the rules file
  sed "s|{{ home }}|$HOME_DIR|" "$RULES_DIR/$RULES_TEMPLATE" >"$RULES_DIR/$RULES_FILE_NAME"

  echo "$RULES_FILE_NAME"
}

# removes soft links and their sources
remove() {
  local RULES_FILE_NAME
  RULES_FILE_NAME=$(get_rules_file_name)
  rm -f "$RULES_INSTALL_DIR/$RULES_FILE_NAME" "$RULES_DIR/$RULES_FILE_NAME"

  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(get_script_file_name)
  rm -f "$SCRIPT_INSTALL_DIR/$SCRIPT_FILE_NAME" "$RULES_DIR/$SCRIPT_FILE_NAME"

  local SERVICE_FILE_NAME
  SERVICE_FILE_NAME=$(get_service_file_name)
  systemctl disable "$SERVICE_FILE_NAME"
  rm -f "$SERVICE_DIR/$SERVICE_FILE_NAME"

  echo 'Autoscaling removed.'
}

reload_rules() {
  ### determine what kind of udev version we have
  RULES_PARAM='reload-rules'
  if [[ $(udevadm control --help | grep -c $RULES_PARAM) -eq 0 ]]; then
    RULES_PARAM='reload'
  fi

  ### reload udev and trigger events
  udevadm control --$RULES_PARAM && udevadm trigger
}

check_no_params() {
  if [[ $1 -eq 0 ]]; then
    usage
    exit 1
  fi
}

check_no_params "$#"
check_root
setup_vars

while getopts ":hir" option; do
  case $option in
  h)
    usage
    exit
    ;;
  i)
    install
    exit
    ;;
  r)
    remove
    exit
    ;;
  *)
    usage
    exit
    ;;
  esac
done
