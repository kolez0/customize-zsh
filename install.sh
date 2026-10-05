#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
PROJECT_DIR=$CONFIG_HOME/customize-zsh
ZSH_CONFIG_DIR=$PROJECT_DIR/zsh
BACKUP_DIR=$PROJECT_DIR/backups
OWNERSHIP_DIR=$PROJECT_DIR/ownership
MANIFEST=$PROJECT_DIR/install-manifest
ANTIDOTE_DIR=${ZDOTDIR:-$HOME}/.antidote
ZSHRC=${ZDOTDIR:-$HOME}/.zshrc
TIMESTAMP=$(date -u '+%Y%m%dT%H%M%SZ')
JOURNAL_DIR=
JOURNAL_COUNT=0
CONFIG_STARTED=0

if [ -d "$HOME/.local/bin" ]; then
  case ":${PATH:-}:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
  esac
  export PATH
fi

say() { printf '%s\n' "customize-zsh: $*"; }
fail() { printf '%s\n' "customize-zsh: ошибка: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif has sudo; then
    sudo "$@"
  else
    fail "для установки системных пакетов требуется sudo или запуск от root."
  fi
}

detect_platform() {
  OS_NAME=$(uname -s)
  case "$OS_NAME" in
    Darwin)
      PLATFORM=macos
      if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || :)" != 1 ]; then
        fail 'поддерживаются только компьютеры Mac с Apple Silicon; Intel Mac не входит в матрицу поддержки.'
      fi
      MACOS_VERSION=$(sw_vers -productVersion)
      MACOS_MAJOR=${MACOS_VERSION%%.*}
      case "$MACOS_MAJOR" in
        ''|*[!0-9]*) fail "не удалось определить версию macOS '$MACOS_VERSION'." ;;
      esac
      [ "$MACOS_MAJOR" -ge 15 ] || fail "macOS $MACOS_VERSION не поддерживается; требуется macOS 15 или новее."
      has brew || fail 'не найден Homebrew; установите его и повторите запуск.'
      ;;
    Linux)
      [ -r /etc/os-release ] || fail 'не найден /etc/os-release; определить дистрибутив Linux невозможно.'
      # shellcheck disable=SC1091
      . /etc/os-release
      DISTRO_ID=${ID:-}
      DISTRO_VERSION=${VERSION_ID:-}
      case "$DISTRO_ID" in
        debian)
          has apt-get || fail 'для Debian не найден apt-get.'
          case "$DISTRO_VERSION" in 12|13) PLATFORM=debian ;; *) fail "Debian $DISTRO_VERSION отсутствует в матрице поддержки (12, 13)." ;; esac
          ;;
        ubuntu)
          has apt-get || fail 'для Ubuntu не найден apt-get.'
          case "$DISTRO_VERSION" in 24.04|26.04) PLATFORM=ubuntu ;; *) fail "Ubuntu $DISTRO_VERSION отсутствует в матрице поддержки (24.04, 26.04)." ;; esac
          ;;
        fedora)
          has dnf || fail 'для Fedora не найден dnf.'
          case "$DISTRO_VERSION" in 43|44) PLATFORM=fedora ;; *) fail "Fedora $DISTRO_VERSION отсутствует в матрице поддержки (43, 44)." ;; esac
          ;;
        arch)
          has pacman || fail 'для Arch Linux не найден pacman.'
          PLATFORM=arch
          ;;
        *) fail "дистрибутив '$DISTRO_ID' не поддерживается; конфигурация не изменена." ;;
      esac
      ;;
    *) fail "ОС '$OS_NAME' не поддерживается; конфигурация не изменена." ;;
  esac
}

