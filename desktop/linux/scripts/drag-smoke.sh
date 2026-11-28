#!/bin/sh
# Run 6 of smoke-test.sh (sourced; uses its start_app, wait_for, keys, typeline, shot, fail): drags with the mouse,
# as a person does (xdotool presses, moves in steps and lets go): a pane's grip onto the right half of another (A|B
# becomes B|A, the dragged pane on the right), Escape cancels, the centre swaps, Ctrl+Shift+Alt drags from anywhere
# in a pane, a pane onto the tab strip becomes a tab, a tab slides along the strip, a tab let go outside every
# window opens a window of its own. Positions come from the app's test state ("dragPoints").

points() { sed -n 's/.*"dragPoints":"\([^"]*\)".*/\1/p' "$STATE"; }
# pane_at <pane 1-based> <field: 1 gripX 2 gripY 3 x 4 y 5 width 6 height>, in screen pixels.
pane_at() {
    v="$(points | cut -d'|' -f1 | cut -d';' -f"$1" | cut -d, -f"$2")"
    case $2 in 1|3) echo $((v + WX)) ;; 2|4) echo $((v + WY)) ;; *) echo "$v" ;; esac
}
# tab_at <tab 1-based> <1 x | 2 y>
tab_at() {
    v="$(points | cut -d'|' -f2 | cut -d';' -f"$1" | cut -d, -f"$2")"
    case $2 in 1) echo $((v + WX)) ;; *) echo $((v + WY)) ;; esac
}
window_origin() {
    wid="$(xdotool search --onlyvisible --name 'rSshTerm$' | head -1)"
    eval "$(xdotool getwindowgeometry --shell "$wid")"
    WX=$X WY=$Y WW=$WIDTH WH=$HEIGHT
}
# drag_shot <name>: the window as it looks mid-drag (the snapshot, the dimmed source, the highlight or the gap).
drag_shot() {
    sleep 0.3
    import -window root -crop "${WW}x${WH}+${WX}+${WY}" +repage "$SHOTS/$1.png" && echo "screenshot: $1.png"
}
# press_and_move x1 y1 x2 y2 [modifiers]: press at (x1, y1) and move to (x2, y2) in 16 steps, still pressed.
press_and_move() {
    xdotool mousemove "$1" "$2"
    sleep 0.2
    if [ -n "${5:-}" ]; then xdotool keydown "$5"; fi
    xdotool mousedown 1
    sleep 0.1
    i=1
    while [ $i -le 16 ]; do
        xdotool mousemove $(($1 + ($3 - $1) * i / 16)) $(($2 + ($4 - $2) * i / 16))
        sleep "${DRAG_STEP:-0.03}" # slower for a demo clip
        i=$((i + 1))
    done
    sleep 0.4
}
let_go() {
    xdotool mouseup 1
    if [ -n "${1:-}" ]; then xdotool keyup "$1"; fi
    sleep 0.6
}

echo "== run 6: drag and drop with the mouse (snapshot, highlight, zones, tab strip, out of the window)"
rm -f "$XDG_STATE_HOME/rssh/session.json" # one fresh local tab, not run 5's windows
start_app
window_origin
typeline "PS1='\$ '"
typeline 'echo pane-$((10+1))'
keys ctrl+shift+e
wait_for "split for the drags" '"panes":\[2\]'
typeline "PS1='\$ '"
typeline 'echo pane-$((20+2))'
wait_for "A | B" '"texts":\["[^"]*pane-11[^"]*","[^"]*pane-22'
sleep 0.5

# A's grip onto the right half of B: B | A.
press_and_move "$(pane_at 1 1)" "$(pane_at 1 2)" $(($(pane_at 2 3) + $(pane_at 2 5) - 20)) $(($(pane_at 2 4) + $(pane_at 2 6) / 2))
wait_for "the drag is on" '"dragging":true'
drag_shot drag-right-half
let_go
wait_for "A dropped on B's right half ends on the right: B | A" '"texts":\["[^"]*pane-22[^"]*","[^"]*pane-11'
wait_for "the drag ended" '"dragging":false'

# Escape while dragging: nothing changes.
press_and_move "$(pane_at 1 1)" "$(pane_at 1 2)" $(($(pane_at 2 3) + 20)) $(($(pane_at 2 4) + $(pane_at 2 6) / 2))
xdotool key Escape
sleep 0.3
let_go
wait_for "Escape cancelled the drag" '"dragging":false'
wait_for "and left B | A as it was" '"texts":\["[^"]*pane-22[^"]*","[^"]*pane-11'

# The centre swaps.
press_and_move "$(pane_at 1 1)" "$(pane_at 1 2)" $(($(pane_at 2 3) + $(pane_at 2 5) / 2)) $(($(pane_at 2 4) + $(pane_at 2 6) / 2))
drag_shot drag-centre-swap
let_go
wait_for "the centre swapped them: A | B" '"texts":\["[^"]*pane-11[^"]*","[^"]*pane-22'

# Ctrl+Shift+Alt: drag from anywhere in a pane (here A's middle onto B's right half).
press_and_move $(($(pane_at 1 3) + $(pane_at 1 5) / 2)) $(($(pane_at 1 4) + $(pane_at 1 6) / 2)) \
    $(($(pane_at 2 3) + $(pane_at 2 5) - 20)) $(($(pane_at 2 4) + $(pane_at 2 6) / 2)) ctrl+shift+alt
let_go ctrl+shift+alt
wait_for "Ctrl+Shift+Alt dragged A from its middle: B | A" '"texts":\["[^"]*pane-22[^"]*","[^"]*pane-11'

# A pane onto the tab strip, right of the only tab: a tab of its own.
press_and_move "$(pane_at 2 1)" "$(pane_at 2 2)" $(($(tab_at 1 1) + 150)) "$(tab_at 1 2)"
drag_shot drag-tab-strip
let_go
wait_for "the pane on the strip became a second tab" '"panes":\[1,1\]'
wait_for "selected, holding A" '"selected":1'
wait_for "its shell kept its text" '"texts":\["[^"]*pane-11'

sleep 0.7 # fresh positions in the test state
# The second tab along the strip before the first: it slides there and stays selected.
press_and_move "$(tab_at 2 1)" "$(tab_at 2 2)" $(($(tab_at 1 1) - 60)) "$(tab_at 1 2)"
let_go
wait_for "the tab slid to the front" '"selected":0'
wait_for "with A in it" '"texts":\["[^"]*pane-11'

sleep 0.7
# A lone pane's grip over the strip: its picture and the pane (dimmed) both keep their text.
press_and_move "$(pane_at 1 1)" "$(pane_at 1 2)" $(($(tab_at 2 1) + 100)) "$(tab_at 2 2)"
xdotool key Escape
let_go
wait_for "Escape left the tabs as they were" '"panes":\[1,1\]'
sleep 0.7
# The tab let go outside every window: a window of its own.
press_and_move "$(tab_at 1 1)" "$(tab_at 1 2)" 1240 780
let_go
wait_for "the tab dragged out opened a second window" '"windowCount":2'
kill "$APP"; wait "$APP" 2>/dev/null || true
