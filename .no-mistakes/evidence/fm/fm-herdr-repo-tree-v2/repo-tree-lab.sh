#!/usr/bin/env bash
# Evidence driver: one throwaway fm-lab-* Herdr session (via bin/fm-herdr-lab.sh)
# plus one marked disposable lab home (via bin/fm-lab-home.sh). Drives the real
# fm-spawn.sh / fm-teardown.sh from the gate worktree, records Herdr's own
# workspace / worktree-group state, Treehouse lease state, and the exact Herdr
# calls, then tears everything down in the same run.
set -u
ROOT=/Users/minh.ngo/.no-mistakes/worktrees/45116ebf5320/01M47S8SPJ0SEW1YWF2RRGGERP
EV=/Users/minh.ngo/.no-mistakes/evidence/01M47S8SPJ0SEW1YWF2RRGGERP/repo-tree-lab
HELPER=$ROOT/bin/fm-herdr-lab.sh
mkdir -p "$EV"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

REAL_HERDR=$(command -v herdr)
REAL_PATH=$PATH
LABSESS=$("$HELPER" name repo-tree-ev)
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab home create failed"; exit 1; }
FAKEBIN=$LAB/fakebin
CALLS=$EV/herdr-calls.tsv
: > "$CALLS"
mkdir -p "$FAKEBIN"
export LABSESS HELPER REAL_HERDR REAL_PATH CALLS

# Route every adapter call through the lab helper (which appends the lab
# session itself); only the session-independent version read goes straight to
# the real binary with the explicit lab session, exactly like the e2e suite.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
( IFS=$'\t'; printf '%s\n' "$*" ) >> "$CALLS"
args=("$@"); n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$LABSESS" ]; then
  unset "args[$((n-1))]" "args[$((n-2))]"
fi
set -- "${args[@]}"
if [ "${1:-}" = --version ]; then exec env PATH="$REAL_PATH" "$REAL_HERDR" "$@" --session "$LABSESS"; fi
exec env PATH="$REAL_PATH" "$HELPER" run "$LABSESS" "$@"
SH
chmod +x "$FAKEBIN/herdr"