install_starship_upstream() {
  local_script=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-starship.XXXXXX") || fail 'не удалось создать временный файл для Starship.'
  if ! curl -fL --retry 2 https://starship.rs/install.sh -o "$local_script"; then
    rm -f "$local_script"
    fail 'не удалось загрузить официальный установщик Starship.'
  fi
  mkdir -p "$HOME/.local/bin"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  if ! sh "$local_script" --yes --bin-dir "$HOME/.local/bin"; then
    rm -f "$local_script"
    fail 'официальный установщик Starship завершился с ошибкой.'
  fi
  rm -f "$local_script"
}

starship_is_suitable() {
  if [ -x "$HOME/.local/bin/starship" ]; then
    starship_command=$HOME/.local/bin/starship
  else
    has starship || return 1
    starship_command=$(command -v starship)
  fi
  version_output=$("$starship_command" --version 2>/dev/null || :)
  version_tuple=$(printf '%s\n' "$version_output" | sed -n 's/^starship \([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p')
  [ -n "$version_tuple" ] || return 1
  set -- $version_tuple
  [ "$1" -gt 1 ] || { [ "$1" -eq 1 ] && [ "$2" -ge 22 ]; }
}

install_zoxide_upstream() {
  local_script=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-zoxide.XXXXXX") || fail 'не удалось создать временный файл для zoxide.'
  if ! curl -fL --retry 2 https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh -o "$local_script"; then
    rm -f "$local_script"
    fail 'не удалось загрузить официальный установщик zoxide.'
  fi
  if ! sh "$local_script" --bin-dir "$HOME/.local/bin" --man-dir "$HOME/.local/share/man"; then
    rm -f "$local_script"
    fail 'официальный установщик zoxide завершился с ошибкой.'
  fi
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  rm -f "$local_script"
}

install_eza_debian() {
  local_key=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-eza-key.XXXXXX") || fail 'не удалось создать временный файл ключа eza.'
  local_keyring=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-eza-ring.XXXXXX") || fail 'не удалось создать временный keyring eza.'
  if ! curl -fL --retry 2 https://raw.githubusercontent.com/eza-community/eza/main/deb.asc -o "$local_key"; then
    rm -f "$local_key" "$local_keyring"
    fail 'не удалось загрузить ключ, указанный официальной инструкцией eza.'
  fi
  rm -f "$local_keyring"
  if ! gpg --dearmor --output "$local_keyring" "$local_key"; then
    rm -f "$local_key" "$local_keyring"
    fail 'не удалось обработать ключ репозитория eza.'
  fi
  rm -f "$local_key"
  as_root mkdir -p /etc/apt/keyrings
  as_root install -m 0644 "$local_keyring" /etc/apt/keyrings/gierens.gpg
  rm -f "$local_keyring"
  printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/gierens.gpg] https://deb.gierens.de stable main' | as_root tee /etc/apt/sources.list.d/gierens.list >/dev/null
  as_root apt-get update
  as_root apt-get install -y eza
}

package_is_installed() {
  case "$PLATFORM" in
    macos) brew list --formula --versions "$1" >/dev/null 2>&1 ;;
    debian|ubuntu) [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = 'install ok installed' ] ;;
    fedora) rpm -q -- "$1" >/dev/null 2>&1 ;;
    arch) pacman -Q -- "$1" >/dev/null 2>&1 ;;
  esac
}

install_missing_packages() {
  missing_packages=
  for package do
    if ! package_is_installed "$package"; then
      missing_packages="${missing_packages:+$missing_packages }$package"
    fi
  done
  [ -n "$missing_packages" ] || return 0

  # Package names below are fixed literals without whitespace.
  # shellcheck disable=SC2086
  set -- $missing_packages
  case "$PLATFORM" in
    macos) brew install "$@" ;;
    debian|ubuntu)
      as_root apt-get update
      as_root apt-get install -y "$@"
      ;;
    fedora) as_root dnf install -y "$@" ;;
    arch) as_root pacman -S --needed --noconfirm "$@" ;;
  esac
}

