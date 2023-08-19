#!/usr/bin/env bash

##
## Note: All mentions of "template" refer to files with .template ext and not systemd service template
##

set -u

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

systemctl_run() {
  systemctl --machine="$REAL_USER"@.host --user "$@"
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
  install_services && echo 'Added systemd service.'

  echo 'Autoscaling installed. Try to connect the display!'
}

# adds a udev rule for display (dis-)connection
install_rules() {
  sudo cp "$RULES_DIR/$(create_rules_file)" "$RULES_INSTALL_DIR"
}

# adds a script that the rule will execute
install_script() {
  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(create_script_file)
  # change ownership back to real user for consistency
  chown "$REAL_USER":"$REAL_USER" "$RULES_DIR/$SCRIPT_FILE_NAME"
  ln -s "$RULES_DIR/$SCRIPT_FILE_NAME" "$SCRIPT_INSTALL_DIR"
}

# adds a2 services
# - systemd service invokable by udev event (hotplug)
# - a systemd service than runs on boot (boot with display already connected)
install_services() {
  local UDEV_SERVICE_FILE_NAME
  UDEV_SERVICE_FILE_NAME=$(create_udev_service_file)

  #  creates a "systemd service template" in a local user home dir ~/.config/systemd/user
  systemctl_run link "$SERVICE_DIR/$UDEV_SERVICE_FILE_NAME"

  local ON_BOOT_SERVICE_FILE_NAME
  ON_BOOT_SERVICE_FILE_NAME=$(create_on_boot_service_file)

  #  creates a regular "systemd service" in a local user home dir
  systemctl_run link "$SERVICE_DIR/$ON_BOOT_SERVICE_FILE_NAME"
  systemctl_run enable "$ON_BOOT_SERVICE_FILE_NAME"

  #  apply changes to current session
  systemctl_run daemon-reload
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

get_on_boot_service_file_name() {
  local DEFAULT_SERVICE_NAME
  DEFAULT_SERVICE_NAME=$(get_service_file_name)
  # replace @ in service template to get external-display-on-boot
  ON_BOOT_SERVICE_FILE_NAME=${DEFAULT_SERVICE_NAME/@/-on-boot}

  echo "$ON_BOOT_SERVICE_FILE_NAME"
}

create_script_file() {
  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(get_script_file_name)

  # replace placeholder with actual path and create the file
  sed -e "s|{{ real_user }}|$REAL_USER|" -e "s|{{ real_user_id }}|$REAL_USER_ID|" "$RULES_DIR/$RULES_SCRIPT_TEMPLATE" >"$RULES_DIR/$SCRIPT_FILE_NAME"
  chmod +x "$RULES_DIR/$SCRIPT_FILE_NAME"

  echo "$SCRIPT_FILE_NAME"
}

create_udev_service_file() {
  local UDEV_SERVICE_FILE_NAME
  UDEV_SERVICE_FILE_NAME=$(get_service_file_name)

  # replace placeholder with actual path and create the file
  sed -e "s|{{ script_path }}|$SCRIPT_INSTALL_DIR/$(get_script_file_name)|" -e '/\[Install\]/,$ d' "$SERVICE_DIR/$SERVICE_TEMPLATE" >"$SERVICE_DIR/$UDEV_SERVICE_FILE_NAME"

  echo "$UDEV_SERVICE_FILE_NAME"
}

create_on_boot_service_file() {
  local ON_BOOT_SERVICE_FILE_NAME
  ON_BOOT_SERVICE_FILE_NAME=$(get_on_boot_service_file_name)

  # replace placeholder with actual path and create the file
  sed -e "s|{{ script_path }}|$SCRIPT_INSTALL_DIR/$(get_script_file_name)|" "$SERVICE_DIR/$SERVICE_TEMPLATE" >"$SERVICE_DIR/$ON_BOOT_SERVICE_FILE_NAME"

  echo "$ON_BOOT_SERVICE_FILE_NAME"
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
  # rules files
  local RULES_FILE_NAME
  RULES_FILE_NAME=$(get_rules_file_name)
  rm -f "$RULES_INSTALL_DIR/$RULES_FILE_NAME" "$RULES_DIR/$RULES_FILE_NAME"

  # executable scaling logic
  local SCRIPT_FILE_NAME
  SCRIPT_FILE_NAME=$(get_script_file_name)
  rm -f "$SCRIPT_INSTALL_DIR/$SCRIPT_FILE_NAME" "$RULES_DIR/$SCRIPT_FILE_NAME"

  # systemd services
  local UDEV_SERVICE_FILE_NAME
  UDEV_SERVICE_FILE_NAME=$(get_service_file_name)
  systemctl_run disable "$UDEV_SERVICE_FILE_NAME"

  local ON_BOOT_SERVICE_FILE_NAME
  ON_BOOT_SERVICE_FILE_NAME=$(get_on_boot_service_file_name)
  systemctl_run disable "$ON_BOOT_SERVICE_FILE_NAME"

  rm -f "$SERVICE_DIR/$UDEV_SERVICE_FILE_NAME" "$SERVICE_DIR/$ON_BOOT_SERVICE_FILE_NAME"

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
