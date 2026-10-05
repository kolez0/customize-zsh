#!/bin/sh
set -eu

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
PROJECT_DIR=$CONFIG_HOME/customize-zsh
ZSH_CONFIG_DIR=$PROJECT_DIR/zsh
OWNERSHIP_DIR=$PROJECT_DIR/ownership
MANIFEST=$PROJECT_DIR/install-manifest
ZSHRC=${ZDOTDIR:-$HOME}/.zshrc

say() { printf '%s\n' "customize-zsh: $*"; }
fail() { printf '%s\n' "customize-zsh: ошибка: $*" >&2; exit 1; }

target_for() {
  case "$1" in
    vimrc) TARGET=$HOME/.vimrc ;;
    vim-plug)
      [ ! -L "$HOME/.vim" ] && [ ! -L "$HOME/.vim/autoload" ] || fail 'каталог Vim является симлинком; остановлено без изменений.'
      TARGET=$HOME/.vim/autoload/plug.vim
      ;;
    starship.toml) TARGET=$CONFIG_HOME/starship.toml ;;
    starship-compact.toml) TARGET=$PROJECT_DIR/starship-compact.toml ;;
    zsh/rc.zsh|zsh/options.zsh|zsh/history.zsh|zsh/completion.zsh|zsh/tools.zsh|zsh/plugins.zsh|zsh/.zsh_plugins.txt|zsh/local.zsh|zsh/antidote_plugins.zsh)
      TARGET=$ZSH_CONFIG_DIR/${1#zsh/}
      ;;
    *) fail "неизвестная цель в манифесте: '$1'; остановлено без удаления." ;;
  esac
}