install_dependencies() {
  case "$PLATFORM" in
    macos)
      install_missing_packages vim git curl starship fzf fd bat eza ripgrep zoxide
      if ! starship_is_suitable; then
        brew upgrade starship || :
        starship_is_suitable || install_starship_upstream
      fi
      ;;
    debian|ubuntu)
      install_missing_packages vim git curl ca-certificates tar gzip gpg fzf fd-find bat ripgrep
      if ! has eza; then install_eza_debian; fi
      if ! has zoxide; then install_zoxide_upstream; fi
      if ! starship_is_suitable; then
        case "$PLATFORM:$DISTRO_VERSION" in
          debian:13|ubuntu:26.04)
            if ! as_root apt-get install -y starship; then install_starship_upstream; fi
            starship_is_suitable || install_starship_upstream
            ;;
          *) install_starship_upstream ;;
        esac
      fi
      ;;
    fedora)
      install_missing_packages vim git curl ca-certificates tar gzip fzf fd-find bat eza ripgrep zoxide
      if ! starship_is_suitable; then install_starship_upstream; fi
      ;;
    arch)
      install_missing_packages vim git starship fzf fd bat eza ripgrep zoxide curl ca-certificates tar gzip gnupg
      if ! starship_is_suitable; then install_starship_upstream; fi
      ;;
  esac

  for dependency in vim git starship fzf fd bat eza rg zoxide; do
    case "$dependency:$PLATFORM" in
      fd:debian|fd:ubuntu|fd:fedora) has fd || has fdfind || fail "после установки не найдена команда fd или fdfind." ;;
      bat:debian|bat:ubuntu) has bat || has batcat || fail "после установки не найдена команда bat или batcat." ;;
      *) has "$dependency" || fail "после установки не найдена команда '$dependency'." ;;
    esac
  done
  starship_is_suitable || fail 'для согласованной конфигурации требуется Starship версии 1.22.0 или новее.'
}

install_antidote() {
  [ ! -L "$ANTIDOTE_DIR" ] || fail "каталог $ANTIDOTE_DIR является симлинком; он не изменён."
  if [ -e "$ANTIDOTE_DIR" ]; then
    if ! git -C "$ANTIDOTE_DIR" remote get-url origin 2>/dev/null | grep -Eq '^https://github\.com/mattmc3/antidote(\.git)?$'; then
      fail "каталог $ANTIDOTE_DIR уже существует и не является подтверждённой установкой Antidote; он не изменён."
    fi
  else
    mkdir -p "${ANTIDOTE_DIR%/*}"
    git clone --depth 1 https://github.com/mattmc3/antidote.git "$ANTIDOTE_DIR"
  fi
  [ -r "$ANTIDOTE_DIR/antidote.zsh" ] || fail 'в каталоге Antidote не найден antidote.zsh.'
}

install_vim_plugins() {
  [ ! -L "$HOME/.vim" ] && [ ! -L "$HOME/.vim/autoload" ] || fail 'каталог Vim является симлинком; он не изменён.'
  if [ ! -f "$HOME/.vim/autoload/plug.vim" ]; then
    mkdir -p "$HOME/.vim/autoload"
    plug_tmp=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-vim-plug.XXXXXX") || fail 'не удалось создать временный файл vim-plug.'
    if ! curl -fL --retry 2 https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim -o "$plug_tmp"; then
      rm -f "$plug_tmp"
      fail 'не удалось загрузить vim-plug.'
    fi
    copy_managed "$plug_tmp" "$HOME/.vim/autoload/plug.vim" vim-plug
    rm -f "$plug_tmp"
  fi
  say 'установка плагинов Vim…'
  # fzf уже установлен пакетным менеджером; используем его без загрузки бинарника.
  vim -n -es -u "$HOME/.vimrc" -i NONE -c 'PlugInstall --sync' -c 'qa!' || fail 'не удалось установить плагины Vim.'
}

