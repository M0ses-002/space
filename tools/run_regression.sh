#!/usr/bin/env bash
# 全量回归：每个测试用独立隔离 APPDATA（满足各测试自身的路径关键字要求），逐个跑并汇总。
# 用法：bash tools/run_regression.sh [测试名...]
set -u

GODOT="/d/Godot/Godot_v4.7-stable_win64.exe/Godot_v4.7-stable_win64_console.exe"
PROJ="/d/Godot/Project/space"
ROAMING="C:/Users/Moses02/AppData/Roaming"

# 各测试要求的隔离目录关键字（测试内部会断言 user:// 路径包含它）
appdata_for() {
  case "$1" in
    quest_system)    echo "$ROAMING/space-quest-core-regress/$1" ;;
    autopilot)       echo "$ROAMING/space-autopilot-regress/$1" ;;
    orbit_tutorial)  echo "$ROAMING/space-orbit-test-regress/$1" ;;
    dialogue_task)   echo "$ROAMING/space-dialogue-architect-test-regress/$1" ;;
    dialogue_skip)   echo "$ROAMING/space-dialogue-skip-regress/$1" ;;
    cg)              echo "$ROAMING/space-cg-test-regress/$1" ;;
    capture_net)     echo "$ROAMING/space-capture-net-test-regress/$1" ;;
    equipment_unlock) echo "$ROAMING/space-equipment-unlock-regress/$1" ;;
    equipment_remove) echo "$ROAMING/space-equipment-remove-regress/$1" ;;
    rollback)        echo "$ROAMING/space-rollback-regress/$1" ;;
    quest_return)    echo "$ROAMING/space-quest-return-regress/$1" ;;
    story_dialogue)  echo "$ROAMING/space-story-dialogue-regress/$1" ;;
    autosave_checkpoint) echo "$ROAMING/space-autosave-test-regress/$1" ;;
    target_trajectory) echo "$ROAMING/space-orbit-trajectory-regress/$1" ;;
    captain_manual)  echo "$ROAMING/space-manual-test-regress/$1" ;;
    tutorial)        echo "$ROAMING/space-tutorial-test-regress/$1" ;;
    tutorial_confirmation) echo "$ROAMING/space-confirm-test-regress/$1" ;;
    tutorial_pause)  echo "$ROAMING/space-tutorial-pause-test-regress/$1" ;;
    tutorial_confirm_review) echo "$ROAMING/space-confirm-review-regress/$1" ;;
    tutorial_pause_review) echo "$ROAMING/space-tutorial-test-pause-review-regress/$1" ;;
    tutorial_robustness) echo "$ROAMING/space-tutorial-robust-regress/$1" ;;
    main_menu|main_menu_integration) echo "$ROAMING/space-menu-test-regress/$1" ;;
    *)               echo "$ROAMING/space-quest-core-regress/$1" ;;
  esac
}

ALL_TESTS=(
  texture_style space_objects space_objects_extra debris_mass
  map_loader map_fallback map_integration
  save_roundtrip star_map_visual star_map fleet_selection thrust_dial flight_ui
  space_object_selection camera_pan hover_orbit_speed multi_gravity orbit_control
  target_trajectory
  mining cargo_physics circular_velocity voyage_cycle
  port_people port_session port_flow port_visual shipyard capture_net
  equipment_unlock equipment_remove rollback
  autosave_checkpoint
  quest_system quest_return story_dialogue autopilot orbit_tutorial dialogue_task dialogue_skip cg
  flat_nuclear_city city_docking
  tutorial tutorial_confirmation tutorial_pause
  tutorial_confirm_review tutorial_pause_review
  pause_menu panel_drag_lifecycle ui_click_sound captain_manual
  background_music main_menu main_menu_integration
)

if [ "$#" -gt 0 ]; then TESTS=("$@"); else TESTS=("${ALL_TESTS[@]}"); fi

OUT="/tmp/space_regression"
mkdir -p "$OUT"
PASS=(); FAIL=()

for t in "${TESTS[@]}"; do
  f="$PROJ/tests/${t}_test.gd"
  if [ ! -f "$f" ]; then echo "SKIP  $t (缺测试文件)"; FAIL+=("$t:MISSING"); continue; fi
  APPDIR="$(appdata_for "$t")"
  rm -rf "$APPDIR" 2>/dev/null
  # Windows 上若上一个进程还持有句柄，rm 可能留下文件；强制清空后再建目录
  if [ -d "$APPDIR" ] && [ -n "$(ls -A "$APPDIR" 2>/dev/null)" ]; then
    echo "WARN  隔离目录未清空，二次清理：$APPDIR"
    find "$APPDIR" -mindepth 1 -delete 2>/dev/null || true
  fi
  mkdir -p "$APPDIR"
  export APPDATA="$APPDIR"
  export SPACE_MENU_TEST_APPDATA="$APPDIR"
  log="$OUT/$t.log"
  timeout 300 "$GODOT" --headless --path "$PROJ" --script "res://tests/${t}_test.gd" >"$log" 2>&1
  code=$?
  summary=$(grep -aiE "(PASS|FAIL)" "$log" | grep -aviE "WARNING|resources still|ObjectDB" | tail -2 | tr '\n' ' ')
  # 引擎退出时的 "resources still in use" 属已知噪声，不计为失败
  real_errors=$(grep -aE "ERROR:" "$log" | grep -avE "resources still in use" | wc -l)
  if [ "$code" -eq 0 ] && [ "$real_errors" -eq 0 ] && ! echo "$summary" | grep -qi ": FAIL"; then
    echo "PASS  $t  | $summary"; PASS+=("$t")
  else
    echo "FAIL  $t  (exit=$code errs=$real_errors) | $summary"; FAIL+=("$t")
  fi
done

echo "=============================================="
echo "通过 ${#PASS[@]} / 失败 ${#FAIL[@]}"
[ "${#FAIL[@]}" -gt 0 ] && { printf '失败项：%s\n' "${FAIL[*]}"; exit 1; }
exit 0