LAB_READY=0
WORKTREES=""
cleanup() {
  local wt
  for wt in $WORKTREES; do [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1 || true; done
  if [ "$LAB_READY" = 1 ]; then
    "$HELPER" teardown "$LABSESS" > "$EV/lab-teardown.txt" 2>&1
    echo "lab teardown exit=$?" >> "$EV/lab-teardown.txt"
  fi
  rm -rf "$LAB"
  echo "cleanup done (lab home removed: $([ -e "$LAB" ] && echo no || echo yes))"
}
trap cleanup EXIT

"$HELPER" provision "$LABSESS" || { echo "provision failed"; exit 1; }
LAB_READY=1
echo "lab session: $LABSESS  lab home: $LAB" | tee "$EV/lab-identity.txt"
herdr --version >> "$EV/lab-identity.txt" 2>&1

lab() { "$HELPER" run "$LABSESS" "$@"; }
make_project() {
  local dir=$1
  mkdir -p "$dir"; git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}
brief() {
  mkdir -p "$LAB/data/$1"
  printf '# Task\n## Captain'"'"'s intent\nRepo-tree evidence fixture %s.\n\n## Firstmate spec\nIdle.\n' "$1" > "$LAB/data/$1/brief.md"
}
spawn() {  # <id> <project>
  PATH="$FAKEBIN:$REAL_PATH" HERDR_SESSION="$LABSESS" FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$1" "$2" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr \
    > "$EV/spawn-$1.out" 2> "$EV/spawn-$1.err"
  local s=$?
  echo "spawn $1 exit=$s"
  local wt; wt=$(grep '^worktree=' "$LAB/state/$1.meta" 2>/dev/null | cut -d= -f2-)
  [ -z "$wt" ] || WORKTREES="$WORKTREES $wt"
  return $s
}
teardown() {
  PATH="$FAKEBIN:$REAL_PATH" HERDR_SESSION="$LABSESS" FM_HOME="$LAB" \
    "$ROOT/bin/fm-teardown.sh" "$1" --force > "$EV/teardown-$1.out" 2> "$EV/teardown-$1.err"
  echo "teardown $1 exit=$?"
}
focused() { lab workspace list | jq -r '[.result.workspaces[] | select(.focused)] | map(.workspace_id + "/" + .active_tab_id) | join(",")'; }
sidebar() {  # derived from Herdr's own workspace list order + worktree provenance
  lab workspace list | jq -r '
    .result.workspaces[]
    | (if (.worktree.is_linked_worktree // false) then "    ├─ " else "" end)
      + .label
      + "   [" + .workspace_id
      + (if (.worktree.is_linked_worktree // false) then " linked-child of repo_root=" + (.worktree.repo_root | split("/") | last) else "" end)
      + "]"'
}
treehouse_status() { for p in alpha beta; do echo "== treehouse status ($p)"; (cd "$LAB/projects/$p" && treehouse status 2>&1); done; }

make_project "$LAB/projects/alpha"
make_project "$LAB/projects/beta"
touch "$LAB/state/.last-watcher-beat"
for t in anchor alpha-1 alpha-2 beta-1; do brief "$t"; done

# 1. Flat anchor (opted out) establishes this home's firstmate workspace.
printf 'off\n' > "$LAB/config/herdr-presentation-spaces"
spawn anchor "$LAB/projects/alpha" || exit 1
rm -f "$LAB/config/herdr-presentation-spaces"   # default-on from here
{ echo "## before grouped spawns"; sidebar; } > "$EV/sidebar-0-before.txt"

FOCUS_BEFORE=$(focused)
START=$(wc -l < "$CALLS")
spawn alpha-1 "$LAB/projects/alpha" || exit 1
spawn alpha-2 "$LAB/projects/alpha" || exit 1
spawn beta-1  "$LAB/projects/beta"  || exit 1
FOCUS_AFTER=$(focused)
sed -n "$((START+1)),\$p" "$CALLS" | grep -E $'^(workspace\t(create|rename|close|focus|move)|worktree\topen|tab\t(close|focus)|pane\tclose)' > "$EV/grouped-spawn-mutation-calls.tsv"

{ echo "## after spawning alpha-1, alpha-2 (repo alpha) and beta-1 (repo beta)"; sidebar; } > "$EV/sidebar-1-grouped.txt"
lab workspace list > "$EV/workspace-list-grouped.json"
lab api snapshot > "$EV/api-snapshot-grouped.json" 2>&1
for label in alpha beta; do
  id=$(jq -r --arg l "$label" '[.result.workspaces[] | select(.label == $l)] | if length == 1 then .[0].workspace_id else empty end' "$EV/workspace-list-grouped.json")
  echo "repo parent '$label' => ${id:-MISSING}"
  [ -z "$id" ] || lab worktree list --workspace "$id" > "$EV/worktree-group-$label.json"
done
for t in alpha-1 alpha-2 beta-1; do
  ws=$(grep '^herdr_workspace_id=' "$LAB/state/$t.meta" | cut -d= -f2-)
  wt=$(grep '^worktree=' "$LAB/state/$t.meta" | cut -d= -f2-)
  echo "$t ws=$ws wt=$wt"
  lab workspace get "$ws" | jq '{label: .result.workspace.label, worktree: .result.workspace.worktree}' > "$EV/task-$t-workspace.json"
done
treehouse_status > "$EV/treehouse-status-grouped.txt"
{ echo "focus before grouped spawns: $FOCUS_BEFORE"; echo "focus after grouped spawns:  $FOCUS_AFTER"; } > "$EV/focus.txt"

# 2. Teardown every grouped task; the repo parents must persist.
START=$(wc -l < "$CALLS")
for t in alpha-1 alpha-2 beta-1; do teardown "$t"; done
FOCUS_AFTER_TD=$(focused)
sed -n "$((START+1)),\$p" "$CALLS" | grep -E $'^(workspace\t(create|rename|close|focus|move)|worktree\t(open|remove)|tab\t(close|focus)|pane\tclose)' > "$EV/teardown-mutation-calls.tsv"
echo "focus after teardowns:       $FOCUS_AFTER_TD" >> "$EV/focus.txt"
{ echo "## after tearing down alpha-1, alpha-2, beta-1"; sidebar; } > "$EV/sidebar-2-after-teardown.txt"
lab workspace list > "$EV/workspace-list-after-teardown.json"
treehouse_status > "$EV/treehouse-status-after-teardown.txt"
ls "$LAB/state" > "$EV/state-after-teardown.txt"


# 3. Probe for the e2e's one failure (unchanged recovery code): does Herdr keep a
# reported agent on a plain-shell pane long enough for agent get to see it?
P=$(lab workspace create --cwd "$LAB/projects/beta" --label probe-report-agent --no-focus)
PANE=$(printf '%s' "$P" | jq -r '.result.root_pane.pane_id')
{ lab pane report-agent "$PANE" --source fm-probe --agent test-agent --state idle; echo "report exit=$?"
  echo "agent get immediately:"; lab agent get "$PANE" 2>&1
  sleep 2; echo "agent get after 2s:"; lab agent get "$PANE" 2>&1; } > "$EV/probe-report-agent.txt" 2>&1

teardown anchor
echo "driver done"