record_change() {
  JOURNAL_COUNT=$((JOURNAL_COUNT + 1))
  record_name=$(printf '%08d' "$JOURNAL_COUNT")
  printf '%s\n' "$1" > "$JOURNAL_DIR/$record_name.path"
  if [ -e "$1" ]; then
    cp -p "$1" "$JOURNAL_DIR/$record_name.data"
    : > "$JOURNAL_DIR/$record_name.existed"
  fi
}

atomic_file() {
  target_path=$1
  source_path=$2
  target_dir=${target_path%/*}
  mkdir -p "$target_dir"
  [ ! -L "$target_path" ] || fail "целевой файл $target_path является симлинком; он не изменён."
  temp_path=$(mktemp "$target_path.tmp.XXXXXX") || fail "не удалось создать временный файл рядом с $target_path."
  record_change "$target_path"
  if ! cp -p "$source_path" "$temp_path"; then
    rm -f "$temp_path"
    fail "не удалось подготовить временную копию для $target_path."
  fi
  mv -f "$temp_path" "$target_path"
}

write_state() {
  state_target=$1
  state_value=$2
  state_tmp=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-state.XXXXXX") || fail 'не удалось создать временную запись состояния.'
  printf '%s\n' "$state_value" > "$state_tmp"
  atomic_file "$OWNERSHIP_DIR/$state_target" "$state_tmp"
  rm -f "$state_tmp"
}

add_manifest_target() {
  manifest_target=$1
  if [ ! -f "$MANIFEST" ] || ! grep -F -x -q "$manifest_target" "$MANIFEST"; then
    manifest_tmp=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-manifest.XXXXXX") || fail 'не удалось создать временный манифест.'
    [ ! -f "$MANIFEST" ] || cat "$MANIFEST" > "$manifest_tmp"
    printf '%s\n' "$manifest_target" >> "$manifest_tmp"
    atomic_file "$MANIFEST" "$manifest_tmp"
    rm -f "$manifest_tmp"
  fi
}

copy_managed() {
  source_file=$1
  target_file=$2
  state_name=$3
  [ -f "$source_file" ] || fail "не найден файл конфигурации $source_file."
  [ ! -L "$PROJECT_DIR" ] || fail "каталог проекта $PROJECT_DIR является симлинком; он не изменён."
  [ ! -L "$BACKUP_DIR" ] || fail "каталог резервных копий $BACKUP_DIR является симлинком; он не изменён."
  [ ! -L "$OWNERSHIP_DIR" ] || fail "каталог записей владения $OWNERSHIP_DIR является симлинком; он не изменён."
  case "$state_name" in
    zsh/*)
      [ ! -L "$ZSH_CONFIG_DIR" ] || fail 'каталог конфигурации zsh является симлинком; он не изменён.'
      [ ! -L "$BACKUP_DIR/zsh" ] || fail 'вложенный каталог резервных копий является симлинком; он не изменён.'
      [ ! -L "$OWNERSHIP_DIR/zsh" ] || fail 'вложенный каталог записей владения является симлинком; он не изменён.'
      ;;
  esac
  mkdir -p "${target_file%/*}" "$BACKUP_DIR" "$OWNERSHIP_DIR"
  [ ! -L "$target_file" ] || fail "целевой файл $target_file является симлинком; он не изменён."

  previous_state=
  backup_path=
  state_file=$OWNERSHIP_DIR/$state_name
  [ ! -L "$state_file" ] || fail "запись владения для $state_name является симлинком; файл не изменён."
  if [ -e "$state_file" ]; then
    [ -f "$state_file" ] || fail "запись владения для $state_name не является обычным файлом; файл не изменён."
    previous_state=$(cat "$state_file")
  fi
  case "$previous_state" in
    ''|created|preexisting|backup:*) ;;
    *) fail "неизвестное состояние владения для $state_name; файл не изменён." ;;
  esac
  case "$previous_state" in
    backup:*)
      previous_backup=${previous_state#backup:}
      previous_prefix=$BACKUP_DIR/$state_name.
      case "$previous_backup" in
        "$previous_prefix"*) previous_suffix=${previous_backup#"$previous_prefix"} ;;
        *) fail "путь резервной копии для $state_name недопустим; файл не изменён." ;;
      esac
      case "$previous_suffix" in ''|*/*) fail "путь резервной копии для $state_name содержит недопустимые компоненты." ;; esac
      [ ! -L "$previous_backup" ] && [ -f "$previous_backup" ] || fail "резервная копия для $state_name отсутствует или является симлинком; файл не изменён."
      ;;
  esac
  if [ -f "$target_file" ] && cmp -s "$source_file" "$target_file"; then
    [ -n "$previous_state" ] || write_state "$state_name" preexisting
    add_manifest_target "$state_name"
    return
  fi

  if [ -e "$target_file" ]; then
    backup_base="$BACKUP_DIR/$state_name.$TIMESTAMP.$$"
    backup_path=$backup_base
    backup_sequence=1
    while [ -e "$backup_path" ] || [ -L "$backup_path" ]; do
      backup_path="$backup_base.$backup_sequence"
      backup_sequence=$((backup_sequence + 1))
    done
    mkdir -p "${backup_path%/*}"
    cp -p "$target_file" "$backup_path"
    case "$previous_state" in
      backup:*|created) ;;
      ''|preexisting) write_state "$state_name" "backup:$backup_path" ;;
    esac
  else
    case "$previous_state" in
      ''|preexisting) write_state "$state_name" created ;;
    esac
  fi

  atomic_file "$target_file" "$source_file"
  add_manifest_target "$state_name"
  say "установлен файл $target_file"
  [ -z "$backup_path" ] || say "резервная копия: $backup_path"
}

