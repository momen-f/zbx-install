#!/usr/bin/env bats
setup() {
  export SRC="$BATS_TEST_DIRNAME/../../src/lib"
  export STATE_FILE="$BATS_TEST_TMPDIR/state"
}

@test "resume metadata is private data, preserves credentials, and never executes shell text" {
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh";
    PLAN_ZBX_VERSION=7.0 ZBX_DB_PASSWORD="quoted\"secret" ZBX_ADMIN_PASSWORD="\$(touch /tmp/zbx-resume-must-not-execute)";
    resume_plan_save; ZBX_DB_PASSWORD="" ZBX_ADMIN_PASSWORD="";
    resume_plan_restore; [[ "$ZBX_DB_PASSWORD" == "quoted\"secret" && "$ZBX_ADMIN_PASSWORD" == \$\(* && "$ZBX_RESUMING" == 1 ]]'
  [ "$status" -eq 0 ]
  [ -n "$(find "$STATE_FILE.plan" -perm 600)" ]
  [ ! -e /tmp/zbx-resume-must-not-execute ]
}

@test "resume refuses changed credentials, insecure permissions, and legacy progress" {
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh"; core_color_init; LOG_FILE=/dev/null;
    ZBX_DB_PASSWORD=old ZBX_ADMIN_PASSWORD=""; resume_plan_save; ZBX_DB_PASSWORD=new; resume_plan_restore'
  [ "$status" -eq 3 ]
  chmod 644 "$STATE_FILE.plan"
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh"; core_color_init; LOG_FILE=/dev/null;
    ZBX_DB_PASSWORD="" ZBX_ADMIN_PASSWORD=""; resume_plan_restore'
  [ "$status" -eq 3 ]
  rm "$STATE_FILE.plan"
  printf 'db=done\n' >"$STATE_FILE"
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh"; core_color_init; LOG_FILE=/dev/null; resume_plan_restore'
  [ "$status" -eq 3 ]
}

@test "resume rejects truncated metadata and symlinks; fresh state clears its secrets" {
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh";
    ZBX_DB_PASSWORD=secret ZBX_ADMIN_PASSWORD=""; resume_plan_save'
  [ "$status" -eq 0 ]
  mv "$STATE_FILE.plan" "$STATE_FILE.saved"
  ln -s "$STATE_FILE.saved" "$STATE_FILE.plan"
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh"; core_color_init; LOG_FILE=/dev/null; resume_plan_restore'
  [ "$status" -eq 3 ]
  rm "$STATE_FILE.plan"
  printf 'zbx-resume-1\0truncated' > "$STATE_FILE.plan"
  chmod 600 "$STATE_FILE.plan"
  run bash -c 'source "$SRC/core.sh"; source "$SRC/resume.sh"; core_color_init; LOG_FILE=/dev/null; resume_plan_restore'
  [ "$status" -eq 3 ]
  run bash -c 'source "$SRC/core.sh"; core_state_clear'
  [ "$status" -eq 0 ]
  [ ! -e "$STATE_FILE.plan" ]
}