validate_backup_path() {
  backup_entry=$1
  backup_path=$2
  backup_prefix=$PROJECT_DIR/backups/$backup_entry.
  case "$backup_path" in
    "$backup_prefix"*) backup_suffix=${backup_path#"$backup_prefix"} ;;
    *) fail "путь резервной копии для $backup_entry недопустим; остановлено без изменений." ;;
  esac
  case "$backup_suffix" in
    ''|*/*) fail "путь резервной копии для $backup_entry содержит недопустимые компоненты; остановлено без изменений." ;;
  esac
  [ ! -L "$backup_path" ] && [ -f "$backup_path" ] || fail "резервная копия для $backup_entry не найдена или является симлинком: $backup_path"
}

validate_state() {
  entry=$1
  target_for "$entry"
  case "$entry" in
    zsh/*)
      [ ! -L "$OWNERSHIP_DIR/zsh" ] || fail 'вложенный каталог записей владения является симлинком; остановлено без изменений.'
      [ ! -L "$PROJECT_DIR/backups/zsh" ] || fail 'вложенный каталог резервных копий является симлинком; остановлено без изменений.'
      ;;
  esac
  [ ! -L "$PROJECT_DIR/backups" ] || fail 'каталог резервных копий является симлинком; остановлено без изменений.'
  state_file=$OWNERSHIP_DIR/$entry
  [ ! -L "$state_file" ] || fail "запись владения для $entry является симлинком; остановлено без изменений."
  [ -f "$state_file" ] || fail "для записи манифеста $entry отсутствует состояние владения; остановлено без изменений."
  state=$(cat "$state_file")
  case "$state" in
    created|preexisting) ;;
    backup:*)
      backup=${state#backup:}
      validate_backup_path "$entry" "$backup"
      ;;
    *) fail "неизвестное состояние владения для $entry; остановлено без изменений." ;;
  esac
}

validate_ownership_index() {
  [ ! -L "$OWNERSHIP_DIR" ] || fail 'каталог записей владения является симлинком; остановлено без изменений.'
  [ ! -L "$OWNERSHIP_DIR/zsh" ] || fail 'вложенный каталог записей владения является симлинком; остановлено без изменений.'
  for state_path in "$OWNERSHIP_DIR"/* "$OWNERSHIP_DIR"/.[!.]* "$OWNERSHIP_DIR"/..?* \
    "$OWNERSHIP_DIR/zsh"/* "$OWNERSHIP_DIR/zsh"/.[!.]* "$OWNERSHIP_DIR/zsh"/..?*; do
    [ -e "$state_path" ] || [ -L "$state_path" ] || continue
    if [ -d "$state_path" ]; then
      [ "$state_path" = "$OWNERSHIP_DIR/zsh" ] || fail "неожиданный каталог в журнале владения: $state_path"
      continue
    fi
    [ ! -L "$state_path" ] && [ -f "$state_path" ] || fail "неожиданный объект в журнале владения: $state_path"
    relative_state=${state_path#"$OWNERSHIP_DIR"/}
    target_for "$relative_state"
    grep -F -x -q "$relative_state" "$MANIFEST" || fail "запись владения $relative_state отсутствует в манифесте; остановлено без изменений."
  done
}

remove_zshrc_block() {
  [ ! -L "$ZSHRC" ] || fail "$ZSHRC является симлинком; он не изменён."
  [ -f "$ZSHRC" ] || return 0
  temp_file=$(mktemp "${TMPDIR:-/tmp}/customize-zsh-uninstall-zshrc.XXXXXX") || fail 'не удалось создать временный файл для .zshrc.'
  if ! awk '
    BEGIN { start = "# >>> customize-zsh >>>"; end = "# <<< customize-zsh <<<" }
    $0 == start { if (inside || seen) bad = 1; inside = 1; seen = 1; next }
    $0 == end { if (!inside) bad = 1; inside = 0; next }
    inside { next }
    { print }
    END { if (inside || bad) exit 42 }
  ' "$ZSHRC" > "$temp_file"; then
    rm -f "$temp_file"
    fail 'в ~/.zshrc обнаружены повреждённые или повторные маркеры customize-zsh; другие файлы не изменены.'
  fi
  if cmp -s "$ZSHRC" "$temp_file"; then
    rm -f "$temp_file"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) zshrc_mode=$(stat -f '%Lp' "$ZSHRC") ;;
    *) zshrc_mode=$(stat -c '%a' "$ZSHRC") ;;
  esac
  chmod "$zshrc_mode" "$temp_file"
  mv -f "$temp_file" "$ZSHRC"
  say 'удалён помеченный блок из .zshrc.'
}

restore_target() {
  target_for "$1"
  state_file=$OWNERSHIP_DIR/$1
  [ -f "$state_file" ] || { say "нет записи владения для $1; пропускаю."; return 0; }
  state=$(cat "$state_file")
  case "$state" in
    backup:*)
      backup=${state#backup:}
      validate_backup_path "$1" "$backup"
      mkdir -p "${TARGET%/*}"
      temp_target=$(mktemp "$TARGET.restore.XXXXXX") || fail "не удалось создать временный файл рядом с $TARGET."
      if ! cp -p "$backup" "$temp_target"; then
        rm -f "$temp_target"
        fail "не удалось подготовить восстановление $TARGET."
      fi
      mv -f "$temp_target" "$TARGET"
      say "восстановлен $TARGET из $backup"
      ;;
    created)
      rm -f "$TARGET"
      say "удалён созданный проектом файл $TARGET"
      ;;
    preexisting)
      say "исходный файл $TARGET не менялся и оставлен на месте."
      ;;
    *) fail "неизвестное состояние владения для $1; остановлено." ;;
  esac
  rm -f "$state_file"
}

# Проверить наличие манифеста и все записи до первого изменения файлов.
[ ! -L "$MANIFEST" ] || fail 'манифест является симлинком; остановлено без изменений.'
[ ! -L "$PROJECT_DIR" ] || fail 'каталог проекта является симлинком; остановлено без изменений.'
[ ! -L "$OWNERSHIP_DIR" ] || fail 'каталог записей владения является симлинком; остановлено без изменений.'
[ -f "$MANIFEST" ] || fail 'манифест установки не найден; конфигурация и журнал владения не изменены.'
if ! awk 'NF { if (seen[$0]++) invalid = 1; count++ } END { if (invalid || count == 0) exit 1 }' "$MANIFEST"; then
  fail 'манифест пуст или содержит повторные записи; конфигурация и журнал владения не изменены.'
fi
while IFS= read -r entry || [ -n "$entry" ]; do
  [ -n "$entry" ] || continue
  validate_state "$entry"
  case "$entry" in
    zsh/*) [ ! -L "$ZSH_CONFIG_DIR" ] || fail 'каталог конфигурации zsh является симлинком; остановлено без изменений.' ;;
  esac
  [ ! -L "$TARGET" ] || fail "цель $TARGET является симлинком; остановлено без изменений."
done < "$MANIFEST"
validate_ownership_index

remove_zshrc_block
while IFS= read -r entry || [ -n "$entry" ]; do
  [ -n "$entry" ] || continue
  restore_target "$entry"
done < "$MANIFEST"
rm -f "$MANIFEST"

rmdir "$OWNERSHIP_DIR/zsh" 2>/dev/null || :
rmdir "$OWNERSHIP_DIR" 2>/dev/null || :
rmdir "$ZSH_CONFIG_DIR" 2>/dev/null || :
say "резервные копии сохранены в $PROJECT_DIR/backups"
say 'Antidote и установленные системные утилиты оставлены без изменений.'
say 'удаление конфигурации завершено.'