replace_zshrc_block() {
  [ ! -L "$ZSHRC" ] || fail "$ZSHRC является симлинком; он не изменён."
  mkdir -p "${ZSHRC%/*}"
  block_tmp=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-zshrc.XXXXXX") || fail 'не удалось создать временный файл для .zshrc.'
  block_body=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-zshrc-body.XXXXXX") || fail 'не удалось создать временный файл блока .zshrc.'
  if [ -f "$ZSHRC" ]; then
    cp -p "$ZSHRC" "$block_tmp"
    if ! awk '
      BEGIN { start = "# >>> customize-zsh >>>"; end = "# <<< customize-zsh <<<" }
      $0 == start { if (inside || seen) bad = 1; inside = 1; seen = 1; next }
      $0 == end { if (!inside) bad = 1; inside = 0; next }
      inside { next }
      { print }
      END { if (inside || bad) exit 42 }
    ' "$ZSHRC" > "$block_body"; then
      rm -f "$block_tmp" "$block_body"
      fail 'в ~/.zshrc обнаружены повреждённые или повторные маркеры customize-zsh; файл не изменён.'
    fi
  else
    : > "$block_tmp"
    : > "$block_body"
  fi

  source_path="$ZSH_CONFIG_DIR/rc.zsh"
  quoted_source=$(printf '%s' "$source_path" | sed "s/'/'\\\\''/g")
  cat "$block_body" > "$block_tmp"
  printf '\n# >>> customize-zsh >>>\nsource '\''%s'\''\n# <<< customize-zsh <<<\n' "$quoted_source" >> "$block_tmp"
  if [ -f "$ZSHRC" ] && cmp -s "$ZSHRC" "$block_tmp"; then
    rm -f "$block_tmp" "$block_body"
    return
  fi
  atomic_file "$ZSHRC" "$block_tmp"
  rm -f "$block_tmp" "$block_body"
}

