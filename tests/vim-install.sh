#!/bin/sh
set -eu
project_dir=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/customize-vim-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
awk '/^trap '\''exit 129'\'' HUP$/ { exit } { print }' "$project_dir/install.sh" > "$test_dir/functions.sh"
awk 'start { print } /^detect_platform$/ { start=1; print }' "$project_dir/install.sh" > "$test_dir/main.sh"
cat > "$test_dir/runner.sh" <<'RUNNER'
#!/bin/sh
set -eu
. "$1/functions.sh"
SCRIPT_DIR=$2
detect_platform() { :; }
install_dependencies() { :; }
install_antidote() { mkdir -p "$ANTIDOTE_DIR"; printf 'antidote() { :; }\n' > "$ANTIDOTE_DIR/antidote.zsh"; }
install_vim_plugins() { :; }
. "$1/main.sh"
RUNNER
mkdir -p "$test_dir/home"
export HOME="$test_dir/home" XDG_CONFIG_HOME="$test_dir/home/.config"
printf 'original vim config\n' > "$HOME/.vimrc"
cp "$HOME/.vimrc" "$test_dir/original"
sh "$test_dir/runner.sh" "$test_dir" "$project_dir"
[ -f "$project_dir/config/vim/vimrc" ] || { printf 'Vim config missing\n' >&2; exit 1; }
cmp "$project_dir/config/vim/vimrc" "$HOME/.vimrc"
sh "$test_dir/runner.sh" "$test_dir" "$project_dir"
sh "$project_dir/uninstall.sh"
cmp "$test_dir/original" "$HOME/.vimrc"
printf 'Vim install/reinstall/restore: passed\n'

# Конфиг должен загружаться и до установки плагинов, без обращения к сети.
mkdir -p "$test_dir/clean-home"
HOME="$test_dir/clean-home" vim -n -es -i NONE -u "$project_dir/config/vim/vimrc" -c 'qa!'
printf 'Vim startup without plugins: passed\n'