rollback() {
  [ "$JOURNAL_COUNT" -gt 0 ] || return 0
  say 'ошибка во время копирования; восстанавливаю состояние до установки.' >&2
  rollback_index=$JOURNAL_COUNT
  rollback_failed=0
  while [ "$rollback_index" -gt 0 ]; do
    record_name=$(printf '%08d' "$rollback_index")
    [ -f "$JOURNAL_DIR/$record_name.path" ] || { rollback_index=$((rollback_index - 1)); continue; }
    restore_path=$(cat "$JOURNAL_DIR/$record_name.path")
    if [ -f "$JOURNAL_DIR/$record_name.existed" ]; then
      restore_tmp=$(mktemp "$restore_path.rollback.XXXXXX") || { rollback_failed=1; rollback_index=$((rollback_index - 1)); continue; }
      if cp -p "$JOURNAL_DIR/$record_name.data" "$restore_tmp"; then
        mv -f "$restore_tmp" "$restore_path" || rollback_failed=1
      else
        rm -f "$restore_tmp"
        rollback_failed=1
      fi
    else
      rm -f "$restore_path" || rollback_failed=1
    fi
    rollback_index=$((rollback_index - 1))
  done
  if [ "$rollback_failed" -eq 0 ]; then
    say 'откат завершён; резервные копии сохранены.' >&2
  else
    say 'откат выполнен не полностью; проверьте целевые файлы и журнал резервных копий.' >&2
  fi
}

cleanup() {
  exit_status=$?
  trap - 0 HUP INT TERM
  if [ "$exit_status" -ne 0 ] && [ "$CONFIG_STARTED" -eq 1 ]; then rollback; fi
  [ -z "$JOURNAL_DIR" ] || rm -rf "$JOURNAL_DIR"
  exit "$exit_status"
}

trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

detect_platform
has zsh || fail 'zsh не установлен. Установите zsh вручную и повторите запуск; установщик zsh не устанавливает.'
if [ -L "$ZSHRC" ]; then fail "$ZSHRC является симлинком; он не изменён."; fi
install_dependencies
install_antidote

mkdir -p "$CONFIG_HOME" "$PROJECT_DIR"
JOURNAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/customize-zsh-journal.XXXXXX") || fail 'не удалось создать журнал отката.'
trap cleanup 0
CONFIG_STARTED=1

bundle_tmp=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-antidote.XXXXXX") || fail 'не удалось создать временный bundle плагинов.'
if ! zsh -c '
  source "$1/antidote.zsh" || exit 1
  antidote bundle < "$2"
' customize-zsh "$ANTIDOTE_DIR" "$SCRIPT_DIR/config/zsh/.zsh_plugins.txt" > "$bundle_tmp"; then
  rm -f "$bundle_tmp"
  fail 'не удалось собрать статический bundle Antidote.'
fi

for config_name in .zsh_plugins.txt rc.zsh options.zsh history.zsh completion.zsh tools.zsh plugins.zsh; do
  copy_managed "$SCRIPT_DIR/config/zsh/$config_name" "$ZSH_CONFIG_DIR/$config_name" "zsh/$config_name"
done

local_target=$ZSH_CONFIG_DIR/local.zsh
if [ ! -e "$local_target" ]; then
  copy_managed "$SCRIPT_DIR/config/zsh/local.zsh" "$local_target" zsh/local.zsh
fi

copy_managed "$bundle_tmp" "$ZSH_CONFIG_DIR/antidote_plugins.zsh" zsh/antidote_plugins.zsh
copy_managed "$SCRIPT_DIR/config/starship.toml" "$CONFIG_HOME/starship.toml" starship.toml
copy_managed "$SCRIPT_DIR/config/starship-compact.toml" "$PROJECT_DIR/starship-compact.toml" starship-compact.toml
rm -f "$bundle_tmp"
copy_managed "$SCRIPT_DIR/config/vim/vimrc" "$HOME/.vimrc" vimrc
replace_zshrc_block
install_vim_plugins

say 'установка завершена.'
say "конфигурация zsh: $ZSH_CONFIG_DIR"
say "конфигурация Vim: $HOME/.vimrc"
say "конфигурация Starship: $CONFIG_HOME/starship.toml"
say "резервные копии: $BACKUP_DIR"
say 'откройте новую сессию zsh или выполните: source ~/.zshrc'
